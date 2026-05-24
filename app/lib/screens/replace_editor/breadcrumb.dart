import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../state/router.dart';
import '../../theme/app_theme.dart';
import '../../theme/text_styles.dart';
import '../../widgets/rm_button.dart';
import '../../widgets/rm_chip.dart';
import '../../widgets/rm_icon.dart';

class EditorBreadcrumb extends StatelessWidget {
  const EditorBreadcrumb({
    super.key,
    required this.trackTitle,
    required this.assignedTo,
    required this.slot,
  });

  final String trackTitle;
  final String? assignedTo;
  final int? slot;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 16),
      child: Row(
        children: [
          RmButton(
            onPressed: () => context.go(RmRoutes.pool),
            size: RmButtonSize.sm,
            variant: RmButtonVariant.ghost,
            leading: Transform.rotate(
              angle: 3.14159,
              child: const RmIcon('arrow-right', size: 12),
            ),
            label: '自建歌曲',
          ),
          const SizedBox(width: 8),
          Text('/', style: RmText.body(color: rm.fg4)),
          const SizedBox(width: 8),
          Text(
            trackTitle,
            style: RmText.body(weight: FontWeight.w500, color: rm.fg),
          ),
          const Spacer(),
          RmChip(
            label: assignedTo == null ? '未分配' : '分配至 $assignedTo · slot $slot',
            variant: RmChipVariant.muted,
            showDot: true,
          ),
        ],
      ),
    );
  }
}
