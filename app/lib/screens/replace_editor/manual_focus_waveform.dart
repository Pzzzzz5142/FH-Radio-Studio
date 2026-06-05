import 'package:flutter/material.dart';

import '../../domain/replacement_models.dart';
import '../../theme/app_theme.dart';
import '../../theme/text_styles.dart';
import '../../theme/tokens.dart';

/// 精修台里的一个可放置端点（单点组只有一个；循环组有 A / B 两个）。
class FocusHandle {
  const FocusHandle({
    required this.key,
    required this.t,
    required this.label,
    required this.active,
    this.dim = false,
  });

  final String key;
  final double t;
  final String label;

  /// 当前正在编辑的端点（放大、加光晕）。
  final bool active;

  /// 非激活的循环端点（淡化到 45%）。
  final bool dim;
}

/// 精修台主波形 —— 直接点 / 拖波形放置时间点。
///
/// 与 [WaveformCard] 不同，这里：
/// * 只画当前时间组的 1 个或 2 个端点，而不是全部 6 个 marker；
/// * 顶部带段落泳道、每拍网格线（downbeat 更重）、循环阴影带；
/// * 端点是可拖拽的旗标 + 立柱 + 抓手，激活态放大、非激活态淡化；
/// * 指针在波形上按下挑最近端点、拖动即移动，磁吸交给父级处理。
class ManualFocusWaveform extends StatefulWidget {
  const ManualFocusWaveform({
    super.key,
    required this.bars,
    required this.beats,
    required this.segments,
    required this.duration,
    required this.accent,
    required this.handles,
    required this.free,
    required this.locked,
    required this.onPlace,
    this.playhead,
    this.canvasHeight = 132,
  });

  final WaveformBars bars;
  final List<double> beats;
  final List<Segment> segments;
  final double duration;
  final Color accent;
  final List<FocusHandle> handles;

  /// 是否处于自由放置（按住 Alt）：影响光标提示。
  final bool free;

  /// 锁定后波形拒绝放点。
  final bool locked;

  /// 试听时的播放头位置（秒），null 表示不画。
  final double? playhead;

  final double canvasHeight;

  /// 放点回调。[isMove] 区分按下（挑最近端点）与拖动（沿用当前端点）。
  final void Function(double seconds, {required bool isMove}) onPlace;

  @override
  State<ManualFocusWaveform> createState() => _ManualFocusWaveformState();
}

class _ManualFocusWaveformState extends State<ManualFocusWaveform> {
  static const double _flagPad = 20;

  double? _width;
  bool _dragging = false;

  double _timeAt(double dx) {
    final w = _width ?? 1;
    final pct = (dx / w).clamp(0.0, 1.0);
    return pct * widget.duration;
  }

  void _down(PointerDownEvent e) {
    if (widget.locked) return;
    _dragging = true;
    widget.onPlace(_timeAt(e.localPosition.dx), isMove: false);
  }

  void _move(PointerMoveEvent e) {
    if (widget.locked || !_dragging) return;
    widget.onPlace(_timeAt(e.localPosition.dx), isMove: true);
  }

  void _up(PointerUpEvent _) => _dragging = false;

  MouseCursor get _cursor {
    if (widget.locked) return SystemMouseCursors.forbidden;
    if (widget.free) return SystemMouseCursors.cell;
    return SystemMouseCursors.precise;
  }

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _segmentLane(rm),
        const SizedBox(height: 6),
        SizedBox(
          height: _flagPad + widget.canvasHeight,
          child: LayoutBuilder(
            builder: (context, c) {
              _width = c.maxWidth;
              final w = c.maxWidth;
              return MouseRegion(
                cursor: _cursor,
                child: Listener(
                  onPointerDown: _down,
                  onPointerMove: _move,
                  onPointerUp: _up,
                  onPointerCancel: (_) => _dragging = false,
                  behavior: HitTestBehavior.opaque,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Positioned.fill(
                        child: CustomPaint(
                          painter: _FocusWavePainter(
                            rm: rm,
                            bars: widget.bars,
                            beats: widget.beats,
                            duration: widget.duration,
                            accent: widget.accent,
                            handles: widget.handles,
                            topPad: _flagPad,
                            barsHeight: widget.canvasHeight,
                          ),
                        ),
                      ),
                      for (final h in widget.handles) _handle(rm, h, w),
                      if (widget.playhead != null) _playheadLine(rm, w),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 6),
        _timeAxis(rm),
      ],
    );
  }

  // --- 段落泳道 ----------------------------------------------------------
  Widget _segmentLane(RmTheme rm) {
    if (widget.duration <= 0 || widget.segments.isEmpty) {
      return const SizedBox(height: 18);
    }
    return SizedBox(
      height: 18,
      child: Row(
        children: [
          for (final s in widget.segments)
            Expanded(
              flex: (((s.end - s.start) / widget.duration) * 1000)
                  .clamp(1, 1000)
                  .round(),
              child: _segBlock(rm, s),
            ),
        ],
      ),
    );
  }

  Widget _segBlock(RmTheme rm, Segment s) {
    final (bg, fg) = _segColors(rm, s.label);
    final wide = (s.end - s.start) / widget.duration > 0.06;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 1),
      child: Container(
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(3),
        ),
        child: wide
            ? Text(
                s.label,
                maxLines: 1,
                overflow: TextOverflow.clip,
                style: RmText.mono(9.5, color: fg),
              )
            : null,
      ),
    );
  }

  // --- 端点旗标 ----------------------------------------------------------
  Widget _handle(RmTheme rm, FocusHandle h, double w) {
    final x = (h.t / widget.duration).clamp(0.0, 1.0) * w;
    final opacity = h.dim ? 0.45 : 1.0;
    final gripSize = h.active ? 20.0 : 16.0;
    return Positioned(
      left: x - 40,
      top: 0,
      bottom: 0,
      width: 80,
      child: IgnorePointer(
        child: Opacity(
          opacity: opacity,
          child: Column(
            mainAxisSize: MainAxisSize.max,
            children: [
              // 旗标
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: widget.accent,
                  borderRadius: BorderRadius.circular(4),
                  border: h.active
                      ? Border.all(color: rm.panel, width: 1.5)
                      : null,
                ),
                child: Text(
                  h.label,
                  style: RmText.mono(
                    10,
                    weight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
              ),
              // 立柱
              Expanded(child: Container(width: 2, color: widget.accent)),
              // 抓手
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Container(
                  width: gripSize,
                  height: gripSize,
                  decoration: BoxDecoration(
                    color: rm.panel,
                    shape: BoxShape.circle,
                    border: Border.all(color: widget.accent, width: 2),
                    boxShadow: h.active
                        ? [
                            BoxShadow(
                              color: widget.accent.withAlpha(64),
                              blurRadius: 6,
                              spreadRadius: 2,
                            ),
                          ]
                        : null,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _playheadLine(RmTheme rm, double w) {
    final x = (widget.playhead! / widget.duration).clamp(0.0, 1.0) * w;
    return Positioned(
      left: x - 0.75,
      top: _flagPad - 2,
      bottom: 0,
      width: 1.5,
      child: IgnorePointer(child: ColoredBox(color: rm.fg)),
    );
  }

  // --- 时间轴 ------------------------------------------------------------
  Widget _timeAxis(RmTheme rm) {
    return Row(
      children: [
        for (int i = 0; i <= 5; i++) ...[
          if (i != 0) const Spacer(),
          Text(
            _shortLabel(widget.duration * i / 5),
            style: RmText.mono(9.5, color: rm.fg4),
          ),
        ],
      ],
    );
  }
}

String _shortLabel(double t) {
  final m = t ~/ 60;
  final s = (t % 60).floor();
  return '$m:${s.toString().padLeft(2, '0')}';
}

/// 段落泳道配色 —— intro/outro 中性、verse 蓝、chorus 绿、bridge 琥珀。
(Color, Color) _segColors(RmTheme rm, String label) {
  final l = label.trim().toLowerCase();
  if (l.contains('verse')) return (RmTokens.segVerseBg, RmTokens.segVerseFg);
  if (l.contains('chorus')) return (RmTokens.segChorusBg, RmTokens.segChorusFg);
  if (l.contains('bridge')) return (RmTokens.segBridgeBg, RmTokens.segBridgeFg);
  if (l.contains('drop') || l.contains('hook')) {
    return (RmTokens.segChorusBg, RmTokens.segChorusFg);
  }
  // intro / outro / 其它 → 中性
  return (RmTokens.segIntroBg, rm.fg3);
}

class _FocusWavePainter extends CustomPainter {
  _FocusWavePainter({
    required this.rm,
    required this.bars,
    required this.beats,
    required this.duration,
    required this.accent,
    required this.handles,
    required this.topPad,
    required this.barsHeight,
  });

  final RmTheme rm;
  final WaveformBars bars;
  final List<double> beats;
  final double duration;
  final Color accent;
  final List<FocusHandle> handles;
  final double topPad;
  final double barsHeight;

  double _x(double t, double width) => (t / duration) * width;

  @override
  void paint(Canvas canvas, Size size) {
    if (duration <= 0) return;
    final width = size.width;
    final centerY = topPad + barsHeight / 2;

    // 循环阴影带（A→B）
    if (handles.length == 2) {
      final a = _x(handles[0].t, width);
      final b = _x(handles[1].t, width);
      canvas.drawRect(
        Rect.fromLTRB(
          a < b ? a : b,
          topPad,
          a < b ? b : a,
          topPad + barsHeight,
        ),
        Paint()..color = accent.withAlpha(30),
      );
    }

    // 每拍网格线（downbeat 更重）
    if (beats.isNotEmpty) {
      for (int i = 0; i < beats.length; i++) {
        final x = _x(beats[i], width);
        final down = i % 4 == 0;
        canvas.drawLine(
          Offset(x, topPad),
          Offset(x, topPad + barsHeight),
          Paint()
            ..color = (down ? rm.borderStrong : rm.border2).withAlpha(
              down ? 128 : 72,
            )
            ..strokeWidth = down ? 1 : 0.6,
        );
      }
    }

    // 中线
    canvas.drawLine(
      Offset(0, centerY),
      Offset(width, centerY),
      Paint()
        ..color = rm.border
        ..strokeWidth = 0.6,
    );

    // 波形 bars（中线对称）
    final values = bars.values;
    if (values.isNotEmpty) {
      final barPaint = Paint()..color = rm.fg3.withAlpha(200);
      final n = values.length;
      final barWidth = width / n * 0.74;
      for (int i = 0; i < n; i++) {
        final h = values[i] * (barsHeight / 2 - 4);
        final x = n == 1 ? width / 2 : (i / (n - 1)) * width;
        canvas.drawRect(
          Rect.fromLTWH(x - barWidth / 2, centerY - h, barWidth, h * 2),
          barPaint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_FocusWavePainter old) =>
      old.bars != bars ||
      old.beats != beats ||
      old.duration != duration ||
      old.accent != accent ||
      old.handles != handles ||
      old.rm != rm ||
      old.barsHeight != barsHeight;
}
