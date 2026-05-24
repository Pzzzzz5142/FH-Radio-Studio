import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// 字号系统（px，对应 README §Typography）。
/// 用 [RmText] 拿到一个 TextStyle，颜色用 Theme 文本默认色，可在 widget 上覆盖。
///
/// **字体决策（详见 docs/dev-handoff.md §10）**：
/// 中文 UI 优先使用系统/本机中文 UI 字体，避免 Inter/Mono fallback 造成字重和字距漂移。
/// 代码、路径、时间码继续使用 JetBrains Mono。
class RmText {
  RmText._();

  static const List<String> _uiFallbacks = [
    'Microsoft YaHei UI',
    'Microsoft YaHei',
    'PingFang SC',
    'Heiti SC',
    'Segoe UI',
    'Arial',
    'sans-serif',
  ];

  static const List<String> _monoFallbacks = [
    'Cascadia Mono',
    'Consolas',
    'Noto Sans SC',
    'Microsoft YaHei UI',
    'monospace',
  ];

  static TextStyle sans(
    double size, {
    FontWeight? weight,
    double? letterSpacing,
    double? height,
    Color? color,
  }) {
    return TextStyle(
      fontFamily: 'Noto Sans SC',
      fontFamilyFallback: _uiFallbacks,
      fontSize: size,
      fontWeight: weight ?? FontWeight.w400,
      letterSpacing: letterSpacing ?? 0,
      height: height,
      color: color,
    );
  }

  static TextStyle mono(
    double size, {
    FontWeight? weight,
    double? letterSpacing,
    double? height,
    Color? color,
  }) {
    if (!GoogleFonts.config.allowRuntimeFetching) {
      return TextStyle(
        fontFamily: 'Cascadia Mono',
        fontFamilyFallback: _monoFallbacks,
        fontSize: size,
        fontWeight: weight ?? FontWeight.w400,
        letterSpacing: letterSpacing ?? -0.01 * size,
        height: height,
        color: color,
        fontFeatures: const [
          FontFeature.tabularFigures(),
          FontFeature.slashedZero(),
        ],
      );
    }
    return GoogleFonts.jetBrainsMono(
      fontSize: size,
      fontWeight: weight ?? FontWeight.w400,
      letterSpacing: letterSpacing ?? -0.01 * size,
      height: height,
      color: color,
      fontFeatures: const [
        FontFeature.tabularFigures(),
        FontFeature.slashedZero(),
      ],
    ).copyWith(fontFamilyFallback: _monoFallbacks);
  }

  // === Named tokens (per README typography table) ===
  static TextStyle microLabel({Color? color}) => mono(
    10.5,
    weight: FontWeight.w500,
    letterSpacing: 0.12 * 10.5,
    color: color,
  );

  static TextStyle chip({Color? color}) => mono(11, color: color);

  static TextStyle monoSm({Color? color}) => mono(11.5, color: color);

  static TextStyle uiSm({Color? color, FontWeight? weight}) =>
      sans(12.5, weight: weight, color: color);

  static TextStyle body({Color? color, FontWeight? weight}) =>
      sans(13, weight: weight, color: color);

  static TextStyle rowTitle({Color? color}) =>
      sans(13.5, weight: FontWeight.w500, color: color);

  static TextStyle panelTitle({Color? color}) =>
      sans(14, weight: FontWeight.w600, color: color);

  static TextStyle emptyTitle({Color? color}) =>
      sans(16, weight: FontWeight.w600, color: color);

  static TextStyle modalH2({Color? color}) =>
      sans(20, weight: FontWeight.w600, color: color);

  static TextStyle bootLogo({Color? color}) => sans(
    22,
    weight: FontWeight.w600,
    letterSpacing: -0.01 * 22,
    color: color,
  );

  static TextStyle pageH1({Color? color}) => sans(
    24,
    weight: FontWeight.w600,
    letterSpacing: -0.01 * 24,
    color: color,
  );

  static TextStyle statValue({Color? color}) => sans(
    26,
    weight: FontWeight.w600,
    letterSpacing: -0.02 * 26,
    color: color,
  );

  static TextStyle timecode({Color? color, FontWeight? weight}) =>
      mono(13, weight: weight ?? FontWeight.w600, color: color);
}
