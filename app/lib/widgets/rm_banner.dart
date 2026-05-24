import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/text_styles.dart';
import '../theme/tokens.dart';
import 'rm_icon.dart';

enum RmBannerKind { info, warn, danger }

/// 横向 banner — 对齐 styles.css `.banner` (info/warn/danger)。
class RmBanner extends StatelessWidget {
  const RmBanner({
    super.key,
    required this.kind,
    required this.title,
    required this.body,
  });

  final RmBannerKind kind;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    final (Color bg, Color border, Color fg, String icon) = switch (kind) {
      RmBannerKind.info => (
        rm.info.withAlpha(20),
        rm.info.withAlpha(77),
        rm.info,
        'info',
      ),
      RmBannerKind.warn => (rm.warnBg, rm.warn.withAlpha(77), rm.warn, 'warn'),
      RmBannerKind.danger => (
        rm.dangerBg,
        rm.danger.withAlpha(77),
        rm.danger,
        'danger',
      ),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: bg,
        border: Border.all(color: border),
        borderRadius: BorderRadius.circular(RmTokens.rMd),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: RmIcon(icon, size: 14, color: fg),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: RichText(
              text: TextSpan(
                style: RmText.body(color: fg),
                children: [
                  TextSpan(
                    text: title,
                    style: RmText.body(weight: FontWeight.w600, color: fg),
                  ),
                  TextSpan(text: ' $body'),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
