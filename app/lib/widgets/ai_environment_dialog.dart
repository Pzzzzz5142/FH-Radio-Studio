import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/fh_radio_studio_cli.dart';
import '../state/studio_state.dart';
import '../theme/app_theme.dart';
import '../theme/text_styles.dart';
import '../theme/tokens.dart';
import 'rm_button.dart';
import 'rm_chip.dart';
import 'rm_icon.dart';

Future<void> showAiEnvironmentSyncDialog({
  required BuildContext context,
  required StudioState state,
  required StudioController controller,
  required StudioState Function() latestState,
}) async {
  final options = await showDialog<AiEnvironmentSyncOptions>(
    context: context,
    barrierColor: RmTokens.modalBackdrop,
    builder: (context) =>
        _AiEnvironmentDialog(state: state, controller: controller),
  );
  if (options == null || !context.mounted) return;
  final ok = await controller.syncToolchainEnvironment(options: options);
  if (!context.mounted || ok) return;
  final latest = latestState();
  if (latest.projectOperationLocked || latest.toolchainRefreshing) return;
  await showAiEnvironmentFailureDialog(context: context, state: latest);
}

Future<void> showAiEnvironmentFailureDialog({
  required BuildContext context,
  required StudioState state,
}) async {
  final errorLines = _aiEnvironmentFailureLines(state);
  await showDialog<void>(
    context: context,
    barrierColor: RmTokens.modalBackdrop,
    builder: (context) => _AiEnvironmentFailureDialog(errorLines: errorLines),
  );
}

class _AiEnvironmentFailureDialog extends StatelessWidget {
  const _AiEnvironmentFailureDialog({required this.errorLines});

  final List<String> errorLines;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    final errorText = errorLines.join('\n');
    final previewText = _compactAiFailureLines(errorLines).join('\n');
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 48, vertical: 36),
      child: Container(
        width: 640,
        decoration: BoxDecoration(
          color: rm.panel,
          border: Border.all(color: rm.border),
          borderRadius: BorderRadius.circular(RmTokens.rLg),
          boxShadow: RmTokens.modal,
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 18, 22, 14),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 30,
                    height: 30,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: rm.dangerBg,
                      border: Border.all(color: rm.danger.withAlpha(77)),
                      borderRadius: BorderRadius.circular(RmTokens.rMd),
                    ),
                    child: RmIcon('danger', size: 16, color: rm.danger),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('AI 环境同步失败', style: RmText.modalH2(color: rm.fg)),
                        const SizedBox(height: 4),
                        Text(
                          'uv sync 或模型 Warmup 没有完成，下面是这次运行抓到的关键错误。',
                          style: RmText.body(color: rm.fg2),
                        ),
                      ],
                    ),
                  ),
                  RmButton.icon(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const RmIcon('x', size: 13),
                    variant: RmButtonVariant.ghost,
                    tooltip: '关闭',
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: rm.border),
            Padding(
              padding: const EdgeInsets.all(22),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '这次失败的关键信息',
                    style: RmText.sans(
                      12,
                      color: rm.fg,
                      weight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    constraints: const BoxConstraints(maxHeight: 170),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: rm.dangerBg.withAlpha(150),
                      border: Border.all(color: rm.danger.withAlpha(70)),
                      borderRadius: BorderRadius.circular(RmTokens.rSm),
                    ),
                    child: SingleChildScrollView(
                      child: SelectableText(
                        previewText,
                        style: RmText.mono(11, color: rm.fg2, height: 1.35),
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  const Row(
                    children: [
                      Expanded(
                        child: _AiFailureHintRow(
                          icon: 'import',
                          title: '下载源 mirror',
                          detail: 'PyPI / Hugging Face mirror 可能返回 403、超时或缺包。',
                        ),
                      ),
                      SizedBox(width: 10),
                      Expanded(
                        child: _AiFailureHintRow(
                          icon: 'spark',
                          title: '模型 Warmup',
                          detail: '模型权重下载或加载失败时，会在上方 ERR 行显示具体 Provider。',
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: rm.border),
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 14, 22, 18),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '完整输出仍保留在 Dashboard 日志里。',
                      style: RmText.sans(12, color: rm.fg3),
                    ),
                  ),
                  RmButton(
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: errorText));
                      if (!context.mounted) return;
                      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                        const SnackBar(content: Text('AI 环境错误信息已复制')),
                      );
                    },
                    variant: RmButtonVariant.ghost,
                    leading: const RmIcon('copy', size: 12),
                    label: '复制错误',
                  ),
                  const SizedBox(width: 8),
                  RmButton(
                    onPressed: () => Navigator.of(context).pop(),
                    label: '知道了',
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

List<String> _aiEnvironmentFailureLines(StudioState state) {
  final log = state.log
      .map((line) => line.trimRight())
      .where((line) => line.trim().isNotEmpty)
      .toList(growable: false);
  if (log.isEmpty) {
    return const ['没有捕获到详细错误。请展开 Dashboard 日志查看完整输出。'];
  }
  final start = log.lastIndexWhere((line) {
    final lower = line.toLowerCase();
    return line.contains('Python / AI 环境') ||
        line.contains('prepare-ai-cache') ||
        line.contains('模型缓存') ||
        lower.contains('warmup');
  });
  final tail = start >= 0
      ? log.sublist(start)
      : log.skip(log.length > 16 ? log.length - 16 : 0);
  final interesting = tail.where((line) {
    final lower = line.toLowerCase();
    return line.startsWith('执行：') ||
        line.startsWith('ERR ') ||
        line.startsWith('退出码') ||
        line.contains('失败') ||
        lower.contains('error') ||
        lower.contains('failed') ||
        lower.contains('forbidden') ||
        lower.contains('timeout');
  }).toList();
  if (interesting.isEmpty) {
    return tail.take(8).toList(growable: false);
  }
  final trimmed = interesting.length > 10
      ? interesting.sublist(interesting.length - 10)
      : interesting;
  return trimmed.toList(growable: false);
}

List<String> _compactAiFailureLines(List<String> lines) {
  return lines
      .map((line) {
        const max = 170;
        if (line.length <= max) return line;
        const head = 116;
        const tail = 42;
        return '${line.substring(0, head)} ... ${line.substring(line.length - tail)}';
      })
      .toList(growable: false);
}

class _AiFailureHintRow extends StatelessWidget {
  const _AiFailureHintRow({
    required this.icon,
    required this.title,
    required this.detail,
  });

  final String icon;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    return Container(
      constraints: const BoxConstraints(minHeight: 74),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: rm.raised,
        border: Border.all(color: rm.border),
        borderRadius: BorderRadius.circular(RmTokens.rSm),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          RmIcon(icon, size: 14, color: rm.fg3),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: RmText.body(weight: FontWeight.w600, color: rm.fg),
                ),
                const SizedBox(height: 2),
                Text(
                  detail,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: RmText.sans(12, color: rm.fg3),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AiEnvironmentDialog extends StatefulWidget {
  const _AiEnvironmentDialog({required this.state, required this.controller});

  final StudioState state;
  final StudioController controller;

  @override
  State<_AiEnvironmentDialog> createState() => _AiEnvironmentDialogState();
}

class _AiEnvironmentDialogState extends State<_AiEnvironmentDialog> {
  late StudioState _liveState = widget.state;
  late String _profile = widget.state.aiProfile;
  late bool _usePipIndexMirror = widget.state.aiUsePipMirror;
  late bool _useTorchWheelMirror = widget.state.aiUseTorchWheelMirror;
  late bool _useHfMirror = widget.state.aiUseHfMirror;
  late final TextEditingController _pipIndexController;
  late final TextEditingController _torchWheelController;
  late final TextEditingController _hfEndpointController;
  late ToolchainStatusSummary _toolchainStatus = widget.state.toolchainStatus;
  late final VoidCallback _removeControllerListener;
  int _profileCheckSerial = 0;
  int? _openPlanStep = 1;

  List<String> get _warmupProviders => aiWarmupProvidersForProfile(_profile);
  bool get _needsWarmup => _warmupProviders.isNotEmpty;
  bool get _dependenciesReady {
    return _dependenciesReadyFor(_toolchainStatus, _profile);
  }

  bool get _mirrorInputsValid {
    return (!_usePipIndexMirror || _validHttpUrl(_pipIndexController.text)) &&
        (!_useTorchWheelMirror || _validHttpUrl(_torchWheelController.text)) &&
        (!_useHfMirror || _validHttpUrl(_hfEndpointController.text));
  }

  bool get _profileChecking =>
      _toolchainStatus.checking && _toolchainStatus.profile == _profile;
  bool get _actionsLocked =>
      _liveState.busy ||
      _liveState.fileIntegrityRefreshing ||
      _liveState.toolchainRefreshing ||
      _profileChecking;
  bool get _canSubmit => !_actionsLocked && _mirrorInputsValid;
  bool get _pipelineReady {
    return _pipelineReadyFor(_toolchainStatus, _profile);
  }

  bool _dependenciesReadyFor(ToolchainStatusSummary status, String profile) {
    if (!status.checked || status.checking || status.profile != profile) {
      return false;
    }
    final python = status.section('python');
    if (python != null) return {'ready', 'ok'}.contains(python.status);
    return {'ready', 'ok'}.contains(status.status);
  }

  bool _pipelineReadyFor(ToolchainStatusSummary status, String profile) {
    if (!_dependenciesReadyFor(status, profile)) {
      return false;
    }
    final ai = status.section('ai');
    if (ai != null) return {'ready', 'ok'}.contains(ai.status);
    return {'ready', 'ok'}.contains(status.status);
  }

  @override
  void initState() {
    super.initState();
    _removeControllerListener = widget.controller.addListener((next) {
      if (!mounted) return;
      setState(() {
        _liveState = next;
        if (next.toolchainStatus.profile == _profile) {
          _toolchainStatus = next.toolchainStatus;
        }
      });
    }, fireImmediately: false);
    _pipIndexController = TextEditingController(
      text: widget.state.aiPipIndexUrl,
    );
    _torchWheelController = TextEditingController(
      text: widget.state.aiTorchWheelMirrorUrl,
    );
    _hfEndpointController = TextEditingController(
      text: widget.state.aiHfEndpoint,
    );
  }

  @override
  void dispose() {
    _removeControllerListener();
    _pipIndexController.dispose();
    _torchWheelController.dispose();
    _hfEndpointController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    final providers = _warmupProviders;
    final desiredHeight = MediaQuery.sizeOf(context).height * 0.86;
    final dialogHeight = desiredHeight < 1120 ? desiredHeight : 1120.0;
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 48, vertical: 36),
      child: SizedBox(
        width: 980,
        height: dialogHeight,
        child: Container(
          decoration: BoxDecoration(
            color: rm.panel,
            border: Border.all(color: rm.borderStrong),
            borderRadius: BorderRadius.circular(RmTokens.rXl),
            boxShadow: RmTokens.modal,
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _dialogHeader(context),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, box) {
                    if (box.maxWidth < 760) {
                      return Column(
                        children: [
                          SizedBox(height: 208, child: _profileMenu(context)),
                          Expanded(child: _detailPanel(context, providers)),
                        ],
                      );
                    }
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(width: 244, child: _profileMenu(context)),
                        Expanded(child: _detailPanel(context, providers)),
                      ],
                    );
                  },
                ),
              ),
              _dialogFooter(context, providers),
            ],
          ),
        ),
      ),
    );
  }

  Widget _dialogHeader(BuildContext context) {
    final rm = context.rm;
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: rm.border)),
      ),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: rm.accent.bg,
              border: Border.all(color: rm.accent.ring),
              borderRadius: BorderRadius.circular(RmTokens.rMd),
            ),
            child: RmIcon('spark', size: 16, color: rm.accent.base),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'AI 环境设置',
                  style: RmText.sans(17, weight: FontWeight.w600, color: rm.fg),
                ),
                const SizedBox(height: 2),
                Text(
                  '选择杯型，Warmup 按杯型固定执行',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: RmText.sans(12.5, color: rm.fg3),
                ),
              ],
            ),
          ),
          const SizedBox(width: 14),
          _AiStatusPill(kind: _statusPillKind()),
          const SizedBox(width: 10),
          RmButton.icon(
            onPressed: () => Navigator.of(context).pop(),
            icon: const RmIcon('x', size: 14),
            variant: RmButtonVariant.ghost,
            tooltip: '关闭',
          ),
        ],
      ),
    );
  }

  Widget _detailPanel(BuildContext context, List<String> providers) {
    final rm = context.rm;
    return Container(
      color: rm.panel,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(22, 18, 22, 22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _currentEnvironmentInfo(context),
            const SizedBox(height: 14),
            _pipelineStatusBanner(context),
            const SizedBox(height: 14),
            const _SectionLabel(title: '下载源', hint: 'CN patch，默认按下方开关切换'),
            const SizedBox(height: 8),
            _mirrorSettings(context),
            if (providers.isNotEmpty) ...[
              const SizedBox(height: 14),
              _SectionLabel(
                title: '模型计划',
                hint: '${providers.length} 个 Provider 会在 Warmup 一次加载',
              ),
              const SizedBox(height: 8),
              _providerPlan(context, providers),
            ],
            const SizedBox(height: 14),
            const _SectionLabel(title: '执行计划', hint: '按顺序执行，失败会原地停下'),
            const SizedBox(height: 8),
            _executionPlan(context, providers),
          ],
        ),
      ),
    );
  }

  Widget _dialogFooter(BuildContext context, List<String> providers) {
    final rm = context.rm;
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
      decoration: BoxDecoration(
        color: rm.bg,
        border: Border(top: BorderSide(color: rm.border)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              _actionsLocked
                  ? _lockedFooterMessage()
                  : _pipelineReady
                  ? '已就绪时会重装依赖并重跑必做 Warmup。'
                  : '完成后会自动重新检查工具链健康。',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: RmText.sans(12, color: rm.fg3),
            ),
          ),
          RmButton(onPressed: () => Navigator.of(context).pop(), label: '取消'),
          const SizedBox(width: 8),
          RmButton(
            onPressed: _canSubmit
                ? () => Navigator.of(context).pop(
                    AiEnvironmentSyncOptions(
                      profile: _profile,
                      syncDependencies: !_dependenciesReady || _pipelineReady,
                      forceReinstall: _pipelineReady,
                      prepareModelCache: _needsWarmup,
                      warmupProviders: providers,
                      usePipIndexMirror: _usePipIndexMirror,
                      pipIndexUrl: _pipIndexController.text.trim(),
                      useTorchWheelMirror: _useTorchWheelMirror,
                      torchWheelMirrorUrl: _torchWheelController.text.trim(),
                      useHfMirror: _useHfMirror,
                      hfEndpoint: _hfEndpointController.text.trim(),
                    ),
                  )
                : null,
            variant: _pipelineReady
                ? RmButtonVariant.dangerPrimary
                : RmButtonVariant.primary,
            leading: const RmIcon('refresh', size: 12),
            label: _pipelineReady
                ? 'Force Reinstall'
                : (_needsWarmup ? '同步并 Warmup' : '同步环境'),
          ),
        ],
      ),
    );
  }

  _AiStatusKind _statusPillKind() {
    if (_actionsLocked) return _AiStatusKind.checking;
    if (_pipelineReady) return _AiStatusKind.ready;
    if (_toolchainStatus.checking && _toolchainStatus.profile == _profile) {
      return _AiStatusKind.checking;
    }
    if (_dependenciesReady) return _AiStatusKind.dependenciesReady;
    return _AiStatusKind.plan;
  }

  String _lockedFooterMessage() {
    if (_liveState.fileIntegrityRefreshing) {
      return '文件扫描进行中，完成后可继续调整 AI 环境。';
    }
    if (_liveState.toolchainRefreshing || _profileChecking) {
      return '工具链扫描进行中，完成后可继续调整 AI 环境。';
    }
    return '当前任务进行中，完成后可继续调整 AI 环境。';
  }

  Widget _pipelineStatusBanner(BuildContext context) {
    final rm = context.rm;
    final status = _toolchainStatus;
    final sameProfile = status.checked && status.profile == _profile;
    final ready = _pipelineReady;
    final checking = status.checking && status.profile == _profile;
    final dependenciesReady = _dependenciesReady;
    final tone = ready
        ? rm.accent.base
        : checking
        ? rm.info
        : dependenciesReady
        ? rm.info
        : sameProfile
        ? rm.warn
        : rm.fg2;
    final bg = ready
        ? rm.accent.bg
        : checking
        ? Color.alphaBlend(rm.info.withAlpha(18), rm.panel)
        : dependenciesReady
        ? Color.alphaBlend(rm.info.withAlpha(18), rm.panel)
        : sameProfile
        ? Color.alphaBlend(rm.warn.withAlpha(18), rm.panel)
        : rm.raised;
    final border = ready
        ? rm.accent.ring
        : checking
        ? rm.info.withAlpha(76)
        : dependenciesReady
        ? rm.info.withAlpha(76)
        : sameProfile
        ? rm.warn.withAlpha(76)
        : rm.border;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
      decoration: BoxDecoration(
        color: bg,
        border: Border.all(color: border),
        borderRadius: BorderRadius.circular(RmTokens.rMd),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          checking
              ? _StatusSpinner(size: 12, color: tone)
              : RmIcon(ready ? 'check' : 'info', size: 14, color: tone),
          const SizedBox(width: 10),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: ready
                        ? '${_profileName(_profile)} · ${_profileCn(_profile)}'
                        : checking
                        ? '正在检查 ${_profileName(_profile)}'
                        : dependenciesReady
                        ? '${_profileName(_profile)} 依赖已就绪'
                        : '切换到 ${_profileName(_profile)}',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  TextSpan(text: ' ${_pipelineStatusDetail(ready)}'),
                ],
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: RmText.sans(12.5, color: tone, height: 1.45),
            ),
          ),
        ],
      ),
    );
  }

  String _pipelineStatusDetail(bool ready) {
    final status = _toolchainStatus;
    if (ready) {
      return '已通过工具链检查。Force Reinstall 会使用 --reinstall 重装并跑一次必做 Warmup。';
    }
    if (status.checking && status.profile == _profile) {
      return aiProfileUserText(status.summary);
    }
    if (_dependenciesReady && !_pipelineReady) {
      return _needsWarmup
          ? 'Python Dependency Groups 已就绪；可以直接继续模型缓存 Warmup。'
          : 'Python Dependency Groups 已就绪；重新检查后会确认实际 Provider。';
    }
    if (!status.checked) {
      return '需要先同步依赖，然后跑一次模型 Warmup。';
    }
    if (status.profile != _profile) {
      return '当前检测结果来自 ${_profileLabel(status.profile)}；提交后会按这个杯型执行。';
    }
    final ai = status.section('ai');
    if (ai != null && ai.summary.trim().isNotEmpty) {
      return aiProfileUserText(ai.summary);
    }
    return aiProfileUserText(status.summary);
  }

  Widget _mirrorSettings(BuildContext context) {
    final rm = context.rm;
    return ClipRRect(
      borderRadius: BorderRadius.circular(RmTokens.rMd),
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(color: rm.border),
          borderRadius: BorderRadius.circular(RmTokens.rMd),
        ),
        child: Column(
          children: [
            _MirrorOptionCard(
              enabled: _usePipIndexMirror,
              interactive: !_actionsLocked,
              onChanged: (value) => setState(() => _usePipIndexMirror = value),
              title: 'PyPI / uv Index Mirror',
              detail: '影响 uv sync 的 PyPI 源',
              controller: _pipIndexController,
              inputLabel: 'UV_DEFAULT_INDEX',
              invalidText:
                  _usePipIndexMirror && !_validHttpUrl(_pipIndexController.text)
                  ? '请输入 http(s) URL'
                  : null,
              onTextChanged: (_) => setState(() {}),
            ),
            Divider(height: 1, color: rm.border),
            _MirrorOptionCard(
              enabled: _useTorchWheelMirror,
              interactive: !_actionsLocked,
              onChanged: (value) =>
                  setState(() => _useTorchWheelMirror = value),
              title: 'Torch Wheel Mirror',
              detail: '自动适配 named index / flat wheel 源',
              controller: _torchWheelController,
              inputLabel: 'Torch wheel URL',
              invalidText:
                  _useTorchWheelMirror &&
                      !_validHttpUrl(_torchWheelController.text)
                  ? '请输入 http(s) URL'
                  : null,
              onTextChanged: (_) => setState(() {}),
            ),
            Divider(height: 1, color: rm.border),
            _MirrorOptionCard(
              enabled: _useHfMirror,
              interactive: !_actionsLocked,
              onChanged: (value) => setState(() => _useHfMirror = value),
              title: 'Hugging Face Mirror',
              detail: '模型权重 Endpoint，影响 Warmup 下载',
              controller: _hfEndpointController,
              inputLabel: 'HF_ENDPOINT',
              invalidText:
                  _useHfMirror && !_validHttpUrl(_hfEndpointController.text)
                  ? '请输入 http(s) URL'
                  : null,
              onTextChanged: (_) => setState(() {}),
            ),
          ],
        ),
      ),
    );
  }

  Widget _providerPlan(BuildContext context, List<String> providers) {
    if (providers.isEmpty) {
      return const SizedBox.shrink();
    }
    return LayoutBuilder(
      builder: (context, box) {
        final columns =
            (box.maxWidth >= 680
                    ? providers.length.clamp(1, 4)
                    : box.maxWidth >= 500
                    ? 2
                    : 1)
                .toInt();
        final cardWidth = (box.maxWidth - 8 * (columns - 1)) / columns;
        return Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final provider in providers)
              SizedBox(
                width: cardWidth,
                height: _ProviderPlanCard.height,
                child: _ProviderPlanCard(
                  key: ValueKey('ai_provider_card_$provider'),
                  label: _providerLabel(provider),
                  version: _providerVersion(provider),
                  tags: _providerTags(provider),
                  ready: _providerReady(provider),
                  statusItem: _providerStatusItem(provider),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _executionPlan(BuildContext context, List<String> providers) {
    final forceReinstall = _pipelineReady;
    final dependenciesReady = _dependenciesReady && !forceReinstall;
    final mirrorSummary = _mirrorSummary();
    return Column(
      children: [
        _PlanStep(
          index: '1',
          title: forceReinstall
              ? 'Force Reinstall 依赖环境'
              : dependenciesReady
              ? '依赖环境已就绪'
              : '同步依赖环境',
          detail: forceReinstall
              ? '通过 uv --reinstall 重装当前杯型的 Python / AI wheel。$mirrorSummary'
              : dependenciesReady
              ? '工具链检测显示当前杯型的 Python Dependency Groups 已覆盖，本次会跳过 uv sync。'
              : '${_dependencySummary(_profile)}$mirrorSummary',
          label: forceReinstall
              ? 'Force'
              : dependenciesReady
              ? '已完成'
              : '必做',
          variant: forceReinstall
              ? RmChipVariant.warn
              : dependenciesReady
              ? RmChipVariant.accent
              : RmChipVariant.accent,
          command: _syncCommand(_profile, forceReinstall: forceReinstall),
          commandEnabled: !dependenciesReady,
          environment: _dependencyEnvironmentPreview(),
          open: _openPlanStep == 1 && !dependenciesReady,
          interactive: !_actionsLocked,
          onToggle: () {
            if (_actionsLocked) return;
            setState(() => _openPlanStep = _openPlanStep == 1 ? null : 1);
          },
        ),
        const SizedBox(height: 8),
        _PlanStep(
          index: '2',
          title: '模型缓存 Warmup',
          detail: '${_prepareCacheDetail(providers)}${_hfMirrorSummary()}',
          label: _needsWarmup ? '必做' : '不需要',
          variant: _needsWarmup ? RmChipVariant.accent : RmChipVariant.muted,
          command: _needsWarmup
              ? _cacheCommand(_profile, providers)
              : '中杯不需要深度模型 Warmup',
          commandEnabled: _needsWarmup,
          environment: _warmupEnvironmentPreview(),
          open:
              _openPlanStep == 2 ||
              (dependenciesReady && _needsWarmup && _openPlanStep == 1),
          interactive: !_actionsLocked,
          onToggle: () {
            if (_actionsLocked) return;
            setState(() => _openPlanStep = _openPlanStep == 2 ? null : 2);
          },
        ),
      ],
    );
  }

  String _mirrorSummary() {
    final parts = [
      if (_usePipIndexMirror) 'PyPI Mirror',
      if (_useTorchWheelMirror) 'Torch Wheel Mirror',
    ];
    if (parts.isEmpty) return '';
    return ' 使用 ${parts.join(' + ')}。';
  }

  String _hfMirrorSummary() {
    if (!_useHfMirror || !_needsWarmup) return '';
    return ' HF 下载走 mirror。';
  }

  List<String> _dependencyEnvironmentPreview() {
    final lines = <String>[];
    if (_usePipIndexMirror) {
      final indexUrl = _pipIndexController.text.trim();
      if (indexUrl.isNotEmpty) {
        lines.addAll(['UV_DEFAULT_INDEX=$indexUrl', 'PIP_INDEX_URL=$indexUrl']);
      }
    }
    if (_useTorchWheelMirror) {
      final torchUrl = _torchWheelController.text.trim();
      if (torchUrl.isNotEmpty) {
        final torchExtra = _currentTorchExtra(_toolchainStatus);
        lines.addAll(torchWheelMirrorEnvironmentPreview(torchUrl, torchExtra));
      }
    }
    return lines;
  }

  List<String> _warmupEnvironmentPreview() {
    if (!_useHfMirror || !_needsWarmup) return const [];
    final endpoint = _hfEndpointController.text.trim();
    if (endpoint.isEmpty) return const [];
    return ['HF_ENDPOINT=$endpoint'];
  }

  Widget _profileMenu(BuildContext context) {
    final rm = context.rm;
    return Container(
      color: rm.bg,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(14, 16, 14, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
              child: Text(
                '目标 Pipeline',
                style: RmText.microLabel(color: rm.fg3),
              ),
            ),
            for (final profile in kAiPipelineProfiles) ...[
              _profileCard(context, profile),
              if (profile != kAiPipelineProfiles.last)
                const SizedBox(height: 6),
            ],
          ],
        ),
      ),
    );
  }

  Widget _profileCard(BuildContext context, String profile) {
    final rm = context.rm;
    final active = profile == _profile;
    final interactive = !_actionsLocked;
    final modelCount = aiWarmupProvidersForProfile(profile).length;
    final checkedProfile =
        _toolchainStatus.checked &&
        !_toolchainStatus.checking &&
        _toolchainStatus.profile == profile;
    final ready =
        modelCount == 0 ||
        (checkedProfile && _pipelineReadyFor(_toolchainStatus, profile));
    final dependenciesReady =
        checkedProfile && _dependenciesReadyFor(_toolchainStatus, profile);
    final checking =
        active &&
        _toolchainStatus.checking &&
        _toolchainStatus.profile == profile;
    final stateColor = checking
        ? rm.info
        : ready
        ? rm.accent.base
        : dependenciesReady
        ? rm.info
        : checkedProfile
        ? rm.warn
        : rm.fg3;
    final stateLabel = checking
        ? 'checking'
        : ready
        ? 'ready'
        : dependenciesReady
        ? '待模型'
        : checkedProfile
        ? '需同步'
        : '待检查';
    return MouseRegion(
      cursor: interactive ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: GestureDetector(
        onTap: () {
          if (!interactive) return;
          if (_profile == profile) return;
          setState(() {
            _profile = profile;
            _openPlanStep = 1;
          });
          unawaited(_checkSelectedProfile(profile));
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.fromLTRB(12, 11, 12, 10),
          decoration: BoxDecoration(
            color: active
                ? Color.alphaBlend(rm.accent.base.withAlpha(20), rm.panel)
                : rm.panel,
            border: Border.all(color: active ? rm.accent.base : rm.border),
            borderRadius: BorderRadius.circular(RmTokens.rMd),
            boxShadow: active
                ? [
                    BoxShadow(
                      color: rm.accent.base.withAlpha(24),
                      blurRadius: 0,
                      spreadRadius: 1,
                    ),
                  ]
                : null,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _profileName(profile),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: RmText.sans(
                  13.5,
                  weight: FontWeight.w600,
                  color: active ? rm.accent.base : rm.fg,
                ),
              ),
              const SizedBox(height: 1),
              Text(
                _profileCn(profile),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: RmText.sans(11.5, color: rm.fg3),
              ),
              const SizedBox(height: 6),
              Text(
                _profileDescription(profile),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: RmText.sans(11.5, color: rm.fg3, height: 1.4),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      color: rm.raised,
                      border: Border.all(color: rm.border),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      modelCount == 0 ? '无深度模型' : '$modelCount 个模型',
                      style: RmText.mono(10, color: rm.fg3),
                    ),
                  ),
                  const Spacer(),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                          color: stateColor,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 5),
                      Text(
                        stateLabel,
                        style: RmText.mono(10, color: stateColor),
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

  Widget _currentEnvironmentInfo(BuildContext context) {
    final rm = context.rm;
    final torchExtra = _currentTorchExtra(_toolchainStatus);
    final modelDir = _modelDirLabel(_toolchainStatus) ?? '默认模型目录';
    return ClipRRect(
      borderRadius: BorderRadius.circular(RmTokens.rMd),
      child: Container(
        padding: const EdgeInsets.all(1),
        decoration: BoxDecoration(
          color: rm.border,
          borderRadius: BorderRadius.circular(RmTokens.rMd),
        ),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                flex: 10,
                child: _EnvironmentInfoLine(
                  label: 'Torch 后端',
                  value: _torchPlanLabel(torchExtra),
                  detail: torchExtra == null
                      ? 'auto'
                      : _torchExtraMetricLabel(torchExtra),
                ),
              ),
              const SizedBox(width: 1),
              Expanded(
                flex: 10,
                child: _EnvironmentInfoLine(
                  label: '安装状态',
                  value: _torchInstallStatus(_toolchainStatus),
                  detail: _torchInstallDetail(_toolchainStatus),
                ),
              ),
              const SizedBox(width: 1),
              Expanded(
                flex: 12,
                child: _EnvironmentInfoLine(
                  label: '模型缓存',
                  value: modelDir,
                  monospaceValue: true,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _cacheCommand(String profile, List<String> providers) {
    final warmupArgs = providers
        .map((provider) => '--warmup-provider $provider')
        .join(' ');
    return [
      'uv run --python $fhRadioStudioDefaultPythonVersion --managed-python fh-radio-studio prepare-ai-cache',
      '--profile $profile',
      if (warmupArgs.isNotEmpty) warmupArgs,
    ].join(' ');
  }

  String _syncCommand(String profile, {required bool forceReinstall}) {
    final groups = _syncGroups(profile);
    final torch =
        _currentTorchExtra(_toolchainStatus) ?? '<torch-cpu|torch-cu128>';
    return [
      'uv sync --python $fhRadioStudioDefaultPythonVersion --managed-python',
      if (forceReinstall) '--reinstall',
      for (final group in groups) '--group $group',
      if (groups.isNotEmpty) '--extra $torch',
    ].join(' ');
  }

  String _dependencySummary(String profile) {
    final groups = _syncGroups(profile);
    if (groups.isEmpty) return '中杯只恢复基础音频分析依赖，不安装深度 Provider。';
    return '恢复 ${groups.join('、')} Dependency Groups。';
  }

  String _prepareCacheDetail(List<String> providers) {
    if (providers.isEmpty) {
      return '中杯不加载大杯 / 超大杯 Provider，无需模型 Warmup。';
    }
    return '必做：${providers.map(_providerLabel).join('、')} 会下载并加载一次模型权重。';
  }

  List<String> _syncGroups(String profile) {
    return switch (profile) {
      'local-deep' => const ['ai-beat-this', 'ai-mert', 'ai-songformer'],
      'local-heavy' => const [
        'ai-beat-this',
        'ai-mert',
        'ai-songformer',
        'ai-demucs',
      ],
      _ => const [],
    };
  }

  String _profileLabel(String value) {
    return switch (value) {
      'local-base' => '中杯 · 基础 MIR',
      'local-deep' => '大杯 · 三模型分析',
      'local-heavy' => '超大杯 · 全量本地分析',
      _ => value,
    };
  }

  String _profileName(String value) {
    return aiProfileCupLabel(value);
  }

  String _profileCn(String value) {
    return switch (value) {
      'local-base' => '节拍 / 响度',
      'local-deep' => '三模型分析',
      'local-heavy' => '四模型全量',
      _ => value,
    };
  }

  String _profileDescription(String value) {
    return switch (value) {
      'local-base' => '本地节拍/响度，无深度模型',
      'local-deep' => 'Beat This · SongFormer · MERT',
      'local-heavy' => 'Beat This · SongFormer · MERT · Demucs',
      _ => '按当前杯型同步依赖和缓存',
    };
  }

  Future<void> _checkSelectedProfile(String profile) async {
    final serial = ++_profileCheckSerial;
    setState(() {
      _toolchainStatus = ToolchainStatusSummary(
        checked: false,
        profile: profile,
        status: 'checking',
        label: '检测中',
        summary: '正在检查 ${_profileLabel(profile)} 的 uv、Python、硬件和 AI Provider。',
        sections: _toolchainStatus.profile == profile
            ? _toolchainStatus.sections
            : const [],
        fixes: const [],
        checking: true,
      );
    });
    final status = await widget.controller.checkToolchainStatusForProfile(
      profile,
    );
    if (!mounted || serial != _profileCheckSerial || _profile != profile) {
      return;
    }
    setState(() {
      _toolchainStatus =
          status ??
          ToolchainStatusSummary(
            checked: true,
            profile: profile,
            status: 'error',
            label: '检查失败',
            summary: '${_profileLabel(profile)} 检查失败。',
            sections: const [],
            fixes: const [],
            error: '${_profileLabel(profile)} 检查失败。',
          );
    });
  }

  String? _currentTorchExtra(ToolchainStatusSummary status) {
    final item = status
        .section('uv')
        ?.items
        .firstWhereOrNull(
          (item) => item.label == 'Torch Extra' || item.label == 'Torch extra',
        );
    final value = item?.value.trim();
    return value != null && value.startsWith('torch-') ? value : null;
  }

  String _torchPlanLabel(String? value) {
    return _torchExtraPlanLabel(value);
  }

  String _torchInstallStatus(ToolchainStatusSummary status) {
    final item = status
        .section('hardware')
        ?.items
        .firstWhereOrNull((item) => item.label == 'Torch');
    if (item == null) return '未检测';
    if (item.status == 'missing' || item.value == 'missing') return '未安装';
    if (item.status == 'ready') return '已安装 ${_torchVersionLabel(item.value)}';
    return item.value;
  }

  String _torchVersionLabel(String value) {
    final version = value.split('+').first.trim();
    if (version.isEmpty || version == value) return value;
    return 'PyTorch $version';
  }

  String? _torchInstallDetail(ToolchainStatusSummary status) {
    final hardware = status.section('hardware');
    if (hardware == null) return null;
    final device = hardware.items
        .firstWhereOrNull((item) => item.label == 'Device')
        ?.value;
    if (device == null || device.trim().isEmpty) return hardware.summary;
    return device == 'unavailable'
        ? hardware.summary
        : '$device · ${hardware.summary}';
  }

  String? _modelDirLabel(ToolchainStatusSummary status) {
    return status
        .section('ai')
        ?.items
        .firstWhereOrNull(
          (item) => item.label == 'Model Dir' || item.label == 'Model dir',
        )
        ?.value;
  }

  String _providerLabel(String value) {
    return switch (value) {
      'beat_this' => 'Beat This',
      'songformer' => 'SongFormer',
      'mert' => 'MERT',
      'demucs' => 'Demucs',
      _ => value,
    };
  }

  String _providerPurpose(String value) {
    return switch (value) {
      'beat_this' => '节拍 / downbeat 网格',
      'songformer' => '曲式段落结构',
      'mert' => 'embedding 候选评分',
      'demucs' => 'stem 分离证据',
      _ => '深度分析 Provider',
    };
  }

  String _providerVersion(String value) {
    final detail = _providerStatusItem(value)?.detail.trim();
    if (detail != null && detail.isNotEmpty) return detail;
    return switch (value) {
      'beat_this' => 'beat-this',
      'songformer' => 'ASLP-lab/SongFormer',
      'mert' => 'm-a-p/MERT-v1-95M',
      'demucs' => 'htdemucs · demucs',
      _ => _providerPurpose(value),
    };
  }

  List<String> _providerTags(String value) {
    final item = _providerStatusItem(value);
    final status = item?.status ?? (_pipelineReady ? 'ready' : 'unknown');
    return switch (status) {
      'ready' || 'ok' => const ['已就绪'],
      'disabled' => const ['未启用'],
      'error' => const ['检查失败'],
      'partial' || 'missing' => _providerMissingTags(value, status),
      _ => const ['等待检查'],
    };
  }

  List<String> _providerMissingTags(String value, String status) {
    final warningText = _providerWarningText(value);
    final missingDependency =
        status == 'missing' ||
        _mentionsAny(warningText, [
          'module',
          'modules:',
          'dependencies',
          'torch/transformers',
          'package',
          'runtime',
          'not installed',
          'cannot be imported',
        ]);
    final missingCache =
        status == 'missing' ||
        _mentionsAny(warningText, ['cache', 'checkpoint', 'model', 'warm']);
    final tags = <String>[];
    switch (value) {
      case 'beat_this':
        if (missingDependency) tags.add('缺 beat-this');
        if (!missingDependency || missingCache) tags.add('缺 final0');
      case 'songformer':
        if (missingDependency) tags.add('缺依赖');
        if (!missingDependency || missingCache) tags.add('缺模型缓存');
      case 'mert':
        if (missingDependency) tags.add('缺 torch/transformers');
        if (!missingDependency || missingCache) tags.add('缺模型缓存');
      case 'demucs':
        if (missingDependency) tags.add('缺 demucs');
        if (!missingDependency || missingCache) tags.add('缺 htdemucs 权重');
      default:
        tags.add(status == 'missing' ? '缺依赖' : '缺缓存');
    }
    return tags.isEmpty ? const ['缺缓存'] : tags;
  }

  String _providerWarningText(String provider) {
    final ai = _toolchainStatus.section('ai');
    if (ai == null) return '';
    final keys = {
      provider,
      _providerLabel(provider),
      if (provider == 'beat_this') 'beat this',
      if (provider == 'demucs') 'htdemucs',
    }.map(_providerKey).toSet();
    return ai.warnings
        .where((warning) {
          final key = _providerKey(warning);
          return keys.any(key.contains);
        })
        .join(' ')
        .toLowerCase();
  }

  bool _mentionsAny(String text, List<String> needles) {
    return needles.any((needle) => text.contains(needle));
  }

  bool _providerReady(String value) {
    final item = _providerStatusItem(value);
    if (item == null) return _pipelineReady;
    return {'ready', 'ok'}.contains(item.status);
  }

  ToolchainStatusItem? _providerStatusItem(String provider) {
    final status = _toolchainStatus;
    if (!status.checked || status.profile != _profile) return null;
    final ai = status.section('ai');
    if (ai == null) return null;
    final providerKey = _providerKey(provider);
    final labelKey = _providerKey(_providerLabel(provider));
    return ai.items.firstWhereOrNull((item) {
      final key = _providerKey(item.label);
      return key == providerKey || key == labelKey;
    });
  }

  String _providerKey(String value) {
    return value.toLowerCase().replaceAll(RegExp(r'[\s_-]+'), '');
  }

  bool _validHttpUrl(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) return false;
    return uri.scheme == 'http' || uri.scheme == 'https';
  }
}

enum _AiStatusKind { ready, checking, dependenciesReady, plan }

class _AiStatusPill extends StatelessWidget {
  const _AiStatusPill({required this.kind});

  final _AiStatusKind kind;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    final isReady = kind == _AiStatusKind.ready;
    final isChecking = kind == _AiStatusKind.checking;
    final dependenciesReady = kind == _AiStatusKind.dependenciesReady;
    final color = isReady
        ? rm.accent.base
        : isChecking
        ? rm.info
        : dependenciesReady
        ? rm.info
        : rm.warn;
    final label = isReady
        ? 'Pipeline 已就绪'
        : isChecking
        ? '正在检查'
        : dependenciesReady
        ? '依赖已就绪'
        : '等待同步';
    return Container(
      padding: const EdgeInsets.fromLTRB(9, 5, 11, 5),
      decoration: BoxDecoration(
        color: Color.alphaBlend(color.withAlpha(22), rm.panel),
        border: Border.all(color: color.withAlpha(88)),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          isChecking
              ? _StatusSpinner(size: 7, color: color, strokeWidth: 1.5)
              : Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                    boxShadow: isReady
                        ? [
                            BoxShadow(
                              color: color.withAlpha(100),
                              blurRadius: 8,
                            ),
                          ]
                        : null,
                  ),
                ),
          const SizedBox(width: 7),
          Text(
            label,
            style: RmText.mono(11.5, weight: FontWeight.w600, color: color),
          ),
        ],
      ),
    );
  }
}

class _MirrorOptionCard extends StatelessWidget {
  const _MirrorOptionCard({
    required this.enabled,
    required this.interactive,
    required this.onChanged,
    required this.title,
    required this.detail,
    required this.controller,
    required this.inputLabel,
    required this.onTextChanged,
    this.invalidText,
  });

  final bool enabled;
  final bool interactive;
  final ValueChanged<bool> onChanged;
  final String title;
  final String detail;
  final TextEditingController controller;
  final String inputLabel;
  final ValueChanged<String> onTextChanged;
  final String? invalidText;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    final invalid = enabled && invalidText != null;
    final inputEnabled = interactive && enabled;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      color: enabled
          ? Color.alphaBlend(rm.accent.base.withAlpha(10), rm.panel)
          : rm.panel,
      child: Row(
        children: [
          MouseRegion(
            cursor: interactive
                ? SystemMouseCursors.click
                : SystemMouseCursors.basic,
            child: GestureDetector(
              onTap: interactive ? () => onChanged(!enabled) : null,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                width: 18,
                height: 18,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: enabled ? rm.accent.base : rm.raised,
                  border: Border.all(
                    color: enabled ? rm.accent.base : rm.borderStrong,
                  ),
                  borderRadius: BorderRadius.circular(RmTokens.rXs),
                ),
                child: enabled
                    ? const RmIcon('check', size: 11, color: Colors.white)
                    : null,
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            flex: 10,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: RmText.sans(
                    12.5,
                    weight: FontWeight.w500,
                    color: rm.fg,
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  detail,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: RmText.sans(11, color: rm.fg3),
                ),
              ],
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            flex: 13,
            child: Opacity(
              opacity: inputEnabled
                  ? 1
                  : enabled
                  ? 0.7
                  : 0.55,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    inputLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: RmText.mono(
                      9.5,
                      letterSpacing: 0.95,
                      weight: FontWeight.w500,
                      color: invalid ? rm.danger : rm.fg3,
                    ),
                  ),
                  const SizedBox(height: 4),
                  SizedBox(
                    height: 28,
                    child: TextField(
                      controller: controller,
                      enabled: inputEnabled,
                      onChanged: inputEnabled ? onTextChanged : null,
                      style: RmText.mono(
                        10.5,
                        color: invalid
                            ? rm.danger
                            : enabled
                            ? rm.accent.base
                            : rm.fg2,
                      ),
                      decoration: InputDecoration(
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 7,
                        ),
                        filled: true,
                        fillColor: enabled
                            ? Color.alphaBlend(
                                rm.accent.base.withAlpha(8),
                                rm.raised,
                              )
                            : rm.raised,
                        hoverColor: rm.hover,
                        errorText: null,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(RmTokens.rXs),
                          borderSide: BorderSide(
                            color: invalid ? rm.danger : rm.border,
                          ),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(RmTokens.rXs),
                          borderSide: BorderSide(
                            color: invalid ? rm.danger : rm.border,
                          ),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(RmTokens.rXs),
                          borderSide: BorderSide(
                            color: invalid ? rm.danger : rm.accent.base,
                            width: 1.2,
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (invalid) ...[
                    const SizedBox(height: 3),
                    Text(
                      invalidText!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: RmText.sans(10.5, color: rm.danger),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ProviderPlanCard extends StatelessWidget {
  const _ProviderPlanCard({
    super.key,
    required this.label,
    required this.version,
    required this.tags,
    required this.ready,
    required this.statusItem,
  });

  final String label;
  final String version;
  final List<String> tags;
  final bool ready;
  final ToolchainStatusItem? statusItem;

  static const height = 108.0;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    final detail = statusItem?.detail.trim();
    final status = statusItem?.status ?? (ready ? 'ready' : 'unknown');
    final visualStatus = status == 'missing' ? 'warn' : status;
    final statusColor = _toolchainStatusColor(context, visualStatus);
    final visibleTags = tags.take(3).toList(growable: false);
    final statusLabel = switch (status) {
      'ready' || 'ok' => '已就绪',
      'partial' => '缺缓存',
      'missing' => '缺依赖',
      'error' => '异常',
      'disabled' => '禁用',
      _ => '待检查',
    };
    return Container(
      height: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: rm.raised,
        border: Border.all(color: rm.border),
        borderRadius: BorderRadius.circular(RmTokens.rMd),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: RmText.sans(
                    12.5,
                    weight: FontWeight.w600,
                    color: rm.fg,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: statusColor.withAlpha(28),
                  border: Border.all(color: statusColor.withAlpha(64)),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  statusLabel,
                  style: RmText.mono(
                    9.5,
                    weight: FontWeight.w600,
                    letterSpacing: 0.76,
                    color: statusColor,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 5),
          Text(
            detail == null || detail.isEmpty ? version : detail,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: RmText.mono(10.5, color: rm.fg3),
          ),
          const Spacer(),
          ClipRect(
            child: SizedBox(
              height: 30,
              child: Wrap(
                spacing: 4,
                runSpacing: 4,
                children: [
                  for (final tag in visibleTags)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: rm.panel,
                        border: Border.all(color: rm.border),
                        borderRadius: BorderRadius.circular(RmTokens.rXs),
                      ),
                      child: Text(tag, style: RmText.mono(9.5, color: rm.fg2)),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PlanStep extends StatelessWidget {
  const _PlanStep({
    required this.index,
    required this.title,
    required this.detail,
    required this.label,
    required this.variant,
    required this.command,
    required this.commandEnabled,
    required this.open,
    required this.interactive,
    required this.onToggle,
    this.environment = const [],
  });

  final String index;
  final String title;
  final String detail;
  final String label;
  final RmChipVariant variant;
  final String command;
  final bool commandEnabled;
  final bool open;
  final bool interactive;
  final VoidCallback onToggle;
  final List<String> environment;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    return Container(
      decoration: BoxDecoration(
        color: commandEnabled ? rm.panel : rm.raised,
        border: Border.all(color: open ? rm.borderStrong : rm.border),
        borderRadius: BorderRadius.circular(RmTokens.rMd),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            mouseCursor: interactive
                ? SystemMouseCursors.click
                : SystemMouseCursors.basic,
            onTap: interactive ? onToggle : null,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Container(
                    width: 22,
                    height: 22,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: rm.raised,
                      border: Border.all(color: rm.border),
                      borderRadius: BorderRadius.circular(RmTokens.rSm),
                    ),
                    child: Text(
                      index,
                      style: RmText.mono(
                        11,
                        weight: FontWeight.w700,
                        color: rm.fg2,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Wrap(
                          crossAxisAlignment: WrapCrossAlignment.center,
                          spacing: 8,
                          runSpacing: 3,
                          children: [
                            Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: RmText.sans(
                                13,
                                weight: FontWeight.w600,
                                color: rm.fg,
                              ),
                            ),
                            _PlanBadge(label: label, variant: variant),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          detail,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: RmText.sans(11.5, color: rm.fg3),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  AnimatedRotation(
                    turns: open ? 0.5 : 0,
                    duration: const Duration(milliseconds: 120),
                    child: RmIcon('chevron-down', size: 14, color: rm.fg3),
                  ),
                ],
              ),
            ),
          ),
          if (open && commandEnabled)
            Padding(
              padding: const EdgeInsets.fromLTRB(52, 0, 14, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _CommandPreview(enabled: commandEnabled, text: command),
                  if (environment.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    _EnvironmentPreview(lines: environment),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _PlanBadge extends StatelessWidget {
  const _PlanBadge({required this.label, required this.variant});

  final String label;
  final RmChipVariant variant;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    final (Color text, Color bg, Color border) = switch (variant) {
      RmChipVariant.warn => (
        rm.warn,
        rm.warn.withAlpha(24),
        rm.warn.withAlpha(76),
      ),
      RmChipVariant.accent => (rm.accent.base, rm.accent.bg, rm.accent.ring),
      _ => (rm.fg3, rm.raised, rm.border),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: bg,
        border: Border.all(color: border),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: RmText.mono(
          9.5,
          weight: FontWeight.w600,
          letterSpacing: 0.76,
          color: text,
        ),
      ),
    );
  }
}

class _EnvironmentPreview extends StatelessWidget {
  const _EnvironmentPreview({required this.lines});

  final List<String> lines;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: Color.alphaBlend(rm.accent.base.withAlpha(10), rm.panel),
        border: Border.all(color: rm.accent.base.withAlpha(38)),
        borderRadius: BorderRadius.circular(RmTokens.rSm),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final line in lines)
              Text.rich(
                _envLineSpan(line, rm),
                style: RmText.mono(11.5, color: rm.fg2, height: 1.6),
              ),
          ],
        ),
      ),
    );
  }

  TextSpan _envLineSpan(String line, RmTheme rm) {
    final eq = line.indexOf('=');
    if (eq <= 0) return TextSpan(text: line);
    return TextSpan(
      children: [
        TextSpan(
          text: line.substring(0, eq),
          style: TextStyle(color: rm.info, fontWeight: FontWeight.w500),
        ),
        TextSpan(
          text: '=',
          style: TextStyle(color: rm.fg2),
        ),
        TextSpan(
          text: line.substring(eq + 1),
          style: TextStyle(color: rm.fg),
        ),
      ],
    );
  }
}

class _EnvironmentInfoLine extends StatelessWidget {
  const _EnvironmentInfoLine({
    required this.label,
    required this.value,
    this.detail,
    this.monospaceValue = false,
  });

  final String label;
  final String value;
  final String? detail;
  final bool monospaceValue;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    final detailText = detail?.trim();
    return Container(
      color: rm.raised,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: RmText.mono(10, letterSpacing: 1.2, color: rm.fg3),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: monospaceValue
                ? RmText.mono(11.5, color: rm.fg)
                : RmText.sans(12.5, color: rm.fg),
          ),
          if (detailText != null && detailText.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              detailText,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: RmText.mono(
                10,
                color: detailText == 'auto' ? rm.info : rm.accent.base,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.title, this.hint});

  final String title;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(
          title,
          style: RmText.mono(
            12,
            weight: FontWeight.w600,
            letterSpacing: 1.2,
            color: rm.fg,
          ),
        ),
        if (hint != null) ...[
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              hint!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: RmText.sans(11.5, color: rm.fg3),
            ),
          ),
        ],
      ],
    );
  }
}

class _CommandPreview extends StatelessWidget {
  const _CommandPreview({required this.enabled, required this.text});

  final bool enabled;
  final String text;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: rm.raised,
        border: Border.all(color: rm.border),
        borderRadius: BorderRadius.circular(RmTokens.rSm),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Text.rich(
          TextSpan(
            children: [
              TextSpan(
                text: r'$ ',
                style: TextStyle(
                  color: enabled ? rm.accent.base : rm.fg4,
                  fontWeight: FontWeight.w700,
                ),
              ),
              TextSpan(text: text),
            ],
          ),
          style: RmText.mono(
            11.5,
            color: enabled ? rm.fg : rm.fg4,
            height: 1.6,
          ),
        ),
      ),
    );
  }
}

class _StatusSpinner extends StatelessWidget {
  const _StatusSpinner({
    required this.size,
    required this.color,
    this.strokeWidth = 2,
  });

  final double size;
  final Color color;
  final double strokeWidth;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CircularProgressIndicator(
        strokeWidth: strokeWidth,
        valueColor: AlwaysStoppedAnimation<Color>(color),
      ),
    );
  }
}

String _torchExtraPlanLabel(String? value) {
  return switch (value) {
    'torch-cu128' => 'NVIDIA / CUDA 12.8 wheel',
    'torch-cpu' => 'CPU wheel',
    _ => '运行时自动选择',
  };
}

String _torchExtraMetricLabel(String value) {
  return switch (value) {
    'torch-cu128' => 'CUDA 12.8',
    'torch-cpu' => 'CPU',
    '未设置' => 'auto',
    _ => value,
  };
}

Color _toolchainStatusColor(BuildContext context, String status) {
  final rm = context.rm;
  return switch (status) {
    'checking' => rm.accent.base,
    'ready' || 'ok' => rm.accent.base,
    'degraded' || 'partial' || 'needs_sync' || 'warn' => rm.warn,
    'missing' || 'error' || 'danger' => rm.danger,
    _ => rm.fg3,
  };
}
