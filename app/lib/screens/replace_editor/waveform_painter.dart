import 'package:flutter/material.dart';

import '../../domain/replacement_models.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import 'group_colors.dart';

/// 波形主区 painter — 一次画完：
/// 1. loop shades（TL/PL 矩形）
/// 2. center axis line
/// 3. 节拍 ticks（每 8 个 beat 一根浅竖线）
/// 4. 波形 bars（中线对称，segment 决定振幅）
/// 5. segment 背景条（底部 24 px）
/// 6. markers（6 个时间点：TD/PD/TL-A/TL-B/PL-A/PL-B），含顶部 flag
/// 7. playhead（白线 + 轻微 glow）
///
/// 布局：top padding 18px 给 flag 留位 → bars 区 130px → 6 gap → segments 24px。
/// 总高 = 178。time axis 由父 widget 单独渲染。
class WaveformPainter extends CustomPainter {
  WaveformPainter({
    required this.rm,
    required this.bars,
    required this.beats,
    required this.segments,
    required this.duration,
    required this.markers,
    required this.tlLoop,
    required this.plLoop,
    required this.playhead,
  });

  final RmTheme rm;
  final WaveformBars bars;
  final List<double> beats;
  final List<Segment> segments;
  final double duration;
  final List<WaveformMarker> markers;
  final ({double start, double end})? tlLoop;
  final ({double start, double end})? plLoop;
  final double playhead;

  static const double flagPad = 18;
  static const double barsHeight = 130;
  static const double gap = 6;
  static const double segHeight = 24;
  static const double totalHeight =
      flagPad + barsHeight + gap + segHeight; // 178

  double _x(double t, double width) => (t / duration) * width;

  @override
  void paint(Canvas canvas, Size size) {
    if (duration <= 0 || bars.values.isEmpty) return;
    final width = size.width;

    // ------------------------------------------------------------
    // Loop shades — drawn behind bars
    // ------------------------------------------------------------
    final shadeTop = flagPad;
    final shadeBottom = flagPad + barsHeight + gap + segHeight;
    if (tlLoop != null) {
      _drawShade(
        canvas,
        width,
        tlLoop!.start,
        tlLoop!.end,
        shadeTop,
        shadeBottom,
        RmTokens.tgTlBlue.withAlpha(26),
      );
    }
    if (plLoop != null) {
      _drawShade(
        canvas,
        width,
        plLoop!.start,
        plLoop!.end,
        shadeTop,
        shadeBottom,
        RmTokens.tgPlOrange.withAlpha(26),
      );
    }

    // ------------------------------------------------------------
    // Center axis line + beat ticks
    // ------------------------------------------------------------
    final centerY = flagPad + barsHeight / 2;
    final axisPaint = Paint()
      ..color = rm.border
      ..strokeWidth = 0.6;
    canvas.drawLine(Offset(0, centerY), Offset(width, centerY), axisPaint);

    final beatPaint = Paint()
      ..color = rm.border2.withAlpha(128)
      ..strokeWidth = 0.6;
    for (int i = 0; i < beats.length; i += 8) {
      final x = _x(beats[i], width);
      canvas.drawLine(
        Offset(x, flagPad),
        Offset(x, flagPad + barsHeight),
        beatPaint,
      );
    }

    // ------------------------------------------------------------
    // Bars
    // ------------------------------------------------------------
    final barPaint = Paint()..color = rm.fg3.withAlpha(204); // 0.8
    final n = bars.values.length;
    final barWidth = width / n * 0.85;
    for (int i = 0; i < n; i++) {
      final v = bars.values[i];
      final h = v * (barsHeight / 2 - 4);
      final x = n == 1 ? width / 2 : (i / (n - 1)) * width;
      canvas.drawRect(
        Rect.fromLTWH(x - barWidth / 2, centerY - h, barWidth, h * 2),
        barPaint,
      );
    }

    // ------------------------------------------------------------
    // Segment backgrounds (below bars)
    // ------------------------------------------------------------
    final segTop = flagPad + barsHeight + gap;
    final segLabelStyle = TextStyle(
      fontSize: 10,
      letterSpacing: 0,
      fontFamilyFallback: const ['monospace'],
    );
    for (final s in segments) {
      final x0 = _x(s.start, width);
      final x1 = _x(s.end, width);
      final (Color bg, Color fg) = _segColors(s.label);
      // 2px gap between segments — emulate by inset
      final rect = Rect.fromLTRB(x0 + 1, segTop, x1 - 1, segTop + segHeight);
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(3)),
        Paint()..color = bg,
      );
      // label centered
      if (rect.width > 30) {
        final label = _segmentDisplayLabel(s.label);
        final tp = TextPainter(
          text: TextSpan(
            text: label,
            style: segLabelStyle.copyWith(color: fg),
          ),
          maxLines: 1,
          ellipsis: '...',
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: rect.width - 8);
        tp.paint(
          canvas,
          Offset(
            rect.left + (rect.width - tp.width) / 2,
            rect.top + (segHeight - tp.height) / 2,
          ),
        );
      }
    }

    // ------------------------------------------------------------
    // Markers (stems + flags) — above shades/bars
    // ------------------------------------------------------------
    for (final m in markers) {
      final x = _x(m.t, width);
      final color = m.kind == null
          ? rm.accent.base
          : groupAccent(rm, m.kind!).base;
      // stem
      canvas.drawRect(
        Rect.fromLTWH(x - 1, flagPad, 2, barsHeight + gap + segHeight),
        Paint()..color = color.withAlpha(217), // 0.85
      );
      // flag (above the stem)
      _drawFlag(canvas, x, color, m.label);
    }

    // ------------------------------------------------------------
    // Playhead (white line + small glow)
    // ------------------------------------------------------------
    final phX = _x(playhead, width);
    final phColor = rm.fg;
    canvas.drawRect(
      Rect.fromLTWH(
        phX - 0.5,
        flagPad - 2,
        1,
        barsHeight + gap + segHeight + 2,
      ),
      Paint()..color = phColor.withAlpha(230),
    );
    // tiny triangle on top
    final tri = Path()
      ..moveTo(phX - 4, flagPad - 4)
      ..lineTo(phX + 4, flagPad - 4)
      ..lineTo(phX, flagPad)
      ..close();
    canvas.drawPath(tri, Paint()..color = phColor);
  }

  void _drawShade(
    Canvas canvas,
    double width,
    double start,
    double end,
    double top,
    double bottom,
    Color color,
  ) {
    final x0 = _x(start, width);
    final x1 = _x(end, width);
    canvas.drawRect(Rect.fromLTRB(x0, top, x1, bottom), Paint()..color = color);
  }

  void _drawFlag(Canvas canvas, double x, Color bg, String label) {
    final tp = TextPainter(
      text: TextSpan(
        text: label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: rm.accent.onAccent,
          fontFamilyFallback: const ['monospace'],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final flagW = tp.width + 12;
    final flagH = tp.height + 4;
    final left = x - 1; // align with stem
    final top = flagPad - flagH - 0;
    final rect = Rect.fromLTWH(left, top, flagW, flagH);
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(3)),
      Paint()..color = bg,
    );
    tp.paint(canvas, Offset(left + 6, top + 2));
  }

  (Color, Color) _segColors(String label) {
    final palette = <(Color, Color)>[
      (RmTokens.segIntroBg, rm.fg3),
      (RmTokens.segVerseBg, RmTokens.segVerseFg),
      (RmTokens.segChorusBg, RmTokens.segChorusFg),
      (RmTokens.segBridgeBg, RmTokens.segBridgeFg),
      (const Color(0xFFE7DDF9), const Color(0xFF44236D)),
      (const Color(0xFFD9ECE2), const Color(0xFF185235)),
      (const Color(0xFFF7D7DA), const Color(0xFF7B2732)),
    ];
    return palette[_stableLabelIndex(label, palette.length)];
  }

  String _segmentDisplayLabel(String label) {
    final collapsed = label.trim().replaceAll(RegExp(r'\s+'), ' ');
    return collapsed.isEmpty ? 'segment' : collapsed;
  }

  int _stableLabelIndex(String label, int length) {
    final normalized = label.trim().toLowerCase();
    if (normalized.isEmpty) return 0;
    var hash = 0;
    for (final code in normalized.codeUnits) {
      hash = ((hash * 31) + code) & 0x7fffffff;
    }
    return hash % length;
  }

  @override
  bool shouldRepaint(WaveformPainter old) =>
      old.playhead != playhead ||
      old.markers != markers ||
      old.beats != beats ||
      old.segments != segments ||
      old.tlLoop != tlLoop ||
      old.plLoop != plLoop ||
      old.duration != duration ||
      old.bars != bars ||
      old.rm != rm;
}

/// 缩略波形 painter（底部 zoom strip）。
class ZoomStripPainter extends CustomPainter {
  ZoomStripPainter({
    required this.rm,
    required this.bars,
    required this.duration,
    required this.windowStart,
    required this.windowEnd,
  });

  final RmTheme rm;
  final WaveformBars bars;
  final double duration;
  final double windowStart;
  final double windowEnd;

  @override
  void paint(Canvas canvas, Size size) {
    if (duration <= 0 || bars.values.isEmpty) return;
    final width = size.width;
    final height = size.height;
    final centerY = height / 2;

    // axis
    canvas.drawLine(
      Offset(0, centerY),
      Offset(width, centerY),
      Paint()
        ..color = rm.border
        ..strokeWidth = 0.5,
    );

    // bars
    final n = bars.values.length;
    final barPaint = Paint()..color = rm.fg4.withAlpha(204);
    final barW = width / n * 0.85;
    for (int i = 0; i < n; i++) {
      final v = bars.values[i];
      final h = v * (height / 2 - 2);
      final x = n == 1 ? width / 2 : (i / (n - 1)) * width;
      canvas.drawRect(
        Rect.fromLTWH(x - barW / 2, centerY - h, barW, h * 2),
        barPaint,
      );
    }

    // window rectangle (accent)
    final wx0 = (windowStart / duration) * width;
    final wx1 = (windowEnd / duration) * width;
    final rect = Rect.fromLTRB(wx0, 0, wx1, height);
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(3)),
      Paint()..color = rm.accent.bg,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(3)),
      Paint()
        ..color = rm.accent.base
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(ZoomStripPainter old) =>
      old.windowStart != windowStart ||
      old.windowEnd != windowEnd ||
      old.duration != duration ||
      old.bars != bars ||
      old.rm != rm;
}

class WaveformMarker {
  const WaveformMarker({required this.t, required this.label, this.kind});
  final double t;
  final String label;
  final GroupKind? kind; // null → main accent
}
