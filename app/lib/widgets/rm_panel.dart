import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/text_styles.dart';
import '../theme/tokens.dart';

class RmPanel extends StatelessWidget {
  const RmPanel({
    super.key,
    this.title,
    this.titleTrailing,
    this.subtitle,
    this.headerTrailing,
    required this.child,
    this.noPad = false,
  });

  final String? title;
  final Widget? titleTrailing;
  final String? subtitle;
  final Widget? headerTrailing;
  final Widget child;
  final bool noPad;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    final hasHead =
        title != null ||
        titleTrailing != null ||
        subtitle != null ||
        headerTrailing != null;
    final radius = BorderRadius.circular(RmTokens.rLg);

    return ClipRRect(
      borderRadius: radius,
      clipBehavior: Clip.antiAlias,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: rm.panel,
          borderRadius: radius,
          border: Border.all(color: rm.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (hasHead)
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 14,
                ),
                decoration: BoxDecoration(
                  border: Border(bottom: BorderSide(color: rm.border)),
                ),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final titleGroup = _PanelTitleGroup(
                      title: title,
                      titleTrailing: titleTrailing,
                      subtitle: subtitle,
                    );
                    final trailing = headerTrailing == null
                        ? null
                        : Align(
                            alignment: Alignment.centerRight,
                            child: headerTrailing!,
                          );

                    if (trailing == null) {
                      return titleGroup;
                    }

                    if (constraints.maxWidth < 820) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          titleGroup,
                          const SizedBox(height: 10),
                          trailing,
                        ],
                      );
                    }

                    return Row(
                      children: [
                        Expanded(child: titleGroup),
                        const SizedBox(width: 16),
                        trailing,
                      ],
                    );
                  },
                ),
              ),
            Padding(
              padding: noPad ? EdgeInsets.zero : const EdgeInsets.all(18),
              child: child,
            ),
          ],
        ),
      ),
    );
  }
}

class _PanelTitleGroup extends StatelessWidget {
  const _PanelTitleGroup({
    required this.title,
    required this.titleTrailing,
    required this.subtitle,
  });

  final String? title;
  final Widget? titleTrailing;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (title != null)
          Text(
            title!,
            style: RmText.body(weight: FontWeight.w600, color: rm.fg),
          ),
        if (titleTrailing != null) ...[
          const SizedBox(width: 12),
          titleTrailing!,
        ],
        if (subtitle != null) ...[
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              subtitle!,
              style: RmText.sans(12, color: rm.fg3),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ],
    );
  }
}
