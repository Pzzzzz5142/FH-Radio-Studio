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
    required this.manualCandidate,
    required this.manualSelected,
    required this.onManualRefine,
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
  final dynamic manualCandidate; // PointCandidate or LoopCandidate
  final bool manualSelected;
  final VoidCallback onManualRefine;
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
                const SizedBox(height: 8),
                _manualRow(context),
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

  Widget _manualRow(BuildContext context) {
    final rm = context.rm;
    final hasManual = manualCandidate != null;
    final lockedOut = confirmed && !manualSelected;
    final highlight = manualSelected;
    final bg = highlight ? rm.accent.bg : (lockedOut ? rm.panel : rm.raised);
    final muted = lockedOut;

    return _RainbowManualRefineCard(
      key: ValueKey('editor-manual-refine-${kind.code.toLowerCase()}'),
      enabled: !confirmed,
      background: bg,
      onTap: confirmed ? null : onManualRefine,
      childBuilder: (context, hovered) {
        return Row(
          children: [
            Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                color: highlight ? rm.accent.base : rm.bg,
                border: Border.all(
                  color: highlight ? rm.accent.base : rm.border,
                ),
                borderRadius: BorderRadius.circular(5),
              ),
              alignment: Alignment.center,
              child: lockedOut
                  ? RmIcon('lock', size: 10, color: rm.fg4)
                  : Text(
                      'M',
                      style: RmText.mono(
                        10.5,
                        weight: FontWeight.w700,
                        color: highlight ? rm.accent.onAccent : rm.fg2,
                      ),
                    ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: hasManual
                  ? _timeBlock(context, manualCandidate, muted: muted)
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        AnimatedSlide(
                          offset: hovered
                              ? const Offset(0, -0.08)
                              : Offset.zero,
                          duration: const Duration(milliseconds: 150),
                          curve: Curves.easeOutCubic,
                          child: Text(
                            '人工选点',
                            style: RmText.sans(
                              13,
                              weight: FontWeight.w600,
                              color: muted ? rm.fg3 : rm.fg,
                            ),
                          ),
                        ),
                        AnimatedSize(
                          duration: const Duration(milliseconds: 150),
                          curve: Curves.easeOutCubic,
                          alignment: Alignment.topLeft,
                          child: hovered
                              ? Padding(
                                  padding: const EdgeInsets.only(top: 2),
                                  child: Text(
                                    '这都什么玩意，我自己来！',
                                    style: RmText.sans(
                                      11.5,
                                      color: muted ? rm.fg4 : rm.fg3,
                                    ),
                                  ),
                                )
                              : const SizedBox.shrink(),
                        ),
                      ],
                    ),
            ),
            const SizedBox(width: 12),
            SizedBox(
              width: 112,
              child: Align(
                alignment: Alignment.centerRight,
                child: confirmed
                    ? RmChip(
                        label: manualSelected ? '人工锁定' : '锁定',
                        variant: manualSelected
                            ? RmChipVariant.accent
                            : RmChipVariant.muted,
                        leading: const RmIcon('lock', size: 10),
                      )
                    : MouseRegion(
                        cursor: SystemMouseCursors.click,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: onManualRefine,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 2,
                              vertical: 4,
                            ),
                            child: Text(
                              hasManual ? '继续精修' : '人工精修',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: RmText.sans(
                                12.5,
                                weight: FontWeight.w600,
                                color: hovered ? rm.fg : rm.fg2,
                              ),
                            ),
                          ),
                        ),
                      ),
              ),
            ),
          ],
        );
      },
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
    if (candidates.isEmpty && manualCandidate == null) {
      return const SizedBox.shrink();
    }
    final c = candidates.isEmpty
        ? manualCandidate
        : manualSelected && manualCandidate != null
        ? manualCandidate
        : candidates[selectedIdx.clamp(0, candidates.length - 1).toInt()];
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

class _RainbowManualRefineCard extends StatefulWidget {
  const _RainbowManualRefineCard({
    super.key,
    required this.enabled,
    required this.background,
    required this.onTap,
    required this.childBuilder,
  });

  final bool enabled;
  final Color background;
  final VoidCallback? onTap;
  final Widget Function(BuildContext context, bool hovered) childBuilder;

  @override
  State<_RainbowManualRefineCard> createState() =>
      _RainbowManualRefineCardState();
}

class _RainbowManualRefineCardState extends State<_RainbowManualRefineCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _flow;
  bool _hovered = false;

  @override
  void initState() {
    super.initState();
    _flow = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    );
  }

  @override
  void didUpdateWidget(covariant _RainbowManualRefineCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled && _flow.isAnimating) {
      _flow.stop();
    } else if (widget.enabled && _hovered && !_flow.isAnimating) {
      _flow.repeat();
    }
  }

  @override
  void dispose() {
    _flow.dispose();
    super.dispose();
  }

  void _setHovered(bool value) {
    if (_hovered == value) return;
    setState(() => _hovered = value);
    if (value && widget.enabled) {
      _flow.repeat();
    } else {
      _flow.stop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(RmTokens.rSm);
    return MouseRegion(
      cursor: widget.enabled
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      onEnter: (_) => _setHovered(true),
      onExit: (_) => _setHovered(false),
      child: GestureDetector(
        onTap: widget.enabled ? widget.onTap : null,
        child: AnimatedSlide(
          offset: _hovered && widget.enabled
              ? const Offset(0, -0.035)
              : Offset.zero,
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOutCubic,
          child: CustomPaint(
            painter: _RainbowManualRefineGlowPainter(
              animation: _flow,
              hovered: _hovered,
              enabled: widget.enabled,
              borderRadius: radius,
            ),
            foregroundPainter: _RainbowManualRefineBorderPainter(
              animation: _flow,
              hovered: _hovered,
              enabled: widget.enabled,
              borderRadius: radius,
            ),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: widget.background,
                borderRadius: radius,
              ),
              child: Container(
                constraints: const BoxConstraints(minHeight: 74),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                child: widget.childBuilder(context, _hovered && widget.enabled),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RainbowManualRefineGlowPainter extends CustomPainter {
  _RainbowManualRefineGlowPainter({
    required this.animation,
    required this.hovered,
    required this.enabled,
    required this.borderRadius,
  }) : super(repaint: animation);

  final Animation<double> animation;
  final bool hovered;
  final bool enabled;
  final BorderRadius borderRadius;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || !hovered || !enabled) return;

    final rect = Offset.zero & size;
    final shader = SweepGradient(
      colors: _rainbowManualRefineGradientColors(animation.value, 220),
    ).createShader(rect.inflate(10));
    final glowPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 9
      ..shader = shader
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);

    canvas.drawRRect(borderRadius.toRRect(rect.inflate(1.5)), glowPaint);
  }

  @override
  bool shouldRepaint(covariant _RainbowManualRefineGlowPainter oldDelegate) {
    return oldDelegate.hovered != hovered ||
        oldDelegate.enabled != enabled ||
        oldDelegate.borderRadius != borderRadius ||
        oldDelegate.animation != animation;
  }
}

class _RainbowManualRefineBorderPainter extends CustomPainter {
  _RainbowManualRefineBorderPainter({
    required this.animation,
    required this.hovered,
    required this.enabled,
    required this.borderRadius,
  }) : super(repaint: animation);

  final Animation<double> animation;
  final bool hovered;
  final bool enabled;
  final BorderRadius borderRadius;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;

    final active = hovered && enabled;
    final alpha = enabled ? 230 : 120;
    final rect = Offset.zero & size;
    final phase = active ? animation.value : 0.08;
    final colors = _rainbowManualRefineGradientColors(phase, alpha);
    final strokeWidth = active ? 1.65 : 1.05;
    final borderRect = rect.deflate(strokeWidth / 2);
    final border = borderRadius.toRRect(borderRect);

    final borderPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..shader = SweepGradient(colors: colors).createShader(rect);
    canvas.drawRRect(border, borderPaint);
  }

  @override
  bool shouldRepaint(covariant _RainbowManualRefineBorderPainter oldDelegate) {
    return oldDelegate.hovered != hovered ||
        oldDelegate.enabled != enabled ||
        oldDelegate.borderRadius != borderRadius ||
        oldDelegate.animation != animation;
  }
}

const _rainbowManualRefinePalette = <Color>[
  Color(0xFFFF3CAC),
  Color(0xFFFF4D6D),
  Color(0xFFFFA928),
  Color(0xFFFFFF45),
  Color(0xFF00F5A0),
  Color(0xFF00D9FF),
  Color(0xFF6C63FF),
];

List<Color> _rainbowManualRefineGradientColors(
  double phase,
  int alpha, {
  int samples = 32,
}) {
  final colors = <Color>[
    for (var i = 0; i < samples; i += 1)
      _rainbowManualRefineColorAt(i / samples + phase, alpha),
  ];
  colors.add(colors.first);
  return colors;
}

Color _rainbowManualRefineColorAt(double value, int alpha) {
  final wrapped = value - value.floorToDouble();
  final position = wrapped * _rainbowManualRefinePalette.length;
  final index = position.floor() % _rainbowManualRefinePalette.length;
  final next = (index + 1) % _rainbowManualRefinePalette.length;
  final t = position - position.floorToDouble();
  return Color.lerp(
    _rainbowManualRefinePalette[index],
    _rainbowManualRefinePalette[next],
    t,
  )!.withAlpha(alpha);
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
