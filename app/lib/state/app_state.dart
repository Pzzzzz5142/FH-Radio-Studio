import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme/accents.dart';

enum NavStyle { rail, tabs }

class _PrefsKeys {
  static const accent = 'rm.accent';
  static const themeMode = 'rm.themeMode';
  static const navStyle = 'rm.navStyle';
}

/// SharedPreferences 句柄。在 main() 里 `overrideWithValue` 后再 runApp。
final sharedPreferencesProvider = Provider<SharedPreferences>((ref) {
  throw UnimplementedError(
    'sharedPreferencesProvider must be overridden in main()',
  );
});

// ============================================================
// Accent
// ============================================================
class AccentNotifier extends StateNotifier<AppAccent> {
  AccentNotifier(this._prefs)
    : super(AppAccent.fromId(_prefs.getString(_PrefsKeys.accent)));

  final SharedPreferences _prefs;

  void set(AppAccent next) {
    state = next;
    _prefs.setString(_PrefsKeys.accent, next.id);
  }
}

final accentProvider = StateNotifierProvider<AccentNotifier, AppAccent>((ref) {
  return AccentNotifier(ref.watch(sharedPreferencesProvider));
});

// ============================================================
// Theme mode
// ============================================================
class ThemeModeNotifier extends StateNotifier<ThemeMode> {
  ThemeModeNotifier(this._prefs) : super(_read(_prefs));

  final SharedPreferences _prefs;

  static ThemeMode _read(SharedPreferences p) {
    switch (p.getString(_PrefsKeys.themeMode)) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      default:
        return ThemeMode.light; // 设计稿默认 light
    }
  }

  void set(ThemeMode next) {
    state = next;
    _prefs.setString(_PrefsKeys.themeMode, next.name);
  }
}

final themeModeProvider = StateNotifierProvider<ThemeModeNotifier, ThemeMode>((
  ref,
) {
  return ThemeModeNotifier(ref.watch(sharedPreferencesProvider));
});

// ============================================================
// Nav style
// ============================================================
class NavStyleNotifier extends StateNotifier<NavStyle> {
  NavStyleNotifier(this._prefs) : super(_read(_prefs));

  final SharedPreferences _prefs;

  static NavStyle _read(SharedPreferences p) {
    return p.getString(_PrefsKeys.navStyle) == 'tabs'
        ? NavStyle.tabs
        : NavStyle.rail;
  }

  void set(NavStyle next) {
    state = next;
    _prefs.setString(_PrefsKeys.navStyle, next.name);
  }
}

final navStyleProvider = StateNotifierProvider<NavStyleNotifier, NavStyle>((
  ref,
) {
  return NavStyleNotifier(ref.watch(sharedPreferencesProvider));
});

// ============================================================
// Tweaks panel visibility (per session, not persisted)
// ============================================================
final tweaksOpenProvider = StateProvider<bool>((ref) => false);
