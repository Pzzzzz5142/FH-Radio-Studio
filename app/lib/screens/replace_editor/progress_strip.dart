import 'package:flutter/material.dart';

import '../../domain/replacement_models.dart';
import '../../theme/app_theme.dart';
import '../../theme/text_styles.dart';
import '../../theme/tokens.dart';
import '../../widgets/rm_icon.dart';
import 'replace_state.dart';

/// 4 宫格 progress strip（TD/PD/TL/PL，按这个顺序显示）。
class ProgressStrip extends StatelessWidget {
  const ProgressStrip({super.key, required this.state});

  final ReplaceEditorState state;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    final cells = <_Cell>[
      _Cell(
        kind: GroupKind.td,
        label: 'TrackDrop · 比赛开始',
        confirmed: state.tdConfirmed,
        value: formatTimecode(state.td.t),
      ),
      _Cell(
        kind: GroupKind.pd,
        label: 'PostDrop · 冲线后',
        confirmed: state.pdConfirmed,
        value: formatTimecode(state.pd.t),
      ),
      _Cell(
        kind: GroupKind.tl,
        label: 'TrackLoop · 比赛循环',
        confirmed: state.tlConfirmed,
        value:
            '${formatTimecode(state.tl.start)} → ${formatTimecode(state.tl.end)}',
      ),
      _Cell(
        kind: GroupKind.pl,
        label: 'PostLoop · 冲线循环',
        confirmed: state.plConfirmed,
        value:
            '${formatTimecode(state.pl.start)} → ${formatTimecode(state.pl.end)}',
      ),
    ];

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: rm.panel,
        border: Border.all(color: rm.border),
        borderRadius: BorderRadius.circular(RmTokens.rLg),
      ),
      child: LayoutBuilder(
        builder: (context, c) {
          const minCellW = 180.0;
          final cols = (c.maxWidth / (minCellW + 8)).floor().clamp(1, 4);
          final cellW = (c.maxWidth - 8 * (cols - 1)) / cols;
          return Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final cell in cells)
                SizedBox(
                  width: cellW,
                  child: _ProgressCell(cell: cell),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _Cell {
  const _Cell({
    required this.kind,
    required this.label,
    required this.confirmed,
    required this.value,
  });
  final GroupKind kind;
  final String label;
  final bool confirmed;
  final String value;
}

class _ProgressCell extends StatelessWidget {
  const _ProgressCell({required this.cell});

  final _Cell cell;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    final confirmed = cell.confirmed;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: confirmed ? rm.accent.bg : rm.raised,
        border: Border.all(color: confirmed ? rm.accent.ring : rm.borderStrong),
        borderRadius: BorderRadius.circular(RmTokens.rSm),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  cell.kind.code,
                  style: RmText.mono(
                    11,
                    weight: FontWeight.w600,
                    letterSpacing: 0.05 * 11,
                    color: confirmed ? rm.accent.base : rm.fg2,
                  ),
                ),
                const SizedBox(height: 2),
                Text(cell.label, style: RmText.sans(11.5, color: rm.fg3)),
                const SizedBox(height: 2),
                Text(cell.value, style: RmText.mono(10.5, color: rm.fg3)),
              ],
            ),
          ),
          Container(
            width: 16,
            height: 16,
            decoration: BoxDecoration(
              color: confirmed ? rm.accent.base : Colors.transparent,
              border: Border.all(
                color: confirmed ? rm.accent.base : rm.borderStrong,
              ),
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: confirmed
                ? RmIcon('check', size: 10, color: rm.accent.onAccent)
                : null,
          ),
        ],
      ),
    );
  }
}
