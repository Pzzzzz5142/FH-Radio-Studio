import 'package:flutter/material.dart';

import 'accents.dart';
import 'text_styles.dart';
import 'tokens.dart';

/// 自定义 ThemeExtension — 携带所有 FH Radio Studio 的 design tokens。
/// 用 `Theme.of(context).extension<RmTheme>()!` 取。
@immutable
class RmTheme extends ThemeExtension<RmTheme> {
  const RmTheme({
    required this.bg,
    required this.panel,
    required this.raised,
    required this.hover,
    required this.border,
    required this.border2,
    required this.borderStrong,
    required this.fg,
    required this.fg2,
    required this.fg3,
    required this.fg4,
    required this.warn,
    required this.warnBg,
    required this.danger,
    required this.dangerBg,
    required this.info,
    required this.accent,
  });

  // surfaces
  final Color bg;
  final Color panel;
  final Color raised;
  final Color hover;
  final Color border;
  final Color border2;
  final Color borderStrong;
  // text
  final Color fg;
  final Color fg2;
  final Color fg3;
  final Color fg4;
  // semantic
  final Color warn;
  final Color warnBg;
  final Color danger;
  final Color dangerBg;
  final Color info;
  // accent (4 derived colors)
  final AccentColors accent;

  @override
  RmTheme copyWith({
    Color? bg,
    Color? panel,
    Color? raised,
    Color? hover,
    Color? border,
    Color? border2,
    Color? borderStrong,
    Color? fg,
    Color? fg2,
    Color? fg3,
    Color? fg4,
    Color? warn,
    Color? warnBg,
    Color? danger,
    Color? dangerBg,
    Color? info,
    AccentColors? accent,
  }) {
    return RmTheme(
      bg: bg ?? this.bg,
      panel: panel ?? this.panel,
      raised: raised ?? this.raised,
      hover: hover ?? this.hover,
      border: border ?? this.border,
      border2: border2 ?? this.border2,
      borderStrong: borderStrong ?? this.borderStrong,
      fg: fg ?? this.fg,
      fg2: fg2 ?? this.fg2,
      fg3: fg3 ?? this.fg3,
      fg4: fg4 ?? this.fg4,
      warn: warn ?? this.warn,
      warnBg: warnBg ?? this.warnBg,
      danger: danger ?? this.danger,
      dangerBg: dangerBg ?? this.dangerBg,
      info: info ?? this.info,
      accent: accent ?? this.accent,
    );
  }

  @override
  RmTheme lerp(ThemeExtension<RmTheme>? other, double t) {
    if (other is! RmTheme) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t)!;
    return RmTheme(
      bg: l(bg, other.bg),
      panel: l(panel, other.panel),
      raised: l(raised, other.raised),
      hover: l(hover, other.hover),
      border: l(border, other.border),
      border2: l(border2, other.border2),
      borderStrong: l(borderStrong, other.borderStrong),
      fg: l(fg, other.fg),
      fg2: l(fg2, other.fg2),
      fg3: l(fg3, other.fg3),
      fg4: l(fg4, other.fg4),
      warn: l(warn, other.warn),
      warnBg: l(warnBg, other.warnBg),
      danger: l(danger, other.danger),
      dangerBg: l(dangerBg, other.dangerBg),
      info: l(info, other.info),
      accent: AccentColors(
        base: l(accent.base, other.accent.base),
        bg: l(accent.bg, other.accent.bg),
        ring: l(accent.ring, other.accent.ring),
        onAccent: l(accent.onAccent, other.accent.onAccent),
      ),
    );
  }
}

/// 便利访问：`context.rm`。
extension RmThemeAccess on BuildContext {
  RmTheme get rm => Theme.of(this).extension<RmTheme>()!;
}

ThemeData buildAppTheme({
  required Brightness brightness,
  required AppAccent accent,
}) {
  final isLight = brightness == Brightness.light;
  final acc = accentColors(accent, brightness);

  final rm = isLight
      ? RmTheme(
          bg: RmTokens.bgLight,
          panel: RmTokens.panelLight,
          raised: RmTokens.raisedLight,
          hover: RmTokens.hoverLight,
          border: RmTokens.borderLight,
          border2: RmTokens.border2Light,
          borderStrong: RmTokens.borderStrongLight,
          fg: RmTokens.fgLight,
          fg2: RmTokens.fg2Light,
          fg3: RmTokens.fg3Light,
          fg4: RmTokens.fg4Light,
          warn: RmTokens.warnLight,
          warnBg: RmTokens.warnBgLight,
          danger: RmTokens.dangerLight,
          dangerBg: RmTokens.dangerBgLight,
          info: RmTokens.infoLight,
          accent: acc,
        )
      : RmTheme(
          bg: RmTokens.bgDark,
          panel: RmTokens.panelDark,
          raised: RmTokens.raisedDark,
          hover: RmTokens.hoverDark,
          border: RmTokens.borderDark,
          border2: RmTokens.border2Dark,
          borderStrong: RmTokens.borderStrongDark,
          fg: RmTokens.fgDark,
          fg2: RmTokens.fg2Dark,
          fg3: RmTokens.fg3Dark,
          fg4: RmTokens.fg4Dark,
          warn: RmTokens.warnDark,
          warnBg: RmTokens.warnBgDark,
          danger: RmTokens.dangerDark,
          dangerBg: RmTokens.dangerBgDark,
          info: RmTokens.infoLight, // info 暗色未单独定义，沿用 light
          accent: acc,
        );

  final base = isLight
      ? ThemeData.light(useMaterial3: true)
      : ThemeData.dark(useMaterial3: true);

  return base.copyWith(
    scaffoldBackgroundColor: rm.bg,
    canvasColor: rm.bg,
    dividerColor: rm.border,
    extensions: [rm],
    splashFactory: NoSplash.splashFactory,
    visualDensity: VisualDensity.standard,
    tooltipTheme: TooltipThemeData(
      constraints: const BoxConstraints(minHeight: 28, maxWidth: 320),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      margin: const EdgeInsets.all(12),
      verticalOffset: 10,
      preferBelow: false,
      decoration: BoxDecoration(
        color: Color.alphaBlend(rm.accent.bg, rm.panel),
        borderRadius: BorderRadius.circular(RmTokens.rSm),
        border: Border.all(color: rm.accent.ring),
        boxShadow: const [
          BoxShadow(
            color: Color(0x1714141E),
            blurRadius: 18,
            offset: Offset(0, 6),
          ),
          BoxShadow(
            color: Color(0x0A14141E),
            blurRadius: 4,
            offset: Offset(0, 1),
          ),
        ],
      ),
      textStyle: RmText.sans(
        12.5,
        weight: FontWeight.w500,
        height: 1.25,
        color: rm.fg,
      ),
      textAlign: TextAlign.center,
      waitDuration: const Duration(milliseconds: 280),
      showDuration: const Duration(milliseconds: 1800),
      exitDuration: const Duration(milliseconds: 90),
      enableFeedback: false,
    ),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: rm.accent.base,
      selectionColor: rm.accent.ring,
      selectionHandleColor: rm.accent.base,
    ),
  );
}
