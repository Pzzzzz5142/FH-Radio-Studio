import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;

import '../state/studio_state.dart';
import '../state/router.dart';
import '../theme/app_theme.dart';
import '../theme/text_styles.dart';
import '../theme/tokens.dart';
import '../widgets/rm_button.dart';
import '../widgets/rm_icon.dart';

class TitleBar extends ConsumerWidget {
  const TitleBar({super.key, this.onCommandTap});

  final VoidCallback? onCommandTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rm = context.rm;
    final cli = ref.watch(studioProvider);
    final showTrafficLights = Platform.isMacOS;
    final toolchain = cli.toolchainStatus;

    return Container(
      height: RmTokens.titleBarHeight,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: rm.bg,
        border: Border(bottom: BorderSide(color: rm.border)),
      ),
      child: Row(
        children: [
          if (showTrafficLights) ...[
            _trafficLight(RmTokens.trafficRed),
            const SizedBox(width: 8),
            _trafficLight(RmTokens.trafficYellow),
            const SizedBox(width: 8),
            _trafficLight(RmTokens.trafficGreen),
            const SizedBox(width: 12),
          ],
          RichText(
            text: TextSpan(
              style: RmText.sans(12, color: rm.fg2),
              children: [
                TextSpan(
                  text: 'FH Radio Studio',
                  style: RmText.mono(
                    12,
                    color: rm.fg,
                    weight: FontWeight.w600,
                    letterSpacing: 0.04 * 12,
                  ),
                ),
                const TextSpan(text: ' · FH6 电台修改工具'),
              ],
            ),
          ),
          const SizedBox(width: 16),
          _projectPill(
            context,
            p.basename(cli.projectDir),
            onTap: () => context.go('${RmRoutes.boot}?manual=1'),
          ),
          const Spacer(),
          _statusItem(
            context,
            _toolchainLedKind(toolchain),
            _toolchainLabel(toolchain),
          ),
          const SizedBox(width: 14),
          _statusItem(
            context,
            cli.gameRunning ? _LedKind.warn : _LedKind.ok,
            cli.gameRunning ? '游戏运行中' : '游戏未运行',
          ),
          const SizedBox(width: 14),
          Text('项目已打开', style: RmText.sans(11.5, color: rm.fg3)),
          const SizedBox(width: 14),
          RmButton(
            onPressed: onCommandTap,
            size: RmButtonSize.sm,
            variant: RmButtonVariant.ghost,
            leading: const RmIcon('command', size: 12),
            tooltip: '命令面板',
            label: 'K',
          ),
        ],
      ),
    );
  }

  Widget _trafficLight(Color c) {
    return Container(
      width: 11,
      height: 11,
      decoration: BoxDecoration(color: c, shape: BoxShape.circle),
    );
  }

  Widget _projectPill(
    BuildContext context,
    String name, {
    required VoidCallback onTap,
  }) {
    final rm = context.rm;
    return Tooltip(
      message: '切换项目',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: rm.raised,
              borderRadius: BorderRadius.circular(RmTokens.rSm),
              border: Border.all(color: rm.border),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                RmIcon('folder', size: 11, color: rm.fg2),
                const SizedBox(width: 8),
                Text(name, style: RmText.mono(11.5, color: rm.fg)),
                const SizedBox(width: 6),
                Text('·', style: RmText.mono(11.5, color: rm.fg4)),
                const SizedBox(width: 6),
                Text('已保存', style: RmText.sans(11.5, color: rm.fg2)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _statusItem(BuildContext context, _LedKind kind, String label) {
    final rm = context.rm;
    final color = switch (kind) {
      _LedKind.ok => rm.accent.base,
      _LedKind.warn => rm.warn,
      _LedKind.danger => rm.danger,
    };
    final glow = color.withAlpha((0.4 * 255).round());
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            boxShadow: [BoxShadow(color: glow, blurRadius: 8)],
          ),
        ),
        const SizedBox(width: 6),
        Text(label, style: RmText.sans(11.5, color: rm.fg3)),
      ],
    );
  }

  _LedKind _toolchainLedKind(ToolchainStatusSummary status) {
    if (status.checking || !status.checked) return _LedKind.warn;
    return switch (status.status) {
      'ready' => _LedKind.ok,
      'degraded' || 'partial' || 'needs_sync' => _LedKind.warn,
      'missing' || 'error' => _LedKind.danger,
      _ => _LedKind.warn,
    };
  }

  String _toolchainLabel(ToolchainStatusSummary status) {
    if (status.checking) return '工具链检测中';
    if (!status.checked) return '工具链待检查';
    return switch (status.status) {
      'ready' => '工具链可用',
      'degraded' || 'partial' => '工具链可降级',
      'needs_sync' => '工具链待同步',
      'missing' => '工具链缺失',
      'error' => '工具链异常',
      _ => '工具链待检查',
    };
  }
}

enum _LedKind { ok, warn, danger }
