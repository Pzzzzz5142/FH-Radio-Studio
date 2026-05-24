import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/text_styles.dart';

enum RmChipVariant { defaultC, accent, info, skip, warn, danger, muted }

class RmChip extends StatelessWidget {
  const RmChip({
    super.key,
    required this.label,
    this.variant = RmChipVariant.defaultC,
    this.leading,
    this.showDot = false,
  });

  final String label;
  final RmChipVariant variant;
  final Widget? leading;
  final bool showDot;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;

    Color text;
    Color border;
    Color bg;
    Color dot;
    switch (variant) {
      case RmChipVariant.defaultC:
        text = rm.fg2;
        border = rm.border;
        bg = rm.raised;
        dot = rm.fg3;
      case RmChipVariant.accent:
        text = rm.accent.base;
        border = rm.accent.ring;
        bg = rm.accent.bg;
        dot = rm.accent.base;
      case RmChipVariant.info:
        text = rm.info;
        border = rm.info.withAlpha(102);
        bg = Color.alphaBlend(rm.info.withAlpha(22), rm.raised);
        dot = rm.info;
      case RmChipVariant.skip:
        text = Color.alphaBlend(rm.info.withAlpha(95), rm.fg2);
        border = rm.info.withAlpha(58);
        bg = Color.alphaBlend(rm.info.withAlpha(10), rm.raised);
        dot = Color.alphaBlend(rm.info.withAlpha(95), rm.fg3);
      case RmChipVariant.warn:
        text = rm.warn;
        border = rm.warn.withAlpha(102); // 0.4
        bg = rm.warnBg;
        dot = rm.warn;
      case RmChipVariant.danger:
        text = rm.danger;
        border = rm.danger.withAlpha(102);
        bg = rm.dangerBg;
        dot = rm.danger;
      case RmChipVariant.muted:
        text = rm.fg3;
        border = rm.border;
        bg = rm.raised;
        dot = rm.fg4;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showDot) ...[
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
            ),
            const SizedBox(width: 6),
          ],
          if (leading != null) ...[
            IconTheme.merge(
              data: IconThemeData(color: text, size: 10),
              child: leading!,
            ),
            const SizedBox(width: 6),
          ],
          Text(label, style: RmText.chip(color: text)),
        ],
      ),
    );
  }
}
