import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/text_styles.dart';

/// key=value 列表（对齐 styles.css `.kv` definition list）。
/// 左列 132px mono 灰，右列 mono fg。
class KvList extends StatelessWidget {
  const KvList({
    super.key,
    required this.entries,
    this.keyWidth = 132,
    this.gap = 4,
    this.colGap = 16,
  });

  final List<KvEntry> entries;
  final double keyWidth;
  final double gap;
  final double colGap;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (int i = 0; i < entries.length; i++) ...[
          if (i != 0) SizedBox(height: gap),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: keyWidth,
                child: Text(
                  entries[i].label,
                  style: RmText.mono(11.5, color: rm.fg3),
                ),
              ),
              SizedBox(width: colGap),
              Expanded(
                child: DefaultTextStyle(
                  style: RmText.mono(12.5, color: rm.fg),
                  child: entries[i].value,
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

class KvEntry {
  const KvEntry(this.label, this.value);
  final String label;
  final Widget value;
}
