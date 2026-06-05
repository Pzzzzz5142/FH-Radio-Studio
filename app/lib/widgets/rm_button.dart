import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/text_styles.dart';
import '../theme/tokens.dart';

enum RmButtonVariant {
  defaultBtn,
  primary,
  ghost,
  danger,
  dangerOutline,
  dangerPrimary,
}

enum RmButtonSize { sm, md, lg, icon }

/// 通用按钮 — 对齐 styles.css `.btn / .btn-sm / .btn-lg / .btn-icon / .btn-primary / .btn-ghost / .btn-danger`。
class RmButton extends StatefulWidget {
  const RmButton({
    super.key,
    required this.onPressed,
    this.label,
    this.leading,
    this.trailing,
    this.variant = RmButtonVariant.defaultBtn,
    this.size = RmButtonSize.md,
    this.tooltip,
    this.disabled = false,
  });

  const RmButton.icon({
    super.key,
    required this.onPressed,
    required Widget icon,
    this.variant = RmButtonVariant.defaultBtn,
    this.tooltip,
    this.disabled = false,
  }) : leading = icon,
       label = null,
       trailing = null,
       size = RmButtonSize.icon;

  final VoidCallback? onPressed;
  final String? label;
  final Widget? leading;
  final Widget? trailing;
  final RmButtonVariant variant;
  final RmButtonSize size;
  final String? tooltip;
  final bool disabled;

  @override
  State<RmButton> createState() => _RmButtonState();
}

class _RmButtonState extends State<RmButton> {
  bool _hover = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    final disabled = widget.disabled || widget.onPressed == null;

    final (
      double height,
      EdgeInsets padding,
      double fontSize,
    ) = switch (widget.size) {
      RmButtonSize.sm => (
        26.0,
        const EdgeInsets.symmetric(horizontal: 10),
        11.5,
      ),
      RmButtonSize.md => (
        32.0,
        const EdgeInsets.symmetric(horizontal: 14),
        12.5,
      ),
      RmButtonSize.lg => (
        38.0,
        const EdgeInsets.symmetric(horizontal: 18),
        13.0,
      ),
      RmButtonSize.icon => (32.0, EdgeInsets.zero, 12.5),
    };

    final isIcon = widget.size == RmButtonSize.icon;
    final transparentHover = rm.hover.withAlpha(0);
    final transparentBorder = rm.border.withAlpha(0);

    Color bg;
    Color fg;
    Color border;
    switch (widget.variant) {
      case RmButtonVariant.defaultBtn:
        bg = _hover ? rm.hover : rm.raised;
        fg = rm.fg;
        border = _hover ? rm.borderStrong : rm.border;
      case RmButtonVariant.primary:
        bg = rm.accent.base;
        fg = rm.accent.onAccent;
        border = rm.accent.base;
      case RmButtonVariant.ghost:
        bg = _hover ? rm.hover : transparentHover;
        fg = _hover ? rm.fg : rm.fg2;
        border = transparentBorder;
      case RmButtonVariant.danger:
        bg = _hover ? rm.dangerBg : rm.raised;
        fg = rm.danger;
        border = _hover ? rm.danger : rm.border;
      case RmButtonVariant.dangerOutline:
        bg = _hover ? rm.dangerBg : rm.panel;
        fg = rm.danger;
        border = rm.danger;
      case RmButtonVariant.dangerPrimary:
        bg = rm.danger;
        fg = Colors.white;
        border = rm.danger;
    }

    final children = <Widget>[
      if (widget.leading != null) widget.leading!,
      if (widget.label != null) ...[
        if (widget.leading != null) const SizedBox(width: 8),
        Flexible(
          child: Text(
            widget.label!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            softWrap: false,
            style: RmText.sans(
              fontSize,
              weight:
                  widget.variant == RmButtonVariant.primary ||
                      widget.variant == RmButtonVariant.dangerOutline ||
                      widget.variant == RmButtonVariant.dangerPrimary
                  ? FontWeight.w600
                  : FontWeight.w500,
              color: fg,
            ),
          ),
        ),
      ],
      if (widget.trailing != null) ...[
        const SizedBox(width: 8),
        widget.trailing!,
      ],
    ];

    final inner = AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      height: height,
      padding: padding,
      width: isIcon ? height : null,
      transform: _pressed
          ? (Matrix4.identity()..translateByDouble(0, 0.5, 0, 0))
          : Matrix4.identity(),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(RmTokens.rSm),
        border: Border.all(color: border, width: 1),
      ),
      child: IconTheme.merge(
        data: IconThemeData(color: fg, size: fontSize),
        child: DefaultTextStyle.merge(
          style: TextStyle(color: fg),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: children,
          ),
        ),
      ),
    );

    Widget gestures = MouseRegion(
      cursor: disabled ? SystemMouseCursors.basic : SystemMouseCursors.click,
      onEnter: disabled ? null : (_) => setState(() => _hover = true),
      onExit: disabled ? null : (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTapDown: disabled ? null : (_) => setState(() => _pressed = true),
        onTapUp: disabled ? null : (_) => setState(() => _pressed = false),
        onTapCancel: disabled ? null : () => setState(() => _pressed = false),
        onTap: disabled ? null : widget.onPressed,
        child: Opacity(opacity: disabled ? 0.4 : 1, child: inner),
      ),
    );

    if (widget.tooltip != null) {
      gestures = Tooltip(message: widget.tooltip!, child: gestures);
    }
    return gestures;
  }
}
