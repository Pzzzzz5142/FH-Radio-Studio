import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/text_styles.dart';
import '../theme/tokens.dart';

/// 分段控制（对齐 styles.css `.pl-mode`）：raised 容器 + 内嵌 panel bg 的高亮段。
class RmSegmented<T> extends StatelessWidget {
  const RmSegmented({
    super.key,
    required this.value,
    required this.options,
    required this.onChanged,
  });

  final T value;
  final List<RmSegmentedOption<T>> options;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: rm.raised,
        borderRadius: BorderRadius.circular(RmTokens.rSm),
        border: Border.all(color: rm.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [for (final o in options) _seg(context, o, o.value == value)],
      ),
    );
  }

  Widget _seg(BuildContext context, RmSegmentedOption<T> o, bool active) {
    final rm = context.rm;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => onChanged(o.value),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          decoration: BoxDecoration(
            color: active ? rm.hover : Colors.transparent,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            o.label,
            style: RmText.sans(
              12,
              color: active ? rm.fg : rm.fg3,
              weight: active ? FontWeight.w500 : FontWeight.w400,
            ),
          ),
        ),
      ),
    );
  }
}

class RmSegmentedOption<T> {
  const RmSegmentedOption({required this.value, required this.label});
  final T value;
  final String label;
}
