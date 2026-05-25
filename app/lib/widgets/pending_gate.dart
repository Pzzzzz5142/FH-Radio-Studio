import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/text_styles.dart';
import '../theme/tokens.dart';

enum PendingOverlayTone { accent, danger }

class PendingGate extends StatelessWidget {
  const PendingGate({
    super.key,
    required this.pending,
    required this.child,
    required this.label,
    this.detail,
    this.detailWidget,
    this.overlayKey,
    this.blockInput = true,
    this.compact = false,
    this.childOpacity = 0.36,
    this.borderRadius,
    this.tone = PendingOverlayTone.accent,
  });

  final bool pending;
  final Widget child;
  final String label;
  final String? detail;
  final Widget? detailWidget;
  final Key? overlayKey;
  final bool blockInput;
  final bool compact;
  final double childOpacity;
  final BorderRadius? borderRadius;
  final PendingOverlayTone tone;

  @override
  Widget build(BuildContext context) {
    if (!pending) return child;
    final radius = borderRadius ?? BorderRadius.circular(RmTokens.rLg);
    return ClipRRect(
      borderRadius: radius,
      child: Stack(
        children: [
          IgnorePointer(
            ignoring: blockInput,
            child: Opacity(opacity: childOpacity, child: child),
          ),
          Positioned.fill(
            child: PendingOverlay(
              key: overlayKey,
              label: label,
              detail: detail,
              detailWidget: detailWidget,
              compact: compact,
              borderRadius: radius,
              tone: tone,
            ),
          ),
        ],
      ),
    );
  }
}

class PendingOverlay extends StatelessWidget {
  const PendingOverlay({
    super.key,
    required this.label,
    this.detail,
    this.detailWidget,
    this.progressLabel,
    this.progressDetail,
    this.progressValue,
    this.progressCaption,
    this.progressExtra,
    this.contentConstraints,
    this.interactive = false,
    this.compact = false,
    this.borderRadius,
    this.tone = PendingOverlayTone.accent,
  });

  final String label;
  final String? detail;
  final Widget? detailWidget;
  final String? progressLabel;
  final String? progressDetail;
  final double? progressValue;
  final String? progressCaption;
  final Widget? progressExtra;
  final BoxConstraints? contentConstraints;
  final bool interactive;
  final bool compact;
  final BorderRadius? borderRadius;
  final PendingOverlayTone tone;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    final toneColor = switch (tone) {
      PendingOverlayTone.accent => rm.accent.base,
      PendingOverlayTone.danger => rm.danger,
    };
    final toneRing = switch (tone) {
      PendingOverlayTone.accent => rm.accent.ring,
      PendingOverlayTone.danger => rm.danger.withAlpha(77),
    };
    final tint = rm.panel.withAlpha(compact ? 232 : 222);
    final border = rm.border.withAlpha(180);
    final content = Container(
      padding: compact
          ? const EdgeInsets.symmetric(horizontal: 12, vertical: 10)
          : const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      decoration: BoxDecoration(
        color: rm.bg.withAlpha(compact ? 220 : 204),
        border: Border.all(color: border),
        borderRadius: BorderRadius.circular(RmTokens.rSm),
        boxShadow: compact ? null : RmTokens.popover,
      ),
      child: _PendingContentWidth(
        constraints: contentConstraints,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: compact
              ? CrossAxisAlignment.start
              : CrossAxisAlignment.stretch,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox.square(
                  dimension: compact ? 7 : 8,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: toneColor,
                      shape: BoxShape.circle,
                      boxShadow: [BoxShadow(color: toneRing, blurRadius: 8)],
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  label,
                  style: RmText.sans(
                    compact ? 11.5 : 12.5,
                    weight: FontWeight.w600,
                    color: rm.fg,
                  ),
                ),
              ],
            ),
            if (detail != null || detailWidget != null) ...[
              const SizedBox(height: 4),
              detailWidget ??
                  Text(
                    detail!,
                    style: RmText.sans(
                      compact ? 11 : 11.5,
                      color: tone == PendingOverlayTone.danger
                          ? toneColor
                          : rm.fg3,
                      weight: compact ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
            ],
            if (progressLabel != null && !compact) ...[
              const SizedBox(height: 10),
              Container(
                key: const ValueKey('pending-overlay-progress-item'),
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: rm.panel.withAlpha(210),
                  border: Border.all(color: rm.border.withAlpha(180)),
                  borderRadius: BorderRadius.circular(RmTokens.rXs),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Text('当前', style: RmText.mono(10.5, color: rm.fg3)),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            progressLabel!,
                            style: RmText.sans(
                              12,
                              weight: FontWeight.w600,
                              color: rm.fg,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (progressCaption != null) ...[
                          const SizedBox(width: 12),
                          Text(
                            progressCaption!,
                            style: RmText.mono(11, color: toneColor),
                          ),
                        ],
                      ],
                    ),
                    if ((progressDetail ?? '').isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        progressDetail!,
                        style: RmText.sans(11, color: rm.fg3),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
            ],
            if (progressExtra != null && !compact) ...[
              const SizedBox(height: 10),
              progressExtra!,
            ],
            const SizedBox(height: 8),
            SizedBox(
              key: const ValueKey('pending-overlay-progress-track'),
              width: compact ? 112 : null,
              height: 2,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: LinearProgressIndicator(
                  minHeight: 2,
                  value: progressValue,
                  backgroundColor: rm.border.withAlpha(120),
                  valueColor: AlwaysStoppedAnimation<Color>(toneColor),
                ),
              ),
            ),
          ],
        ),
      ),
    );

    final overlay = DecoratedBox(
      decoration: BoxDecoration(color: tint, borderRadius: borderRadius),
      child: Stack(
        children: [
          Positioned.fill(
            child: CustomPaint(
              painter: _PendingGridPainter(
                color: rm.border.withAlpha(compact ? 68 : 54),
              ),
            ),
          ),
          Align(alignment: Alignment.center, child: content),
        ],
      ),
    );
    return interactive ? overlay : IgnorePointer(child: overlay);
  }
}

class _PendingContentWidth extends StatelessWidget {
  const _PendingContentWidth({required this.child, this.constraints});

  final Widget child;
  final BoxConstraints? constraints;

  @override
  Widget build(BuildContext context) {
    final constraints = this.constraints;
    if (constraints == null) return IntrinsicWidth(child: child);
    return ConstrainedBox(constraints: constraints, child: child);
  }
}

class AiPendingGate extends PendingGate {
  const AiPendingGate({
    super.key,
    required super.pending,
    required super.child,
    required super.label,
    super.detail,
    super.overlayKey,
    super.blockInput,
    super.compact,
    super.childOpacity,
    super.borderRadius,
  });
}

class AiPendingOverlay extends PendingOverlay {
  const AiPendingOverlay({
    super.key,
    required super.label,
    super.detail,
    super.compact,
    super.borderRadius,
  });
}

class _PendingGridPainter extends CustomPainter {
  const _PendingGridPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    const step = 18.0;
    for (double x = -size.height; x < size.width; x += step) {
      canvas.drawLine(
        Offset(x, 0),
        Offset(x + size.height, size.height),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _PendingGridPainter oldDelegate) {
    return oldDelegate.color != color;
  }
}
