import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// 5 段进度（candidate score）— 对齐 ui.jsx 的 `<ConfidencePip>`。
/// score 在 [0,1]；< 0.5 时点亮的部分变 warn 色。
class ConfidencePip extends StatelessWidget {
  const ConfidencePip({super.key, required this.score});
  final double score;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    final clamped = score.clamp(0.0, 1.0);
    final n = (clamped * 5).round();
    final isLow = score < 0.5;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (int i = 0; i < 5; i++) ...[
          if (i != 0) const SizedBox(width: 2),
          Container(
            width: 4,
            height: 8,
            decoration: BoxDecoration(
              color: i < n ? (isLow ? rm.warn : rm.accent.base) : rm.border2,
              borderRadius: BorderRadius.circular(1),
            ),
          ),
        ],
      ],
    );
  }
}
