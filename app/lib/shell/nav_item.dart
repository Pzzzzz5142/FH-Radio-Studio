import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/text_styles.dart';
import '../theme/tokens.dart';
import '../widgets/rm_icon.dart';

class NavSpec {
  const NavSpec({
    required this.id,
    required this.label,
    required this.icon,
    this.kbd,
    this.group,
  });

  final String id;
  final String label;
  final String icon;
  final String? kbd;
  final String? group;
}

const List<NavSpec> kNavItems = [
  NavSpec(id: 'dashboard', label: '概览', icon: 'dashboard'),
  NavSpec(id: 'pool', label: '自建歌曲', icon: 'music', group: '内容'),
  NavSpec(id: 'playlist', label: '播放列表', icon: 'list', group: '内容'),
  NavSpec(id: 'siren', label: '塞壬唱片', icon: 'spark', group: '工具'),
];

/// Sidebar 一行 nav-item，按 spec：
/// - default: fg-2, no bg
/// - hover:   bg=hover, color=fg
/// - active:  bg=color-mix(accent 14%, raised), fg=fg, weight=600,
///            inset 1px ring @35% accent, ::before 3px 强调色竖条 (top/bottom 7, left 3),
///            icon 染色为 accent
class NavItem extends StatefulWidget {
  const NavItem({
    super.key,
    required this.spec,
    required this.active,
    this.enabled = true,
    this.tooltip,
    this.onTap,
  });

  final NavSpec spec;
  final bool active;
  final bool enabled;
  final String? tooltip;
  final VoidCallback? onTap;

  @override
  State<NavItem> createState() => _NavItemState();
}

class _NavItemState extends State<NavItem> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    final active = widget.active;
    final enabled = widget.enabled;

    // active bg = mix(accent 14%, raised)
    final activeBg = Color.alphaBlend(
      rm.accent.base.withAlpha((0.14 * 255).round()),
      rm.raised,
    );

    final bg = active && enabled
        ? activeBg
        : (_hover && enabled ? rm.hover : Colors.transparent);
    final fg = !enabled ? rm.fg4 : (active ? rm.fg : (_hover ? rm.fg : rm.fg2));
    final iconColor = !enabled ? rm.fg4 : (active ? rm.accent.base : rm.fg3);

    final item = MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) {
        if (enabled) setState(() => _hover = true);
      },
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: enabled ? widget.onTap : null,
        child: Stack(
          children: [
            Container(
              padding: const EdgeInsets.fromLTRB(13, 8, 10, 8),
              decoration: BoxDecoration(
                color: bg,
                borderRadius: BorderRadius.circular(RmTokens.rSm),
                border: Border.all(
                  color: active && enabled
                      ? rm.accent.ring
                      : Colors.transparent,
                  width: 1,
                ),
              ),
              child: Row(
                children: [
                  SizedBox(
                    width: 15,
                    height: 15,
                    child: Center(
                      child: RmIcon(
                        widget.spec.icon,
                        size: 15,
                        color: iconColor,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    widget.spec.label,
                    style: RmText.sans(
                      13,
                      weight: active ? FontWeight.w600 : FontWeight.w400,
                      color: fg,
                    ),
                  ),
                  if (widget.spec.kbd != null) ...[
                    const Spacer(),
                    Text(
                      widget.spec.kbd!,
                      style: RmText.mono(10.5, color: active ? rm.fg2 : rm.fg4),
                    ),
                  ],
                ],
              ),
            ),
            // active accent bar (3px wide, top 7, bottom 7, left 3)
            if (active && enabled)
              Positioned(
                left: 3,
                top: 7,
                bottom: 7,
                child: Container(
                  width: 3,
                  decoration: BoxDecoration(
                    color: rm.accent.base,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
    if (widget.tooltip == null || enabled) return item;
    return Tooltip(message: widget.tooltip!, child: item);
  }
}

/// 顶部 tab 模式的项
class TabItem extends StatefulWidget {
  const TabItem({
    super.key,
    required this.spec,
    required this.active,
    this.enabled = true,
    this.tooltip,
    this.onTap,
  });

  final NavSpec spec;
  final bool active;
  final bool enabled;
  final String? tooltip;
  final VoidCallback? onTap;

  @override
  State<TabItem> createState() => _TabItemState();
}

class _TabItemState extends State<TabItem> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    final active = widget.active;
    final enabled = widget.enabled;
    final fg = !enabled ? rm.fg4 : (active ? rm.fg : (_hover ? rm.fg : rm.fg2));
    final iconColor = !enabled ? rm.fg4 : (active ? rm.accent.base : rm.fg3);

    final item = MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) {
        if (enabled) setState(() => _hover = true);
      },
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: enabled ? widget.onTap : null,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          height: RmTokens.tabsBarHeight,
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: active && enabled ? rm.accent.base : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          child: Row(
            children: [
              RmIcon(widget.spec.icon, size: 14, color: iconColor),
              const SizedBox(width: 8),
              Text(
                widget.spec.label,
                style: RmText.sans(
                  13,
                  weight: active ? FontWeight.w600 : FontWeight.w400,
                  color: fg,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (widget.tooltip == null || enabled) return item;
    return Tooltip(message: widget.tooltip!, child: item);
  }
}
