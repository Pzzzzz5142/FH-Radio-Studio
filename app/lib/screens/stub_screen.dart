import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/text_styles.dart';
import '../theme/tokens.dart';
import '../widgets/rm_icon.dart';

/// 占位屏 — 各 Phase 未实现的屏幕用它。
class StubScreen extends StatelessWidget {
  const StubScreen({
    super.key,
    required this.title,
    required this.sub,
    required this.screenshot,
  });

  final String title;
  final String sub;
  final String screenshot;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Padding(
          padding: const EdgeInsets.all(40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: rm.accent.bg,
                  border: Border.all(color: rm.accent.ring),
                  borderRadius: BorderRadius.circular(RmTokens.rMd),
                ),
                alignment: Alignment.center,
                child: RmIcon('warn', size: 18, color: rm.accent.base),
              ),
              const SizedBox(height: 14),
              Text(title, style: RmText.pageH1(color: rm.fg)),
              const SizedBox(height: 8),
              Text(sub, style: RmText.body(color: rm.fg3)),
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: rm.raised,
                  border: Border.all(color: rm.border),
                  borderRadius: BorderRadius.circular(RmTokens.rSm),
                ),
                child: Text(
                  '设计参考：design_handoff/design_handoff_fh_radio_studio/$screenshot',
                  style: RmText.mono(11, color: rm.fg2),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
