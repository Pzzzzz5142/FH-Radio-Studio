import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// 4 段进度条（custom pool 行内 confirmed 0..4 用）。
/// 对齐 styles.css `.tp-bars` —— 14×5 px 实色块，未激活灰，激活 accent。
class ProgressBars extends StatelessWidget {
  const ProgressBars({
    super.key,
    required this.value,
    this.total = 4,
    this.barWidth = 14,
    this.barHeight = 5,
    this.gap = 2,
    this.color,
  });

  final int value;
  final int total;
  final double barWidth;
  final double barHeight;
  final double gap;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    final on = color ?? rm.accent.base;
    final off = rm.border2;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (int i = 0; i < total; i++) ...[
          if (i != 0) SizedBox(width: gap),
          Container(
            width: barWidth,
            height: barHeight,
            decoration: BoxDecoration(
              color: i < value ? on : off,
              borderRadius: BorderRadius.circular(1),
            ),
          ),
        ],
      ],
    );
  }
}
