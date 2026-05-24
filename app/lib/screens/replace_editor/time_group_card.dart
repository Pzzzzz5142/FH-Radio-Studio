import 'package:flutter/material.dart';

import '../../domain/replacement_models.dart';
import '../../theme/app_theme.dart';
import '../../theme/text_styles.dart';
import '../../theme/tokens.dart';
import '../../widgets/confidence_pip.dart';
import '../../widgets/rm_button.dart';
import '../../widgets/rm_chip.dart';
import '../../widgets/rm_icon.dart';
import 'group_colors.dart';

/// 4 个时间组的卡片 — point (TD/PD) 和 loop (TL/PL) 由 `kind.isLoop` 区分。
///
/// callbacks 都在 notifier 上跑（父屏组装）。
class TimeGroupCard extends StatelessWidget {
  const TimeGroupCard({
    super.key,
    required this.kind,
    required this.candidates,
    required this.selectedIdx,
    required this.confirmed,
    required this.lowConfidence,
    required this.onSelect,
    required this.onConfirm,
    required this.onCancelConfirm,
    required this.onPreview,
    required this.onNudge,
    required this.bpm,
  });

  final GroupKind kind;
  final List<dynamic> candidates; // PointCandidate or LoopCandidate
  final int selectedIdx;
  final bool confirmed;
  final bool lowConfidence;
  final ValueChanged<int> onSelect;
  final ValueChanged<int> onConfirm; // idx
  final VoidCallback onCancelConfirm;
  final ValueChanged<int> onPreview;
  final void Function(FineTarget target, double deltaSec) onNudge;
  final double bpm;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    final acc = groupAccent(rm, kind);

    return Container(
      decoration: BoxDecoration(
        color: rm.panel,
        border: Border.all(color: rm.border),
        borderRadius: BorderRadius.circular(RmTokens.rLg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _head(context, acc),
          if (lowConfidence) _warnBar(context, acc),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  _candidateHeading,
                  style: RmText.mono(
                    11,
                    color: rm.fg3,
                    letterSpacing: 0.08 * 11,
                  ),
                ),
                const SizedBox(height: 8),
                for (int i = 0; i < candidates.length; i++) ...[
                  if (i != 0) const SizedBox(height: 8),
                  _candRow(context, i),
                ],
                const SizedBox(height: 12),
                _fine(context),
                if (kind.isLoop) ...[
                  const SizedBox(height: 10),
                  _loopInfo(context),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  String get _candidateHeading => '候选 (top ${candidates.length})';

  // ---------------- head ----------------
  Widget _head(BuildContext context, GroupAccent acc) {
    final rm = context.rm;
    final state = confirmed
        ? _ChipState.confirmed
        : (candidates.isNotEmpty ? _ChipState.suggested : _ChipState.pending);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: rm.border)),
      ),
      child: Row(
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: acc.bg,
              border: Border.all(color: acc.ring),
              borderRadius: BorderRadius.circular(RmTokens.rSm),
            ),
            alignment: Alignment.center,
            child: Text(
              kind.code,
              style: RmText.mono(11, weight: FontWeight.w600, color: acc.base),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  kind.name,
                  style: RmText.sans(13, weight: FontWeight.w600, color: rm.fg),
                ),
                const SizedBox(height: 2),
                Text(
                  '${kind.description} · 采样率 ${kind.sampleRate}'
                  '${kind.isLoop ? " · 必须节拍对齐" : ""}',
                  style: RmText.sans(12, color: rm.fg3),
                ),
              ],
            ),
          ),
          _stateChip(state),
          if (!confirmed && candidates.isNotEmpty) ...[
            const SizedBox(width: 8),
            RmButton(
              onPressed: () => onConfirm(selectedIdx),
              size: RmButtonSize.sm,
              variant: RmButtonVariant.primary,
              leading: const RmIcon('check', size: 12),
              label: '确认',
            ),
          ],
          if (confirmed) ...[
            const SizedBox(width: 8),
            RmButton(
              onPressed: onCancelConfirm,
              size: RmButtonSize.sm,
              leading: const RmIcon('unlock', size: 12),
              label: '解锁重选',
            ),
          ],
        ],
      ),
    );
  }

  Widget _stateChip(_ChipState s) {
    return switch (s) {
      _ChipState.pending => const RmChip(
        label: '待确认',
        variant: RmChipVariant.muted,
        showDot: true,
      ),
      _ChipState.suggested => const RmChip(label: 'AI 已建议', showDot: true),
      _ChipState.confirmed => const RmChip(
        label: '已确认',
        variant: RmChipVariant.accent,
        leading: RmIcon('lock', size: 10),
        showDot: true,
      ),
    };
  }

  Widget _warnBar(BuildContext context, GroupAccent acc) {
    final rm = context.rm;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
      decoration: BoxDecoration(
        color: rm.warnBg,
        border: Border(top: BorderSide(color: rm.warn.withAlpha(64))),
      ),
      child: Row(
        children: [
          RmIcon('warn', size: 14, color: rm.warn),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              kind.isLoop
                  ? 'AI 信心不足。建议先点"试听拼接"听一遍循环点是否无缝，再确认。'
                  : 'AI 信心不足（top score < 0.5）。请手动指定或听过候选后再确认。',
              style: RmText.sans(12, color: rm.warn),
            ),
          ),
        ],
      ),
    );
  }

  // ---------------- candidate row ----------------
  Widget _candRow(BuildContext context, int i) {
    final rm = context.rm;
    final c = candidates[i];
    final selected = !confirmed && i == selectedIdx;
    final isConfirmedRow = confirmed && i == selectedIdx;
    final lockedOut = confirmed && i != selectedIdx;
    final highlight = selected || isConfirmedRow;
    final bg = highlight ? rm.accent.bg : (lockedOut ? rm.panel : rm.raised);
    final border = highlight
        ? rm.accent.base
        : (lockedOut ? rm.border.withAlpha(150) : rm.border);

    return MouseRegion(
      cursor: confirmed ? SystemMouseCursors.basic : SystemMouseCursors.click,
      child: GestureDetector(
        onTap: confirmed ? null : () => onSelect(i),
        child: Container(
          clipBehavior: Clip.antiAlias,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: bg,
            border: Border.all(color: border),
            borderRadius: BorderRadius.circular(RmTokens.rSm),
          ),
          child: Stack(
            children: [
              if (lockedOut)
                Positioned.fill(
                  child: CustomPaint(
                    painter: _LockedStripePainter(
                      color: rm.border.withAlpha(120),
                    ),
                  ),
                ),
              Row(
                children: [
                  // rank
                  Container(
                    width: 22,
                    height: 22,
                    decoration: BoxDecoration(
                      color: highlight ? rm.accent.base : rm.bg,
                      border: Border.all(
                        color: highlight
                            ? rm.accent.base
                            : (lockedOut ? rm.borderStrong : rm.border),
                      ),
                      borderRadius: BorderRadius.circular(5),
                    ),
                    alignment: Alignment.center,
                    child: lockedOut
                        ? RmIcon('lock', size: 10, color: rm.fg4)
                        : Text(
                            '${i + 1}',
                            style: RmText.mono(
                              10.5,
                              color: highlight ? rm.accent.onAccent : rm.fg2,
                            ),
                          ),
                  ),
                  const SizedBox(width: 12),
                  // time + why
                  Expanded(child: _timeBlock(context, c, muted: lockedOut)),
                  // score + actions
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Row(
                        children: [
                          ConfidencePip(score: c.score as double),
                          const SizedBox(width: 8),
                          Text(
                            '${((c.score as double) * 100).round()}%',
                            style: RmText.mono(
                              11,
                              color: lockedOut ? rm.fg4 : rm.fg2,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      if (isConfirmedRow)
                        const RmChip(
                          label: '当前选择',
                          variant: RmChipVariant.accent,
                          leading: RmIcon('lock', size: 10),
                        )
                      else if (lockedOut)
                        const RmChip(
                          label: '锁定',
                          variant: RmChipVariant.muted,
                          leading: RmIcon('lock', size: 10),
                        )
                      else
                        RmButton(
                          onPressed: () => onPreview(i),
                          size: RmButtonSize.sm,
                          variant: RmButtonVariant.ghost,
                          leading: RmIcon(
                            kind.isLoop ? 'loop' : 'play',
                            size: 11,
                          ),
                          label: kind.isLoop ? '试听拼接' : '试听',
                        ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _timeBlock(BuildContext context, dynamic c, {required bool muted}) {
    final rm = context.rm;
    final primary = muted ? rm.fg3 : rm.fg;
    final secondary = muted ? rm.fg4 : rm.fg3;
    if (kind.isLoop) {
      final lc = c as LoopCandidate;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                formatTimecode(lc.start),
                style: RmText.mono(13, weight: FontWeight.w600, color: primary),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Text('→', style: RmText.sans(12, color: secondary)),
              ),
              Text(
                formatTimecode(lc.end),
                style: RmText.mono(13, weight: FontWeight.w600, color: primary),
              ),
              const SizedBox(width: 8),
              Text(
                'Δ ${(lc.end - lc.start).toStringAsFixed(2)}s · ${lc.bars} 小节',
                style: RmText.mono(10.5, color: secondary),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(lc.why, style: RmText.sans(11.5, color: secondary)),
        ],
      );
    } else {
      final pc = c as PointCandidate;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                formatTimecode(pc.t),
                style: RmText.mono(13, weight: FontWeight.w600, color: primary),
              ),
              const SizedBox(width: 6),
              Text(
                '= ${formatSamples(pc.t, kind.sampleRate)} samples',
                style: RmText.mono(10, color: secondary),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(pc.why, style: RmText.sans(11.5, color: secondary)),
        ],
      );
    }
  }

  // ---------------- fine tune row ----------------
  Widget _fine(BuildContext context) {
    if (candidates.isEmpty) return const SizedBox.shrink();
    final c = candidates[selectedIdx];
    if (kind.isLoop) {
      final lc = c as LoopCandidate;
      return Row(
        children: [
          Expanded(
            child: _fineCell(
              context,
              label: 'A · start',
              value: formatTimecode(lc.start),
              target: FineTarget.loopStart,
              includeMsControls: false,
              locked: confirmed,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _fineCell(
              context,
              label: 'B · end',
              value: formatTimecode(lc.end),
              target: FineTarget.loopEnd,
              includeMsControls: false,
              locked: confirmed,
            ),
          ),
        ],
      );
    } else {
      final pc = c as PointCandidate;
      return _fineCell(
        context,
        label: '已选',
        value: formatTimecode(pc.t),
        target: FineTarget.point,
        includeMsControls: true,
        locked: confirmed,
      );
    }
  }

  Widget _fineCell(
    BuildContext context, {
    required String label,
    required String value,
    required FineTarget target,
    required bool includeMsControls,
    required bool locked,
  }) {
    final rm = context.rm;
    final beat = 60 / bpm;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: rm.raised,
        border: Border.all(color: rm.border),
        borderRadius: BorderRadius.circular(RmTokens.rSm),
      ),
      child: Row(
        children: [
          Text(
            label.toUpperCase(),
            style: RmText.mono(11, color: rm.fg3, letterSpacing: 0.08 * 11),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              value,
              style: RmText.mono(
                14,
                weight: FontWeight.w600,
                color: locked ? rm.fg3 : rm.fg,
              ),
            ),
          ),
          RmButton(
            onPressed: locked ? null : () => onNudge(target, -beat),
            size: RmButtonSize.sm,
            label: '−拍',
          ),
          const SizedBox(width: 2),
          RmButton(
            onPressed: locked ? null : () => onNudge(target, beat),
            size: RmButtonSize.sm,
            label: '+拍',
          ),
          if (includeMsControls) ...[
            const SizedBox(width: 2),
            RmButton(
              onPressed: locked ? null : () => onNudge(target, -0.010),
              size: RmButtonSize.sm,
              label: '−10ms',
            ),
            const SizedBox(width: 2),
            RmButton(
              onPressed: locked ? null : () => onNudge(target, 0.010),
              size: RmButtonSize.sm,
              label: '+10ms',
            ),
          ],
        ],
      ),
    );
  }

  Widget _loopInfo(BuildContext context) {
    final rm = context.rm;
    return Wrap(
      spacing: 14,
      runSpacing: 4,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('BPM ', style: RmText.mono(11, color: rm.fg3)),
            Text(bpm.toStringAsFixed(1), style: RmText.mono(11, color: rm.fg)),
          ],
        ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('1 拍 = ', style: RmText.mono(11, color: rm.fg3)),
            Text(
              '${(60 / bpm * 1000).toStringAsFixed(1)} ms',
              style: RmText.mono(11, color: rm.fg),
            ),
          ],
        ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('磁吸 ', style: RmText.mono(11, color: rm.fg3)),
            Text('downbeat', style: RmText.mono(11, color: rm.accent.base)),
          ],
        ),
      ],
    );
  }
}

class _LockedStripePainter extends CustomPainter {
  const _LockedStripePainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    const gap = 12.0;
    for (double x = -size.height; x < size.width + size.height; x += gap) {
      canvas.drawLine(
        Offset(x, size.height),
        Offset(x + size.height, 0),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _LockedStripePainter oldDelegate) {
    return oldDelegate.color != color;
  }
}

enum _ChipState { pending, suggested, confirmed }
