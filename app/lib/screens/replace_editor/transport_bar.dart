import 'package:flutter/material.dart';

import '../../domain/replacement_models.dart';
import '../../theme/app_theme.dart';
import '../../theme/text_styles.dart';
import '../../theme/tokens.dart';
import '../../widgets/rm_button.dart';
import '../../widgets/rm_icon.dart';
import 'replace_state.dart';

class TransportBar extends StatelessWidget {
  const TransportBar({
    super.key,
    required this.state,
    required this.aiPending,
    required this.onTogglePlay,
    required this.onRewind,
    required this.onSkipFwd,
    this.floating = false,
    this.compact = false,
    this.trailing,
  });

  final ReplaceEditorState state;
  final bool aiPending;
  final VoidCallback onTogglePlay;
  final VoidCallback onRewind;
  final VoidCallback onSkipFwd;
  final bool floating;

  /// 精简模式：人工选点面板里只保留传输键、时间码与 BPM，去掉段落标签和快捷键提示。
  final bool compact;

  /// 行尾追加的自定义控件（人工选点里放 A/B 端点切换）。
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    final ai = state.ai;
    final currentSeg = segmentAt(ai.segments, state.playhead);
    final durationText = ai.durationSec > 0
        ? formatTimecode(ai.durationSec)
        : '--:--';

    return Container(
      padding: EdgeInsets.all(compact ? 9 : 12),
      decoration: BoxDecoration(
        color: rm.panel,
        border: Border.all(color: floating ? rm.borderStrong : rm.border),
        borderRadius: BorderRadius.circular(RmTokens.rLg),
        boxShadow: floating ? RmTokens.popover : null,
      ),
      child: Row(
        children: [
          if (!compact) ...[
            RmButton.icon(
              onPressed: onRewind,
              icon: const RmIcon('skip-back', size: 12),
            ),
            const SizedBox(width: 8),
          ],
          _playButton(context),
          if (!compact) ...[
            const SizedBox(width: 8),
            RmButton.icon(
              onPressed: onSkipFwd,
              icon: const RmIcon('skip-fwd', size: 12),
            ),
          ],
          const SizedBox(width: 12),
          RichText(
            text: TextSpan(
              style: RmText.mono(13, color: rm.fg),
              children: [
                TextSpan(text: formatTimecode(state.playhead)),
                TextSpan(
                  text: ' / $durationText',
                  style: RmText.mono(13, color: rm.fg3),
                ),
              ],
            ),
          ),
          const Spacer(),
          if (!compact) ...[
            Text(
              aiPending ? '段：分析中' : '段：${currentSeg.label}',
              style: RmText.mono(11, color: rm.fg3),
            ),
            const SizedBox(width: 14),
          ],
          Text(
            aiPending ? 'BPM --' : 'BPM ${ai.bpm.toStringAsFixed(1)}',
            style: RmText.mono(11, color: rm.fg3),
          ),
          if (!compact) ...[const SizedBox(width: 14), _kbd(context, 'Space')],
          if (trailing != null) ...[const SizedBox(width: 12), trailing!],
        ],
      ),
    );
  }

  Widget _playButton(BuildContext context) {
    final rm = context.rm;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        key: ValueKey(floating ? 'editor-play-floating' : 'editor-play-inline'),
        onTap: onTogglePlay,
        child: Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: rm.accent.base,
            shape: BoxShape.circle,
          ),
          alignment: Alignment.center,
          child: RmIcon(
            state.playing ? 'pause' : 'play',
            size: 16,
            color: rm.accent.onAccent,
          ),
        ),
      ),
    );
  }

  Widget _kbd(BuildContext context, String label) {
    final rm = context.rm;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: rm.raised,
        border: Border.all(color: rm.border),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(label, style: RmText.mono(10.5, color: rm.fg2)),
    );
  }
}
