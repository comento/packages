import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';

/// 네이티브 드래그 제스쳐를 유지하면서 WebView에 드래그 제스쳐를 전달하도록 하는 클래스.
/// 제스쳐 아레나에서는 오직 하나의 제스쳐만 accept될 수 있고, WebView에서 설정해준
/// gestureRecognizers들은 한 팀을 이뤄 아레나에 입장한다.
/// 때문에 accept된 제스쳐가 하나라도 있으면, WebView가 모든 제스쳐 이벤트를 가져가게 된다.
/// 웹뷰에 있는 스와이퍼 뿐 아니라, 네이티브 스와이프까지 동작하게 하기 위해서는 accept를 하지 않고
/// 제스쳐 아레나와 관계없이 viewController를 이용해서 직접 제스쳐 이벤트를 송신해준다.
/// 이렇게 되면 처음에 제스쳐 이벤트가 중복으로 보내지지만, 웹뷰 쪽에서 네이티브 쪽으로
/// 네이티브 제스쳐를 중지하라는 신호를 보내므로 웹뷰 스와이퍼만 작동하게 된다.
/// swipe가 아닌 tap의 중복 송신을 막기 위해서 일단은 이벤트를 cache하고,
/// drag가 맞다고 판단되는 순간 cache된 이벤트까지 모두 합쳐서 송신한다.
class InitialDragGestureRecognizer extends OneSequenceGestureRecognizer {
  InitialDragGestureRecognizer(this.androidViewController);

  /// 직접 motionEvent를 보내주는 컨트롤러
  AndroidViewController androidViewController;

  /// 드래그 판단 기준
  final double dragDistance = 10.0;

  bool _isDragging = false;
  PointerDownEvent? _initialEvent;

  final Map<int, List<PointerEvent>> cachedEvents = <int, List<PointerEvent>>{};

  @override
  String get debugDescription => throw UnimplementedError();

  /// pointer up 이벤트가 발생했으므로 이전에 저장한 포인터들을 비워준다.
  @override
  void didStopTrackingLastPointer(int pointer) {
    cachedEvents.clear();
  }

  /// 첫 PointerEvent를 저장한다.
  @override
  void addAllowedPointer(PointerDownEvent event) {
    _initialEvent = event;
    super.addAllowedPointer(event);
  }

  @override
  void handleEvent(PointerEvent event) {
    if (!_isDragging) {
      // 드래그인지 판단해서 토글한다.
      _checkIsDragging(event);
    }
    if (_isDragging) {
      // 드래그라고 판단되면, 캐시해놓은 이전 이벤트까지 controller로 보낸다.
      _dispatchCachedEvents(event);
      _dispatchPointerEvent(event);
    } else {
      // 아직 드래그인지 판단이 안되므로 일단 캐싱한다.
      _cacheEvent(event);
    }
    if (event is PointerUpEvent) {
      resolve(GestureDisposition.rejected);
      _isDragging = false;
    } else if (event is PointerCancelEvent) {
      resolve(GestureDisposition.rejected);
      _isDragging = false;
    }
    stopTrackingIfPointerNoLongerDown(event);
  }

  /// 저장해놓은 첫 이벤트와 지금 이벤트의 offset 차이로 drag를 판단한다.
  void _checkIsDragging(PointerEvent currentEvent) {
    if (_initialEvent == null) {
      return;
    }
    final double xDistance =
        (_initialEvent!.position.dx - currentEvent.position.dx).abs();
    final double yDistance =
        (_initialEvent!.position.dy - currentEvent.position.dy).abs();

    _isDragging = xDistance >= dragDistance ||
        yDistance >= dragDistance ||
        xDistance + yDistance >= dragDistance;
  }

  /// 포인터 별로 이벤트를 캐시한다.
  void _cacheEvent(PointerEvent event) {
    if (!cachedEvents.containsKey(event.pointer)) {
      cachedEvents[event.pointer] = <PointerEvent>[];
    }
    cachedEvents[event.pointer]!.add(event);
  }

  /// 캐시해놓은 event가 있다면 모두 dispatch하고 중복을 피하기 위해 지운다.
  void _dispatchCachedEvents(PointerEvent event) {
    if (cachedEvents.containsKey(event.pointer)) {
      cachedEvents.remove(event.pointer)!.forEach(_dispatchPointerEvent);
    }
  }

  /// androidViewController를 이용해 gesture를 accept하지 않고 직접 motionEvent를 보낸다.
  /// 따라서 gestureArena에서 승리한 제스쳐와 함께 중복으로 motionEvent가 가게된다.
  /// webView에서는 javascriptChannel을 통해 스와이프 신호를 보내고, 이에 따라
  /// gestureArena에서 승리한 제스쳐를 disable함으로써 웹뷰의 스와이프만 동작하게 된다.
  Future<void> _dispatchPointerEvent(PointerEvent event) async {
    if (event is PointerHoverEvent) {
      return;
    }
    if (event is PointerDownEvent) {
      _handlePointerDownEvent(event);
    }
    _updatePointerPositions(event);

    final AndroidMotionEvent? androidEvent = _toAndroidMotionEvent(event);

    if (event is PointerUpEvent) {
      _handlePointerUpEvent(event);
    } else if (event is PointerCancelEvent) {
      _handlePointerCancelEvent(event);
    }

    if (androidEvent != null) {
      await androidViewController.sendMotionEvent(androidEvent);
    }
  }

  final Map<int, AndroidPointerCoords> _pointerPositions =
      <int, AndroidPointerCoords>{};
  final Map<int, AndroidPointerProperties> _pointerProperties =
      <int, AndroidPointerProperties>{};
  final Set<int> _usedAndroidPointerIds = <int>{};

  int? _downTimeMillis;

  void _handlePointerDownEvent(PointerDownEvent event) {
    if (_pointerProperties.isEmpty) {
      _downTimeMillis = event.timeStamp.inMilliseconds;
    }
    int androidPointerId = 0;
    while (_usedAndroidPointerIds.contains(androidPointerId)) {
      androidPointerId++;
    }
    _usedAndroidPointerIds.add(androidPointerId);
    _pointerProperties[event.pointer] = _propertiesFor(event, androidPointerId);
  }

  void _updatePointerPositions(PointerEvent event) {
    final Offset position =
        androidViewController.pointTransformer(event.position);
    _pointerPositions[event.pointer] = AndroidPointerCoords(
      orientation: event.orientation,
      pressure: event.pressure,
      size: event.size,
      toolMajor: event.radiusMajor,
      toolMinor: event.radiusMinor,
      touchMajor: event.radiusMajor,
      touchMinor: event.radiusMinor,
      x: position.dx,
      y: position.dy,
    );
  }

  void _remove(int pointer) {
    _pointerPositions.remove(pointer);
    _usedAndroidPointerIds.remove(_pointerProperties[pointer]!.id);
    _pointerProperties.remove(pointer);
    if (_pointerProperties.isEmpty) {
      _downTimeMillis = null;
    }
  }

  void _handlePointerUpEvent(PointerUpEvent event) {
    _remove(event.pointer);
  }

  void _handlePointerCancelEvent(PointerCancelEvent event) {
    _remove(event.pointer);
  }

  AndroidMotionEvent? _toAndroidMotionEvent(PointerEvent event) {
    final List<int> pointers = _pointerPositions.keys.toList();
    final int pointerIdx = pointers.indexOf(event.pointer);
    final int numPointers = pointers.length;
    const int kPointerDataFlagBatched = 1;
    if (event.platformData == kPointerDataFlagBatched ||
        (_isSinglePointerAction(event) && pointerIdx < numPointers - 1)) {
      return null;
    }
    final int action;
    if (event is PointerDownEvent) {
      action = numPointers == 1
          ? AndroidViewController.kActionDown
          : AndroidViewController.pointerAction(
              pointerIdx, AndroidViewController.kActionPointerDown);
    } else if (event is PointerUpEvent) {
      action = numPointers == 1
          ? AndroidViewController.kActionUp
          : AndroidViewController.pointerAction(
              pointerIdx, AndroidViewController.kActionPointerUp);
    } else if (event is PointerMoveEvent) {
      action = AndroidViewController.kActionMove;
    } else if (event is PointerCancelEvent) {
      action = AndroidViewController.kActionCancel;
    } else {
      return null;
    }

    return AndroidMotionEvent(
      downTime: _downTimeMillis!,
      eventTime: event.timeStamp.inMilliseconds,
      action: action,
      pointerCount: _pointerPositions.length,
      pointerProperties: pointers
          .map<AndroidPointerProperties>((int i) => _pointerProperties[i]!)
          .toList(),
      pointerCoords: pointers
          .map<AndroidPointerCoords>((int i) => _pointerPositions[i]!)
          .toList(),
      metaState: 0,
      buttonState: 0,
      xPrecision: 1.0,
      yPrecision: 1.0,
      deviceId: 0,
      edgeFlags: 0,
      source: 0,
      flags: 0,
      motionEventId: event.embedderId,
    );
  }

  AndroidPointerProperties _propertiesFor(PointerEvent event, int pointerId) {
    int toolType = AndroidPointerProperties.kToolTypeUnknown;
    switch (event.kind) {
      case PointerDeviceKind.touch:
        toolType = AndroidPointerProperties.kToolTypeFinger;
        break;
      case PointerDeviceKind.mouse:
        toolType = AndroidPointerProperties.kToolTypeMouse;
        break;
      case PointerDeviceKind.stylus:
        toolType = AndroidPointerProperties.kToolTypeStylus;
        break;
      case PointerDeviceKind.invertedStylus:
        toolType = AndroidPointerProperties.kToolTypeEraser;
        break;
      case PointerDeviceKind.unknown:
        toolType = AndroidPointerProperties.kToolTypeUnknown;
        break;
    }
    return AndroidPointerProperties(id: pointerId, toolType: toolType);
  }

  bool _isSinglePointerAction(PointerEvent event) =>
      event is! PointerDownEvent && event is! PointerUpEvent;
}
