import 'package:canvas_danmaku/models/danmaku_content_item.dart';
import 'package:canvas_danmaku/models/danmaku_item.dart';
import 'package:canvas_danmaku/models/danmaku_option.dart';
import 'package:flutter/material.dart';

/// A single bulk-insert entry: content with its clock birth and dedup key.
typedef DanmakuBatchEntry<T> = ({
  DanmakuContentItem<T> content,
  int? birthTick,
  Object? key,
});

class DanmakuController<T> {
  final void Function(
    DanmakuContentItem<T> content, {
    int? birthTick,
    Object? key,
  })
  addDanmaku;
  final void Function(List<DanmakuBatchEntry<T>> entries) addAll;

  /// Re-anchors the shared clock to [tickMs] (seek / drift correction).
  /// Views rebuild their visible windows out of the retained items, so a
  /// seek lands mid-flight instead of dropping everything in the gap.
  final ValueChanged<int> seekTo;
  final ValueChanged<DanmakuOption> updateOption;
  final VoidCallback pause;
  final VoidCallback resume;
  final VoidCallback clear;
  final DanmakuOption Function() getOption;
  final bool Function() isRunning;
  final Iterable<DanmakuItem<T>> Function(Offset) findDanmaku;
  final DanmakuItem<T>? Function(Offset) findSingleDanmaku;
  final double Function() getViewWidth;
  final double Function() getViewHeight;

  final List<DanmakuItem<T>> scrollDanmaku;
  final List<DanmakuItem<T>> staticDanmaku;
  final List<DanmakuItem<T>> specialDanmaku;

  DanmakuOption get option => getOption();

  bool get running => isRunning();

  double get viewWidth => getViewWidth();

  double get viewHeight => getViewHeight();

  DanmakuController({
    required this.addDanmaku,
    required this.addAll,
    required this.seekTo,
    required this.updateOption,
    required this.pause,
    required this.resume,
    required this.clear,
    required this.getOption,
    required this.isRunning,
    required this.findDanmaku,
    required this.findSingleDanmaku,
    required this.getViewWidth,
    required this.getViewHeight,
    required this.scrollDanmaku,
    required this.staticDanmaku,
    required this.specialDanmaku,
  });
}
