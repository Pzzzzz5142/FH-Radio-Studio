import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/backup_history_state.dart';
import '../state/studio_state.dart';
import '../theme/app_theme.dart';
import '../theme/text_styles.dart';
import '../theme/tokens.dart';
import '../widgets/kv_list.dart';
import '../widgets/pending_gate.dart';
import '../widgets/rm_banner.dart';
import '../widgets/rm_button.dart';
import '../widgets/rm_icon.dart';
import '../widgets/rm_panel.dart';
import '../widgets/rm_segmented.dart';

enum _SnapshotFilter { all, manual, automatic }

class BackupsScreen extends ConsumerStatefulWidget {
  const BackupsScreen({super.key});

  @override
  ConsumerState<BackupsScreen> createState() => _BackupsScreenState();
}

class _BackupsScreenState extends ConsumerState<BackupsScreen> {
  _SnapshotFilter _snapshotFilter = _SnapshotFilter.all;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _refreshBackupManifests(ref);
    });
  }

  @override
  Widget build(BuildContext context) {
    final cliState = ref.watch(studioProvider);
    final history = ref.watch(backupHistoryProvider);
    final baselineBackups = ref.watch(baselineBackupProvider);
    final backupsDir = cliState.backupsDir;
    final refreshing = cliState.refreshingStatus;

    return SingleChildScrollView(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: RmTokens.pageDefault),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(40, 36, 40, 96),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _pageHead(context, ref, backupsDir, cliState.busy),
                const SizedBox(height: 28),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final gameCard = _gameBackupCard(
                      context,
                      ref,
                      baselineBackups,
                      cliState,
                    );
                    final configCard = _currentConfigCard(
                      context,
                      ref,
                      cliState,
                    );
                    final gatedGameCard = _refreshGate(
                      pending: refreshing,
                      label: '完整校验原版基线',
                      detail: '正在重新计算游戏文件、准备包和原始基线 MD5。',
                      child: gameCard,
                    );
                    final gatedConfigCard = _refreshGate(
                      pending: refreshing,
                      label: '完整校验当前配置',
                      detail: '正在重新计算游戏文件、准备包和原始基线 MD5。',
                      child: configCard,
                    );
                    if (constraints.maxWidth < 880) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          gatedGameCard,
                          const SizedBox(height: 14),
                          gatedConfigCard,
                        ],
                      );
                    }
                    return _EqualHeightBackupCards(
                      gameCard: gatedGameCard,
                      configCard: gatedConfigCard,
                    );
                  },
                ),
                const SizedBox(height: 14),
                _refreshGate(
                  pending: refreshing,
                  label: '刷新恢复快照',
                  detail: '正在完整校验，同时轻量刷新快照 manifest。',
                  child: _snapshotPanel(context, ref, history, cliState.busy),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _refreshGate({
    required bool pending,
    required String label,
    required String detail,
    required Widget child,
  }) {
    return PendingGate(
      pending: pending,
      label: label,
      detail: detail,
      overlayKey: ValueKey('backups-refresh-$label'),
      childOpacity: 0.44,
      blockInput: true,
      child: child,
    );
  }

  Widget _pageHead(
    BuildContext context,
    WidgetRef ref,
    String backupsDir,
    bool busy,
  ) {
    final rm = context.rm;
    return LayoutBuilder(
      builder: (context, constraints) {
        final title = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('旧恢复记录', style: RmText.pageH1(color: rm.fg)),
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Text(
                'Deprecated 区域只用于查看旧项目遗留 artifact。新流程只认原始基线、准备包和 last-applied 指纹。',
                style: RmText.body(color: rm.fg3),
              ),
            ),
          ],
        );
        final actions = Wrap(
          spacing: 8,
          runSpacing: 8,
          alignment: WrapAlignment.end,
          children: [
            RmButton(
              onPressed: () => _openFolder(backupsDir),
              leading: const RmIcon('folder', size: 12),
              label: '打开目录',
            ),
            RmButton(
              onPressed: busy ? null : () => _verifyBackups(ref),
              leading: const RmIcon('search', size: 12),
              label: '完整校验',
            ),
          ],
        );

        if (constraints.maxWidth < 720) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              title,
              const SizedBox(height: 16),
              Align(alignment: Alignment.centerLeft, child: actions),
            ],
          );
        }

        return Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(child: title),
            const SizedBox(width: 18),
            actions,
          ],
        );
      },
    );
  }

  Widget _gameBackupCard(
    BuildContext context,
    WidgetRef ref,
    AsyncValue<List<BaselineBackupEntry>> baselines,
    StudioState cliState,
  ) {
    final baselinePlan = cliState.baselinePlanSummary;
    final baselineBroken = baselinePlan?.hasIntegrityBreak ?? false;
    return baselines.when(
      loading: () => _BackupStatusCard(
        key: const ValueKey('backups-game-card'),
        tag: const _BackupTag(label: '游戏原版'),
        icon: const RmIcon('shield', size: 14),
        title: 'vanilla · 正在扫描原始基线',
        entries: const [
          KvEntry('建立时间', Text('扫描中')),
          KvEntry('Steam build', Text('读取中')),
          KvEntry('包含文件', Text('读取 baseline_manifest.json')),
          KvEntry('大小', Text('...')),
          KvEntry('完整性', Text('等待校验记录')),
        ],
        footnote: '这是回到 vanilla 的唯一退路。FH Radio Studio 不会自动覆盖它。',
        actions: const [],
      ),
      error: (error, _) => _BackupStatusCard(
        key: const ValueKey('backups-game-card'),
        tag: const _BackupTag(label: '游戏原版'),
        icon: const RmIcon('shield', size: 14),
        title: 'vanilla · 原始基线读取失败',
        entries: [
          const KvEntry('建立时间', Text('未知')),
          const KvEntry('Steam build', Text('未知')),
          KvEntry('包含文件', Text('$error')),
          const KvEntry('大小', Text('未知')),
          KvEntry(
            '完整性',
            Text('读取失败', style: TextStyle(color: context.rm.danger)),
          ),
        ],
        footnote: '无法读取基线清单时，不建议直接执行回滚。',
        actions: const [],
      ),
      data: (entries) {
        final entry = _primaryBaseline(entries);
        if (entry == null) {
          return _BackupStatusCard(
            key: const ValueKey('backups-game-card'),
            tag: const _BackupTag(label: '游戏原版'),
            icon: const RmIcon('shield', size: 14),
            title: 'vanilla · 尚未建立原始基线',
            entries: const [
              KvEntry('建立时间', Text('未创建')),
              KvEntry('Steam build', Text('等待读取游戏版本')),
              KvEntry('包含文件', Text('等待首次导入或验证后创建')),
              KvEntry('大小', Text('未知')),
              KvEntry('完整性', Text('没有 baseline_manifest.json')),
            ],
            footnote: '创建原始基线后，这里会记录官方文件的可信起点。',
            actions: const [],
          );
        }

        return _BackupStatusCard(
          key: const ValueKey('backups-game-card'),
          tag: const _BackupTag(label: '游戏原版'),
          icon: const RmIcon('shield', size: 14),
          title: '${_baselineKind(entry)} · ${entry.versionLabel}',
          notice: baselineBroken
              ? RmBanner(
                  kind: RmBannerKind.danger,
                  title: '校验断裂：',
                  body:
                      '${baselinePlan!.integrityBreakCount} 个原始基线文件缺失或 MD5 与 manifest 不一致。当前只允许查看，禁止写回和写入游戏。',
                )
              : null,
          entries: [
            KvEntry('建立时间', Text(_baselineWhen(entry))),
            KvEntry('Steam build', Text(entry.versionLabel)),
            KvEntry('版本详情', Text(entry.versionDetail)),
            KvEntry('包含文件', Text(_baselineFiles(entry))),
            KvEntry('大小', Text(_formatBytes(entry.totalSize))),
            KvEntry(
              '完整性',
              Text(
                baselineBroken ? '校验断裂' : '✓ 校验记录已建立',
                style: TextStyle(
                  color: baselineBroken
                      ? context.rm.danger
                      : context.rm.accent.base,
                ),
              ),
            ),
          ],
          footnote: baselineBroken
              ? '先修复或重新创建可信基线，再允许写回或写入游戏。'
              : '这是官方文件的可信起点。FH Radio Studio 不会自动覆盖它。',
          actions: [
            RmButton(
              onPressed: () => _openFolder(entry.folderPath),
              size: RmButtonSize.sm,
              leading: const RmIcon('folder', size: 11),
              label: '打开',
            ),
          ],
        );
      },
    );
  }

  Widget _currentConfigCard(
    BuildContext context,
    WidgetRef ref,
    StudioState cliState,
  ) {
    final packageSummary =
        cliState.pendingPackageSummary ?? cliState.lastPackageSummary;
    final packageDir = cliState.pendingPackageDir ?? cliState.lastPackageDir;
    final lastBackup = cliState.lastBackupSummary;
    final lastSync = _backupCreatedLabel(lastBackup?.createdAt);
    final include =
        packageSummary?.detail ?? lastBackup?.detail ?? '还没有准备或写入的电台包';
    final steamBuild = lastBackup?.steamBuildLabel ?? 'Steam build 未记录';
    final size = packageDir == null ? '未生成' : _folderSizeLabel(packageDir);
    final configSource = packageDir == null
        ? '暂无准备包'
        : cliState.pendingPackageDir != null
        ? 'pending 准备包'
        : '常驻准备包';

    return _BackupStatusCard(
      key: const ValueKey('backups-config-card'),
      tag: const _BackupTag(label: '当前配置', accent: true),
      icon: const RmIcon('dot', size: 14),
      title: 'live · ${packageSummary?.title ?? '你现在的 mod 状态'}',
      entries: [
        KvEntry('最后同步', Text(lastSync)),
        KvEntry('状态', Text(cliState.fileIntegrity.title)),
        KvEntry('Steam build', Text(steamBuild)),
        KvEntry('包含', Text(include)),
        KvEntry('配置来源', Text(configSource)),
        KvEntry('大小', Text(size)),
      ],
      footnote: '新流程写入后只更新 last-applied 指纹。这里保留旧 artifact 便于查看。',
      actions: [
        RmButton(
          onPressed: packageDir == null ? null : () => _openFolder(packageDir),
          size: RmButtonSize.sm,
          leading: const RmIcon('folder', size: 11),
          label: '打开包',
        ),
      ],
    );
  }

  Widget _snapshotPanel(
    BuildContext context,
    WidgetRef ref,
    AsyncValue<List<BackupHistoryEntry>> history,
    bool busy,
  ) {
    return history.when(
      loading: () => RmPanel(
        title: '恢复快照',
        subtitle: '正在扫描写入前旧记录',
        noPad: true,
        child: const _SnapshotLoading(),
      ),
      error: (error, _) => RmPanel(
        title: '恢复快照',
        subtitle: '读取失败',
        noPad: true,
        child: _SnapshotError(message: '$error'),
      ),
      data: (entries) {
        final manualCount = entries
            .where((entry) => entry.isManualSnapshot)
            .length;
        final automaticCount = entries.length - manualCount;
        final filtered = switch (_snapshotFilter) {
          _SnapshotFilter.all => entries,
          _SnapshotFilter.manual =>
            entries
                .where((entry) => entry.isManualSnapshot)
                .toList(growable: false),
          _SnapshotFilter.automatic =>
            entries
                .where((entry) => entry.isAutomaticBackup)
                .toList(growable: false),
        };
        return RmPanel(
          title: '恢复快照',
          titleTrailing: RmSegmented<_SnapshotFilter>(
            value: _snapshotFilter,
            onChanged: (value) => setState(() => _snapshotFilter = value),
            options: [
              RmSegmentedOption(
                value: _SnapshotFilter.all,
                label: '全部 ${entries.length}',
              ),
              RmSegmentedOption(
                value: _SnapshotFilter.manual,
                label: '手动 $manualCount',
              ),
              RmSegmentedOption(
                value: _SnapshotFilter.automatic,
                label: '自动 $automaticCount',
              ),
            ],
          ),
          noPad: true,
          child: entries.isEmpty
              ? const _SnapshotEmpty()
              : filtered.isEmpty
              ? _SnapshotEmpty(
                  title: '没有${_snapshotFilterLabel(_snapshotFilter)}快照',
                  subtitle: '切换到“全部”可以查看其他类型的恢复快照。',
                )
              : Column(
                  children: [
                    for (var i = 0; i < filtered.length; i++)
                      _SnapshotRow(
                        entry: filtered[i],
                        isLast: i == filtered.length - 1,
                        sizeLabel: _snapshotSizeLabel(filtered[i]),
                        busy: busy,
                        onOpen: () => _openFolder(filtered[i].folderPath),
                        onRestore: () =>
                            _confirmAndRestore(context, ref, filtered[i]),
                        onDelete: () =>
                            _confirmAndDelete(context, ref, filtered[i]),
                      ),
                  ],
                ),
        );
      },
    );
  }

  void _refreshBackupManifests(WidgetRef ref) {
    ref.invalidate(backupHistoryProvider);
    ref.invalidate(baselineBackupProvider);
  }

  void _verifyBackups(WidgetRef ref) {
    _refreshBackupManifests(ref);
    ref.read(studioProvider.notifier).verifyFileIntegrity();
  }

  Future<void> _confirmAndRestore(
    BuildContext context,
    WidgetRef ref,
    BackupHistoryEntry entry,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      barrierColor: RmTokens.modalBackdrop,
      builder: (context) => _RestoreConfirmDialog(
        eyebrow: entry.isManualSnapshot ? 'RESTORE SNAPSHOT' : 'RESTORE BACKUP',
        title: entry.isManualSnapshot ? '恢复手动旧记录？' : '恢复写入前旧记录？',
        body: entry.isManualSnapshot
            ? '这会把手动旧记录中保存的文件复制回 FH6。'
            : '这会把写入前保存的文件复制回 FH6，用于撤销对应写入。',
        artifactTitle: entry.title,
        artifactDetail: entry.detail,
        artifactBuild: entry.steamBuildLabel,
        warningBody: '恢复会直接覆盖当前游戏文件，不会创建新的恢复日志。',
        actionLabel: '确认恢复',
      ),
    );
    if (ok != true) return;
    await ref.read(studioProvider.notifier).restoreBackup(entry.manifestPath);
    ref.invalidate(backupHistoryProvider);
  }

  Future<void> _confirmAndDelete(
    BuildContext context,
    WidgetRef ref,
    BackupHistoryEntry entry,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      barrierColor: RmTokens.modalBackdrop,
      builder: (context) => _DeleteConfirmDialog(entry: entry),
    );
    if (ok != true) return;
    try {
      await ref
          .read(studioProvider.notifier)
          .deleteBackupSnapshot(entry.manifestPath);
      ref.invalidate(backupHistoryProvider);
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('删除失败：$error')));
    }
  }

  void _openFolder(String path) {
    final dir = Directory(path);
    if (!dir.existsSync()) return;
    if (Platform.isWindows) {
      Process.start('explorer', [dir.path]);
    } else if (Platform.isMacOS) {
      Process.start('open', [dir.path]);
    } else if (Platform.isLinux) {
      Process.start('xdg-open', [dir.path]);
    }
  }
}

class _BackupModalShell extends StatelessWidget {
  const _BackupModalShell({
    required this.eyebrow,
    required this.title,
    required this.icon,
    required this.iconColor,
    required this.iconBg,
    required this.iconBorder,
    required this.body,
    required this.footer,
    required this.onClose,
  });

  final String eyebrow;
  final String title;
  final String icon;
  final Color iconColor;
  final Color iconBg;
  final Color iconBorder;
  final Widget body;
  final Widget footer;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 36),
      child: Container(
        width: 560,
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
              padding: const EdgeInsets.fromLTRB(24, 22, 24, 16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: iconBg,
                      border: Border.all(color: iconBorder),
                      borderRadius: BorderRadius.circular(RmTokens.rMd),
                    ),
                    child: RmIcon(icon, size: 17, color: iconColor),
                  ),
                  const SizedBox(width: 13),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          eyebrow,
                          style: RmText.mono(
                            11,
                            color: iconColor,
                            letterSpacing: 0.12 * 11,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(title, style: RmText.modalH2(color: rm.fg)),
                      ],
                    ),
                  ),
                  RmButton.icon(
                    onPressed: onClose,
                    icon: const RmIcon('x', size: 13),
                    variant: RmButtonVariant.ghost,
                    tooltip: '取消',
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: rm.border),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 18, 24, 18),
                child: body,
              ),
            ),
            Container(
              padding: const EdgeInsets.fromLTRB(24, 14, 24, 22),
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: rm.border)),
              ),
              child: footer,
            ),
          ],
        ),
      ),
    );
  }
}

class _SnapshotNameDialog extends StatefulWidget {
  const _SnapshotNameDialog({required this.controller});

  final TextEditingController controller;

  @override
  State<_SnapshotNameDialog> createState() => _SnapshotNameDialogState();
}

class _SnapshotNameDialogState extends State<_SnapshotNameDialog> {
  bool get _canCreate => widget.controller.text.trim().isNotEmpty;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_sync);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_sync);
    super.dispose();
  }

  void _sync() => setState(() {});

  void _submit() {
    final trimmed = widget.controller.text.trim();
    if (trimmed.isNotEmpty) Navigator.of(context).pop(trimmed);
  }

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    return _BackupModalShell(
      eyebrow: 'MANUAL SNAPSHOT',
      title: '新建旧记录',
      icon: 'history',
      iconColor: rm.accent.base,
      iconBg: rm.accent.bg,
      iconBorder: rm.accent.ring,
      onClose: () => Navigator.of(context).pop(),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '保存当前游戏里 FH Radio Studio 管理的文件。之后如果恢复操作覆盖了当前状态，可以从这里找回这份旧记录。',
            style: RmText.body(color: rm.fg2),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: widget.controller,
            autofocus: true,
            style: RmText.body(color: rm.fg),
            decoration: InputDecoration(
              labelText: '快照名称',
              hintText: '例如：加 BLK 之前',
              helperText: '建议用能说明改动前状态的名字。',
              filled: true,
              fillColor: rm.raised,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(RmTokens.rSm),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(RmTokens.rSm),
                borderSide: BorderSide(color: rm.border),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(RmTokens.rSm),
                borderSide: BorderSide(color: rm.accent.base),
              ),
            ),
            onSubmitted: (_) => _submit(),
          ),
        ],
      ),
      footer: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          RmButton(onPressed: () => Navigator.of(context).pop(), label: '取消'),
          const SizedBox(width: 10),
          RmButton(
            onPressed: _canCreate ? _submit : null,
            variant: RmButtonVariant.primary,
            label: '创建快照',
          ),
        ],
      ),
    );
  }
}

class _RestoreConfirmDialog extends StatelessWidget {
  const _RestoreConfirmDialog({
    required this.eyebrow,
    required this.title,
    required this.body,
    required this.artifactTitle,
    required this.artifactDetail,
    required this.artifactBuild,
    required this.warningBody,
    required this.actionLabel,
  });

  final String eyebrow;
  final String title;
  final String body;
  final String artifactTitle;
  final String artifactDetail;
  final String artifactBuild;
  final String warningBody;
  final String actionLabel;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    return _BackupModalShell(
      eyebrow: eyebrow,
      title: title,
      icon: 'danger',
      iconColor: rm.danger,
      iconBg: rm.dangerBg,
      iconBorder: rm.danger.withAlpha(77),
      onClose: () => Navigator.of(context).pop(false),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(body, style: RmText.body(color: rm.fg2)),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            decoration: BoxDecoration(
              color: rm.raised,
              border: Border.all(color: rm.border),
              borderRadius: BorderRadius.circular(RmTokens.rMd),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  artifactTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: RmText.sans(13, weight: FontWeight.w700, color: rm.fg),
                ),
                const SizedBox(height: 5),
                Text(artifactDetail, style: RmText.mono(11.5, color: rm.fg3)),
                const SizedBox(height: 5),
                Text(artifactBuild, style: RmText.mono(11.5, color: rm.fg2)),
              ],
            ),
          ),
          const SizedBox(height: 14),
          RmBanner(
            kind: RmBannerKind.danger,
            title: '覆盖提醒：',
            body: warningBody,
          ),
        ],
      ),
      footer: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          RmButton(
            onPressed: () => Navigator.of(context).pop(false),
            label: '取消',
          ),
          const SizedBox(width: 10),
          RmButton(
            onPressed: () => Navigator.of(context).pop(true),
            variant: RmButtonVariant.danger,
            label: actionLabel,
          ),
        ],
      ),
    );
  }
}

class _DeleteConfirmDialog extends StatelessWidget {
  const _DeleteConfirmDialog({required this.entry});

  final BackupHistoryEntry entry;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    return _BackupModalShell(
      eyebrow: 'DELETE SNAPSHOT',
      title: entry.isManualSnapshot ? '删除手动旧记录？' : '删除自动旧记录？',
      icon: 'trash',
      iconColor: rm.danger,
      iconBg: rm.dangerBg,
      iconBorder: rm.danger.withAlpha(77),
      onClose: () => Navigator.of(context).pop(false),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '这会永久删除这个恢复快照对应的文件夹。当前游戏文件、准备包和原始游戏基线不会被修改。',
            style: RmText.body(color: rm.fg2),
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            decoration: BoxDecoration(
              color: rm.raised,
              border: Border.all(color: rm.border),
              borderRadius: BorderRadius.circular(RmTokens.rMd),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: RmText.sans(13, weight: FontWeight.w700, color: rm.fg),
                ),
                const SizedBox(height: 5),
                Text(entry.detail, style: RmText.mono(11.5, color: rm.fg3)),
                const SizedBox(height: 5),
                Text(
                  entry.steamBuildLabel,
                  style: RmText.mono(11.5, color: rm.fg2),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          RmBanner(
            kind: RmBannerKind.danger,
            title: '删除提醒：',
            body: '删除后无法从 FH Radio Studio 内恢复这份快照。需要保留时，请先打开目录手动复制。',
          ),
        ],
      ),
      footer: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          RmButton(
            onPressed: () => Navigator.of(context).pop(false),
            label: '取消',
          ),
          const SizedBox(width: 10),
          RmButton(
            onPressed: () => Navigator.of(context).pop(true),
            variant: RmButtonVariant.danger,
            label: '确认删除',
          ),
        ],
      ),
    );
  }
}

class _EqualHeightBackupCards extends MultiChildRenderObjectWidget {
  _EqualHeightBackupCards({
    required Widget gameCard,
    required Widget configCard,
  }) : super(children: [gameCard, configCard]);

  @override
  RenderObject createRenderObject(BuildContext context) {
    return _RenderEqualHeightBackupCards(gap: 14);
  }

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderEqualHeightBackupCards renderObject,
  ) {
    renderObject.gap = 14;
  }
}

class _EqualHeightBackupCardsParentData
    extends ContainerBoxParentData<RenderBox> {}

class _RenderEqualHeightBackupCards extends RenderBox
    with
        ContainerRenderObjectMixin<
          RenderBox,
          _EqualHeightBackupCardsParentData
        >,
        RenderBoxContainerDefaultsMixin<
          RenderBox,
          _EqualHeightBackupCardsParentData
        > {
  _RenderEqualHeightBackupCards({required double gap}) : _gap = gap;

  double _gap;

  double get gap => _gap;

  set gap(double value) {
    if (_gap == value) return;
    _gap = value;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _EqualHeightBackupCardsParentData) {
      child.parentData = _EqualHeightBackupCardsParentData();
    }
  }

  @override
  void performLayout() {
    final left = firstChild;
    final right = left == null ? null : childAfter(left);
    if (left == null || right == null) {
      size = constraints.constrain(Size.zero);
      return;
    }

    final rowWidth = constraints.hasBoundedWidth
        ? constraints.maxWidth
        : constraints.minWidth;
    final childWidth = math.max(0.0, (rowWidth - gap) / 2);
    final looseHeight = constraints.hasBoundedHeight
        ? constraints.maxHeight
        : double.infinity;
    final naturalConstraints = BoxConstraints(
      minWidth: childWidth,
      maxWidth: childWidth,
      minHeight: 0,
      maxHeight: looseHeight,
    );

    left.layout(naturalConstraints, parentUsesSize: true);
    right.layout(naturalConstraints, parentUsesSize: true);

    final rowHeight = constraints.constrainHeight(
      math.max(left.size.height, right.size.height),
    );
    final equalConstraints = BoxConstraints.tightFor(
      width: childWidth,
      height: rowHeight,
    );

    left.layout(equalConstraints, parentUsesSize: true);
    right.layout(equalConstraints, parentUsesSize: true);

    size = constraints.constrain(Size(rowWidth, rowHeight));

    final leftParentData =
        left.parentData! as _EqualHeightBackupCardsParentData;
    final rightParentData =
        right.parentData! as _EqualHeightBackupCardsParentData;
    leftParentData.offset = Offset.zero;
    rightParentData.offset = Offset(childWidth + gap, 0);
  }

  @override
  double computeMinIntrinsicWidth(double height) {
    return gap;
  }

  @override
  double computeMaxIntrinsicWidth(double height) {
    var total = gap;
    var child = firstChild;
    while (child != null) {
      total += child.getMaxIntrinsicWidth(height);
      final childParentData =
          child.parentData! as _EqualHeightBackupCardsParentData;
      child = childParentData.nextSibling;
    }
    return total;
  }

  @override
  double computeMinIntrinsicHeight(double width) {
    return _intrinsicHeight(width, (child, childWidth) {
      return child.getMinIntrinsicHeight(childWidth);
    });
  }

  @override
  double computeMaxIntrinsicHeight(double width) {
    return _intrinsicHeight(width, (child, childWidth) {
      return child.getMaxIntrinsicHeight(childWidth);
    });
  }

  double _intrinsicHeight(
    double width,
    double Function(RenderBox child, double childWidth) measure,
  ) {
    final childWidth = width.isFinite
        ? math.max(0.0, (width - gap) / 2)
        : width;
    var maxHeight = 0.0;
    var child = firstChild;
    while (child != null) {
      maxHeight = math.max(maxHeight, measure(child, childWidth));
      final childParentData =
          child.parentData! as _EqualHeightBackupCardsParentData;
      child = childParentData.nextSibling;
    }
    return maxHeight;
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final rowWidth = constraints.hasBoundedWidth
        ? constraints.maxWidth
        : constraints.minWidth;
    return constraints.constrain(Size(rowWidth, 0));
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    return defaultHitTestChildren(result, position: position);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    defaultPaint(context, offset);
  }
}

class _BackupStatusCard extends StatelessWidget {
  const _BackupStatusCard({
    super.key,
    required this.tag,
    required this.icon,
    required this.title,
    required this.entries,
    required this.footnote,
    required this.actions,
    this.notice,
  });

  final Widget tag;
  final Widget icon;
  final String title;
  final List<KvEntry> entries;
  final String footnote;
  final List<Widget> actions;
  final Widget? notice;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
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
        child: LayoutBuilder(
          builder: (context, constraints) {
            final boundedHeight = constraints.hasBoundedHeight;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: boundedHeight ? MainAxisSize.max : MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 10,
                  ),
                  child: Row(children: [tag, const SizedBox(width: 12), icon]),
                ),
                Divider(height: 1, color: rm.border),
                if (boundedHeight)
                  Expanded(child: _BackupStatusBody(title, entries, notice))
                else
                  _BackupStatusBody(title, entries, notice),
                Divider(height: 1, color: rm.border),
                _BackupStatusFooter(footnote: footnote, actions: actions),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _BackupStatusBody extends StatelessWidget {
  const _BackupStatusBody(this.title, this.entries, this.notice);

  final String title;
  final List<KvEntry> entries;
  final Widget? notice;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: RmText.sans(13.5, weight: FontWeight.w600, color: rm.fg),
          ),
          const SizedBox(height: 12),
          _BackupKvList(entries: entries),
          if (notice != null) ...[const SizedBox(height: 12), notice!],
        ],
      ),
    );
  }
}

class _BackupStatusFooter extends StatelessWidget {
  const _BackupStatusFooter({required this.footnote, required this.actions});

  final String footnote;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final buttons = Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.end,
            children: actions,
          );
          if (constraints.maxWidth < 360) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(footnote, style: RmText.sans(11.5, color: rm.fg3)),
                const SizedBox(height: 12),
                buttons,
              ],
            );
          }
          return Row(
            children: [
              Expanded(
                child: Text(
                  footnote,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: RmText.sans(11.5, color: rm.fg3),
                ),
              ),
              const SizedBox(width: 14),
              buttons,
            ],
          );
        },
      ),
    );
  }
}

class _BackupTag extends StatelessWidget {
  const _BackupTag({required this.label, this.accent = false});

  final String label;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    final fg = accent ? rm.accent.base : rm.fg3;
    final bg = accent ? rm.accent.bg : rm.raised;
    final border = accent ? rm.accent.ring : rm.border;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        border: Border.all(color: border),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: RmText.mono(10.5, letterSpacing: 0.4, color: fg),
      ),
    );
  }
}

class _BackupKvList extends StatelessWidget {
  const _BackupKvList({required this.entries});

  static const int _rowCount = 5;
  static const double _rowHeight = 34;

  final List<KvEntry> entries;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < _rowCount; i++) ...[
          if (i != 0) const SizedBox(height: 4),
          SizedBox(
            height: _rowHeight,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 108,
                  child: Text(
                    i < entries.length ? entries[i].label : '',
                    style: RmText.mono(11, color: rm.fg3),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: DefaultTextStyle.merge(
                    style: RmText.mono(11.8, color: rm.fg),
                    child: i < entries.length
                        ? _BackupKvValue(child: entries[i].value)
                        : const SizedBox.shrink(),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _BackupKvValue extends StatelessWidget {
  const _BackupKvValue({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DefaultTextStyle.merge(
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      child: child,
    );
  }
}

class _SnapshotRow extends StatefulWidget {
  const _SnapshotRow({
    required this.entry,
    required this.isLast,
    required this.sizeLabel,
    required this.busy,
    required this.onOpen,
    required this.onRestore,
    required this.onDelete,
  });

  final BackupHistoryEntry entry;
  final bool isLast;
  final String sizeLabel;
  final bool busy;
  final VoidCallback onOpen;
  final VoidCallback onRestore;
  final VoidCallback onDelete;

  @override
  State<_SnapshotRow> createState() => _SnapshotRowState();
}

class _SnapshotRowState extends State<_SnapshotRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    final entry = widget.entry;
    final rowBg = _hover ? rm.raised : rm.raised.withAlpha(0);
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        decoration: BoxDecoration(
          color: rowBg,
          border: widget.isLast
              ? null
              : Border(bottom: BorderSide(color: rm.border)),
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final description = Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    _SnapshotTypeTag(entry: entry),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        entry.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: RmText.sans(
                          13.5,
                          weight: FontWeight.w700,
                          color: rm.fg,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  entry.detail,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: RmText.mono(11.5, color: rm.fg3),
                ),
              ],
            );
            final actions = Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.end,
              children: [
                RmButton(
                  onPressed: widget.onOpen,
                  size: RmButtonSize.sm,
                  leading: const RmIcon('folder', size: 11),
                  label: '打开',
                ),
              ],
            );

            if (constraints.maxWidth < 760) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _relativeTimeLabel(entry.createdAt),
                    style: RmText.mono(12, color: rm.fg2),
                  ),
                  const SizedBox(height: 10),
                  description,
                  const SizedBox(height: 10),
                  Text(
                    entry.steamBuildLabel,
                    style: RmText.mono(12, color: rm.fg2),
                  ),
                  const SizedBox(height: 8),
                  Text(widget.sizeLabel, style: RmText.mono(12, color: rm.fg3)),
                  const SizedBox(height: 12),
                  actions,
                ],
              );
            }

            return Row(
              children: [
                SizedBox(
                  width: 150,
                  child: Text(
                    _relativeTimeLabel(entry.createdAt),
                    style: RmText.mono(12, color: rm.fg2),
                  ),
                ),
                const SizedBox(width: 18),
                Expanded(child: description),
                const SizedBox(width: 18),
                SizedBox(
                  width: 148,
                  child: Text(
                    entry.steamBuildLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.right,
                    style: RmText.mono(12, color: rm.fg2),
                  ),
                ),
                const SizedBox(width: 18),
                SizedBox(
                  width: 92,
                  child: Text(
                    widget.sizeLabel,
                    textAlign: TextAlign.right,
                    style: RmText.mono(12, color: rm.fg3),
                  ),
                ),
                const SizedBox(width: 22),
                actions,
              ],
            );
          },
        ),
      ),
    );
  }
}

class _SnapshotTypeTag extends StatelessWidget {
  const _SnapshotTypeTag({required this.entry});

  final BackupHistoryEntry entry;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    final accent = entry.isManualSnapshot;
    final fg = accent ? rm.accent.base : rm.fg3;
    final bg = accent ? rm.accent.bg : rm.raised;
    final border = accent ? rm.accent.ring : rm.border;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        border: Border.all(color: border),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        entry.typeLabel,
        style: RmText.mono(10, letterSpacing: 0.3, color: fg),
      ),
    );
  }
}

class _SnapshotLoading extends StatelessWidget {
  const _SnapshotLoading();

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 44),
      child: Center(child: CircularProgressIndicator(color: rm.accent.base)),
    );
  }
}

class _SnapshotError extends StatelessWidget {
  const _SnapshotError({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Text(message, style: RmText.body(color: rm.danger)),
    );
  }
}

class _SnapshotEmpty extends StatelessWidget {
  const _SnapshotEmpty({
    this.title = '暂无恢复快照',
    this.subtitle = '写入游戏后，这里会出现可恢复到写入前状态的快照。',
  });

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 44),
      child: Column(
        children: [
          Text(title, style: RmText.emptyTitle(color: rm.fg)),
          const SizedBox(height: 6),
          Text(subtitle, style: RmText.body(color: rm.fg3)),
        ],
      ),
    );
  }
}

BaselineBackupEntry? _primaryBaseline(List<BaselineBackupEntry> entries) {
  for (final entry in entries) {
    if (entry.isCurrent) return entry;
  }
  for (final entry in entries) {
    if (entry.isPending) return entry;
  }
  return entries.isEmpty ? null : entries.first;
}

String _baselineKind(BaselineBackupEntry entry) {
  if (entry.isCurrent) return 'vanilla';
  if (entry.isPending) return 'pending vanilla';
  if (entry.isOld) return 'old vanilla';
  return 'vanilla';
}

String _baselineWhen(BaselineBackupEntry entry) {
  final state = entry.isCurrent
      ? '当前基线'
      : entry.isPending
      ? '待验证'
      : entry.isOld
      ? '历史基线'
      : '基线';
  return '$state · ${_relativeTimeLabel(entry.sortDate)}';
}

String _baselineFiles(BaselineBackupEntry entry) {
  final parts = <String>[
    '${entry.fileCount} 个文件',
    if (entry.bankCount > 0) '${entry.bankCount} 个 .bank',
    if (entry.radioInfoCount > 0)
      'RadioInfo_*.xml (${entry.radioInfoCount} 种语言)',
    if (entry.stringTableCount > 0) '${entry.stringTableCount} 个语言表',
  ];
  return parts.join(' · ');
}

String _backupCreatedLabel(String? value) {
  if (value == null || value.trim().isEmpty) return '尚未写入';
  return _relativeTimeLabel(DateTime.tryParse(value));
}

String _relativeTimeLabel(DateTime? value) {
  if (value == null) return '未知时间';
  final date = value.toLocal();
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(date.year, date.month, date.day);
  final time = '${_two(date.hour)}:${_two(date.minute)}';
  if (day == today) return '今天 $time';
  if (day == today.subtract(const Duration(days: 1))) return '昨天 $time';
  if (date.year == now.year) return '${date.month}/${date.day} $time';
  return '${date.year}-${_two(date.month)}-${_two(date.day)} $time';
}

String _folderSizeLabel(String path) {
  final dir = Directory(path);
  if (!dir.existsSync()) return '未知';
  var total = 0;
  try {
    for (final entity in dir.listSync(recursive: true, followLinks: false)) {
      if (entity is File) total += entity.lengthSync();
    }
  } on FileSystemException {
    return '未知';
  }
  return _formatBytes(total);
}

String _snapshotSizeLabel(BackupHistoryEntry entry) {
  if (entry.totalSize > 0) return _formatBytes(entry.totalSize);
  return 'manifest';
}

String _formatBytes(int value) {
  if (value <= 0) return '0 B';
  if (value < 1024) return '$value B';
  final kb = value / 1024;
  if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
  final mb = kb / 1024;
  if (mb < 1024) return '${mb.toStringAsFixed(1)} MB';
  final gb = mb / 1024;
  return '${gb.toStringAsFixed(2)} GB';
}

String _snapshotFilterLabel(_SnapshotFilter filter) {
  return switch (filter) {
    _SnapshotFilter.all => '恢复',
    _SnapshotFilter.manual => '手动',
    _SnapshotFilter.automatic => '自动',
  };
}

String _two(int value) => value.toString().padLeft(2, '0');
