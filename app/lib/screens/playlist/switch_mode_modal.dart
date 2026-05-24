import 'package:flutter/material.dart';

import '../../domain/radio_library.dart';
import '../../theme/app_theme.dart';
import '../../theme/text_styles.dart';
import '../../theme/tokens.dart';
import '../../widgets/rm_banner.dart';
import '../../widgets/rm_button.dart';
import '../../widgets/rm_chip.dart';

/// 拖入 builtin 电台时弹出的确认 modal：
/// "把 X 切换为 custom？" — 列出会消失的原版曲目 + 将要分配的曲目。
class SwitchModeModal extends StatelessWidget {
  const SwitchModeModal({
    super.key,
    required this.radio,
    required this.track,
    this.originalTracks,
    required this.onConfirm,
  });

  final RadioStation radio;
  final PoolTrack track;
  final List<TrackRef>? originalTracks;
  final VoidCallback onConfirm;

  static Future<void> show(
    BuildContext context, {
    required RadioStation radio,
    required PoolTrack track,
    List<TrackRef>? originalTracks,
    required VoidCallback onConfirm,
  }) {
    return showDialog<void>(
      context: context,
      barrierColor: RmTokens.modalBackdrop,
      builder: (_) => SwitchModeModal(
        radio: radio,
        track: track,
        originalTracks: originalTracks,
        onConfirm: onConfirm,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    final original =
        originalTracks ?? kTracks[radio.code] ?? const <TrackRef>[];

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(40),
      child: Container(
        width: 540,
        constraints: const BoxConstraints(maxHeight: 720),
        decoration: BoxDecoration(
          color: rm.panel,
          border: Border.all(color: rm.borderStrong),
          borderRadius: BorderRadius.circular(RmTokens.rXl),
          boxShadow: RmTokens.modal,
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 22, 24, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '即将切换电台模式',
                    style: RmText.mono(
                      11,
                      color: rm.warn,
                      letterSpacing: 0.12 * 11,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '把 ${radio.name} 切换为 custom？',
                    style: RmText.modalH2(color: rm.fg),
                  ),
                  const SizedBox(height: 6),
                  RichText(
                    text: TextSpan(
                      style: RmText.body(color: rm.fg3),
                      children: [
                        TextSpan(
                          text:
                              '该电台目前是 builtin，包含 ${original.length} 首游戏原版歌曲。切换后这些原版歌曲在游戏内将',
                        ),
                        TextSpan(
                          text: '全部消失',
                          style: RmText.body(
                            weight: FontWeight.w700,
                            color: rm.danger,
                          ),
                        ),
                        const TextSpan(text: '（不能只换一首）。'),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 18, 24, 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _h4(context, '会消失的原版曲目'),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final t in original)
                          RmChip(
                            label: t.title,
                            variant: RmChipVariant.danger,
                            showDot: true,
                          ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    _h4(context, '将分配的曲目'),
                    const SizedBox(height: 8),
                    _trackChip(context),
                    const SizedBox(height: 14),
                    const RmBanner(
                      kind: RmBannerKind.info,
                      title: '可逆操作：',
                      body: '「游戏原版」备份还在，可随时把这个电台切回 builtin。',
                    ),
                  ],
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.fromLTRB(24, 14, 24, 22),
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: rm.border)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  RmButton(
                    onPressed: () => Navigator.of(context).pop(),
                    label: '取消',
                  ),
                  const SizedBox(width: 10),
                  RmButton(
                    onPressed: () {
                      Navigator.of(context).pop();
                      onConfirm();
                    },
                    variant: RmButtonVariant.primary,
                    label: '切换并分配',
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _h4(BuildContext context, String label) {
    final rm = context.rm;
    return Text(
      label.toUpperCase(),
      style: RmText.mono(11, color: rm.fg3, letterSpacing: 0.1 * 11),
    );
  }

  Widget _trackChip(BuildContext context) {
    final rm = context.rm;
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 12, 8),
      decoration: BoxDecoration(
        color: rm.raised,
        border: Border.all(color: rm.border),
        borderRadius: BorderRadius.circular(RmTokens.rSm),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            track.title,
            style: RmText.sans(12.5, weight: FontWeight.w500, color: rm.fg),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 2),
          Text(
            '${track.artist} · 进入 slot 1',
            style: RmText.mono(10.5, color: rm.fg3),
          ),
        ],
      ),
    );
  }
}
