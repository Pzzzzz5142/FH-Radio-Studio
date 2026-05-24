import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../../theme/text_styles.dart';
import '../../theme/tokens.dart';
import '../../widgets/rm_chip.dart';
import '../../widgets/rm_icon.dart';

/// 顶部 "来源文件" 卡片（对齐 .target / .swatch-lg / .target-chips）。
class TargetSourceCard extends StatelessWidget {
  const TargetSourceCard({
    super.key,
    required this.source,
    required this.sourceSampleRate,
    this.aiPending = false,
    this.targetSampleRate = 48000,
    this.peakDbfs,
    this.rmsDbfs,
  });

  final String source;
  final int sourceSampleRate;
  final bool aiPending;
  final int targetSampleRate;
  final double? peakDbfs;
  final double? rmsDbfs;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      decoration: BoxDecoration(
        color: rm.panel,
        border: Border.all(color: rm.border),
        borderRadius: BorderRadius.circular(RmTokens.rLg),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: rm.raised,
              border: Border.all(color: rm.border),
              borderRadius: BorderRadius.circular(RmTokens.rSm),
            ),
            alignment: Alignment.center,
            child: RmIcon('music', size: 16, color: rm.accent.base),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '来源文件',
                  style: RmText.sans(14, weight: FontWeight.w600, color: rm.fg),
                ),
                const SizedBox(height: 2),
                Text(
                  source,
                  style: RmText.mono(12, color: rm.fg),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              if (aiPending) ...[
                const RmChip(label: 'AI 候选生成中', showDot: true),
                RmChip(
                  label: sourceSampleRate > 0 ? _sampleRateLabel() : '采样率 --',
                  showDot: true,
                ),
              ] else ...[
                RmChip(label: _sampleRateLabel(), showDot: true),
              ],
            ],
          ),
        ],
      ),
    );
  }

  String _sampleRateLabel() {
    final source = _khz(sourceSampleRate);
    final target = _khz(targetSampleRate);
    if (sourceSampleRate > 0 && sourceSampleRate != targetSampleRate) {
      return '采样率 $source → $target';
    }
    return '采样率 $target';
  }

  String _khz(int sampleRate) {
    if (sampleRate <= 0) return '未知';
    final khz = sampleRate / 1000;
    return khz == khz.roundToDouble()
        ? '${khz.round()} kHz'
        : '${khz.toStringAsFixed(1)} kHz';
  }
}
