import 'dart:ui' as ui;

import 'package:canvas_danmaku/models/danmaku_content_item.dart';
import 'package:canvas_danmaku/utils/utils.dart';

class DanmakuItem<T> {
  /// 弹幕内容
  final DanmakuContentItem<T> content;

  /// 弹幕宽度
  double width;

  /// 弹幕高度
  double height;

  /// 弹幕水平方向位置
  double xPosition;

  /// 弹幕竖直方向位置
  double yPosition;

  /// 上次绘制时间
  int? drawTick;

  /// The clock time ([DanmakuClock.nowMs]) the flight starts, i.e. the
  /// moment the danmaku appears at the right edge (scroll) or appears
  /// (static). Positions are a pure function of `nowMs - birthTick`, so all
  /// views sharing one clock render the same danmaku identically.
  /// Set at insert; null only for items constructed but not yet added.
  int? birthTick;

  /// Deduplication key for re-delivery (e.g. normal + fullscreen views
  /// subscribed to the same comment stream). Managed by [DanmakuStore].
  Object? dedupKey;

  /// 弹幕布局缓存
  ui.Image? image;

  bool expired = false;

  bool suspend = false;

  @pragma("vm:prefer-inline")
  bool needRemove(bool needRemove) {
    if (needRemove) {
      dispose();
    }
    return needRemove;
  }

  void dispose() {
    image?.dispose();
    image = null;
  }

  DanmakuItem({
    required this.content,
    required this.height,
    required this.width,
    this.xPosition = 0,
    this.yPosition = 0,
    this.image,
    this.drawTick,
    this.birthTick,
    this.dedupKey,
  });

  /// Whether text measurement ([width]/[height]) is available.
  bool get measured => width > 0;

  /// Lays out the text for measurement only (no rasterization).
  ///
  /// Measurement is needed for track assignment and must precede painting,
  /// while the expensive GPU texture is still deferred to
  /// [drawParagraphIfNeeded]. Cheap enough to run on first paint of each
  /// item, so bulk inserts never jank.
  void ensureMeasured(double fontSize, int fontWeight, double strokeWidth) {
    if (measured) return;
    final paragraph = DmUtils.generateParagraph(
      content: content,
      fontSize: fontSize,
      fontWeight: fontWeight,
    );
    width =
        paragraph.maxIntrinsicWidth +
        strokeWidth +
        (content.selfSend ? 4.0 : 0.0);
    height = paragraph.height + strokeWidth;
    paragraph.dispose();
  }

  void drawParagraphIfNeeded(
    double fontSize,
    int fontWeight,
    double strokeWidth,
    double devicePixelRatio,
  ) {
    ensureMeasured(fontSize, fontWeight, strokeWidth);
    if (image == null) {
      final paragraph = DmUtils.generateParagraph(
        content: content,
        fontSize: fontSize,
        fontWeight: fontWeight,
      );
      image = DmUtils.recordDanmakuImage(
        contentParagraph: paragraph,
        content: content,
        fontSize: fontSize,
        fontWeight: fontWeight,
        strokeWidth: strokeWidth,
        devicePixelRatio: devicePixelRatio,
      );
      paragraph.dispose();
    }
  }

  @override
  String toString() {
    return 'DanmakuItem(content=$content, xPos=$xPosition, yPos=$yPosition, size=${ui.Size(width, height)}, drawTick=$drawTick, birthTick=$birthTick)';
  }
}
