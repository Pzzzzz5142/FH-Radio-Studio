import 'package:flutter/material.dart';

import '../../domain/replacement_models.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';

/// 4 个时间组的 accent 三件套（base / bg / ring）。
/// TD 用主 accent；其余三个用 RmTokens 固定值。
class GroupAccent {
  const GroupAccent({required this.base, required this.bg, required this.ring});
  final Color base;
  final Color bg;
  final Color ring;
}

GroupAccent groupAccent(RmTheme rm, GroupKind kind) {
  switch (kind) {
    case GroupKind.td:
      return GroupAccent(
        base: rm.accent.base,
        bg: rm.accent.bg,
        ring: rm.accent.ring,
      );
    case GroupKind.pd:
      return GroupAccent(
        base: RmTokens.tgPdPurple,
        bg: RmTokens.tgPdPurple.withAlpha(26), // 10%
        ring: RmTokens.tgPdPurple.withAlpha(77), // 30%
      );
    case GroupKind.tl:
      return GroupAccent(
        base: RmTokens.tgTlBlue,
        bg: RmTokens.tgTlBlue.withAlpha(26),
        ring: RmTokens.tgTlBlue.withAlpha(77),
      );
    case GroupKind.pl:
      return GroupAccent(
        base: RmTokens.tgPlOrange,
        bg: RmTokens.tgPlOrange.withAlpha(26),
        ring: RmTokens.tgPlOrange.withAlpha(77),
      );
  }
}
