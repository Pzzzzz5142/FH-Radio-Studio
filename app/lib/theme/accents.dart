import 'package:flutter/material.dart';

/// 4 个用户可选的主题 accent。
///
/// 每个 accent 派生：
/// - [base]      实色（用于主按钮 / focus ring / 强调文本）
/// - [bg]        12% opacity（chip / badge 背景 / 选中态背景）
/// - [ring]      35% opacity（描边 / focus ring）
/// - [onAccent]  accent 上的文字色
enum AppAccent {
  lime('lime', '默认 · 强调电台、确认状态'),
  cyan('cyan', '冷调 · 信息、检索'),
  orange('orange', '暖调 · 警示外的醒目'),
  magenta('magenta', '高对比 · 标识区分');

  const AppAccent(this.id, this.description);
  final String id;
  final String description;

  static AppAccent fromId(String? id) {
    return AppAccent.values.firstWhere(
      (a) => a.id == id,
      orElse: () => AppAccent.lime,
    );
  }
}

/// 取一个 accent 在某 brightness 下的派生色集。
AccentColors accentColors(AppAccent accent, Brightness brightness) {
  return brightness == Brightness.light
      ? _lightTable[accent]!
      : _darkTable[accent]!;
}

class AccentColors {
  const AccentColors({
    required this.base,
    required this.bg,
    required this.ring,
    required this.onAccent,
  });

  /// 实色 base
  final Color base;

  /// 12% opacity 的 base（chip 背景）
  final Color bg;

  /// 35% opacity 的 base（描边 / focus ring）
  final Color ring;

  /// accent 上的对比文字色
  final Color onAccent;
}

// OKLCH → sRGB（见 tokens.dart 注释与 docs/dev-handoff.md §10）
// Light:
//   lime    oklch(0.62 0.18 145) → #23A136
//   cyan    oklch(0.58 0.13 210) → #008DA4
//   orange  oklch(0.62 0.18 50)  → #D75C00
//   magenta oklch(0.55 0.22 340) → #BD2099
// Dark:
//   lime    oklch(0.86 0.18 130) → #A9E85E
//   cyan    oklch(0.86 0.13 210) → #4DE8FF
//   orange  oklch(0.86 0.18 50)  → #FFA958
//   magenta oklch(0.86 0.22 340) → #FF8FFE

final Map<AppAccent, AccentColors> _lightTable = {
  AppAccent.lime: _build(const Color(0xFF23A136), Brightness.light),
  AppAccent.cyan: _build(const Color(0xFF008DA4), Brightness.light),
  AppAccent.orange: _build(const Color(0xFFD75C00), Brightness.light),
  AppAccent.magenta: _build(const Color(0xFFBD2099), Brightness.light),
};

final Map<AppAccent, AccentColors> _darkTable = {
  AppAccent.lime: _build(const Color(0xFFA9E85E), Brightness.dark),
  AppAccent.cyan: _build(const Color(0xFF4DE8FF), Brightness.dark),
  AppAccent.orange: _build(const Color(0xFFFFA958), Brightness.dark),
  AppAccent.magenta: _build(const Color(0xFFFF8FFE), Brightness.dark),
};

AccentColors _build(Color base, Brightness brightness) {
  return AccentColors(
    base: base,
    bg: base.withAlpha((0.12 * 255).round()),
    ring: base.withAlpha((0.35 * 255).round()),
    onAccent: brightness == Brightness.light
        ? const Color(0xFFFFFFFF)
        : const Color(0xFF0A0A0B),
  );
}
