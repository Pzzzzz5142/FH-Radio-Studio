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
    this.dense = false,
  });

  final String label;
  final RmChipVariant variant;
  final Widget? leading;
  final bool showDot;

  /// 紧凑模式：更小的字号与内边距，整体高度低于正文行高，
  /// 方便嵌进标题行而不撑高那一行。
  final bool dense;

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

    final dotSize = dense ? 5.0 : 6.0;
    final gap = dense ? 4.0 : 6.0;
    return Container(
      padding: dense
          ? const EdgeInsets.symmetric(horizontal: 6, vertical: 1)
          : const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
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
              width: dotSize,
              height: dotSize,
              decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
            ),
            SizedBox(width: gap),
          ],
          if (leading != null) ...[
            IconTheme.merge(
              data: IconThemeData(color: text, size: dense ? 9 : 10),
              child: leading!,
            ),
            SizedBox(width: gap),
          ],
          Text(
            label,
            style: dense
                ? RmText.mono(9.5, color: text)
                : RmText.chip(color: text),
          ),
        ],
      ),
    );
  }
}
