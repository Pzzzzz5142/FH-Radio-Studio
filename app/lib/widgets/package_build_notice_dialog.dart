import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../theme/app_theme.dart';
import '../theme/text_styles.dart';
import '../theme/tokens.dart';
import 'rm_button.dart';
import 'rm_icon.dart';

enum PackageBuildNoticeAction { close, openPlaylist }

enum MissingPlaylistSourcesAction { cleanup, keep }

Future<void> showPackageBuildSuccessDialog(
  BuildContext context, {
  required String detail,
  required String trackPreview,
  String title = '准备包已完成',
  String? packageDir,
}) {
  return showDialog<void>(
    context: context,
    barrierColor: RmTokens.modalBackdrop,
    builder: (context) => PackageBuildSuccessDialog(
      title: title,
      detail: detail,
      trackPreview: trackPreview,
      packageDir: packageDir,
    ),
  );
}

Future<PackageBuildNoticeAction?> showPackageBuildNoticeDialog(
  BuildContext context, {
  required String message,
  required bool languageChanged,
  String? title,
  bool showPlaylistAction = true,
}) {
  return showDialog<PackageBuildNoticeAction>(
    context: context,
    barrierColor: RmTokens.modalBackdrop,
    builder: (context) => PackageBuildNoticeDialog(
      message: message,
      languageChanged: languageChanged,
      title: title,
      showPlaylistAction: showPlaylistAction,
    ),
  );
}

Future<MissingPlaylistSourcesAction?> showMissingPlaylistSourcesDialog(
  BuildContext context, {
  required List<String> sources,
}) {
  return showDialog<MissingPlaylistSourcesAction>(
    context: context,
    barrierColor: RmTokens.modalBackdrop,
    builder: (context) => MissingPlaylistSourcesDialog(sources: sources),
  );
}

class PackageBuildSuccessDialog extends StatelessWidget {
  const PackageBuildSuccessDialog({
    super.key,
    required this.title,
    required this.detail,
    required this.trackPreview,
    this.packageDir,
  });

  final String title;
  final String detail;
  final String trackPreview;
  final String? packageDir;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    final cleanDetail = detail.trim().isEmpty ? '准备包已生成。' : detail.trim();
    final cleanPreview = trackPreview.trim().isEmpty
        ? '未读取到曲目信息'
        : trackPreview.trim();
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 48, vertical: 36),
      child: Container(
        width: 600,
        decoration: BoxDecoration(
          color: rm.panel,
          border: Border.all(color: rm.border),
          borderRadius: BorderRadius.circular(RmTokens.rLg),
          boxShadow: RmTokens.modal,
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 18, 22, 14),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 30,
                    height: 30,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: rm.accent.bg,
                      border: Border.all(color: rm.accent.ring),
                      borderRadius: BorderRadius.circular(RmTokens.rMd),
                    ),
                    child: RmIcon('check', size: 16, color: rm.accent.base),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title, style: RmText.modalH2(color: rm.fg)),
                        const SizedBox(height: 4),
                        Text(cleanDetail, style: RmText.body(color: rm.fg2)),
                      ],
                    ),
                  ),
                  RmButton.icon(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const RmIcon('x', size: 13),
                    variant: RmButtonVariant.ghost,
                    tooltip: '关闭',
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: rm.border),
            Padding(
              padding: const EdgeInsets.all(22),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _NoticeRow(
                    icon: 'music',
                    title: '准备内容',
                    detail: cleanPreview,
                  ),
                  if (packageDir != null && packageDir!.trim().isNotEmpty) ...[
                    const SizedBox(height: 10),
                    _NoticeRow(
                      icon: 'folder',
                      title: '包目录',
                      detail: packageDir!.trim(),
                    ),
                  ],
                ],
              ),
            ),
            Divider(height: 1, color: rm.border),
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 14, 22, 18),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '准备包只写入项目目录，不会直接覆盖游戏文件。',
                      style: RmText.sans(12, color: rm.fg3),
                    ),
                  ),
                  RmButton(
                    onPressed: () => Navigator.of(context).pop(),
                    variant: RmButtonVariant.primary,
                    label: '知道了',
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class MissingPlaylistSourcesDialog extends StatelessWidget {
  const MissingPlaylistSourcesDialog({super.key, required this.sources});

  final List<String> sources;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    final uniqueSources = _uniqueSources(sources);
    final count = uniqueSources.length;
    final title = count <= 1 ? '播放列表里有已删除的歌曲' : '播放列表里有 $count 首已删除的歌曲';
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 48, vertical: 36),
      child: Container(
        width: 600,
        decoration: BoxDecoration(
          color: rm.panel,
          border: Border.all(color: rm.border),
          borderRadius: BorderRadius.circular(RmTokens.rLg),
          boxShadow: RmTokens.modal,
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 18, 22, 14),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 30,
                    height: 30,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: rm.warnBg,
                      border: Border.all(color: rm.warn.withAlpha(77)),
                      borderRadius: BorderRadius.circular(RmTokens.rMd),
                    ),
                    child: RmIcon('warn', size: 16, color: rm.warn),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title, style: RmText.modalH2(color: rm.fg)),
                        const SizedBox(height: 4),
                        Text(
                          '准备包没有继续生成，因为播放列表草稿引用的源音频已经不在项目里。你可以现在删除所有失效引用，也可以保持草稿不变。',
                          style: RmText.body(color: rm.fg2),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: rm.border),
            Padding(
              padding: const EdgeInsets.all(22),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final source in uniqueSources.take(4)) ...[
                    _NoticeRow(
                      icon: 'music',
                      title: p.basename(source).isEmpty
                          ? '失效歌曲'
                          : p.basename(source),
                      detail: source,
                    ),
                    if (source != uniqueSources.take(4).last)
                      const SizedBox(height: 10),
                  ],
                  if (uniqueSources.length > 4) ...[
                    const SizedBox(height: 10),
                    _NoticeRow(
                      icon: 'info',
                      title: '还有 ${uniqueSources.length - 4} 首',
                      detail: '删除时会一次性清理所有失效歌曲引用。',
                    ),
                  ],
                ],
              ),
            ),
            Divider(height: 1, color: rm.border),
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 14, 22, 18),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '删除只会清理项目引用、时间点和缓存，不会修改游戏文件。',
                      style: RmText.sans(12, color: rm.fg3),
                    ),
                  ),
                  RmButton(
                    onPressed: () => Navigator.of(
                      context,
                    ).pop(MissingPlaylistSourcesAction.keep),
                    label: '保持不动',
                  ),
                  const SizedBox(width: 8),
                  RmButton(
                    onPressed: () => Navigator.of(
                      context,
                    ).pop(MissingPlaylistSourcesAction.cleanup),
                    variant: RmButtonVariant.dangerPrimary,
                    leading: const RmIcon('trash', size: 12),
                    label: '删除所有失效歌曲',
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class PackageBuildNoticeDialog extends StatelessWidget {
  const PackageBuildNoticeDialog({
    super.key,
    required this.message,
    required this.languageChanged,
    this.title,
    this.showPlaylistAction = true,
  });

  final String message;
  final bool languageChanged;
  final String? title;
  final bool showPlaylistAction;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    final body = message.trim().isEmpty ? '准备包没有生成。' : message.trim();
    final heading = title?.trim().isNotEmpty == true
        ? title!.trim()
        : _isNoNewFileTestPackageMessage(body)
        ? '没有生成测试准备包'
        : '没有生成准备包';
    final notices = _buildNoticeRows(body, languageChanged);
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 48, vertical: 36),
      child: Container(
        width: 600,
        decoration: BoxDecoration(
          color: rm.panel,
          border: Border.all(color: rm.border),
          borderRadius: BorderRadius.circular(RmTokens.rLg),
          boxShadow: RmTokens.modal,
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 18, 22, 14),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 30,
                    height: 30,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: rm.warnBg,
                      border: Border.all(color: rm.warn.withAlpha(77)),
                      borderRadius: BorderRadius.circular(RmTokens.rMd),
                    ),
                    child: RmIcon('warn', size: 16, color: rm.warn),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(heading, style: RmText.modalH2(color: rm.fg)),
                        const SizedBox(height: 4),
                        Text(body, style: RmText.body(color: rm.fg2)),
                      ],
                    ),
                  ),
                  RmButton.icon(
                    onPressed: () => Navigator.of(
                      context,
                    ).pop(PackageBuildNoticeAction.close),
                    icon: const RmIcon('x', size: 13),
                    variant: RmButtonVariant.ghost,
                    tooltip: '关闭',
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: rm.border),
            Padding(
              padding: const EdgeInsets.all(22),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var index = 0; index < notices.length; index += 1) ...[
                    notices[index],
                    if (index != notices.length - 1) const SizedBox(height: 10),
                  ],
                ],
              ),
            ),
            Divider(height: 1, color: rm.border),
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 14, 22, 18),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '准备包只写入项目目录，不会直接覆盖游戏文件。',
                      style: RmText.sans(12, color: rm.fg3),
                    ),
                  ),
                  RmButton(
                    onPressed: () => Navigator.of(
                      context,
                    ).pop(PackageBuildNoticeAction.close),
                    label: '知道了',
                  ),
                  if (showPlaylistAction) ...[
                    const SizedBox(width: 8),
                    RmButton(
                      onPressed: () => Navigator.of(
                        context,
                      ).pop(PackageBuildNoticeAction.openPlaylist),
                      variant: RmButtonVariant.primary,
                      leading: const RmIcon('list', size: 12),
                      label: '打开播放列表',
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

List<_NoticeRow> _buildNoticeRows(String message, bool languageChanged) {
  final lower = message.toLowerCase();
  final rows = <_NoticeRow>[];
  if (_isNoNewFileTestPackageMessage(message)) {
    rows.add(
      const _NoticeRow(
        icon: 'info',
        title: '没有需要单独测试的新文件',
        detail: '这个入口只在游戏文件不同于原始备份或准备包时使用；当前状态不需要生成测试准备包。',
      ),
    );
    rows.add(
      const _NoticeRow(
        icon: 'list',
        title: '普通电台包从播放列表生成',
        detail: '如果只是改播放列表或语言设置，请回到播放列表使用“准备电台包”。',
      ),
    );
    return rows;
  }
  if (message.contains('当前游戏文件还没确认')) {
    rows.add(
      const _NoticeRow(
        icon: 'shield',
        title: '先处理当前游戏文件',
        detail: '回到概览保存新文件记录、生成测试准备包，或写回旧的基线；确认或放弃后再准备普通电台包。',
      ),
    );
    rows.add(
      const _NoticeRow(
        icon: 'music',
        title: '普通电台包不会直接写入游戏',
        detail: '处理完文件状态后，播放列表里的准备流程仍会只写入项目目录。',
      ),
    );
    return rows;
  }
  if (lower.contains('no r') && lower.contains('tracks_*.assets.bank')) {
    rows.add(
      const _NoticeRow(
        icon: 'warn',
        title: '播放列表引用了当前游戏目录没有的电台',
        detail:
            '草稿里有其他电台的分配，但这个游戏目录没有对应的 R*_Tracks bank。先清掉那些电台的草稿，或换到完整游戏目录后再生成。',
      ),
    );
  } else if (lower.contains('slots') || lower.contains('slot ')) {
    rows.add(
      const _NoticeRow(
        icon: 'warn',
        title: '超过电台列表上限',
        detail: '某个电台的分配数量或 slot 编号超过了实际 bank 槽位。移出多余歌曲后再生成准备包。',
      ),
    );
  } else if (lower.contains('source not found') ||
      lower.contains('input not found') ||
      message.contains('找不到音乐输入')) {
    rows.add(
      const _NoticeRow(
        icon: 'search',
        title: '源音乐文件不存在',
        detail: '草稿引用的音频路径已经移动或删除。把文件放回 sources 目录，或从播放列表移除失效歌曲。',
      ),
    );
  } else if (message.contains('播放列表') || lower.contains('playlist')) {
    rows.add(
      const _NoticeRow(
        icon: 'list',
        title: '电台包需要播放列表草稿',
        detail: '把至少一首自建歌曲拖进“准备包”视图里的目标电台后，再点准备电台包。',
      ),
    );
  } else {
    rows.add(
      const _NoticeRow(
        icon: 'warn',
        title: '构建命令返回错误',
        detail: '上方是后端返回的最后一条错误。展开 Dashboard 日志可以看到完整命令输出。',
      ),
    );
  }
  rows.add(
    _NoticeRow(
      icon: languageChanged ? 'check' : 'settings',
      title: languageChanged ? '语言变更会随完整 radio 包准备' : '只改语言也可以准备',
      detail: languageChanged
          ? '如果播放列表为空，App 会把当前目标 radio 的 RadioInfo 和 bank 原样放进准备包，并加入语言设置。'
          : '先在基础设置里改显示/语音语言；没有播放列表时也会生成完整 radio 包。',
    ),
  );
  return rows;
}

bool _isNoNewFileTestPackageMessage(String message) {
  return message.contains('没有发现需要单独测试的新游戏文件') ||
      message.contains('没有发现需要单独保存的新游戏文件');
}

List<String> _uniqueSources(List<String> sources) {
  final out = <String>[];
  final seen = <String>{};
  for (final source in sources) {
    final trimmed = source.trim();
    if (trimmed.isEmpty) continue;
    final key = trimmed.toLowerCase();
    if (seen.add(key)) out.add(trimmed);
  }
  return out;
}

class _NoticeRow extends StatelessWidget {
  const _NoticeRow({
    required this.icon,
    required this.title,
    required this.detail,
  });

  final String icon;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: rm.raised,
        border: Border.all(color: rm.border),
        borderRadius: BorderRadius.circular(RmTokens.rSm),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          RmIcon(icon, size: 14, color: rm.fg3),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: RmText.body(weight: FontWeight.w600, color: rm.fg),
                ),
                const SizedBox(height: 2),
                Text(
                  detail,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: RmText.sans(12, color: rm.fg3),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
