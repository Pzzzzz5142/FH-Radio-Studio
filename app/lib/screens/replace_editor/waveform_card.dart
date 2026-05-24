import 'package:flutter/material.dart';

import '../../domain/replacement_models.dart';
import '../../theme/app_theme.dart';
import '../../theme/text_styles.dart';
import '../../theme/tokens.dart';
import '../../widgets/rm_button.dart';
import '../../widgets/rm_icon.dart';
import 'ai_pending_overlay.dart';
import 'replace_state.dart';
import 'waveform_painter.dart';

/// 波形卡片 — 包 toolbar + 主波形 + zoom strip。
class WaveformCard extends StatelessWidget {
  const WaveformCard({
    super.key,
    required this.state,
    required this.aiPending,
    required this.onSeek,
    required this.onZoomIn,
    required this.onZoomOut,
  });

  final ReplaceEditorState state;
  final bool aiPending;
  final ValueChanged<double> onSeek;
  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    final ai = state.ai;
    final bars = ai.waveformPeaks.isEmpty
        ? WaveformBars.build(segments: ai.segments, duration: ai.durationSec)
        : WaveformBars.fromValues(ai.waveformPeaks);
    final markers = <WaveformMarker>[
      WaveformMarker(t: state.td.t, label: 'TD', kind: GroupKind.td),
      WaveformMarker(t: state.pd.t, label: 'PD', kind: GroupKind.pd),
      WaveformMarker(t: state.tl.start, label: 'TL-A', kind: GroupKind.tl),
      WaveformMarker(t: state.tl.end, label: 'TL-B', kind: GroupKind.tl),
      WaveformMarker(t: state.pl.start, label: 'PL-A', kind: GroupKind.pl),
      WaveformMarker(t: state.pl.end, label: 'PL-B', kind: GroupKind.pl),
    ];

    final card = Container(
      decoration: BoxDecoration(
        color: rm.panel,
        border: Border.all(color: rm.border),
        borderRadius: BorderRadius.circular(RmTokens.rLg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _toolbar(context),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 0),
            child: _waveformArea(context, bars: bars, markers: markers),
          ),
          _timeAxis(context, ai.durationSec),
          Container(height: 1, color: rm.border),
          _zoom(context, bars: bars),
        ],
      ),
    );
    return AiPendingGate(
      pending: aiPending,
      overlayKey: const ValueKey('editor-ai-pending-waveform'),
      label: '波形与结构分析中',
      detail: '等待真实波形、节拍、段落和 marker。',
      blockInput: false,
      childOpacity: 0.42,
      child: card,
    );
  }

  Widget _toolbar(BuildContext context) {
    final rm = context.rm;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: rm.border)),
      ),
      child: Row(
        children: [
          _segGroup(context, [('波形', true), ('频谱', false), ('+ 节拍', false)]),
          const SizedBox(width: 10),
          _segGroup(context, [('段落', true), ('和弦', false)]),
          const Spacer(),
          // timecode
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: rm.raised,
              border: Border.all(color: rm.border),
              borderRadius: BorderRadius.circular(RmTokens.rSm),
            ),
            child: Row(
              children: [
                Text(
                  formatTimecode(state.playhead),
                  style: RmText.mono(12, color: rm.fg2),
                ),
                const SizedBox(width: 4),
                Text(
                  ' / ${formatTimecode(state.ai.durationSec)}',
                  style: RmText.mono(12, color: rm.fg4),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          RmButton.icon(
            onPressed: onZoomOut,
            icon: const RmIcon('zoom-out', size: 12),
          ),
          const SizedBox(width: 4),
          RmButton.icon(
            onPressed: onZoomIn,
            icon: const RmIcon('zoom-in', size: 12),
          ),
        ],
      ),
    );
  }

  Widget _segGroup(BuildContext context, List<(String, bool)> items) {
    final rm = context.rm;
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: rm.raised,
        border: Border.all(color: rm.border),
        borderRadius: BorderRadius.circular(RmTokens.rSm),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final i in items)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: i.$2 ? rm.hover : Colors.transparent,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                i.$1,
                style: RmText.mono(11, color: i.$2 ? rm.fg : rm.fg3),
              ),
            ),
        ],
      ),
    );
  }

  Widget _waveformArea(
    BuildContext context, {
    required WaveformBars bars,
    required List<WaveformMarker> markers,
  }) {
    final rm = context.rm;
    final ai = state.ai;
    return LayoutBuilder(
      builder: (context, c) {
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (d) {
            final pct = (d.localPosition.dx / c.maxWidth).clamp(0.0, 1.0);
            onSeek(pct * ai.durationSec);
          },
          child: SizedBox(
            height: WaveformPainter.totalHeight,
            width: c.maxWidth,
            child: CustomPaint(
              painter: WaveformPainter(
                rm: rm,
                bars: bars,
                beats: ai.beats,
                segments: ai.segments,
                duration: ai.durationSec,
                markers: markers,
                tlLoop: (start: state.tl.start, end: state.tl.end),
                plLoop: (start: state.pl.start, end: state.pl.end),
                playhead: state.playhead,
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _timeAxis(BuildContext context, double duration) {
    final rm = context.rm;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 4, 14, 10),
      child: Row(
        children: [
          for (int i = 0; i <= 4; i++) ...[
            if (i != 0) const Spacer(),
            Text(
              _short(duration * i / 4),
              style: RmText.mono(10, color: rm.fg4),
            ),
          ],
        ],
      ),
    );
  }

  String _short(double t) {
    final m = t ~/ 60;
    final s = (t % 60).floor();
    return '$m:${s.toString().padLeft(2, "0")}';
  }

  Widget _zoom(BuildContext context, {required WaveformBars bars}) {
    final rm = context.rm;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 10),
      height: 56,
      child: LayoutBuilder(
        builder: (context, c) {
          return CustomPaint(
            size: Size(c.maxWidth, c.maxHeight),
            painter: ZoomStripPainter(
              rm: rm,
              bars: bars,
              duration: state.ai.durationSec,
              windowStart: state.zoomStart,
              windowEnd: state.zoomEnd,
            ),
          );
        },
      ),
    );
  }
}
