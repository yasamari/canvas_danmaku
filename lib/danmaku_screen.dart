import 'package:canvas_danmaku/danmaku_clock.dart';
import 'package:canvas_danmaku/danmaku_controller.dart';
import 'package:canvas_danmaku/danmaku_store.dart';
import 'package:canvas_danmaku/danmaku_track_assign.dart';
import 'package:canvas_danmaku/models/danmaku_content_item.dart';
import 'package:canvas_danmaku/models/danmaku_item.dart';
import 'package:canvas_danmaku/models/danmaku_option.dart';
import 'package:canvas_danmaku/scroll_danmaku_painter.dart';
import 'package:canvas_danmaku/special_danmaku_painter.dart';
import 'package:canvas_danmaku/static_danmaku_painter.dart';
import 'package:canvas_danmaku/utils/utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// Recently-expired scroll items keep their raster image this long so that
/// small backward seeks repaint instantly instead of re-rasterizing.
const _imageGraceMs = 15000;

/// A danmaku view rendering the visible clock window of a [DanmakuStore].
///
/// Pass the same [clock] and [store] to every view of one session (e.g. the
/// normal video controls and the media_kit fullscreen route, which builds a
/// second subtree from the same `controls` builder) and all of them render
/// the same danmaku at the same position. Omitting both keeps the legacy
/// behavior: the screen owns a private store and clock.
///
/// Positions are absolute functions of `clock.nowMs - birthTick`
/// ([scrollDanmakuX]), never incremental, so a view built later (rotation,
/// fullscreen, seek) lands mid-flight deterministically. Track assignment
/// runs in birth order with [scrollTrackFree]/[staticTrackFree] and a
/// deterministic [massiveFallbackTrack], replacing arrival-timing-dependent
/// occupancy checks and `Random`.
class DanmakuScreen<T> extends StatefulWidget {
  // 创建Screen后返回控制器
  final ValueChanged<DanmakuController<T>> createdController;
  final DanmakuOption option;

  /// Shared session clock. Null creates a screen-owned one.
  final DanmakuClock? clock;

  /// Shared session storage. Null creates a screen-owned one.
  final DanmakuStore<T>? store;

  const DanmakuScreen({
    required this.createdController,
    required this.option,
    super.key,
    this.clock,
    this.store,
  });

  @override
  State<DanmakuScreen<T>> createState() => _DanmakuScreenState<T>();
}

class _DanmakuScreenState<T> extends State<DanmakuScreen<T>>
    with SingleTickerProviderStateMixin {
  /// 视图宽度
  double _viewWidth = 0;
  double _viewHeight = 0;
  double devicePixelRatio = 1;

  /// 弹幕配置
  late final ValueNotifier<DanmakuOption> _optionNotifier;
  DanmakuOption get _option => _optionNotifier.value;

  late DanmakuClock _clock;
  bool _ownsClock = false;
  late DanmakuStore<T> _store;
  bool _ownsStore = false;

  /// 滚动弹幕 alive window (birth order), painted every scroll tick.
  final _scrollAlive = <DanmakuItem<T>>[];

  /// 静态弹幕 alive snapshot; separate notifier preserves the static layer's
  /// independent repaint cadence (no repaint on scroll ticks).
  final _staticDanmakuItems = ListValueNotifier(<DanmakuItem<T>>[]);

  /// Recently expired scroll items whose images are kept for fast seek-back.
  final _grace = <DanmakuItem<T>>[];

  /// Cursors into the birth-sorted store lists; everything before a cursor
  /// has been measured and admitted-or-skipped for the alive window.
  int _scrollCursor = 0;
  int _staticCursor = 0;
  bool _cursorsInit = false;

  /// Per-view scroll track assignment (birth order, deterministic per size).
  final _scrollTrackOf = <DanmakuItem<T>, int>{};
  final _scrollTracks = <List<DanmakuItem<T>>>[];

  /// Per-view static track assignment: latest item per track and type.
  final _staticTrackOf = <DanmakuItem<T>, int>{};
  final _topLast = <DanmakuItem<T>?>[];
  final _bottomLast = <DanmakuItem<T>?>[];

  int _clockVersion = -1;
  int _storeVersion = -1;
  bool _rebuildNeeded = true;

  /// 弹幕高度
  late double _danmakuHeight;

  /// 弹幕轨道数
  late int _trackCount;

  /// 弹幕轨道位置
  List<double> _trackYPositions = const [];

  late final Ticker _ticker;
  late final ValueNotifier<int> _tickNotifier;
  late final ValueNotifier<double> _opacityNotifier;

  /// 运行状态
  bool _running = true;

  @override
  void initState() {
    super.initState();
    _optionNotifier = ValueNotifier(widget.option);
    DmUtils.updateSelfSendPaint(_option.strokeWidth);

    _danmakuHeight = _textPainter.height;

    _ownsClock = widget.clock == null;
    _clock = widget.clock ?? DanmakuClock();
    _ownsStore = widget.store == null;
    _store = widget.store ?? DanmakuStore<T>();
    _clock.addListener(_onClockChanged);
    _store.addListener(_onStoreChanged);
    _clockVersion = _clock.version;
    _storeVersion = _store.version;

    _ticker = createTicker(_tick);
    _tickNotifier = ValueNotifier(0);
    _opacityNotifier = ValueNotifier(_option.opacity);
    _optionNotifier.addListener(_syncOpacity);

    widget.createdController(DanmakuController<T>(
      addDanmaku: _addDanmaku,
      addAll: _addAll,
      seekTo: _seekTo,
      updateOption: _updateOption,
      pause: _pause,
      resume: _resume,
      clear: _clear,
      getOption: () => _option,
      isRunning: () => _running,
      findDanmaku: findDanmaku,
      findSingleDanmaku: findSingleDanmaku,
      getViewWidth: () => _viewWidth,
      getViewHeight: () => _viewHeight,
      scrollDanmaku: _scrollAlive,
      staticDanmaku: _staticDanmakuItems.value,
      specialDanmaku: _store.specialItems,
    ));

    // A fresh view over a pre-filled store (re-enable, second fullscreen
    // view) starts with a stopped ticker; kick it once laid out.
    _requestWake();
  }

  /// Coalesced post-frame wake requests (see [_requestWake]).
  bool _wakeScheduled = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final devicePixelRatio = MediaQuery.devicePixelRatioOf(context);
    if (devicePixelRatio != this.devicePixelRatio) {
      this.devicePixelRatio = devicePixelRatio;
      // Widths are DPR-independent; only GPU textures are rebuilt lazily.
      _store.dropImages();
    }
  }

  int _time = 0;
  void _tick(Duration elapsed) {
    final now = _clock.nowMs;
    if (_viewWidth > 0) {
      if (_rebuildNeeded) {
        _rebuildNeeded = false;
        _rebuildWindows(now);
      } else {
        _advanceWindows(now);
      }
    }
    _tickNotifier.value = now;
    if (_time++ > 10) {
      _time = 0;
      _lazyTick(now);
    }
  }

  TextPainter get _textPainter => TextPainter(
        text: TextSpan(
          text: '弹幕',
          style: TextStyle(
            fontSize: _option.fontSize,
            height: _option.lineHeight,
            fontFamily: _option.fontFamily,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();

  @override
  void dispose() {
    _running = false;
    _ticker.dispose();
    _clock.removeListener(_onClockChanged);
    _store.removeListener(_onStoreChanged);
    if (_ownsClock) _clock.dispose();
    if (_ownsStore) _store.dispose();
    _tickNotifier.dispose();
    _optionNotifier.removeListener(_syncOpacity);
    _opacityNotifier.dispose();
    _optionNotifier.dispose();
    _staticDanmakuItems.dispose();
    super.dispose();
  }

  void _onClockChanged() {
    // seekTo bumps the clock version; setRunning only freezes/resumes.
    if (_clock.version != _clockVersion) {
      _clockVersion = _clock.version;
      _rebuildNeeded = true;
    }
    _requestWake();
  }

  void _onStoreChanged() {
    if (_store.version != _storeVersion) {
      _storeVersion = _store.version;
      _rebuildNeeded = true;
    }
    _requestWake();
  }

  /// Admits the current window and starts the ticker when idle.
  ///
  /// Store writes bypassing the controller (direct `store.add`, used when no
  /// view is built yet) do not start the ticker, so every notification also
  /// requests a wake. Admission itself is deferred to post-frame: store
  /// notifications can fire during builds (another view mounting), and
  /// admitting synchronously would notify paint layers mid-build.
  /// Bursts coalesce into one wake per frame.
  void _requestWake() {
    if (!_running || _ticker.isActive || _wakeScheduled) return;
    _wakeScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _wakeScheduled = false;
      // Tick 中に起動済みならそちらが窓更新を引き受ける。
      if (mounted && !_ticker.isActive) _wakeIfNeeded();
    });
  }

  void _wakeIfNeeded() {
    if (!_running || !mounted || _viewWidth <= 0) return;
    // A frozen clock with nothing to rebuild paints no new frame.
    if (!_rebuildNeeded && !_clock.running) return;
    if (_rebuildNeeded) {
      _rebuildNeeded = false;
      _rebuildWindows(_clock.nowMs);
    } else {
      _advanceWindows(_clock.nowMs);
    }
    if (!_ticker.isActive && _shouldRun(_clock.nowMs)) {
      _ticker.start();
    }
  }

  double get _durationMs => _option.durationInMilliseconds;
  double get _staticDurationMs => _option.staticDurationInMilliseconds;

  /// Upper bound of the scroll transit for window bounding, using the
  /// longest inserted text as a safe width over-approximation
  /// (`length * fontSize >= actual advance` for CJK/latin/emoji).
  double _scrollWindowMs() {
    final maxLen = _store.maxTextLength;
    final estWidth = maxLen * _option.fontSize + _option.strokeWidth;
    final width = _viewWidth + (estWidth > 0 ? estWidth : 0);
    return _durationMs * width / _viewWidth;
  }

  void _initCursors(int now) {
    _scrollCursor = lowerBoundBirth(
      _store.scrollItems,
      (now - _scrollWindowMs()).floor(),
    );
    _staticCursor = lowerBoundBirth(
      _store.staticItems,
      (now - _staticDurationMs).floor(),
    );
    _cursorsInit = true;
  }

  void _rebuildWindows(int now) {
    _scrollAlive.clear();
    _staticDanmakuItems.clear();
    _scrollTrackOf.clear();
    _staticTrackOf.clear();
    for (final track in _scrollTracks) {
      track.clear();
    }
    _topLast.fillRange(0, _topLast.length, null);
    _bottomLast.fillRange(0, _bottomLast.length, null);
    _initCursors(now);
    _advanceWindows(now);
  }

  void _advanceWindows(int now) {
    if (!_cursorsInit) _initCursors(now);
    _advanceScroll(now);
    _advanceStatic(now);
  }

  void _advanceScroll(int now) {
    final items = _store.scrollItems;
    final hideScroll = _option.hideScroll;
    while (_scrollCursor < items.length &&
        items[_scrollCursor].birthTick! <= now) {
      final item = items[_scrollCursor];
      _scrollCursor++;
      item.ensureMeasured(
        _option.fontSize,
        _option.fontWeight,
        _option.strokeWidth,
      );
      _store.reportMeasuredWidth(item.width);
      if (hideScroll) continue;
      final birth = item.birthTick!;
      if (now - birth >=
          scrollTransitMs(
            viewWidth: _viewWidth,
            itemWidth: item.width,
            durationMs: _durationMs,
          )) {
        continue;
      }
      if (_assignScroll(item, birth)) {
        _scrollAlive.add(item);
      }
    }
    // Drop the expired head. Widths vary per item, so expiry is checked
    // exactly per item instead of assuming birth order implies expiry order.
    while (_scrollAlive.isNotEmpty &&
        _scrollExpired(_scrollAlive.first, now)) {
      final item = _scrollAlive.removeAt(0);
      _scrollTrackOf.remove(item);
      _toGrace(item, now);
    }
  }

  bool _scrollExpired(DanmakuItem<T> item, int now) {
    final birth = item.birthTick ?? now;
    return now - birth >=
        scrollTransitMs(
          viewWidth: _viewWidth,
          itemWidth: item.width,
          durationMs: _durationMs,
        );
  }

  void _toGrace(DanmakuItem<T> item, int now) {
    final birth = item.birthTick ?? now;
    if (now - birth - _durationMs <= _imageGraceMs && _grace.length < 300) {
      _grace.add(item);
    } else {
      item.dispose();
    }
  }

  void _advanceStatic(int now) {
    final items = _store.staticItems;
    var changed = false;
    while (_staticCursor < items.length &&
        items[_staticCursor].birthTick! <= now) {
      final item = items[_staticCursor];
      _staticCursor++;
      item.ensureMeasured(
        _option.fontSize,
        _option.fontWeight,
        _option.strokeWidth,
      );
      _store.reportMeasuredWidth(item.width);
      final hidden = switch (item.content.type) {
        DanmakuItemType.top => _option.hideTop,
        DanmakuItemType.bottom => _option.hideBottom,
        _ => true,
      };
      if (hidden) continue;
      final birth = item.birthTick!;
      if (now - birth >= _staticDurationMs) continue;
      if (_assignStatic(item, birth)) {
        _staticDanmakuItems.add(item);
        changed = true;
      }
    }
    final snapshot = _staticDanmakuItems.value;
    var write = 0;
    for (var read = 0; read < snapshot.length; read++) {
      final item = snapshot[read];
      final birth = item.birthTick ?? now;
      if (now - birth >= _staticDurationMs) {
        _staticTrackOf.remove(item);
        item.dispose();
        changed = true;
      } else {
        if (write < read) snapshot[write] = item;
        write++;
      }
    }
    if (write != snapshot.length) {
      snapshot.length = write;
      changed = true;
    }
    if (changed) _staticDanmakuItems.refresh();
  }

  bool _assignScroll(DanmakuItem<T> item, int birth) {
    if (_trackYPositions.isEmpty) return false;
    for (var i = 0; i < _trackYPositions.length; i++) {
      if (_scrollTrackFree(i, birth, item.width)) {
        _placeScroll(item, i);
        return true;
      }
    }
    if (item.content.selfSend) {
      _placeScroll(item, 0);
      return true;
    }
    if (_option.massiveMode) {
      _placeScroll(
        item,
        massiveFallbackTrack(birthTick: birth, trackCount: _trackYPositions.length),
      );
      return true;
    }
    return false;
  }

  bool _scrollTrackFree(int track, int birth, double width) {
    for (final occupant in _scrollTracks[track]) {
      if (!scrollTrackFree(
        viewWidth: _viewWidth,
        durationMs: _durationMs,
        existingBirth: occupant.birthTick!,
        existingWidth: occupant.width,
        newBirth: birth,
        newWidth: width,
      )) {
        return false;
      }
    }
    return true;
  }

  void _placeScroll(DanmakuItem<T> item, int track) {
    _scrollTrackOf[item] = track;
    _scrollTracks[track].add(item);
    item.yPosition = _trackYPositions[track];
  }

  bool _assignStatic(DanmakuItem<T> item, int birth) {
    if (_trackYPositions.isEmpty) return false;
    final isTop = item.content.type == DanmakuItemType.top;
    final last = isTop ? _topLast : _bottomLast;
    for (var i = 0; i < _trackYPositions.length; i++) {
      final y = _trackYPositions[i];
      if (!isTop && _option.safeArea && y <= _danmakuHeight) continue;
      final prev = last[i];
      if (prev != null &&
          !staticTrackFree(
            lastBirth: prev.birthTick!,
            newBirth: birth,
            staticDurationMs: _staticDurationMs,
          )) {
        continue;
      }
      _staticTrackOf[item] = i;
      last[i] = item;
      item.yPosition = y;
      return true;
    }
    return false;
  }

  /// 添加弹幕
  void _addDanmaku(
    DanmakuContentItem<T> content, {
    int? birthTick,
    Object? key,
  }) {
    if (!mounted) return;
    if (_trackYPositions.isEmpty) _calcTracks();
    final birth = birthTick ?? _clock.nowMs;
    switch (content.type) {
      case DanmakuItemType.scroll:
        if (_option.hideScroll) return;
        break;
      case DanmakuItemType.top:
        if (_option.hideTop) return;
        break;
      case DanmakuItemType.bottom:
        if (_option.hideBottom) return;
        break;
      case DanmakuItemType.special:
        if (_option.hideSpecial) return;
        final addedSpecial = _store.addSpecial(
          DanmakuItem<T>(
            width: 0,
            height: 0,
            content: content,
            birthTick: birth,
            image: DmUtils.recordSpecialDanmakuImg(
              content: content as SpecialDanmakuContentItem,
              fontWeight: _option.fontWeight,
              strokeWidth: _option.strokeWidth,
              devicePixelRatio: devicePixelRatio,
              fontFamily: _option.fontFamily,
            ),
          ),
          key: key,
        );
        if (addedSpecial && _running) {
          if (!_ticker.isActive) _ticker.start();
        }
        return;
    }
    final added = _store.add(
      DanmakuItem<T>(
        content: content,
        width: 0,
        height: 0,
        xPosition: _viewWidth,
        birthTick: birth,
      ),
      key: key,
    );
    if (added && _running) {
      if (!_ticker.isActive) _ticker.start();
    }
  }

  /// Bulk insert; entries are merged in birth order in one pass.
  void _addAll(List<DanmakuBatchEntry<T>> entries) {
    if (!mounted) return;
    if (entries.isEmpty) return;
    if (_trackYPositions.isEmpty) _calcTracks();
    final now = _clock.nowMs;
    final accepted = _store.addAll(entries, now);
    if (accepted > 0) {
      // Bulk loads (e.g. a recording's fetched comments) may already
      // contain the current window; admit it without waiting a frame.
      if (_viewWidth > 0) {
        if (_rebuildNeeded) {
          _rebuildNeeded = false;
          _rebuildWindows(now);
        } else {
          _advanceWindows(now);
        }
      }
      if (_running && !_ticker.isActive && _shouldRun(now)) {
        _ticker.start();
      }
    }
  }

  void _seekTo(int tickMs) {
    _clock.seekTo(tickMs);
  }

  /// 暂停
  void _pause() {
    _running = false;
    if (_ticker.isActive) {
      _ticker.stop();
    }
  }

  /// 恢复
  void _resume() {
    _running = true;
    if (!_ticker.isActive) {
      _ticker.start();
    }
    _staticDanmakuItems.refresh();
  }

  /// 清空弹幕
  void _clear() {
    _store.clear();
    // The store notification triggers [_onStoreChanged] -> rebuild; clear
    // per-view state eagerly too so no stale frame paints meanwhile.
    _scrollAlive.clear();
    _staticDanmakuItems.clear();
    _grace.clear();
    _scrollTrackOf.clear();
    _staticTrackOf.clear();
    for (final track in _scrollTracks) {
      track.clear();
    }
    _topLast.fillRange(0, _topLast.length, null);
    _bottomLast.fillRange(0, _bottomLast.length, null);
    if (_ticker.isActive) {
      // SchedulerBinding.instance.addPostFrameCallback(
      //   (_) => _ticker.stop(),
      // );
    } else {
      _tickNotifier.refresh();
    }
  }

  /// 更新弹幕设置
  void _updateOption(DanmakuOption option) {
    final lineHeightChanged = option.lineHeight != _option.lineHeight;
    if (lineHeightChanged) {
      _optionNotifier.value = option;
      _danmakuHeight = _textPainter.height;
      _calcTracks();
      _rebuildNeeded = true;
      return;
    }

    final fontSizeChanged = option.fontSize != _option.fontSize;
    final fontFamilyChanged = option.fontFamily != _option.fontFamily;

    final clearParagraph = fontSizeChanged ||
        fontFamilyChanged ||
        option.fontWeight != _option.fontWeight ||
        option.strokeWidth != _option.strokeWidth;

    /// 清理已经存在的 Paragraph 缓存
    if (clearParagraph) {
      DmUtils.updateSelfSendPaint(option.strokeWidth);
      _store.resetMeasurements();
    }

    final hideTopChanged = option.hideTop != _option.hideTop;
    final hideBottomChanged = option.hideBottom != _option.hideBottom;
    final hideScrollChanged = option.hideScroll != _option.hideScroll;
    final hideSpecialChanged = option.hideSpecial != _option.hideSpecial;
    final durationChanged = option.duration != _option.duration;
    final staticDurationChanged =
        option.staticDuration != _option.staticDuration;
    final massiveModeChanged = option.massiveMode != _option.massiveMode;
    _optionNotifier.value = option;
    if (fontSizeChanged) {
      _danmakuHeight = _textPainter.height;
    }
    final areaChanged = option.area != _option.area;
    final safeAreaChanged = option.safeArea != _option.safeArea;
    if (fontSizeChanged || areaChanged || safeAreaChanged) {
      _calcTracks();
    }

    final layoutChanged = clearParagraph ||
        hideTopChanged ||
        hideBottomChanged ||
        hideScrollChanged ||
        hideSpecialChanged ||
        durationChanged ||
        staticDurationChanged ||
        massiveModeChanged ||
        areaChanged ||
        safeAreaChanged;
    if (layoutChanged) {
      // Widths, tracks and windows depend on the new option; re-derive them
      // deterministically from the retained items.
      _rebuildNeeded = true;
      _tickNotifier.refresh();
      _staticDanmakuItems.refresh();
    }
  }

  void _syncOpacity() {
    final opacity = _option.opacity;
    if (opacity != _opacityNotifier.value) {
      _opacityNotifier.value = opacity;
    }
  }

  bool _shouldRun(int now) {
    if (_scrollAlive.isNotEmpty || _staticDanmakuItems.value.isNotEmpty) {
      return true;
    }
    if (_viewWidth <= 0) return !_store.isEmpty;
    if (!_clock.running) return false;
    // Future items (seekable use) keep the ticker alive while advancing.
    return _store.scrollItems.isNotEmpty &&
            _store.scrollItems.last.birthTick! > now ||
        _store.staticItems.isNotEmpty &&
            _store.staticItems.last.birthTick! > now ||
        _store.specialItems.isNotEmpty &&
            _store.specialItems.last.birthTick! > now;
  }

  @pragma("vm:prefer-inline")
  void _lazyTick(int tick) {
    // Drop retention-expired items from the shared store and forget their
    // per-view track assignments.
    final removed = _store.prune(
      nowMs: tick,
      viewWidth: _viewWidth,
      durationMs: _durationMs,
      staticDurationMs: _staticDurationMs,
    );
    if (removed.isNotEmpty) {
      _storeVersion = _store.version;
      for (final item in removed) {
        final scrollTrack = _scrollTrackOf.remove(item);
        if (scrollTrack != null) {
          _scrollTracks[scrollTrack].remove(item);
        }
        final staticTrack = _staticTrackOf.remove(item);
        if (staticTrack != null) {
          if (_topLast[staticTrack] == item) _topLast[staticTrack] = null;
          if (_bottomLast[staticTrack] == item) _bottomLast[staticTrack] = null;
        }
        _grace.remove(item);
      }
    }
    // Reclaim grace images past their keep window.
    if (_grace.isNotEmpty) {
      _grace.removeWhere((item) {
        final birth = item.birthTick ?? tick;
        final old = tick - birth - _durationMs > _imageGraceMs;
        if (old) item.dispose();
        return old;
      });
    }
    // 暂停动画: freeze while the clock is paused; stop when idle.
    if (!_clock.running || !_shouldRun(tick)) {
      if (_ticker.isActive) _ticker.stop();
    }
    // Expired special danmaku is flagged during paint; drop it here.
    _store.dropExpiredSpecial();
  }

  void _calcTracks() {
    _trackCount = (_viewHeight * _option.area / _danmakuHeight).floor();

    /// 为字幕留出余量
    if (_option.safeArea && _option.area == 1.0) {
      _trackCount = _trackCount - 1;
    }
    if (_trackCount < 0) _trackCount = 0;

    _trackYPositions = List<double>.generate(
        _trackCount, (i) => i * _danmakuHeight,
        growable: false);
    _scrollTracks
      ..clear()
      ..addAll(List.generate(_trackCount, (_) => <DanmakuItem<T>>[]));
    _topLast
      ..clear()
      ..addAll(List.filled(_trackCount, null));
    _bottomLast
      ..clear()
      ..addAll(List.filled(_trackCount, null));
    _scrollTrackOf.clear();
    _staticTrackOf.clear();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        /// 计算视图宽度
        final viewWidth = constraints.maxWidth;
        final viewHeight = constraints.maxHeight;
        if (_viewWidth != viewWidth || _viewHeight != viewHeight) {
          _viewWidth = viewWidth;
          _viewHeight = viewHeight;
          _calcTracks();
          // Collision math used the old size; re-derive deterministically.
          _rebuildNeeded = true;
        }

        return ClipRect(
          child: ValueListenableBuilder<double>(
            valueListenable: _opacityNotifier,
            builder: (context, opacity, child) {
              return Opacity(opacity: opacity, child: child);
            },
            child: IgnorePointer(
              child: Stack(
                children: [
                  RepaintBoundary.wrap(
                    ValueListenableBuilder(
                      valueListenable: _tickNotifier,
                      builder: (context, value, child) {
                        return CustomPaint(
                          willChange: _running,
                          painter: ScrollDanmakuPainter(
                            length: _scrollAlive.length,
                            danmakuItems: _scrollAlive,
                            durationInMilliseconds:
                                _option.durationInMilliseconds,
                            fontSize: _option.fontSize,
                            fontWeight: _option.fontWeight,
                            strokeWidth: _option.strokeWidth,
                            devicePixelRatio: devicePixelRatio,
                            running: _running,
                            tick: value,
                          ),
                          size: Size.infinite,
                        );
                      },
                    ),
                    0,
                  ),
                  RepaintBoundary.wrap(
                    ValueListenableBuilder(
                      valueListenable: _staticDanmakuItems,
                      builder: (context, value, child) {
                        return CustomPaint(
                          painter: StaticDanmakuPainter(
                            length: value.length,
                            danmakuItems: value,
                            staticDurationInMilliseconds:
                                _option.staticDurationInMilliseconds,
                            fontSize: _option.fontSize,
                            fontWeight: _option.fontWeight,
                            strokeWidth: _option.strokeWidth,
                            devicePixelRatio: devicePixelRatio,
                            tick: _tickNotifier.value,
                          ),
                          size: Size.infinite,
                        );
                      },
                    ),
                    1,
                  ),
                  RepaintBoundary.wrap(
                    IgnorePointer(
                        child: ValueListenableBuilder(
                      valueListenable: _tickNotifier, // 与滚动弹幕共用控制器
                      builder: (context, value, child) {
                        return CustomPaint(
                          willChange: _running,
                          painter: SpecialDanmakuPainter(
                            length: _store.specialItems.length,
                            danmakuItems: _store.specialItems,
                            fontSize: _option.fontSize,
                            fontWeight: _option.fontWeight,
                            strokeWidth: _option.strokeWidth,
                            devicePixelRatio: devicePixelRatio,
                            running: _running,
                            tick: value,
                          ),
                          size: Size.infinite,
                        );
                      },
                    )),
                    2,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  double _scrollXOf(DanmakuItem<T> item, int now) {
    return scrollDanmakuX(
      viewWidth: _viewWidth,
      itemWidth: item.width,
      birthTick: item.birthTick ?? now,
      nowMs: now,
      durationMs: _durationMs,
    );
  }

  double? _trackYOf(DanmakuItem<T> item) {
    final scrollTrack = _scrollTrackOf[item];
    if (scrollTrack != null &&
        scrollTrack >= 0 &&
        scrollTrack < _trackYPositions.length) {
      return _trackYPositions[scrollTrack];
    }
    final staticTrack = _staticTrackOf[item];
    if (staticTrack != null &&
        staticTrack >= 0 &&
        staticTrack < _trackYPositions.length) {
      return _trackYPositions[staticTrack];
    }
    return null;
  }

  Iterable<DanmakuItem<T>> hitDanmaku(
      List<DanmakuItem<T>> danmakuItems, Offset position, int now) sync* {
    if (danmakuItems.isNotEmpty) {
      final dy = position.dy;
      for (var i in danmakuItems.reversed) {
        final double danmakuY0;
        final double danmakuY1;
        final y = _trackYOf(i) ?? i.yPosition;
        if (i.content.type == DanmakuItemType.bottom) {
          danmakuY1 = _viewHeight - y;
          danmakuY0 = danmakuY1 - i.height;
        } else {
          assert(i.content.type != DanmakuItemType.special);
          danmakuY0 = y;
          danmakuY1 = danmakuY0 + i.height;
        }

        if (danmakuY0 <= dy && dy <= danmakuY1) {
          final dx = position.dx;
          final x = i.content.type == DanmakuItemType.scroll
              ? _scrollXOf(i, now)
              : (_viewWidth - i.width) / 2;
          if (x <= dx && dx <= x + i.width) {
            yield i;
          }
        }
      }
    }
  }

  DanmakuItem<T>? hitSingleDanmaku(
      List<DanmakuItem<T>> danmakuItems, Offset position, int now) {
    if (danmakuItems.isNotEmpty) {
      final dy = position.dy;
      for (var i in danmakuItems.reversed) {
        final double danmakuY0;
        final double danmakuY1;
        final y = _trackYOf(i) ?? i.yPosition;
        if (i.content.type == DanmakuItemType.bottom) {
          danmakuY1 = _viewHeight - y;
          danmakuY0 = danmakuY1 - i.height;
        } else {
          assert(i.content.type != DanmakuItemType.special);
          danmakuY0 = y;
          danmakuY1 = danmakuY0 + i.height;
        }

        if (danmakuY0 <= dy && dy <= danmakuY1) {
          final dx = position.dx;
          final x = i.content.type == DanmakuItemType.scroll
              ? _scrollXOf(i, now)
              : ((_viewWidth - i.width) / 2);
          if (x <= dx && dx <= x + i.width) {
            return i;
          }
        }
      }
    }
    return null;
  }

  Iterable<DanmakuItem<T>> findDanmaku(Offset pos) {
    final now = _clock.nowMs;
    return hitDanmaku(_staticDanmakuItems.value, pos, now)
        .followedBy(hitDanmaku(_scrollAlive, pos, now));
  }

  DanmakuItem<T>? findSingleDanmaku(Offset pos) {
    final now = _clock.nowMs;
    return hitSingleDanmaku(_staticDanmakuItems.value, pos, now) ??
        hitSingleDanmaku(_scrollAlive, pos, now);
  }
}

class ListValueNotifier<T> extends ValueNotifier<List<T>> {
  ListValueNotifier(super.value);

  void add(T item) {
    value.add(item);
    notifyListeners();
  }

  void clear() {
    if (value.isNotEmpty) {
      value.clear();
      notifyListeners();
    }
  }

  void removeWhere(bool Function(T element) test) {
    if (value.removeWhereUnsafe(test)) {
      notifyListeners();
    }
  }
}

extension ValueNotifierExt<T> on ValueNotifier<T> {
  @pragma("vm:prefer-inline")
  void refresh() {
    // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
    notifyListeners();
  }
}

extension<E> on List<E> {
  bool removeWhereUnsafe(bool Function(E) test) {
    int write = 0;
    final length = this.length;
    for (int read = 0; read < length; read++) {
      final element = this[read];
      if (!test(element)) {
        if (write < read) this[write] = element;
        write++;
      }
    }
    if (length != write) {
      this.length = write;
      return true;
    }
    return false;
  }
}
