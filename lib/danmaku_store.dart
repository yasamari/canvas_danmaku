import 'package:canvas_danmaku/models/danmaku_content_item.dart';
import 'package:canvas_danmaku/models/danmaku_item.dart';
import 'package:flutter/foundation.dart';

/// View-independent danmaku storage shared by danmaku views.
///
/// A [DanmakuScreen] showing the normal video controls and the one pushed by
/// the media_kit fullscreen route (same `controls` builder, two widget
/// subtrees) render the same session. Giving both the same [DanmakuStore]
/// (and the same [DanmakuClock]) keeps already-flying
/// danmaku visible across fullscreen toggles and rotation: the new view
/// paints the current clock window out of the retained items instead of
/// starting from an empty list.
///
/// Items are kept in birth-tick order per type so views can slide a visible
/// window over them. Measurement (text layout for widths, needed for track
/// assignment) and rasterization (GPU textures) both happen lazily on first
/// paint, never on insert, so bulk-loading a whole recording's comments is a
/// cheap sorted insert.
///
/// Lifecycle notes:
///
/// * Raster images ([DanmakuItem.image]) live on the items and may be
///   disposed by any view (expiry, DPR or font change); painting recreates
///   them lazily. Disposal is idempotent via nulling, so sharing is safe.
/// * [prune] fully drops items older than [retentionMs] (or past their
///   natural visibility when null, i.e. upstream behavior). Views additionally
///   drop expired items from their own alive windows every tick.
/// * [clear] drops everything; views observe [version] to discard their
///   per-view track assignment.
/// * Inserted keys ([add]/[addAll] `key`) deduplicate re-delivery when two
///   views (normal + fullscreen) subscribe to the same comment stream.
class DanmakuStore<T> extends ChangeNotifier {
  DanmakuStore({this.retentionMs});

  /// How long items are retained for backward seeks, in clock ms.
  ///
  /// Must exceed the scroll transit and the static duration to be useful;
  /// pass the program length for seekable (recording) use. Null keeps the
  /// upstream behavior: items are dropped once fully expired and backward
  /// seeks past that point lose them. Pruned keys are forgotten, so
  /// re-adding a pruned danmaku works.
  final int? retentionMs;

  /// Birth-sorted items per type.
  final List<DanmakuItem<T>> scrollItems = [];

  /// Birth-sorted items per type.
  final List<DanmakuItem<T>> staticItems = [];

  /// Birth-sorted items per type.
  final List<DanmakuItem<T>> specialItems = [];

  final Set<Object> _keys = {};

  /// Bumped on every structural change ([clear], [prune] removals).
  int version = 0;

  /// Whether all three lists are empty.
  bool get isEmpty =>
      scrollItems.isEmpty && staticItems.isEmpty && specialItems.isEmpty;

  List<DanmakuItem<T>> _listFor(DanmakuItemType type) {
    switch (type) {
      case DanmakuItemType.scroll:
        return scrollItems;
      case DanmakuItemType.top:
      case DanmakuItemType.bottom:
        return staticItems;
      case DanmakuItemType.special:
        return specialItems;
    }
  }

  /// Inserts [item] in birth order. Returns false when [key] was seen before.
  ///
  /// The item's [DanmakuItem.birthTick] must be set (views stamp
  /// `clock.nowMs` when omitted). No text layout or rasterization happens
  /// here; both are deferred to first paint.
  bool add(DanmakuItem<T> item, {Object? key}) {
    assert(item.birthTick != null, 'birthTick must be set before store.add');
    if (key != null && !_keys.add(key)) return false;
    item.dedupKey = key;
    _insertSorted(_listFor(item.content.type), item);
    notifyListeners();
    return true;
  }

  /// Bulk insert; entries are merged in birth order in one pass.
  ///
  /// Returns the number of accepted (non-duplicate) items.
  int addAll(
    Iterable<({DanmakuContentItem<T> content, int? birthTick, Object? key})>
    entries,
    int fallbackBirth,
  ) {
    final pending = <DanmakuItem<T>>[];
    for (final entry in entries) {
      if (entry.key != null && !_keys.add(entry.key!)) continue;
      final item = DanmakuItem<T>(
        content: entry.content,
        width: 0,
        height: 0,
        birthTick: entry.birthTick ?? fallbackBirth,
      )
        ..dedupKey = entry.key;
      pending.add(item);
    }
    if (pending.isEmpty) return 0;
    pending.sort((a, b) => a.birthTick!.compareTo(b.birthTick!));
    // Merge per type to keep each list sorted with a single pass.
    var accepted = 0;
    for (final type in DanmakuItemType.values) {
      final typed = pending
          .where((item) => item.content.type == type)
          .toList();
      if (typed.isEmpty) continue;
      _mergeSorted(_listFor(type), typed);
      accepted += typed.length;
    }
    notifyListeners();
    return accepted;
  }

  /// Inserts a pre-rasterized special danmaku in birth order.
  /// Returns false when [key] was seen before.
  bool addSpecial(DanmakuItem<T> item, {Object? key}) {
    assert(item.birthTick != null);
    if (key != null && !_keys.add(key)) return false;
    item.dedupKey = key;
    _insertSorted(specialItems, item);
    notifyListeners();
    return true;
  }

  /// Drops everything, including keys.
  void clear() {
    for (final list in [scrollItems, staticItems, specialItems]) {
      for (final item in list) {
        item.dispose();
      }
      list.clear();
    }
    _keys.clear();
    version++;
    notifyListeners();
  }

  /// Drops items fully outside the retention window. Safe to call from any
  /// view (idempotent); returns the removed items so views can drop their
  /// per-view track assignments.
  ///
  /// Bounds are width-independent (see [DanmakuStore.retentionMs]), so every
  /// view agrees on what is gone regardless of its own size.
  List<DanmakuItem<T>> prune({
    required int nowMs,
    required double durationMs,
    required double staticDurationMs,
  }) {
    final removed = <DanmakuItem<T>>[];
    _pruneList(scrollItems, removed, (item) {
      if (item.width <= 0) return false;
      // Natural expiry is `durationMs` after birth for every width (see
      // scrollDanmakuX), never a width-dependent transit: expiry follows birth
      // order, which is what lets views drop their alive window head in one
      // pass.
      return nowMs - item.birthTick! > (retentionMs ?? durationMs);
    });
    _pruneList(staticItems, removed, (item) {
      return nowMs - item.birthTick! >
          (retentionMs ?? staticDurationMs);
    });
    _pruneList(specialItems, removed, (item) {
      final content = item.content;
      final double duration;
      if (content is SpecialDanmakuContentItem<T>) {
        duration = content.duration.toDouble();
      } else {
        duration = staticDurationMs;
      }
      return nowMs - item.birthTick! > (retentionMs ?? duration);
    });
    if (removed.isNotEmpty) {
      version++;
      notifyListeners();
    }
    return removed;
  }

  /// Drops every recorded track ([DanmakuItem.track]).
  ///
  /// For when the collision math changes underneath the danmaku that are
  /// already on screen — the text width (font size / family / weight /
  /// stroke) or the durations. The next window pass then re-assigns from the
  /// current options. A plain resize keeps the records: out-of-range ones are
  /// re-decided on their own, the rest keep their row.
  void resetTracks() {
    for (final list in [scrollItems, staticItems, specialItems]) {
      for (final item in list) {
        item.track = null;
      }
    }
  }

  /// Forgets cached text measurements (font/size change); images are
  /// disposed and both are rebuilt lazily on next paint.
  void resetMeasurements() {
    for (final list in [scrollItems, staticItems, specialItems]) {
      for (final item in list) {
        item
          ..dispose()
          ..width = 0
          ..height = 0;
      }
    }
    notifyListeners();
  }

  /// Disposes raster images only, keeping text measurements (DPR change:
  /// widths are DPR-independent, only textures are rebuilt lazily).
  /// Idempotent across views sharing this store.
  void dropImages() {
    for (final list in [scrollItems, staticItems, specialItems]) {
      for (final item in list) {
        item.dispose();
      }
    }
    notifyListeners();
  }

  /// Removes special danmaku flagged expired by painting.
  void dropExpiredSpecial() {
    final before = specialItems.length;
    for (var i = specialItems.length - 1; i >= 0; i--) {
      final item = specialItems[i];
      if (item.expired) {
        item.dispose();
        if (item.dedupKey != null) _keys.remove(item.dedupKey);
        specialItems.removeAt(i);
      }
    }
    if (specialItems.length != before) {
      version++;
      notifyListeners();
    }
  }

  void _insertSorted(List<DanmakuItem<T>> list, DanmakuItem<T> item) {
    if (list.isEmpty || list.last.birthTick! <= item.birthTick!) {
      list.add(item);
      return;
    }
    list.insert(_lowerBound(list, item.birthTick!), item);
  }

  void _mergeSorted(List<DanmakuItem<T>> list, List<DanmakuItem<T>> sorted) {
    if (list.isEmpty) {
      list.addAll(sorted);
      return;
    }
    final merged = <DanmakuItem<T>>[];
    var i = 0;
    var j = 0;
    while (i < list.length && j < sorted.length) {
      if (list[i].birthTick! <= sorted[j].birthTick!) {
        merged.add(list[i++]);
      } else {
        merged.add(sorted[j++]);
      }
    }
    while (i < list.length) {
      merged.add(list[i++]);
    }
    while (j < sorted.length) {
      merged.add(sorted[j++]);
    }
    list
      ..clear()
      ..addAll(merged);
  }

  void _pruneList(
    List<DanmakuItem<T>> list,
    List<DanmakuItem<T>> removed,
    bool Function(DanmakuItem<T> item) drop,
  ) {
    // Birth-sorted: drop decisions are monotonic only for the head, but
    // widths vary, so scan fully; prune runs on the lazy-tick cadence and
    // each check is a few integer ops.
    var write = 0;
    for (var read = 0; read < list.length; read++) {
      final item = list[read];
      if (drop(item)) {
        item.dispose();
        if (item.dedupKey != null) _keys.remove(item.dedupKey);
        removed.add(item);
      } else {
        if (write < read) list[write] = item;
        write++;
      }
    }
    if (write != list.length) {
      list.length = write;
    }
  }
}

/// First index with `birthTick >= birth` in a birth-sorted list.
int lowerBoundBirth<T>(List<DanmakuItem<T>> list, int birth) {
  var lo = 0;
  var hi = list.length;
  while (lo < hi) {
    final mid = (lo + hi) >> 1;
    if (list[mid].birthTick! < birth) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  return lo;
}

int _lowerBound<T>(List<DanmakuItem<T>> list, int birth) =>
    lowerBoundBirth(list, birth);
