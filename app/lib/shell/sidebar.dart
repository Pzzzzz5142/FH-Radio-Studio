import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/app_info.dart';
import '../state/app_state.dart';
import '../state/studio_state.dart';
import '../state/router.dart';
import '../theme/app_theme.dart';
import '../theme/text_styles.dart';
import '../theme/tokens.dart';
import 'nav_item.dart';

/// 左侧 220px 导航栏
class Sidebar extends ConsumerWidget {
  const Sidebar({super.key, required this.activeId});

  final String activeId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rm = context.rm;
    final cli = ref.watch(studioProvider);
    final appInfo = ref.watch(appInfoProvider).valueOrNull ?? AppInfo.fallback;
    final toolchainLocked = cli.toolchainWorkflowLocked;
    final lockMessage = cli.toolchainWorkflowLockMessage;

    String? lastGroup;
    final children = <Widget>[];
    for (final spec in kNavItems) {
      if (spec.group != null && spec.group != lastGroup) {
        if (children.isNotEmpty) children.add(const SizedBox(height: 14));
        children.add(
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
            child: Text(
              spec.group!.toUpperCase(),
              style: RmText.mono(
                10.5,
                color: rm.fg4,
                letterSpacing: 0.12 * 10.5,
              ),
            ),
          ),
        );
        lastGroup = spec.group;
      }
      final enabled = !toolchainLocked || _toolchainLockAllowsNavItem(spec.id);
      children.add(
        NavItem(
          spec: spec,
          active: spec.id == activeId,
          enabled: enabled,
          tooltip: enabled ? null : lockMessage,
          onTap: enabled ? () => context.go(_pathFor(spec.id)) : null,
        ),
      );
      children.add(const SizedBox(height: 4));
    }

    return Container(
      width: RmTokens.sidebarWidth,
      decoration: BoxDecoration(
        border: Border(right: BorderSide(color: rm.border)),
      ),
      padding: const EdgeInsets.fromLTRB(12, 18, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: ListView(children: children)),
          NavItem(
            spec: const NavSpec(id: 'settings', label: '设置', icon: 'settings'),
            active: false,
            onTap: () => ref.read(tweaksOpenProvider.notifier).state = true,
          ),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.all(10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final line in appInfo.sidebarLines)
                  Text(line, style: RmText.mono(10.5, color: rm.fg4)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _pathFor(String id) {
    switch (id) {
      case 'dashboard':
        return RmRoutes.dashboard;
      case 'pool':
        return RmRoutes.pool;
      case 'siren':
        return RmRoutes.siren;
      case 'playlist':
        return RmRoutes.playlist;
    }
    return RmRoutes.dashboard;
  }
}

/// 顶部 tab 模式
class TabsBar extends ConsumerWidget {
  const TabsBar({super.key, required this.activeId});

  final String activeId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rm = context.rm;
    final cli = ref.watch(studioProvider);
    final toolchainLocked = cli.toolchainWorkflowLocked;
    final lockMessage = cli.toolchainWorkflowLockMessage;
    return Container(
      height: RmTokens.tabsBarHeight,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: rm.border)),
      ),
      child: Row(
        children: [
          for (final spec in kNavItems)
            Builder(
              builder: (context) {
                final enabled =
                    !toolchainLocked || _toolchainLockAllowsNavItem(spec.id);
                return TabItem(
                  spec: spec,
                  active: spec.id == activeId,
                  enabled: enabled,
                  tooltip: enabled ? null : lockMessage,
                  onTap: enabled ? () => context.go(_pathFor(spec.id)) : null,
                );
              },
            ),
          const Spacer(),
          // ⌘K 占位
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Row(
              children: [Text('⌘K', style: RmText.mono(11, color: rm.fg3))],
            ),
          ),
        ],
      ),
    );
  }

  String _pathFor(String id) {
    switch (id) {
      case 'dashboard':
        return RmRoutes.dashboard;
      case 'pool':
        return RmRoutes.pool;
      case 'siren':
        return RmRoutes.siren;
      case 'playlist':
        return RmRoutes.playlist;
    }
    return RmRoutes.dashboard;
  }
}

bool _toolchainLockAllowsNavItem(String id) {
  return id == 'dashboard' || id == 'siren';
}
