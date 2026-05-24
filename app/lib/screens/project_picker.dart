import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;

import '../core/app_info.dart';
import '../state/studio_state.dart';
import '../state/router.dart';
import '../theme/app_theme.dart';
import '../theme/text_styles.dart';
import '../theme/tokens.dart';
import '../widgets/boot_logo.dart';
import '../widgets/rm_icon.dart';
import '../widgets/rm_button.dart';

class ProjectPickerScreen extends ConsumerStatefulWidget {
  const ProjectPickerScreen({super.key, this.autoOpen = false});

  final bool autoOpen;

  @override
  ConsumerState<ProjectPickerScreen> createState() =>
      _ProjectPickerScreenState();
}

class _ProjectPickerScreenState extends ConsumerState<ProjectPickerScreen> {
  bool _redirected = false;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    final cli = ref.watch(studioProvider);
    final appInfo = ref.watch(appInfoProvider).valueOrNull ?? AppInfo.fallback;
    if (widget.autoOpen && cli.hasProject && !_redirected) {
      _redirected = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) context.go(RmRoutes.dashboard);
      });
    }

    return Scaffold(
      backgroundColor: rm.bg,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 60),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 920),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _logoRow(context, appInfo.releaseId),
                const SizedBox(height: 6),
                Padding(
                  padding: const EdgeInsets.only(left: 42),
                  child: Text(
                    '为 Forza Horizon 6 (PC) 设计的电台修改工具 · 仅修改本地游戏文件',
                    style: RmText.body(color: rm.fg3),
                  ),
                ),
                const SizedBox(height: 32),
                Row(
                  children: [
                    Expanded(
                      child: _BootCard(
                        icon: 'plus',
                        title: '新建工程',
                        body: '选择一个文件夹作为自包含项目目录，素材、包和原始备份都会放在里面。',
                        onTap: () => _pickProject(
                          context,
                          ref,
                          cli.projectDir,
                          title: '新建 FH Radio Studio 项目目录',
                        ),
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: _BootCard(
                        icon: 'import',
                        title: '打开项目目录',
                        body: '打开已有 FH Radio Studio 项目目录，或把普通文件夹初始化成项目。',
                        onTap: () => _pickProject(
                          context,
                          ref,
                          cli.projectDir,
                          title: '打开 FH Radio Studio 项目目录',
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 36),
                _recentHeader(context, cli.recentProjectDirs.length),
                const SizedBox(height: 10),
                if (cli.recentProjectDirs.isEmpty)
                  _emptyRecent(context)
                else
                  for (final path in cli.recentProjectDirs) ...[
                    _RecentRow(
                      path: path,
                      active: cli.hasProject && _samePath(path, cli.projectDir),
                      exists: Directory(path).existsSync(),
                      onOpen: () => _openRecentProject(path),
                      onEdit: () => _relocateRecentProject(path),
                      onRemove: () => _confirmRemoveRecentProject(path),
                    ),
                    const SizedBox(height: 6),
                  ],
                const SizedBox(height: 24),
                _footer(context),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _pickProject(
    BuildContext context,
    WidgetRef ref,
    String currentProjectDir, {
    required String title,
  }) async {
    final selected = await FilePicker.getDirectoryPath(
      dialogTitle: title,
      initialDirectory: p.dirname(currentProjectDir),
    );
    if (selected == null) return;
    ref.read(studioProvider.notifier).setProjectDirAndStartFullScan(selected);
    if (context.mounted) context.go(RmRoutes.dashboard);
  }

  Future<void> _openRecentProject(String path) async {
    if (!Directory(path).existsSync()) {
      await _showMissingProjectDialog(path);
      return;
    }
    ref.read(studioProvider.notifier).setProjectDirAndStartFullScan(path);
    if (mounted) context.go(RmRoutes.dashboard);
  }

  Future<void> _relocateRecentProject(String oldPath) async {
    final selected = await FilePicker.getDirectoryPath(
      dialogTitle: '重新定位 FH Radio Studio 项目目录',
      initialDirectory: _existingDirectoryForPicker(oldPath),
    );
    if (selected == null) return;
    ref
        .read(studioProvider.notifier)
        .updateRecentProjectPath(oldPath, selected);
    if (!mounted) return;
    final cli = ref.read(studioProvider);
    if (cli.hasProject && _samePath(cli.projectDir, selected)) {
      context.go(RmRoutes.dashboard);
    }
  }

  Future<void> _confirmRemoveRecentProject(String path) async {
    final shouldRemove = await _showRemoveProjectDialog(
      title: '移除最近项目？',
      body: '这只会从最近项目列表移除入口，不会删除磁盘上的项目文件。',
      path: path,
    );
    if (shouldRemove != true || !mounted) return;
    ref.read(studioProvider.notifier).removeRecentProject(path);
  }

  Future<void> _showMissingProjectDialog(String path) async {
    final action = await showDialog<_MissingProjectAction>(
      context: context,
      barrierColor: RmTokens.modalBackdrop,
      builder: (dialogContext) {
        return _ProjectPickerDialog<_MissingProjectAction>(
          icon: 'folder',
          title: '找不到这个项目',
          body: '项目目录可能已经被移动、重命名或删除。你可以重新定位它，也可以移除这个最近访问入口。',
          path: path,
          actions: [
            const _ProjectPickerDialogAction(
              label: '取消',
              value: _MissingProjectAction.cancel,
            ),
            const _ProjectPickerDialogAction(
              label: '重新定位',
              value: _MissingProjectAction.relocate,
              variant: RmButtonVariant.primary,
              icon: 'import',
            ),
            const _ProjectPickerDialogAction(
              label: '移除入口',
              value: _MissingProjectAction.remove,
              variant: RmButtonVariant.danger,
              icon: 'trash',
            ),
          ],
        );
      },
    );
    if (!mounted || action == null || action == _MissingProjectAction.cancel) {
      return;
    }
    if (action == _MissingProjectAction.relocate) {
      await _relocateRecentProject(path);
      return;
    }
    ref.read(studioProvider.notifier).removeRecentProject(path);
  }

  Future<bool?> _showRemoveProjectDialog({
    required String title,
    required String body,
    required String path,
  }) {
    return showDialog<bool>(
      context: context,
      barrierColor: RmTokens.modalBackdrop,
      builder: (dialogContext) {
        return _ProjectPickerDialog<bool>(
          icon: 'trash',
          danger: true,
          title: title,
          body: body,
          path: path,
          actions: [
            const _ProjectPickerDialogAction(label: '取消', value: false),
            const _ProjectPickerDialogAction(
              label: '移除入口',
              value: true,
              variant: RmButtonVariant.dangerPrimary,
              icon: 'trash',
            ),
          ],
        );
      },
    );
  }

  String? _existingDirectoryForPicker(String path) {
    final normalized = File(path).absolute.path;
    if (Directory(normalized).existsSync()) return normalized;
    final parent = p.dirname(normalized);
    if (Directory(parent).existsSync()) return parent;
    return null;
  }

  bool _samePath(String left, String right) {
    try {
      return p.canonicalize(File(left).absolute.path).toLowerCase() ==
          p.canonicalize(File(right).absolute.path).toLowerCase();
    } on ArgumentError {
      return p.normalize(File(left).absolute.path).toLowerCase() ==
          p.normalize(File(right).absolute.path).toLowerCase();
    }
  }

  Widget _emptyRecent(BuildContext context) {
    final rm = context.rm;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 18),
      decoration: BoxDecoration(
        color: rm.panel,
        border: Border.all(color: rm.border),
        borderRadius: BorderRadius.circular(RmTokens.rMd),
      ),
      child: Text('还没有最近工程。先新建或打开一个项目目录。', style: RmText.body(color: rm.fg3)),
    );
  }

  Widget _logoRow(BuildContext context, String releaseId) {
    final rm = context.rm;
    return Row(
      children: [
        const BootLogoMark(size: 30),
        const SizedBox(width: 12),
        Text('FH Radio Studio', style: RmText.bootLogo(color: rm.fg)),
        const SizedBox(width: 6),
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(releaseId, style: RmText.mono(11, color: rm.fg3)),
        ),
      ],
    );
  }

  Widget _recentHeader(BuildContext context, int count) {
    final rm = context.rm;
    return Row(
      children: [
        Text(
          '最近工程',
          style: RmText.mono(11.5, color: rm.fg3, letterSpacing: 0.12 * 11.5),
        ),
        const Spacer(),
        Text('$count 个', style: RmText.mono(11, color: rm.fg4)),
      ],
    );
  }

  Widget _footer(BuildContext context) {
    final rm = context.rm;
    return Container(
      padding: const EdgeInsets.only(top: 18),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: rm.border)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'FH Radio Studio 不修改账号、存档或在线连接数据。所有写入都会先对照备份，再确认后执行。',
              style: RmText.mono(11, color: rm.fg3),
            ),
          ),
          ...['文档', 'GitHub', '报告问题'].map(
            (label) => Padding(
              padding: const EdgeInsets.only(left: 18),
              child: Text(label, style: RmText.mono(11, color: rm.fg2)),
            ),
          ),
        ],
      ),
    );
  }
}

enum _MissingProjectAction { cancel, relocate, remove }

enum _RecentProjectAction { open, relocate, remove }

class _ProjectPickerDialogAction<T> {
  const _ProjectPickerDialogAction({
    required this.label,
    required this.value,
    this.variant = RmButtonVariant.defaultBtn,
    this.icon,
  });

  final String label;
  final T value;
  final RmButtonVariant variant;
  final String? icon;
}

class _ProjectPickerDialog<T> extends StatelessWidget {
  const _ProjectPickerDialog({
    required this.icon,
    required this.title,
    required this.body,
    required this.path,
    required this.actions,
    this.danger = false,
  });

  final String icon;
  final String title;
  final String body;
  final String path;
  final List<_ProjectPickerDialogAction<T>> actions;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    final tone = danger ? rm.danger : rm.accent.base;
    final toneBg = danger ? rm.dangerBg : rm.accent.bg;
    final toneBorder = danger ? rm.danger.withAlpha(77) : rm.accent.ring;
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 48, vertical: 36),
      child: Container(
        width: 520,
        constraints: const BoxConstraints(maxHeight: 620),
        decoration: BoxDecoration(
          color: rm.panel,
          border: Border.all(color: rm.border),
          borderRadius: BorderRadius.circular(RmTokens.rXl),
          boxShadow: RmTokens.modal,
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 16, 14),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 30,
                    height: 30,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: toneBg,
                      border: Border.all(color: toneBorder),
                      borderRadius: BorderRadius.circular(RmTokens.rMd),
                    ),
                    child: RmIcon(icon, size: 16, color: tone),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'PROJECT',
                          style: RmText.mono(
                            10.5,
                            color: tone,
                            letterSpacing: 1.45,
                          ),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          title,
                          style: RmText.sans(
                            16.5,
                            color: rm.fg,
                            weight: FontWeight.w700,
                          ),
                        ),
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
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      body,
                      style: RmText.sans(12.5, color: rm.fg2, height: 1.45),
                    ),
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: rm.raised,
                        border: Border.all(color: rm.border),
                        borderRadius: BorderRadius.circular(RmTokens.rMd),
                      ),
                      child: SelectableText(
                        path,
                        style: RmText.mono(11, color: rm.fg3, letterSpacing: 0),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Divider(height: 1, color: rm.border),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 14),
              child: Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final action in actions)
                    RmButton(
                      onPressed: () =>
                          Navigator.of(context).pop<T>(action.value),
                      label: action.label,
                      leading: action.icon == null
                          ? null
                          : RmIcon(action.icon!, size: 12),
                      size: RmButtonSize.sm,
                      variant: action.variant,
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

class _BootCard extends StatefulWidget {
  const _BootCard({
    required this.icon,
    required this.title,
    required this.body,
    required this.onTap,
  });

  final String icon;
  final String title;
  final String body;
  final VoidCallback onTap;

  @override
  State<_BootCard> createState() => _BootCardState();
}

class _BootCardState extends State<_BootCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.all(22),
          decoration: BoxDecoration(
            color: _hover ? rm.raised : rm.panel,
            border: Border.all(color: _hover ? rm.borderStrong : rm.border),
            borderRadius: BorderRadius.circular(RmTokens.rLg),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: rm.raised,
                  border: Border.all(color: rm.border),
                  borderRadius: BorderRadius.circular(RmTokens.rSm),
                ),
                alignment: Alignment.center,
                child: RmIcon(widget.icon, size: 16, color: rm.accent.base),
              ),
              const SizedBox(height: 14),
              Text(widget.title, style: RmText.panelTitle(color: rm.fg)),
              const SizedBox(height: 4),
              Text(widget.body, style: RmText.sans(12.5, color: rm.fg3)),
            ],
          ),
        ),
      ),
    );
  }
}

class _RecentRow extends StatefulWidget {
  const _RecentRow({
    required this.path,
    required this.active,
    required this.exists,
    required this.onOpen,
    required this.onEdit,
    required this.onRemove,
  });

  final String path;
  final bool active;
  final bool exists;
  final VoidCallback onOpen;
  final VoidCallback onEdit;
  final VoidCallback onRemove;

  @override
  State<_RecentRow> createState() => _RecentRowState();
}

class _RecentRowState extends State<_RecentRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    final border = !widget.exists
        ? rm.warn
        : _hover
        ? rm.borderStrong
        : rm.border;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onOpen,
        onSecondaryTapDown: _showMenu,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: _hover ? rm.raised : rm.panel,
            border: Border.all(color: border),
            borderRadius: BorderRadius.circular(RmTokens.rMd),
          ),
          child: Row(
            children: [
              // game code square
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: rm.raised,
                  border: Border.all(color: rm.border),
                  borderRadius: BorderRadius.circular(RmTokens.rSm),
                ),
                alignment: Alignment.center,
                child: Text(
                  'FH6',
                  style: RmText.mono(
                    11,
                    color: rm.accent.base,
                    weight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      p.basename(widget.path),
                      style: RmText.rowTitle(color: rm.fg),
                    ),
                    const SizedBox(height: 2),
                    Text(widget.path, style: RmText.mono(11, color: rm.fg4)),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              Text(
                !widget.exists
                    ? '未找到'
                    : widget.active
                    ? '当前项目'
                    : '可切换',
                style: RmText.sans(12, color: widget.exists ? rm.fg3 : rm.warn),
              ),
              const SizedBox(width: 16),
              Text('本地目录', style: RmText.mono(11, color: rm.fg3)),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showMenu(TapDownDetails details) async {
    final rm = context.rm;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final action = await showMenu<_RecentProjectAction>(
      context: context,
      color: rm.panel,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(
          details.globalPosition.dx,
          details.globalPosition.dy,
          0,
          0,
        ),
        Offset.zero & overlay.size,
      ),
      items: [
        PopupMenuItem(
          value: _RecentProjectAction.open,
          enabled: widget.exists,
          child: Text('打开项目', style: RmText.body(color: rm.fg)),
        ),
        PopupMenuItem(
          value: _RecentProjectAction.relocate,
          child: Text(
            widget.exists ? '编辑地址' : '重新定位',
            style: RmText.body(color: rm.fg),
          ),
        ),
        PopupMenuItem(
          value: _RecentProjectAction.remove,
          child: Text('移除入口', style: RmText.body(color: rm.danger)),
        ),
      ],
    );
    if (!mounted || action == null) return;
    switch (action) {
      case _RecentProjectAction.open:
        widget.onOpen();
      case _RecentProjectAction.relocate:
        widget.onEdit();
      case _RecentProjectAction.remove:
        widget.onRemove();
    }
  }
}
