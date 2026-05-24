import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../state/app_state.dart';
import '../state/studio_state.dart';
import '../tweaks/tweaks_panel.dart';
import '../theme/app_theme.dart';
import '../theme/text_styles.dart';
import '../theme/tokens.dart';
import '../widgets/pending_gate.dart';
import '../widgets/rm_button.dart';
import '../widgets/rm_chip.dart';
import '../widgets/rm_icon.dart';
import 'sidebar.dart';
import 'title_bar.dart';

/// 三段式 shell：TitleBar / (Sidebar | TabsBar) / 内容区。
class AppShell extends ConsumerWidget {
  const AppShell({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final navStyle = ref.watch(navStyleProvider);
    final location = GoRouterState.of(context).uri.toString();
    final activeId = _activeIdFor(location);
    final rm = context.rm;
    final showTweaks = !location.startsWith('/editor');
    final cli = ref.watch(studioProvider);
    final blockForPackageBuild =
        cli.busy && _isPackageBuildLabel(cli.busyLabel);
    final blockForToolchainFix =
        cli.busy && _isToolchainFixLabel(cli.busyLabel);
    if (!location.startsWith('/dashboard') && cli.aiProfileNotice != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) {
          ref.read(studioProvider.notifier).clearAiProfileNotice();
        }
      });
    }
    final blockForToolchain =
        cli.toolchainWorkflowLocked && !_toolchainLockAllowsLocation(location);
    final content = blockForToolchain
        ? _ToolchainLockedContent(cli: cli)
        : child;

    final isRail = navStyle == NavStyle.rail;

    return Scaffold(
      backgroundColor: rm.bg,
      body: Stack(
        children: [
          Column(
            children: [
              const TitleBar(),
              Expanded(
                child: isRail
                    ? Row(
                        children: [
                          Sidebar(activeId: activeId),
                          Expanded(child: content),
                        ],
                      )
                    : Column(
                        children: [
                          TabsBar(activeId: activeId),
                          Expanded(child: content),
                        ],
                      ),
              ),
            ],
          ),
          if (showTweaks) const TweaksPanel(),
          if (blockForPackageBuild) _PackageBuildBlockingOverlay(cli: cli),
          if (blockForToolchainFix)
            _ToolchainFixBlockingOverlay(
              cli: cli,
              onCancelAiEnvironmentSync: () {
                unawaited(
                  ref.read(studioProvider.notifier).cancelAiEnvironmentSync(),
                );
              },
            ),
        ],
      ),
    );
  }

  /// 把 location 映射到 sidebar 高亮 id；editor 高亮 pool。
  static String _activeIdFor(String location) {
    if (location.startsWith('/dashboard')) return 'dashboard';
    if (location.startsWith('/pool')) return 'pool';
    if (location.startsWith('/siren')) return 'siren';
    if (location.startsWith('/playlist')) return 'playlist';
    if (location.startsWith('/editor')) return 'pool';
    return 'dashboard';
  }

  static bool _isPackageBuildLabel(String? label) {
    return label == '构建电台包' || label == '生成测试准备包';
  }

  static bool _isToolchainFixLabel(String? label) {
    return label == '安装本地处理组件' || label == '同步 AI 环境';
  }

  static bool _toolchainLockAllowsLocation(String location) {
    return location.startsWith('/dashboard') || location.startsWith('/siren');
  }
}

class _ToolchainFixBlockingOverlay extends StatelessWidget {
  const _ToolchainFixBlockingOverlay({
    required this.cli,
    this.onCancelAiEnvironmentSync,
  });

  final StudioState cli;
  final VoidCallback? onCancelAiEnvironmentSync;

  @override
  Widget build(BuildContext context) {
    final installingTools = cli.busyLabel == '安装本地处理组件';
    final syncingAiEnvironment = cli.busyLabel == '同步 AI 环境';
    final title = cli.busyLabel == '同步 AI 环境' ? '正在修复 AI 环境' : '正在安装本地处理组件';
    final detail = cli.busyLabel == '同步 AI 环境'
        ? '正在下载/安装 Python wheel，按需拉取 AI 模型缓存，并在结束后自动刷新工具链状态。'
        : '正在下载、解压并登记 ffmpeg、vgmstream-cli 和 FMOD/FSBank 工具。完成前请保持窗口打开。';
    final aiProgressPercent = cli.aiEnvironmentProgressPercent;
    final width = (MediaQuery.sizeOf(context).width - 96)
        .clamp(320.0, 880.0)
        .toDouble();
    return Positioned.fill(
      child: Stack(
        children: [
          const ModalBarrier(dismissible: false, color: Colors.transparent),
          PendingOverlay(
            key: const ValueKey('toolchain-fix-blocking-overlay'),
            label: title,
            detail: detail,
            progressLabel: syncingAiEnvironment
                ? (cli.aiEnvironmentProgressLabel ?? cli.busyLabel)
                : cli.busyLabel,
            progressDetail: installingTools
                ? '下方只显示本次工具安装输出。'
                : (cli.aiEnvironmentProgressDetail ?? '这一步可能需要一点时间。'),
            progressValue: syncingAiEnvironment && aiProgressPercent != null
                ? aiProgressPercent / 100
                : null,
            progressCaption: syncingAiEnvironment && aiProgressPercent != null
                ? '$aiProgressPercent%'
                : null,
            progressExtra: installingTools
                ? _ToolInstallLogView(lines: cli.toolInstallLog)
                : syncingAiEnvironment
                ? _AiEnvironmentSyncDetails(
                    cli: cli,
                    onCancel: onCancelAiEnvironmentSync,
                  )
                : null,
            contentConstraints: BoxConstraints(
              minWidth: width < 560 ? width : 560,
              maxWidth: width,
            ),
            interactive: installingTools || syncingAiEnvironment,
            borderRadius: BorderRadius.zero,
          ),
        ],
      ),
    );
  }
}

class _ToolInstallLogView extends StatefulWidget {
  const _ToolInstallLogView({required this.lines});

  final List<String> lines;

  @override
  State<_ToolInstallLogView> createState() => _ToolInstallLogViewState();
}

class _ToolInstallLogViewState extends State<_ToolInstallLogView> {
  final ScrollController _controller = ScrollController();

  @override
  void initState() {
    super.initState();
    _scrollToLatest();
  }

  @override
  void didUpdateWidget(covariant _ToolInstallLogView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.lines.length != widget.lines.length) {
      _scrollToLatest();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _scrollToLatest() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_controller.hasClients) return;
      _controller.jumpTo(_controller.position.maxScrollExtent);
    });
  }

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    final visibleLines = widget.lines.isEmpty
        ? const ['等待 install-tools 输出...']
        : widget.lines;
    final logHeight = (MediaQuery.sizeOf(context).height * 0.32)
        .clamp(190.0, 310.0)
        .toDouble();
    return Container(
      key: const ValueKey('tool-install-log-panel'),
      height: logHeight,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: rm.panel.withAlpha(224),
        border: Border.all(color: rm.border.withAlpha(190)),
        borderRadius: BorderRadius.circular(RmTokens.rXs),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(
                '工具安装日志',
                style: RmText.sans(11.5, color: rm.fg, weight: FontWeight.w700),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'install-tools stdout / stderr',
                  style: RmText.mono(10.5, color: rm.fg3),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: rm.bg.withAlpha(150),
                borderRadius: BorderRadius.circular(RmTokens.rXs),
              ),
              child: Scrollbar(
                controller: _controller,
                thumbVisibility: true,
                trackVisibility: true,
                child: ListView.builder(
                  key: const ValueKey('tool-install-log-list'),
                  controller: _controller,
                  primary: false,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  itemCount: visibleLines.length,
                  itemBuilder: (context, index) {
                    final line = visibleLines[index];
                    final isError = line.startsWith('ERR ');
                    return Text(
                      line,
                      style: RmText.mono(
                        10.5,
                        color: isError ? rm.danger : rm.fg2,
                        height: 1.28,
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AiEnvironmentSyncDetails extends StatelessWidget {
  const _AiEnvironmentSyncDetails({required this.cli, this.onCancel});

  final StudioState cli;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    final steps = _visibleSteps;
    final logLines = cli.aiEnvironmentProgressLog.isEmpty
        ? const ['等待 uv / Hugging Face 下载输出...']
        : cli.aiEnvironmentProgressLog
              .skip(
                cli.aiEnvironmentProgressLog.length > 6
                    ? cli.aiEnvironmentProgressLog.length - 6
                    : 0,
              )
              .toList(growable: false);
    return Container(
      key: const ValueKey('ai-environment-sync-details'),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: rm.panel.withAlpha(224),
        border: Border.all(color: rm.border.withAlpha(190)),
        borderRadius: BorderRadius.circular(RmTokens.rXs),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Text(
                '下载明细',
                style: RmText.sans(11.5, color: rm.fg, weight: FontWeight.w700),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _sourceSummary,
                  style: RmText.sans(10.5, color: rm.fg3),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              RmChip(
                label: aiProfileCupLabel(cli.aiProfile),
                variant: RmChipVariant.accent,
              ),
              if (onCancel != null) ...[
                const SizedBox(width: 8),
                RmButton(
                  key: const ValueKey('ai-environment-sync-cancel'),
                  onPressed: onCancel,
                  label: '取消下载',
                  leading: const RmIcon('x', size: 11),
                  size: RmButtonSize.sm,
                  variant: RmButtonVariant.danger,
                ),
              ],
            ],
          ),
          const SizedBox(height: 8),
          for (final step in steps) ...[
            _AiEnvironmentStepRow(step: step),
            if (step != steps.last) const SizedBox(height: 6),
          ],
          const SizedBox(height: 10),
          Container(
            key: const ValueKey('ai-environment-sync-log-panel'),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: rm.bg.withAlpha(150),
              borderRadius: BorderRadius.circular(RmTokens.rXs),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Text(
                      '最近下载输出',
                      style: RmText.sans(
                        10.5,
                        color: rm.fg,
                        weight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'uv sync / prepare-ai-cache',
                        style: RmText.mono(10, color: rm.fg3),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 5),
                for (final line in logLines) _AiEnvironmentLogLine(line: line),
              ],
            ),
          ),
        ],
      ),
    );
  }

  List<AiEnvironmentProgressStep> get _visibleSteps {
    if (cli.aiEnvironmentProgressSteps.isNotEmpty) {
      return cli.aiEnvironmentProgressSteps;
    }
    final providers = aiWarmupProvidersForProfile(cli.aiProfile);
    final label = cli.aiEnvironmentProgressLabel ?? '';
    final percent = cli.aiEnvironmentProgressPercent ?? 0;
    final dependenciesStatus = label.contains('依赖')
        ? 'running'
        : percent >= 46
        ? 'done'
        : 'pending';
    final modelsStatus = providers.isEmpty
        ? 'skipped'
        : label.contains('模型缓存')
        ? 'running'
        : percent >= 84
        ? 'done'
        : 'pending';
    final verifyStatus = label.contains('刷新')
        ? 'running'
        : percent >= 100
        ? 'done'
        : 'pending';
    return [
      AiEnvironmentProgressStep(
        id: 'dependencies',
        label: 'Python / AI 依赖',
        detail: '下载缺失 wheel 并同步到${aiProfileCupLabel(cli.aiProfile)}环境。',
        status: dependenciesStatus,
      ),
      AiEnvironmentProgressStep(
        id: 'models',
        label: '模型缓存',
        detail: providers.isEmpty
            ? '${aiProfileCupLabel(cli.aiProfile)}不需要深度 Provider。'
            : '下载或复用 ${providers.length} 个 Provider：${providers.join(', ')}。',
        status: modelsStatus,
      ),
      AiEnvironmentProgressStep(
        id: 'verify',
        label: '完成后复检',
        detail: '重新检查 uv、Python、AI Provider 和硬件能力。',
        status: verifyStatus,
      ),
    ];
  }

  String get _sourceSummary {
    final pip = cli.aiUsePipMirror ? 'PyPI Mirror' : 'PyPI Official';
    final torch = cli.aiUseTorchWheelMirror
        ? 'Torch Wheel Mirror'
        : 'Torch Wheel Official';
    final hf = cli.aiUseHfMirror ? 'HF Mirror' : 'HF Official';
    return '$pip · $torch · $hf';
  }
}

class _AiEnvironmentLogLine extends StatelessWidget {
  const _AiEnvironmentLogLine({required this.line});

  final String line;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    final display = _aiEnvironmentLogDisplay(line);
    return Text(
      display,
      style: RmText.mono(
        10,
        color: _aiEnvironmentLogLineColor(context, display, fallback: rm.fg2),
        height: 1.25,
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}

String _aiEnvironmentLogDisplay(String line) {
  final trimmed = line.trim();
  if (trimmed.startsWith('ERR ')) return trimmed.substring(4).trimLeft();
  return trimmed;
}

Color _aiEnvironmentLogLineColor(
  BuildContext context,
  String line, {
  required Color fallback,
}) {
  final rm = context.rm;
  final lower = line.toLowerCase();
  if (lower.contains('cancel') || line.contains('取消')) {
    return rm.warn;
  }
  if (lower.contains('error') ||
      lower.contains('failed') ||
      lower.contains('traceback') ||
      lower.contains('exception') ||
      line.contains('失败')) {
    return rm.danger;
  }
  return fallback;
}

class _AiEnvironmentStepRow extends StatelessWidget {
  const _AiEnvironmentStepRow({required this.step});

  final AiEnvironmentProgressStep step;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    final color = _aiEnvironmentStepColor(context, step.status);
    return Container(
      padding: const EdgeInsets.fromLTRB(9, 8, 9, 8),
      decoration: BoxDecoration(
        color: rm.bg.withAlpha(112),
        border: Border.all(color: rm.border.withAlpha(150)),
        borderRadius: BorderRadius.circular(RmTokens.rXs),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 7,
            height: 7,
            margin: const EdgeInsets.only(top: 5),
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  step.label,
                  style: RmText.sans(
                    11.5,
                    color: rm.fg,
                    weight: FontWeight.w700,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  step.detail,
                  style: RmText.sans(10.5, color: rm.fg3, height: 1.25),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          RmChip(
            label: _aiEnvironmentStepStatusLabel(step.status),
            variant: _aiEnvironmentStepChipVariant(step.status),
            showDot: step.status == 'running',
          ),
        ],
      ),
    );
  }
}

String _aiEnvironmentStepStatusLabel(String status) {
  return switch (status) {
    'running' => '进行中',
    'done' => '完成',
    'skipped' => '跳过',
    'warning' => '注意',
    'error' => '失败',
    _ => '等待',
  };
}

RmChipVariant _aiEnvironmentStepChipVariant(String status) {
  return switch (status) {
    'running' => RmChipVariant.accent,
    'done' => RmChipVariant.info,
    'skipped' => RmChipVariant.skip,
    'warning' => RmChipVariant.warn,
    'error' => RmChipVariant.danger,
    _ => RmChipVariant.muted,
  };
}

Color _aiEnvironmentStepColor(BuildContext context, String status) {
  final rm = context.rm;
  return switch (status) {
    'running' => rm.accent.base,
    'done' => rm.info,
    'warning' => rm.warn,
    'error' => rm.danger,
    _ => rm.fg4,
  };
}

class _ToolchainLockedContent extends StatelessWidget {
  const _ToolchainLockedContent({required this.cli});

  final StudioState cli;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    return ColoredBox(
      color: rm.bg,
      child: Center(
        child: Container(
          width: 520,
          padding: const EdgeInsets.all(22),
          decoration: BoxDecoration(
            color: rm.panel,
            border: Border.all(color: rm.border),
            borderRadius: BorderRadius.circular(RmTokens.rMd),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                cli.toolchainWorkflowLockTitle,
                style: RmText.sans(18, color: rm.fg, weight: FontWeight.w700),
              ),
              const SizedBox(height: 10),
              Text(
                cli.toolchainWorkflowLockMessage,
                style: RmText.sans(13, color: rm.fg2, height: 1.45),
              ),
              const SizedBox(height: 18),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  RmButton(
                    onPressed: () => context.go('/dashboard'),
                    size: RmButtonSize.sm,
                    label: '回到概览',
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PackageBuildBlockingOverlay extends StatelessWidget {
  const _PackageBuildBlockingOverlay({required this.cli});

  final StudioState cli;

  @override
  Widget build(BuildContext context) {
    final title = cli.busyLabel == '生成测试准备包' ? '正在生成测试准备包' : '正在准备电台包';
    final active =
        cli.activePackageBuildProgressStep ??
        cli.lastVisiblePackageBuildProgressStep;
    final progressValue = cli.hasPackageBuildProgress
        ? cli.packageBuildProgressPercent / 100
        : null;
    return Positioned.fill(
      child: Stack(
        children: [
          const ModalBarrier(dismissible: false, color: Colors.transparent),
          PendingOverlay(
            key: const ValueKey('package-build-blocking-overlay'),
            label: title,
            detail: '正在转码、重建 bank 并校验包文件。这一步通常需要几十秒，完成后会弹出结果提示。',
            progressLabel: active?.label,
            progressDetail: active?.summary.isNotEmpty == true
                ? active!.summary
                : active?.detail,
            progressValue: progressValue,
            progressCaption: cli.hasPackageBuildProgress
                ? '${cli.packageBuildProgressPercent}%'
                : null,
            borderRadius: BorderRadius.zero,
          ),
        ],
      ),
    );
  }
}
