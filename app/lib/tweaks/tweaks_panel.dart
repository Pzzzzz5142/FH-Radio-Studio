import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../state/app_state.dart';
import '../state/router.dart';
import '../theme/accents.dart';
import '../theme/app_theme.dart';
import '../theme/text_styles.dart';
import '../theme/tokens.dart';
import '../widgets/rm_icon.dart';

/// 右下角浮动可拖面板：主题 / 强调色 / 导航 / 快速跳转。
/// 默认收起为一个圆形按钮，点击展开。
class TweaksPanel extends ConsumerStatefulWidget {
  const TweaksPanel({super.key});

  @override
  ConsumerState<TweaksPanel> createState() => _TweaksPanelState();
}

class _TweaksPanelState extends ConsumerState<TweaksPanel> {
  Offset _offset = const Offset(24, 24); // distance from bottom-right

  @override
  Widget build(BuildContext context) {
    final open = ref.watch(tweaksOpenProvider);
    return Positioned(
      right: _offset.dx,
      bottom: _offset.dy,
      child: open ? _expanded(context) : _collapsed(context),
    );
  }

  Widget _collapsed(BuildContext context) {
    final rm = context.rm;
    return _draggable(
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => ref.read(tweaksOpenProvider.notifier).state = true,
          borderRadius: BorderRadius.circular(999),
          child: Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: rm.panel,
              border: Border.all(color: rm.borderStrong),
              boxShadow: RmTokens.popover,
            ),
            alignment: Alignment.center,
            child: RmIcon('settings', size: 16, color: rm.fg2),
          ),
        ),
      ),
    );
  }

  Widget _expanded(BuildContext context) {
    final rm = context.rm;
    return _draggable(
      child: Container(
        width: 280,
        decoration: BoxDecoration(
          color: rm.panel,
          borderRadius: BorderRadius.circular(RmTokens.rLg),
          border: Border.all(color: rm.borderStrong),
          boxShadow: RmTokens.popover,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            // header (drag handle)
            MouseRegion(
              cursor: SystemMouseCursors.grab,
              child: Container(
                padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
                decoration: BoxDecoration(
                  border: Border(bottom: BorderSide(color: rm.border)),
                ),
                child: Row(
                  children: [
                    RmIcon('drag', size: 12, color: rm.fg4),
                    const SizedBox(width: 8),
                    Text(
                      '设置',
                      style: RmText.sans(
                        12,
                        color: rm.fg2,
                        weight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    GestureDetector(
                      onTap: () =>
                          ref.read(tweaksOpenProvider.notifier).state = false,
                      child: RmIcon('x', size: 14, color: rm.fg3),
                    ),
                  ],
                ),
              ),
            ),
            _section(context, '主题', _themeSection(context)),
            _divider(context),
            _section(context, '强调色', _accentSection(context)),
            _divider(context),
            _section(context, '导航布局', _navSection(context)),
            _divider(context),
            _section(context, '跳转', _routeSection(context)),
          ],
        ),
      ),
    );
  }

  Widget _section(BuildContext context, String label, Widget body) {
    final rm = context.rm;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            label.toUpperCase(),
            style: RmText.mono(10.5, color: rm.fg4, letterSpacing: 0.12 * 10.5),
          ),
          const SizedBox(height: 8),
          body,
        ],
      ),
    );
  }

  Widget _divider(BuildContext context) =>
      Container(height: 1, color: context.rm.border);

  Widget _themeSection(BuildContext context) {
    final mode = ref.watch(themeModeProvider);
    return Row(
      children: [
        _seg(
          context,
          '浅色',
          mode == ThemeMode.light,
          () => ref.read(themeModeProvider.notifier).set(ThemeMode.light),
        ),
        const SizedBox(width: 6),
        _seg(
          context,
          '深色',
          mode == ThemeMode.dark,
          () => ref.read(themeModeProvider.notifier).set(ThemeMode.dark),
        ),
      ],
    );
  }

  Widget _accentSection(BuildContext context) {
    final accent = ref.watch(accentProvider);
    return Row(
      children: [
        for (final a in AppAccent.values) ...[
          _accentSwatch(context, a, a == accent),
          if (a != AppAccent.values.last) const SizedBox(width: 8),
        ],
      ],
    );
  }

  Widget _accentSwatch(BuildContext context, AppAccent a, bool active) {
    final rm = context.rm;
    final brightness = Theme.of(context).brightness;
    final color = accentColors(a, brightness).base;
    return GestureDetector(
      onTap: () => ref.read(accentProvider.notifier).set(a),
      child: Container(
        width: 28,
        height: 28,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(
            color: active ? rm.fg : rm.border,
            width: active ? 2 : 1,
          ),
        ),
      ),
    );
  }

  Widget _navSection(BuildContext context) {
    final style = ref.watch(navStyleProvider);
    return Row(
      children: [
        _seg(
          context,
          '左侧栏',
          style == NavStyle.rail,
          () => ref.read(navStyleProvider.notifier).set(NavStyle.rail),
        ),
        const SizedBox(width: 6),
        _seg(
          context,
          '顶部 tab',
          style == NavStyle.tabs,
          () => ref.read(navStyleProvider.notifier).set(NavStyle.tabs),
        ),
      ],
    );
  }

  Widget _routeSection(BuildContext context) {
    final routes = [
      ('概览', RmRoutes.dashboard),
      ('塞壬', RmRoutes.siren),
      ('池子', RmRoutes.pool),
      ('播放列表', RmRoutes.playlist),
      ('启动', RmRoutes.boot),
    ];
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final r in routes)
          _seg(context, r.$1, false, () => context.go(r.$2)),
      ],
    );
  }

  Widget _seg(
    BuildContext context,
    String label,
    bool active,
    VoidCallback onTap,
  ) {
    final rm = context.rm;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: active ? rm.accent.bg : rm.raised,
          border: Border.all(color: active ? rm.accent.ring : rm.border),
          borderRadius: BorderRadius.circular(RmTokens.rSm),
        ),
        child: Text(
          label,
          style: RmText.sans(
            11.5,
            color: active ? rm.accent.base : rm.fg2,
            weight: active ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ),
    );
  }

  Widget _draggable({required Widget child}) {
    return GestureDetector(
      onPanUpdate: (d) {
        setState(() {
          _offset = Offset(
            (_offset.dx - d.delta.dx).clamp(0, 4000),
            (_offset.dy - d.delta.dy).clamp(0, 4000),
          );
        });
      },
      child: child,
    );
  }
}
