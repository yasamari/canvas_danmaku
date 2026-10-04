import 'dart:ui' as ui;

import 'package:canvas_danmaku/base_danmaku_painter.dart';
import 'package:canvas_danmaku/danmaku_track_assign.dart';
import 'package:canvas_danmaku/models/danmaku_item.dart';
import 'package:flutter/material.dart';

final class ScrollDanmakuPainter extends BaseDanmakuPainter {
  final double durationInMilliseconds;

  late final Paint selfSendPaint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = strokeWidth
    ..color = Colors.green;

  ScrollDanmakuPainter({
    required super.length,
    required super.danmakuItems,
    required this.durationInMilliseconds,
    required super.fontSize,
    required super.fontWeight,
    required super.strokeWidth,
    required super.devicePixelRatio,
    required super.running,
    required super.tick,
    super.batchThreshold,
  });

  @override
  void paintDanmaku(ui.Canvas canvas, ui.Size size, DanmakuItem item) {
    item.drawParagraphIfNeeded(
      fontSize,
      fontWeight,
      strokeWidth,
      devicePixelRatio,
    );
    if (!item.suspend) {
      // Deterministic position: a pure function of the clock (`tick`) and
      // the danmaku's birth tick, replacing the former incremental
      // `xPosition += delta` update. The same clock value always yields the
      // same position, so seeks land mid-flight and rebuilt views
      // (fullscreen / rotation) resume seamlessly.
      final birth = item.birthTick ?? tick;
      item.xPosition = scrollDanmakuX(
        viewWidth: size.width,
        itemWidth: item.width,
        birthTick: birth,
        nowMs: tick,
        durationMs: durationInMilliseconds,
      );

      if (item.xPosition < -item.width || item.xPosition > size.width) {
        item.expired = true;
        return;
      }
    }

    BaseDanmakuPainter.paintImg(
      canvas,
      item,
      item.xPosition,
      item.yPosition,
      devicePixelRatio,
    );

    item.drawTick = tick;
  }
}
