import 'package:flutter/material.dart';

/// Design tokens (raw constants).
///
/// 与 `design_handoff/design_handoff_fh_radio_studio/design/styles.css` 的 `:root` 一一对应。
/// 颜色用 Color(0xFFrrggbb)；OKLCH 已离线转换成 sRGB（见 docs/dev-handoff.md §10）。
class RmTokens {
  RmTokens._();

  // ============================================================
  // Surfaces — Light
  // ============================================================
  static const Color bgLight = Color(0xFFF7F7F8);
  static const Color panelLight = Color(0xFFFFFFFF);
  static const Color raisedLight = Color(0xFFF3F3F5);
  static const Color hoverLight = Color(0xFFECECEF);
  static const Color borderLight = Color(0xFFE5E5EA);
  static const Color border2Light = Color(0xFFD8D8DE);
  static const Color borderStrongLight = Color(0xFFB8B8C0);

  // ============================================================
  // Surfaces — Dark
  // ============================================================
  static const Color bgDark = Color(0xFF0A0A0B);
  static const Color panelDark = Color(0xFF111113);
  static const Color raisedDark = Color(0xFF17171A);
  static const Color hoverDark = Color(0xFF1D1D21);
  static const Color borderDark = Color(0xFF232328);
  static const Color border2Dark = Color(0xFF2C2C33);
  static const Color borderStrongDark = Color(0xFF3A3A42);

  // ============================================================
  // Text — Light
  // ============================================================
  static const Color fgLight = Color(0xFF18181B);
  static const Color fg2Light = Color(0xFF52525B);
  static const Color fg3Light = Color(0xFF71717A);
  static const Color fg4Light = Color(0xFFA1A1AA);

  // ============================================================
  // Text — Dark
  // ============================================================
  static const Color fgDark = Color(0xFFEDEDED);
  static const Color fg2Dark = Color(0xFFA1A1A6);
  static const Color fg3Dark = Color(0xFF6B6B72);
  static const Color fg4Dark = Color(0xFF4A4A52);

  // ============================================================
  // Semantic
  // ============================================================
  // oklch(0.55 0.16 75)  → #A65F00
  static const Color warnLight = Color(0xFFA65F00);
  // oklch(0.95 0.06 85)  → #FFECC1
  static const Color warnBgLight = Color(0xFFFFECC1);
  // oklch(0.55 0.20 25)  → #CC272E
  static const Color dangerLight = Color(0xFFCC272E);
  // oklch(0.96 0.05 25)  → #FFE6E1
  static const Color dangerBgLight = Color(0xFFFFE6E1);
  // oklch(0.50 0.15 230) → #006FA7
  static const Color infoLight = Color(0xFF006FA7);

  static const Color warnDark = Color(0xFFFACB39);
  static const Color warnBgDark = Color(0x1AFACB39); // 10% opacity
  static const Color dangerDark = Color(0xFFFF4C4D);
  static const Color dangerBgDark = Color(0x1AFF4C4D);

  // ============================================================
  // Traffic lights (macOS-style on title bar)
  // ============================================================
  static const Color trafficRed = Color(0xFFFF5F57);
  static const Color trafficYellow = Color(0xFFFEBC2E);
  static const Color trafficGreen = Color(0xFF28C840);

  // ============================================================
  // Time Group accent colors (do NOT replace — info encoding)
  // ============================================================
  /// TD = main accent — resolved dynamically per active accent
  // oklch(0.52 0.18 270) → #435BCF
  static const Color tgPdPurple = Color(0xFF435BCF);
  // oklch(0.55 0.15 210) → #0086A1
  static const Color tgTlBlue = Color(0xFF0086A1);
  // oklch(0.60 0.18 30)  → #D64938
  static const Color tgPlOrange = Color(0xFFD64938);

  // ============================================================
  // Waveform segment colors
  // ============================================================
  static const Color segIntroBg = Color(0xFFE1E5EB);
  static const Color segVerseBg = Color(0xFFC8EBF7);
  static const Color segVerseFg = Color(0xFF00536C);
  static const Color segChorusBg = Color(0xFFC8ECA5);
  static const Color segChorusFg = Color(0xFF153F00);
  static const Color segBridgeBg = Color(0xFFFFDCBD);
  static const Color segBridgeFg = Color(0xFF743300);
  static const Color segOutroBg = segIntroBg;

  // ============================================================
  // Radius
  // ============================================================
  static const double rXs = 4;
  static const double rSm = 6;
  static const double rMd = 8;
  static const double rLg = 12;
  static const double rXl = 16;

  // ============================================================
  // Spacing (used as ad-hoc gap/padding values — see README §Spacing)
  // ============================================================
  static const double gap4 = 4;
  static const double gap6 = 6;
  static const double gap8 = 8;
  static const double gap10 = 10;
  static const double gap12 = 12;
  static const double gap14 = 14;
  static const double gap16 = 16;
  static const double gap18 = 18;
  static const double gap24 = 24;
  static const double gap28 = 28;
  static const double gap36 = 36;

  // Page max widths
  static const double pageNarrow = 920;
  static const double pageDefault = 1240;
  static const double pageWide = 1400;

  // Shell
  static const double titleBarHeight = 44;
  static const double sidebarWidth = 220;
  static const double tabsBarHeight = 44;

  // ============================================================
  // Shadows
  // ============================================================
  static const List<BoxShadow> popover = [
    BoxShadow(
      color: Color(0x1F14141E), // rgba(20,20,30,0.12)
      blurRadius: 40,
      offset: Offset(0, 16),
    ),
    BoxShadow(
      color: Color(0x0F14141E), // rgba(20,20,30,0.06)
      blurRadius: 12,
      offset: Offset(0, 4),
    ),
  ];

  static const List<BoxShadow> modal = [
    BoxShadow(
      color: Color(0x2E14141E), // 0.18
      blurRadius: 60,
      offset: Offset(0, 30),
    ),
    BoxShadow(
      color: Color(0x1414141E), // 0.08
      blurRadius: 20,
      offset: Offset(0, 8),
    ),
  ];

  static const Color modalBackdrop = Color(0x5914141E); // 0.35
}
