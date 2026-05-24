import 'package:flutter/material.dart';

import '../../domain/replacement_models.dart';
import '../../state/audio_analysis_state.dart';
import '../../theme/app_theme.dart';
import '../../theme/text_styles.dart';
import '../../theme/tokens.dart';
import '../../widgets/rm_button.dart';
import '../../widgets/rm_icon.dart';
import '../../widgets/rm_panel.dart';
import 'ai_pending_overlay.dart';
import 'replace_state.dart';

class EditorSidePanel extends StatelessWidget {
  const EditorSidePanel({
    super.key,
    required this.state,
    required this.analysis,
    required this.onAnalyze,
  });

  final ReplaceEditorState state;
  final AudioAnalysisState? analysis;
  final VoidCallback onAnalyze;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _aiCard(context),
        const SizedBox(height: 14),
        _shortcutsCard(context),
      ],
    );
  }

  Widget _aiCard(BuildContext context) {
    final rm = context.rm;
    final ai = state.ai;
    final confLow = ai.confidence < 0.5;
    return Container(
      key: const ValueKey('editor-ai-card'),
      decoration: BoxDecoration(
        color: rm.panel,
        borderRadius: BorderRadius.circular(RmTokens.rLg),
        border: Border.all(color: rm.border),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: rm.border)),
            ),
            child: Row(
              children: [
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    color: rm.accent.base,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(color: rm.accent.ring, blurRadius: 8),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  'AI 分析',
                  style: RmText.body(weight: FontWeight.w600, color: rm.fg),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: (analysis?.hasProgress ?? false)
                        ? _analysisSummaryTag(context, analysis!)
                        : const SizedBox.shrink(),
                  ),
                ),
                const SizedBox(width: 8),
                RmButton.icon(
                  onPressed: state.analyzing ? null : onAnalyze,
                  variant: RmButtonVariant.ghost,
                  icon: const RmIcon('refresh', size: 13),
                  tooltip: '重新分析',
                ),
              ],
            ),
          ),
          if (state.analyzing && (analysis?.hasProgress ?? false))
            _pipelineProgress(context, analysis!)
          else
            AiPendingGate(
              pending: state.aiPending,
              overlayKey: const ValueKey('editor-ai-pending-side'),
              label: '统计生成中',
              detail: '等待真实音频参数。',
              compact: true,
              blockInput: true,
              borderRadius: const BorderRadius.only(
                bottomLeft: Radius.circular(RmTokens.rLg),
                bottomRight: Radius.circular(RmTokens.rLg),
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 12, 18, 18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _row(
                      context,
                      '全局置信度',
                      '${(ai.confidence * 100).round()}%',
                      valueColor: confLow ? rm.warn : rm.fg,
                    ),
                    _row(context, '总时长', formatTimecode(ai.durationSec)),
                    _row(
                      context,
                      '采样数 (48k)',
                      formatSamples(ai.durationSec, 48000),
                    ),
                    _row(context, 'BPM', ai.bpm.toStringAsFixed(1)),
                    _row(context, '节拍数', '${ai.beats.length}'),
                    _row(context, '段落识别', '${ai.segments.length}'),
                    Container(
                      height: 1,
                      color: rm.border,
                      margin: const EdgeInsets.symmetric(vertical: 8),
                    ),
                    _row(
                      context,
                      'TD top score',
                      _scorePercent(ai.td),
                      valueColor: rm.accent.base,
                    ),
                    _row(
                      context,
                      'PD top score',
                      _scorePercent(ai.pd),
                      valueColor: rm.accent.base,
                    ),
                    _row(
                      context,
                      'TL top score',
                      _scorePercent(ai.tl),
                      valueColor: rm.accent.base,
                    ),
                    _row(
                      context,
                      'PL top score',
                      _scorePercent(ai.pl),
                      valueColor: rm.accent.base,
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _analysisSummaryTag(
    BuildContext context,
    AudioAnalysisState analysis,
  ) {
    final rm = context.rm;
    final completed = analysis.progressSteps
        .where((step) => step.terminal)
        .length;
    final total = analysis.progressSteps.length;
    final runtime = analysis.progressSteps.fold<int>(
      0,
      (sum, step) => sum + (step.runtimeMs ?? 0),
    );
    final label = analysis.busy
        ? '运行中 · $completed/$total'
        : '${_durationLabel(runtime)} · $total steps';
    final textColor = analysis.busy ? rm.accent.base : rm.fg3;
    final borderColor = analysis.busy ? rm.accent.ring : rm.border;
    final bgColor = analysis.busy ? rm.accent.bg : rm.raised;
    return Tooltip(
      message: _analysisSummaryTooltip(analysis),
      waitDuration: const Duration(milliseconds: 350),
      child: Container(
        key: const ValueKey('editor-ai-summary-tag'),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: borderColor),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            RmIcon('info', size: 10, color: textColor),
            const SizedBox(width: 5),
            Flexible(
              child: Text(
                label,
                style: RmText.chip(color: textColor),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _analysisSummaryTooltip(AudioAnalysisState analysis) {
    final lines = <String>[
      analysis.busy
          ? '本次 AI 分析流程'
          : '本次 AI 分析用时 ${_durationLabel(_analysisRuntimeMs(analysis))}',
      for (final step in analysis.progressSteps)
        '${_statusLabel(step.status)} ${step.label}${step.runtimeMs == null ? '' : ' · ${_durationLabel(step.runtimeMs!)}'}',
    ];
    return lines.join('\n');
  }

  int _analysisRuntimeMs(AudioAnalysisState analysis) {
    return analysis.progressSteps.fold<int>(
      0,
      (sum, step) => sum + (step.runtimeMs ?? 0),
    );
  }

  String _durationLabel(int runtimeMs) {
    if (runtimeMs >= 1000) return '${(runtimeMs / 1000).toStringAsFixed(1)}s';
    return '${runtimeMs}ms';
  }

  String _statusLabel(String status) {
    return switch (status) {
      'running' => '运行中',
      'done' => '完成',
      'skipped' => '跳过',
      'warning' => '注意',
      'error' => '失败',
      _ => '等待',
    };
  }

  Widget _pipelineProgress(BuildContext context, AudioAnalysisState analysis) {
    final rm = context.rm;
    final active = analysis.activeProgressStep;
    return Padding(
      key: const ValueKey('editor-ai-pipeline-progress'),
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text('流程', style: RmText.mono(11, color: rm.fg3)),
              const Spacer(),
              Text(
                '${analysis.progressPercent}%',
                style: RmText.mono(12, color: rm.accent.base),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              minHeight: 5,
              value: analysis.progressPercent / 100,
              backgroundColor: rm.raised,
              valueColor: AlwaysStoppedAnimation<Color>(rm.accent.base),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            active == null ? '等待 CLI 回报' : active.label,
            style: RmText.sans(12.5, weight: FontWeight.w600, color: rm.fg),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          if ((active?.detail ?? '').isNotEmpty) ...[
            const SizedBox(height: 3),
            Text(
              active!.detail,
              style: RmText.sans(11.5, color: rm.fg3),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          Container(
            height: 1,
            color: rm.border,
            margin: const EdgeInsets.symmetric(vertical: 10),
          ),
          for (final step in analysis.progressSteps)
            _pipelineStepRow(context, step),
        ],
      ),
    );
  }

  Widget _pipelineStepRow(
    BuildContext context,
    AudioAnalysisProgressStep step,
  ) {
    final rm = context.rm;
    final color = _stepColor(context, step);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 18,
            height: 18,
            child: Center(child: _stepMarker(context, step, color)),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  step.label,
                  style: RmText.sans(
                    12,
                    weight: step.status == 'running'
                        ? FontWeight.w600
                        : FontWeight.w400,
                    color: step.status == 'pending' ? rm.fg3 : rm.fg,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (step.summary.isNotEmpty)
                  Text(
                    step.summary,
                    style: RmText.sans(10.5, color: rm.fg3),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            _stepTrailing(step),
            style: RmText.mono(10.5, color: color),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  Widget _stepMarker(
    BuildContext context,
    AudioAnalysisProgressStep step,
    Color color,
  ) {
    final rm = context.rm;
    if (step.status == 'running') {
      return SizedBox(
        width: 12,
        height: 12,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          valueColor: AlwaysStoppedAnimation<Color>(color),
        ),
      );
    }
    if (step.status == 'done') {
      return RmIcon('check', size: 12, color: color);
    }
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(
        color: step.status == 'pending' ? rm.raised : color,
        border: Border.all(color: color),
        shape: BoxShape.circle,
      ),
    );
  }

  Color _stepColor(BuildContext context, AudioAnalysisProgressStep step) {
    final rm = context.rm;
    return switch (step.status) {
      'running' => rm.accent.base,
      'done' => RmTokens.trafficGreen,
      'skipped' => rm.fg4,
      'warning' => rm.warn,
      'error' => rm.danger,
      _ => rm.borderStrong,
    };
  }

  String _stepTrailing(AudioAnalysisProgressStep step) {
    return switch (step.status) {
      'running' => '运行中',
      'done' => _runtimeLabel(step.runtimeMs),
      'skipped' => '跳过',
      'warning' => '注意',
      'error' => '失败',
      _ => '等待',
    };
  }

  String _runtimeLabel(int? runtimeMs) {
    if (runtimeMs == null) return '完成';
    if (runtimeMs >= 1000) return '${(runtimeMs / 1000).toStringAsFixed(1)}s';
    return '${runtimeMs}ms';
  }

  Widget _row(BuildContext context, String k, String v, {Color? valueColor}) {
    final rm = context.rm;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Text(k, style: RmText.mono(11, color: rm.fg3)),
          const Spacer(),
          Text(v, style: RmText.mono(12, color: valueColor ?? rm.fg)),
        ],
      ),
    );
  }

  String _scorePercent(List<dynamic> candidates) {
    if (candidates.isEmpty) return '—';
    final score = candidates.first.score as double;
    return '${(score * 100).round()}%';
  }

  Widget _shortcutsCard(BuildContext context) {
    final rm = context.rm;
    final items = <(String, List<String>)>[
      ('播放 / 暂停', ['Space']),
      ('跳到下一段', ['1', '2', '…']),
      ('确认当前候选', ['Enter']),
      ('前进 1 拍', ['→']),
      ('毫秒级微调', ['Shift', '→']),
      ('撤销', ['Ctrl', 'Z']),
    ];
    return RmPanel(
      title: '快捷键',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final i in items)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Text(i.$1, style: RmText.sans(12, color: rm.fg2)),
                  const Spacer(),
                  for (final k in i.$2) ...[
                    _kbd(context, k),
                    if (k != i.$2.last) const SizedBox(width: 4),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _kbd(BuildContext context, String label) {
    final rm = context.rm;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: rm.raised,
        border: Border.all(color: rm.border),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(label, style: RmText.mono(10.5, color: rm.fg2)),
    );
  }
}

// 解决 `disabled: true` 时 RmButton 接受 onPressed 为非 null 但被忽略 — 让 disabled 的 button 也能编译。
// 用 `disabled: !ok` 控制态。
extension on RmButton {}
