import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/text_styles.dart';
import '../theme/tokens.dart';

class StatCard extends StatelessWidget {
  const StatCard({
    super.key,
    required this.label,
    required this.value,
    this.delta,
    this.valueColor,
    this.deltaUp = false,
  });

  final String label;
  final String value;
  final String? delta;
  final Color? valueColor;
  final bool deltaUp;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    final labelHasCjk = _hasCjk(label);
    final deltaHasCjk = delta != null && _hasCjk(delta!);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      decoration: BoxDecoration(
        color: rm.panel,
        borderRadius: BorderRadius.circular(RmTokens.rLg),
        border: Border.all(color: rm.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            labelHasCjk ? label : label.toUpperCase(),
            style: labelHasCjk
                ? RmText.sans(12, color: rm.fg3, weight: FontWeight.w500)
                : RmText.mono(11, color: rm.fg3, letterSpacing: 0.1 * 11),
          ),
          const SizedBox(height: 6),
          Text(value, style: RmText.statValue(color: valueColor ?? rm.fg)),
          if (delta != null) ...[
            const SizedBox(height: 4),
            Text(
              delta!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: deltaHasCjk
                  ? RmText.sans(12, color: deltaUp ? rm.accent.base : rm.fg3)
                  : RmText.mono(11, color: deltaUp ? rm.accent.base : rm.fg3),
            ),
          ],
        ],
      ),
    );
  }

  bool _hasCjk(String value) {
    return RegExp(r'[\u3400-\u9fff]').hasMatch(value);
  }
}
