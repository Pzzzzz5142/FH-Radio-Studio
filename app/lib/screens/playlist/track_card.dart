import 'package:flutter/material.dart';

import '../../domain/radio_library.dart';
import '../../theme/app_theme.dart';
import '../../theme/text_styles.dart';
import '../../theme/tokens.dart';
import '../../widgets/rm_icon.dart';

/// playlist 列里一行 track。
/// - `locked = true` → 原版曲目，半透明且不可拖
/// - `locked = false` → 自建曲目，accent 高亮且可拖
///
/// 拖拽部分由父 widget（`Draggable`）外包；本 widget 只关心视觉。
class TrackCard extends StatefulWidget {
  const TrackCard({
    super.key,
    required this.title,
    required this.artist,
    required this.durationSec,
    required this.locked,
    this.custom = false,
    this.notConfiguredProgress, // e.g. "2/4" — null 表示已配置
    this.siren = false,
    this.assignmentLabels = const [],
    this.dragging = false,
  });

  final String title;
  final String artist;
  final double durationSec;
  final bool locked;
  final bool custom;
  final String? notConfiguredProgress;
  final bool siren;
  final List<String> assignmentLabels;
  final bool dragging;

  /// 工厂：从 PoolTrack 创建（自建曲目）。
  factory TrackCard.fromPoolTrack(
    PoolTrack t, {
    bool dragging = false,
    bool locked = false,
    List<String> assignmentLabels = const [],
  }) {
    return TrackCard(
      title: t.title,
      artist: t.artist,
      durationSec: t.durationSec,
      locked: locked,
      custom: true,
      notConfiguredProgress: t.configured ? null : '${t.confirmed}/4',
      siren: t.isSiren,
      assignmentLabels: assignmentLabels,
      dragging: dragging,
    );
  }

  @override
  State<TrackCard> createState() => _TrackCardState();
}

class _TrackCardState extends State<TrackCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    final locked = widget.locked;
    final modded = widget.custom || !locked;
    final badges = _badges(rm);

    final Color bg;
    final Color border;
    if (widget.dragging) {
      bg = rm.accent.bg;
      border = rm.accent.base;
    } else if (modded) {
      bg = rm.accent.bg;
      border = rm.accent.ring;
    } else if (_hover) {
      bg = rm.raised;
      border = rm.border;
    } else {
      bg = Colors.transparent;
      border = Colors.transparent;
    }

    return MouseRegion(
      cursor: locked ? SystemMouseCursors.basic : SystemMouseCursors.grab,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Opacity(
        opacity: locked ? 0.8 : 1,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
          decoration: BoxDecoration(
            color: bg,
            border: Border.all(color: border),
            borderRadius: BorderRadius.circular(RmTokens.rSm),
          ),
          child: Row(
            children: [
              RmIcon(
                locked ? 'lock' : 'drag',
                size: locked ? 10 : 12,
                color: rm.fg4,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            widget.title,
                            style: RmText.sans(
                              12.5,
                              weight: FontWeight.w500,
                              color: modded
                                  ? rm.accent.base
                                  : (locked ? rm.fg2 : rm.fg),
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        for (final badge in badges) ...[
                          const SizedBox(width: 5),
                          badge,
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      widget.artist,
                      style: RmText.sans(11, color: locked ? rm.fg4 : rm.fg3),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(
                _short(widget.durationSec),
                style: RmText.mono(10.5, color: rm.fg3),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _short(double t) {
    final m = t ~/ 60;
    final s = (t % 60).floor();
    return '$m:${s.toString().padLeft(2, "0")}';
  }

  List<Widget> _badges(RmTheme rm) {
    return [
      if (widget.siren)
        _TrackBadge(
          label: 'MSR',
          text: rm.accent.base,
          border: rm.accent.ring,
          bg: Color.alphaBlend(rm.accent.base.withAlpha(18), rm.raised),
          dot: rm.accent.base,
        ),
      if (widget.notConfiguredProgress != null)
        _TrackBadge(
          label: widget.notConfiguredProgress!,
          text: rm.warn,
          border: rm.warn.withAlpha(102),
          bg: rm.warnBg,
          dot: rm.warn,
        ),
      if (widget.assignmentLabels.isNotEmpty)
        Tooltip(
          message: widget.assignmentLabels.join('\n'),
          waitDuration: const Duration(milliseconds: 350),
          child: _TrackBadge(
            label: widget.assignmentLabels.length == 1
                ? widget.assignmentLabels.first
                : '${widget.assignmentLabels.length} 个列表',
            text: rm.fg2,
            border: rm.border,
            bg: rm.raised,
            dot: rm.fg3,
          ),
        ),
    ];
  }
}

class _TrackBadge extends StatelessWidget {
  const _TrackBadge({
    required this.label,
    required this.text,
    required this.border,
    required this.bg,
    required this.dot,
  });

  final String label;
  final Color text;
  final Color border;
  final Color bg;
  final Color dot;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 5,
            height: 5,
            decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
          ),
          const SizedBox(width: 5),
          Text(label, style: RmText.mono(10, color: text)),
        ],
      ),
    );
  }
}
