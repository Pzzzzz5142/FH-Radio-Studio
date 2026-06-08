import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/playlist_plan.dart';
import '../../domain/radio_library.dart';
import '../../state/studio_state.dart';
import '../../state/playlist_catalog_state.dart';
import '../../state/playlist_plan_state.dart';
import '../../state/track_timing_state.dart';
import '../../theme/app_theme.dart';
import '../../theme/text_styles.dart';
import '../../theme/tokens.dart';
import '../../widgets/package_build_notice_dialog.dart';
import '../../widgets/package_loudness_dialog.dart';
import '../../widgets/rm_banner.dart';
import '../../widgets/rm_button.dart';
import '../../widgets/rm_chip.dart';
import '../../widgets/rm_icon.dart';
import '../../widgets/rm_panel.dart';
import '../../widgets/rm_segmented.dart';
import 'playlist_state.dart';
import 'radio_column.dart';
import 'switch_mode_modal.dart';
import 'track_card.dart';

const double _playlistPageMaxWidth = 1280;

class PlaylistScreen extends ConsumerStatefulWidget {
  const PlaylistScreen({super.key});

  @override
  ConsumerState<PlaylistScreen> createState() => _PlaylistScreenState();
}

class _PlaylistScreenState extends ConsumerState<PlaylistScreen> {
  bool _matches(PlaylistState s, PoolTrack t) {
    final q = s.search.trim().toLowerCase();
    if (q.isEmpty) return true;
    return t.title.toLowerCase().contains(q) ||
        t.artist.toLowerCase().contains(q) ||
        t.source.toLowerCase().contains(q);
  }

  bool _matchesRef(PlaylistState s, TrackRef t) {
    final q = s.search.trim().toLowerCase();
    if (q.isEmpty) return true;
    return t.title.toLowerCase().contains(q) ||
        t.artist.toLowerCase().contains(q);
  }

  Future<void> _assign(
    _PlaylistDragData data,
    RadioStation radio,
    String playlistType,
    bool isCustom,
    int maxSlots,
    List<TrackRef> originalTracks,
  ) async {
    bool assignTrack() {
      final assigned = ref
          .read(playlistProvider.notifier)
          .assignToRadio(
            data.track.id,
            radio.code,
            playlistType,
            maxSlots: maxSlots,
            originRadioCode: data.originRadioCode,
            originPlaylistType: data.originPlaylistType,
          );
      if (!assigned && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${radio.name} 已达到 $maxSlots 首上限。')),
        );
      }
      return assigned;
    }

    if (!isCustom) {
      await SwitchModeModal.show(
        context,
        radio: radio,
        track: data.track,
        originalTracks: originalTracks,
        onConfirm: assignTrack,
      );
      return;
    }
    assignTrack();
  }

  Future<void> _restoreBuiltin(
    RadioStation radio,
    String playlistType,
    List<PoolTrack> assignedTracks,
  ) async {
    final ok = await _confirmRestoreBuiltin(
      context,
      radio: radio,
      playlistType: playlistType,
      assignedTracks: assignedTracks,
    );
    if (!ok || !mounted) return;
    ref
        .read(playlistProvider.notifier)
        .restoreBuiltin(radio.code, playlistType);
  }

  Future<void> _handlePoolDrop(
    BuildContext context,
    PlaylistState s,
    PlaylistCatalog catalog,
    PlaylistPlan plan,
    _PlaylistDragData data,
  ) async {
    final originRadio = data.originRadioCode;
    final originType = data.originPlaylistType;
    if (originRadio == null || originType == null) return;

    final assignments = plan.assignmentsForRadio(originRadio, originType);
    if (assignments.length <= 1) {
      final radio = _radioByCode(catalog, originRadio);
      if (radio == null) return;
      final assignedTracks = s.tracksOfRadio(originRadio, originType, plan);
      await _restoreBuiltin(radio, originType, assignedTracks);
      return;
    }

    ref
        .read(playlistProvider.notifier)
        .unassign(
          data.track.id,
          radioCode: originRadio,
          playlistType: originType,
        );
  }

  RadioStation? _radioByCode(PlaylistCatalog catalog, String code) {
    for (final radio in catalog.radios) {
      if (radio.code == code) return radio;
    }
    return null;
  }

  String _playlistLabel(String playlistType) {
    return PlaylistAssignment.playlistLabel(playlistType);
  }

  Future<bool> _confirmRestoreBuiltin(
    BuildContext context, {
    required RadioStation radio,
    required String playlistType,
    required List<PoolTrack> assignedTracks,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      barrierColor: RmTokens.modalBackdrop,
      builder: (context) {
        final rm = context.rm;
        return Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.all(40),
          child: Container(
            width: 500,
            constraints: const BoxConstraints(maxHeight: 620),
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
                      Text('恢复游戏原版', style: RmText.microLabel(color: rm.warn)),
                      const SizedBox(height: 8),
                      Text(
                        '把 ${radio.name} 的${_playlistLabel(playlistType)}列表恢复为 builtin？',
                        style: RmText.modalH2(color: rm.fg),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '这会清空当前列表里的自建曲目分配；下次生成包时，这个列表不再参与替换。',
                        style: RmText.sans(13, color: rm.fg3, height: 1.45),
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
                        Text(
                          '将移出的自建曲目',
                          style: RmText.microLabel(color: rm.fg3),
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            for (final track in assignedTracks)
                              RmChip(
                                label: track.title,
                                variant: RmChipVariant.danger,
                                showDot: true,
                              ),
                          ],
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
                        onPressed: () => Navigator.of(context).pop(false),
                        label: '取消',
                      ),
                      const SizedBox(width: 10),
                      RmButton(
                        onPressed: () => Navigator.of(context).pop(true),
                        variant: RmButtonVariant.primary,
                        leading: const RmIcon('undo', size: 12),
                        label: '恢复 builtin',
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
    return result == true;
  }

  Future<void> _setSplitPlaylistTypes(
    BuildContext context,
    bool value,
    PlaylistPlan plan,
  ) async {
    final notifier = ref.read(playlistProvider.notifier);
    if (value) {
      final ok = await _confirmSplitPlaylistTypes(context);
      if (!ok || !mounted) return;
      notifier.setSplitPlaylistTypes(true);
      return;
    }

    var keepType = 'FreeRoam';
    if (plan.hasSplitPlaylistDifferences) {
      final selected = await _choosePlaylistTypeToKeep(context);
      if (selected == null || !mounted) return;
      keepType = selected;
    }
    final synced = plan.syncPlaylistTypesFrom(keepType);
    ref.read(playlistPlanProvider.notifier).replaceWith(synced);
    ref.read(playlistProvider.notifier)
      ..setMode(
        keepType == 'Event' ? PlaylistMode.event : PlaylistMode.freeroam,
      )
      ..setSplitPlaylistTypes(false);
  }

  Future<bool> _confirmSplitPlaylistTypes(BuildContext context) async {
    final result = await showDialog<bool>(
      context: context,
      barrierColor: RmTokens.modalBackdrop,
      builder: (context) {
        final rm = context.rm;
        return Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.all(40),
          child: Container(
            width: 520,
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
                  padding: const EdgeInsets.fromLTRB(24, 22, 24, 18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('高级模式', style: RmText.microLabel(color: rm.info)),
                      const SizedBox(height: 8),
                      Text('分开编辑漫游和比赛？', style: RmText.modalH2(color: rm.fg)),
                      const SizedBox(height: 10),
                      Text(
                        '开启后会显示 FreeRoam 和 Event 两张独立列表。FreeRoam 用于开放世界漫游，Event 用于比赛内播放。',
                        style: RmText.sans(13, color: rm.fg3, height: 1.45),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '关闭时如果两边不一致，需要选择保留哪一张，并用它覆盖另一张。',
                        style: RmText.sans(13, color: rm.fg3, height: 1.45),
                      ),
                    ],
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
                        onPressed: () => Navigator.of(context).pop(false),
                        label: '取消',
                      ),
                      const SizedBox(width: 10),
                      RmButton(
                        onPressed: () => Navigator.of(context).pop(true),
                        variant: RmButtonVariant.primary,
                        leading: const RmIcon('list', size: 12),
                        label: '打开',
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
    return result == true;
  }

  Future<String?> _choosePlaylistTypeToKeep(BuildContext context) {
    return showDialog<String>(
      context: context,
      barrierColor: RmTokens.modalBackdrop,
      builder: (context) {
        final rm = context.rm;
        return Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.all(40),
          child: Container(
            width: 520,
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
                  padding: const EdgeInsets.fromLTRB(24, 22, 24, 18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('合并列表', style: RmText.microLabel(color: rm.warn)),
                      const SizedBox(height: 8),
                      Text('关闭前保留哪张列表？', style: RmText.modalH2(color: rm.fg)),
                      const SizedBox(height: 10),
                      Text(
                        '当前 FreeRoam 和 Event 不一致。关闭高级模式后，会用你选择的列表覆盖另一张，并回到统一编辑。',
                        style: RmText.sans(13, color: rm.fg3, height: 1.45),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.fromLTRB(24, 14, 24, 22),
                  decoration: BoxDecoration(
                    border: Border(top: BorderSide(color: rm.border)),
                  ),
                  child: Wrap(
                    alignment: WrapAlignment.end,
                    spacing: 10,
                    runSpacing: 8,
                    children: [
                      RmButton(
                        onPressed: () => Navigator.of(context).pop(),
                        label: '取消',
                      ),
                      RmButton(
                        onPressed: () => Navigator.of(context).pop('FreeRoam'),
                        leading: const RmIcon('map', size: 12),
                        label: '保留漫游',
                      ),
                      RmButton(
                        onPressed: () => Navigator.of(context).pop('Event'),
                        variant: RmButtonVariant.primary,
                        leading: const RmIcon('flag', size: 12),
                        label: '保留比赛',
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _copyGameLayoutToPackage(BuildContext context) async {
    final catalog = ref.read(gamePlaylistCatalogProvider);
    final messenger = ScaffoldMessenger.of(context);
    if (catalog.failed) {
      messenger.showSnackBar(
        SnackBar(content: Text(catalog.error ?? '没有找到可读取的游戏内播放列表。')),
      );
      return;
    }
    final copied = ref.read(playlistProvider.notifier).copyGameLayout(catalog);
    ref.read(playlistCatalogViewProvider.notifier).state =
        PlaylistCatalogView.package;
    messenger.showSnackBar(
      SnackBar(content: Text('已复制当前游戏内排布：$copied 首自建曲目。')),
    );
  }

  Future<void> _preparePackageFromUi(BuildContext context) async {
    final cli = ref.read(studioProvider.notifier);
    final preview = cli.buildPackageLoudnessPreview();
    final loudnessOffsetLu = await showPackageLoudnessDialog(
      context,
      referenceMedianLufs: preview.referenceMedianLufs,
      initialOffsetLu: preview.initialOffsetLu,
      previewInputLufs: preview.previewInputLufs,
      previewSource: preview.source,
      previewTitle: preview.previewTitle,
      previewArtist: preview.previewArtist,
      currentPackageOffsetLu: preview.currentPackageOffsetLu,
    );
    if (loudnessOffsetLu == null) return;
    if (!mounted) return;
    if (!context.mounted) return;
    final built = await cli.buildPackage(
      loudnessOffsetLu: loudnessOffsetLu,
      plan: ref.read(effectivePlaylistPlanProvider),
    );
    if (!mounted) return;
    if (!context.mounted) return;
    final latest = ref.read(studioProvider);
    if (built) {
      final summary = latest.lastPackageSummary;
      await showPackageBuildSuccessDialog(
        context,
        detail: summary?.detail ?? '准备包已生成。',
        trackPreview: summary?.trackPreview ?? '未读取到曲目信息',
        packageDir: latest.lastPackageDir,
      );
      return;
    }
    final handledMissing = await _handleMissingPlaylistSources(context, latest);
    if (!mounted) return;
    if (!context.mounted || handledMissing) return;
    await showPackageBuildNoticeDialog(
      context,
      message: _latestBuildPackageMessage(latest),
      languageChanged: !latest.languageSelectionMatchesGame,
      showPlaylistAction: false,
    );
  }

  Future<bool> _handleMissingPlaylistSources(
    BuildContext context,
    StudioState latest,
  ) async {
    final missing = ref.read(effectivePlaylistPlanProvider).missingSources();
    if (missing.isEmpty) return false;
    final action = await showMissingPlaylistSourcesDialog(
      context,
      sources: missing,
    );
    if (!mounted || !context.mounted) return true;
    if (action != MissingPlaylistSourcesAction.cleanup) return true;
    final cleaned = await ref
        .read(studioProvider.notifier)
        .cleanupMissingPlaylistSources(missing);
    if (!mounted || !context.mounted) return true;
    ref.read(playlistPlanProvider.notifier).removeDeletedSources(missing);
    ref.read(trackTimingProvider.notifier).reload();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(cleaned > 0 ? '已删除 $cleaned 首失效歌曲。' : '没有发现需要删除的失效歌曲。'),
      ),
    );
    return true;
  }

  String _latestBuildPackageMessage(StudioState state) {
    for (final line in state.log.reversed) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      if (trimmed.startsWith('==')) continue;
      if (trimmed.startsWith('执行：')) continue;
      if (trimmed.startsWith('退出码：')) continue;
      return trimmed;
    }
    return '准备包没有生成。';
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(playlistProvider);
    final cli = ref.watch(studioProvider);
    final view = ref.watch(playlistCatalogViewProvider);
    final catalog = ref.watch(playlistCatalogProvider);
    final baselineCatalog = ref.watch(baselinePlaylistCatalogProvider);
    final plan = ref.watch(effectivePlaylistPlanProvider);
    final poolPlan = _poolAssignmentPlan(catalog, plan, s.pool);
    final editingPlan = plan.hasDraft ? plan : poolPlan;
    final pool = s
        .poolForDisplay(editingPlan)
        .where((t) => _matches(s, t))
        .toList();

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: _playlistPageMaxWidth),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(40, 36, 40, 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _pageHead(context, cli, view),
              if (cli.projectEditingLocked) ...[
                const SizedBox(height: 12),
                RmBanner(
                  kind: RmBannerKind.warn,
                  title: cli.projectEditingLockTitle,
                  body:
                      '${cli.projectEditingLockMessage} 播放列表拖拽、恢复、复制和写包暂时不可用。',
                ),
              ],
              const SizedBox(height: 18),
              if (catalog.failed)
                Expanded(
                  child: SingleChildScrollView(
                    child: _catalogError(context, catalog, cli, view),
                  ),
                )
              else ...[
                _toolbar(context, s, catalog, view, editingPlan, cli),
                const SizedBox(height: 18),
                Expanded(
                  child: _board(
                    context,
                    s,
                    pool,
                    catalog,
                    baselineCatalog,
                    editingPlan,
                    editingPlan,
                    view,
                    cli,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _pageHead(
    BuildContext context,
    StudioState cli,
    PlaylistCatalogView view,
  ) {
    final rm = context.rm;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('播放列表', style: RmText.pageH1(color: rm.fg)),
              const SizedBox(height: 6),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 620),
                child: Text(
                  '在“游戏内”查看当前 RadioInfo，只读确认 custom / builtin；在“准备包”编辑下一次要生成的排布。',
                  style: RmText.body(color: rm.fg3),
                ),
              ),
            ],
          ),
        ),
        if (view == PlaylistCatalogView.package)
          RmButton(
            onPressed: cli.busy || cli.projectEditingLocked
                ? null
                : () => unawaited(_preparePackageFromUi(context)),
            variant: RmButtonVariant.primary,
            leading: const RmIcon('music', size: 12),
            label: '构建准备包',
            tooltip: cli.projectEditingLocked
                ? cli.projectEditingLockMessage
                : null,
          ),
      ],
    );
  }

  Widget _toolbar(
    BuildContext context,
    PlaylistState s,
    PlaylistCatalog catalog,
    PlaylistCatalogView view,
    PlaylistPlan plan,
    StudioState cli,
  ) {
    final rm = context.rm;
    final editingLocked = cli.projectEditingLocked;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: rm.panel,
        border: Border.all(color: rm.border),
        borderRadius: BorderRadius.circular(RmTokens.rLg),
      ),
      child: LayoutBuilder(
        builder: (context, _) {
          final viewSwitch = _PlaylistViewSwitch(
            value: view,
            onChanged: (value) {
              ref.read(playlistCatalogViewProvider.notifier).state = value;
            },
          );
          final segmented = RmSegmented<PlaylistMode>(
            value: s.mode,
            onChanged: ref.read(playlistProvider.notifier).setMode,
            options: const [
              RmSegmentedOption(
                value: PlaylistMode.freeroam,
                label: 'FreeRoam · 漫游',
              ),
              RmSegmentedOption(value: PlaylistMode.event, label: 'Event · 比赛'),
            ],
          );
          final splitSwitch = _SplitPlaylistSwitch(
            value: s.splitPlaylistTypes,
            onChanged: editingLocked
                ? null
                : (value) =>
                      unawaited(_setSplitPlaylistTypes(context, value, plan)),
          );
          final baseChip = Tooltip(
            message: catalog.badgeTooltip,
            child: RmChip(
              label: catalog.badgeLabel,
              variant: switch (catalog.origin) {
                PlaylistCatalogOrigin.package => RmChipVariant.accent,
                PlaylistCatalogOrigin.failed => RmChipVariant.warn,
                PlaylistCatalogOrigin.game => RmChipVariant.defaultC,
              },
              showDot: true,
            ),
          );
          final search = SizedBox(
            width: 280,
            child: TextField(
              onChanged: ref.read(playlistProvider.notifier).setSearch,
              style: RmText.sans(12.5, color: rm.fg),
              decoration: InputDecoration(
                isDense: true,
                hintText: '搜索曲目 / 艺术家',
                hintStyle: RmText.sans(12.5, color: rm.fg4),
                prefixIcon: Padding(
                  padding: const EdgeInsets.only(left: 10, right: 8),
                  child: RmIcon('search', size: 13, color: rm.fg3),
                ),
                prefixIconConstraints: const BoxConstraints(minWidth: 30),
                filled: true,
                fillColor: rm.raised,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 9,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(RmTokens.rSm),
                  borderSide: BorderSide(color: rm.border),
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
            ),
          );
          final Widget? copyAction = view == PlaylistCatalogView.package
              ? RmButton(
                  onPressed: editingLocked
                      ? null
                      : () => unawaited(_copyGameLayoutToPackage(context)),
                  leading: const RmIcon('copy', size: 12),
                  label: '复制游戏内排布',
                  tooltip: editingLocked ? cli.projectEditingLockMessage : null,
                )
              : null;
          const customChip = RmChip(
            label: 'custom · 自建',
            variant: RmChipVariant.accent,
            showDot: true,
          );
          const builtinChip = RmChip(
            label: 'builtin · 锁定',
            variant: RmChipVariant.muted,
            leading: RmIcon('lock', size: 10),
          );
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                spacing: 10,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [viewSwitch, baseChip, ?copyAction],
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 10,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  splitSwitch,
                  if (s.splitPlaylistTypes) segmented,
                  search,
                  customChip,
                  builtinChip,
                ],
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _catalogError(
    BuildContext context,
    PlaylistCatalog catalog,
    StudioState cli,
    PlaylistCatalogView view,
  ) {
    final rm = context.rm;
    return RmPanel(
      title: '播放列表读取失败',
      subtitle: '没有可用的真实 RadioInfo 文件',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            catalog.error ?? '没有找到可读取的 RadioInfo_*.xml。',
            style: RmText.body(color: rm.fg2),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              RmButton(
                onPressed: cli.busy
                    ? null
                    : ref.read(studioProvider.notifier).refreshStatus,
                leading: const RmIcon('search', size: 12),
                label: '刷新状态',
              ),
              if (view == PlaylistCatalogView.package)
                RmButton(
                  onPressed: cli.busy || cli.projectEditingLocked
                      ? null
                      : () => unawaited(_preparePackageFromUi(context)),
                  variant: RmButtonVariant.primary,
                  leading: const RmIcon('music', size: 12),
                  label: '构建准备包',
                  tooltip: cli.projectEditingLocked
                      ? cli.projectEditingLockMessage
                      : null,
                ),
            ],
          ),
        ],
      ),
    );
  }

  PlaylistPlan _poolAssignmentPlan(
    PlaylistCatalog catalog,
    PlaylistPlan plan,
    List<PoolTrack> pool,
  ) {
    if (plan.hasDraft || catalog.failed) return plan;
    final detected = playlistPlanFromCatalog(
      catalog,
      pool,
      includeBuiltinTargets: false,
    );
    return detected.assignments.isEmpty ? plan : detected;
  }

  Widget _board(
    BuildContext context,
    PlaylistState s,
    List<PoolTrack> pool,
    PlaylistCatalog catalog,
    PlaylistCatalog? baselineCatalog,
    PlaylistPlan plan,
    PlaylistPlan poolPlan,
    PlaylistCatalogView view,
    StudioState cli,
  ) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const gap = 12.0;

        if (view != PlaylistCatalogView.package) {
          return SingleChildScrollView(
            child: _radioBoard(
              context,
              s,
              catalog,
              baselineCatalog,
              plan,
              view,
              cli,
            ),
          );
        }

        final poolPanelWidth = constraints.maxWidth >= 1120
            ? 280.0
            : (constraints.maxWidth >= 780 ? 260.0 : 220.0);

        if (constraints.maxWidth < 780) {
          final radioBoardWidth = (constraints.maxWidth - poolPanelWidth - gap)
              .clamp(0.0, double.infinity)
              .toDouble();
          final radioCanvasWidth = radioBoardWidth < 640
              ? 640.0
              : radioBoardWidth;
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: SizedBox(
                    width: radioCanvasWidth,
                    child: SingleChildScrollView(
                      child: _radioBoard(
                        context,
                        s,
                        catalog,
                        baselineCatalog,
                        plan,
                        view,
                        cli,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: gap),
              SizedBox(
                key: const ValueKey('playlist-pool-side-panel'),
                width: poolPanelWidth,
                child: _poolColumn(context, s, pool, catalog, poolPlan, cli),
              ),
            ],
          );
        }

        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: SingleChildScrollView(
                child: _radioBoard(
                  context,
                  s,
                  catalog,
                  baselineCatalog,
                  plan,
                  view,
                  cli,
                ),
              ),
            ),
            const SizedBox(width: gap),
            SizedBox(
              key: const ValueKey('playlist-pool-side-panel'),
              width: poolPanelWidth,
              child: _poolColumn(context, s, pool, catalog, poolPlan, cli),
            ),
          ],
        );
      },
    );
  }

  Widget _radioBoard(
    BuildContext context,
    PlaylistState s,
    PlaylistCatalog catalog,
    PlaylistCatalog? baselineCatalog,
    PlaylistPlan plan,
    PlaylistCatalogView view,
    StudioState cli,
  ) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const gap = 12.0;
        const minColumnWidth = 205.0;
        const columnHeight = 480.0;
        final columns = (constraints.maxWidth + gap) ~/ (minColumnWidth + gap);
        final columnCount = columns.clamp(1, 5);
        final columnWidth =
            (constraints.maxWidth - gap * (columnCount - 1)) / columnCount;
        return Wrap(
          key: const ValueKey('playlist-radio-board'),
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final r in catalog.radios)
              SizedBox(
                key: ValueKey('playlist-radio-column-${r.code}'),
                width: columnWidth,
                height: columnHeight,
                child: _radioColumn(
                  context,
                  s,
                  r,
                  catalog,
                  baselineCatalog,
                  plan,
                  view,
                  cli,
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _radioColumn(
    BuildContext context,
    PlaylistState s,
    RadioStation r,
    PlaylistCatalog catalog,
    PlaylistCatalog? baselineCatalog,
    PlaylistPlan plan,
    PlaylistCatalogView view,
    StudioState cli,
  ) {
    final playlistType = _displayPlaylistType(s, r, catalog, plan);
    final readOnly = view == PlaylistCatalogView.game;
    final editingLocked = cli.projectEditingLocked;
    final draftBuiltin =
        !readOnly && plan.hasBuiltinOverride(r.code, playlistType);
    final draftCustom =
        !readOnly &&
        !draftBuiltin &&
        plan.hasAssignmentsForRadio(r.code, playlistType);
    final catalogCustom =
        catalog.modeOfList(r.code, playlistType) == StationMode.custom;
    final isCustom = readOnly
        ? catalogCustom
        : draftCustom || (!draftBuiltin && catalogCustom);
    final customTracks = s.tracksOfRadio(r.code, playlistType, plan);
    final assignedTracks = customTracks.where((t) => _matches(s, t)).toList();
    final originalCatalog = draftBuiltin
        ? (baselineCatalog ?? catalog)
        : catalog;
    final baselineTrackRefs = baselineCatalog?.tracksOfRadio(
      r.code,
      playlistType,
    );
    final originalTrackRefs = originalCatalog.tracksOfRadio(
      r.code,
      playlistType,
    );
    final originalTracks = originalTrackRefs
        .where((t) => _matchesRef(s, t))
        .toList();
    final originalTrackCount = originalTrackRefs.length;
    final count = isCustom && (customTracks.isNotEmpty || draftCustom)
        ? customTracks.length
        : originalTrackCount;
    final replaceableCapacity = baselineTrackRefs?.length ?? r.slot;
    final capacity = isCustom ? replaceableCapacity : originalTrackCount;

    Widget buildColumn({required bool isDragOver}) {
      final children = <Widget>[];
      if (isCustom) {
        if (!readOnly && (customTracks.isNotEmpty || draftCustom)) {
          for (final t in assignedTracks) {
            children.add(
              _draggableTrack(
                t,
                originRadioCode: r.code,
                originPlaylistType: playlistType,
                locked: editingLocked,
              ),
            );
          }
        } else {
          for (final t in originalTracks) {
            children.add(
              TrackCard(
                title: t.title,
                artist: t.artist,
                durationSec: t.durationSec,
                locked: readOnly,
                custom: t.modded || readOnly,
              ),
            );
          }
        }
      } else {
        for (final t in originalTracks) {
          children.add(
            TrackCard(
              title: t.title,
              artist: t.artist,
              durationSec: t.durationSec,
              locked: true,
              custom: t.modded,
            ),
          );
        }
      }
      return PlaylistColumn.radio(
        radio: r,
        isCustom: isCustom,
        count: count,
        capacity: capacity,
        isDragOver: isDragOver,
        onRestoreBuiltin: !readOnly && !editingLocked && isCustom
            ? () => unawaited(_restoreBuiltin(r, playlistType, customTracks))
            : null,
        children: children,
      );
    }

    if (readOnly || editingLocked) return buildColumn(isDragOver: false);

    return DragTarget<_PlaylistDragData>(
      onWillAcceptWithDetails: (details) {
        return _canAcceptTrack(
          details.data,
          r,
          plan,
          playlistType,
          replaceableCapacity,
        );
      },
      onAcceptWithDetails: (details) {
        _assign(
          details.data,
          r,
          playlistType,
          isCustom,
          replaceableCapacity,
          originalTrackRefs,
        );
      },
      builder: (context, candidate, rejected) {
        return buildColumn(isDragOver: candidate.isNotEmpty);
      },
    );
  }

  bool _canAcceptTrack(
    _PlaylistDragData data,
    RadioStation radio,
    PlaylistPlan plan,
    String playlistType,
    int maxSlots,
  ) {
    if (plan.assignmentFor(
          source: data.track.source,
          radioCode: radio.code,
          playlistType: playlistType,
        ) !=
        null) {
      return true;
    }
    final playlistState = ref.read(playlistProvider);
    if (!playlistState.splitPlaylistTypes &&
        plan.assignmentFor(
              source: data.track.source,
              radioCode: radio.code,
              playlistType: _otherPlaylistType(playlistType),
            ) !=
            null) {
      return true;
    }
    return plan.assignmentsForRadio(radio.code, playlistType).length < maxSlots;
  }

  String _otherPlaylistType(String playlistType) {
    return PlaylistAssignment.normalizePlaylistType(playlistType) == 'Event'
        ? 'FreeRoam'
        : 'Event';
  }

  String _displayPlaylistType(
    PlaylistState s,
    RadioStation radio,
    PlaylistCatalog catalog,
    PlaylistPlan plan,
  ) {
    if (s.splitPlaylistTypes) {
      return s.mode == PlaylistMode.event ? 'Event' : 'FreeRoam';
    }
    final freeAssignments = plan.assignmentsForRadio(radio.code, 'FreeRoam');
    final eventAssignments = plan.assignmentsForRadio(radio.code, 'Event');
    if (freeAssignments.isEmpty && eventAssignments.isNotEmpty) {
      return 'Event';
    }
    final freeMode = catalog.modeOfList(radio.code, 'FreeRoam');
    final eventMode = catalog.modeOfList(radio.code, 'Event');
    if (freeMode != StationMode.custom && eventMode == StationMode.custom) {
      return 'Event';
    }
    return 'FreeRoam';
  }

  Widget _poolColumn(
    BuildContext context,
    PlaylistState s,
    List<PoolTrack> pool,
    PlaylistCatalog catalog,
    PlaylistPlan plan,
    StudioState cli,
  ) {
    final assignmentLabelsByTrackKey = _assignmentLabelsByTrackKey(plan, s);
    Widget buildColumn({required bool isDragOver}) {
      return PlaylistColumn.poolBuilder(
        count: pool.length,
        isDragOver: isDragOver,
        itemCount: pool.length,
        itemBuilder: (context, index) {
          final track = pool[index];
          final trackKey = PlaylistAssignment.keyForPath(track.source);
          return _draggableTrack(
            track,
            assignmentLabels: assignmentLabelsByTrackKey[trackKey] ?? const [],
            locked: cli.projectEditingLocked,
          );
        },
      );
    }

    final column = buildColumn(isDragOver: false);
    if (cli.projectEditingLocked) return column;

    return DragTarget<_PlaylistDragData>(
      onWillAcceptWithDetails: (_) {
        return true;
      },
      onAcceptWithDetails: (details) {
        unawaited(_handlePoolDrop(context, s, catalog, plan, details.data));
      },
      builder: (context, candidate, rejected) {
        return buildColumn(isDragOver: candidate.isNotEmpty);
      },
    );
  }

  Map<String, List<String>> _assignmentLabelsByTrackKey(
    PlaylistPlan plan,
    PlaylistState s,
  ) {
    final labelsByTrackKey = <String, List<String>>{};
    final seenByTrackKey = <String, Set<String>>{};
    final assignments =
        plan.assignments.values
            .where((assignment) => assignment.isAssigned)
            .toList()
          ..sort(_compareAssignmentsForDisplay);

    for (final assignment in assignments) {
      final label = s.splitPlaylistTypes
          ? assignment.listLabel
          : '${assignment.radioCode} · ${assignment.slot}';
      final dedupeKey = s.splitPlaylistTypes
          ? label
          : '${assignment.radioCode}|${assignment.slot}';
      for (final trackKey in _assignmentTrackKeys(assignment)) {
        final seen = seenByTrackKey.putIfAbsent(trackKey, () => <String>{});
        if (!seen.add(dedupeKey)) continue;
        labelsByTrackKey.putIfAbsent(trackKey, () => <String>[]).add(label);
      }
    }

    return labelsByTrackKey;
  }

  Set<String> _assignmentTrackKeys(PlaylistAssignment assignment) {
    final keys = <String>{};
    if (assignment.trackKey.isNotEmpty) keys.add(assignment.trackKey);
    if (assignment.source.trim().isNotEmpty) {
      keys.add(PlaylistAssignment.keyForPath(assignment.source));
    }
    return keys;
  }

  int _compareAssignmentsForDisplay(
    PlaylistAssignment a,
    PlaylistAssignment b,
  ) {
    final byRadio = a.radioCode.compareTo(b.radioCode);
    if (byRadio != 0) return byRadio;
    final byType = _playlistTypeSortKey(
      a.playlistType,
    ).compareTo(_playlistTypeSortKey(b.playlistType));
    if (byType != 0) return byType;
    final bySlot = a.slot.compareTo(b.slot);
    if (bySlot != 0) return bySlot;
    return a.source.toLowerCase().compareTo(b.source.toLowerCase());
  }

  int _playlistTypeSortKey(String type) {
    return PlaylistAssignment.normalizePlaylistType(type) == 'FreeRoam' ? 0 : 1;
  }

  Widget _draggableTrack(
    PoolTrack t, {
    String? originRadioCode,
    String? originPlaylistType,
    List<String> assignmentLabels = const [],
    bool locked = false,
  }) {
    if (locked) {
      return TrackCard.fromPoolTrack(
        t,
        assignmentLabels: assignmentLabels,
        locked: true,
      );
    }
    return Draggable<_PlaylistDragData>(
      data: _PlaylistDragData(
        track: t,
        originRadioCode: originRadioCode,
        originPlaylistType: originPlaylistType,
      ),
      feedback: Material(
        color: Colors.transparent,
        child: SizedBox(
          width: 260,
          child: TrackCard.fromPoolTrack(
            t,
            dragging: true,
            assignmentLabels: assignmentLabels,
          ),
        ),
      ),
      childWhenDragging: Opacity(
        opacity: 0.35,
        child: TrackCard.fromPoolTrack(t, assignmentLabels: assignmentLabels),
      ),
      child: TrackCard.fromPoolTrack(t, assignmentLabels: assignmentLabels),
    );
  }
}

class _SplitPlaylistSwitch extends StatelessWidget {
  const _SplitPlaylistSwitch({required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    if (!value) {
      return _SplitPlaylistButton(
        onPressed: onChanged == null ? null : () => onChanged!(true),
        color: rm.info,
        bg: Color.alphaBlend(rm.info.withAlpha(12), rm.raised),
        hoverBg: Color.alphaBlend(rm.info.withAlpha(22), rm.hover),
        border: rm.info.withAlpha(110),
      );
    }
    return Container(
      height: 32,
      padding: const EdgeInsets.only(left: 10, right: 6),
      decoration: BoxDecoration(
        color: value
            ? Color.alphaBlend(rm.info.withAlpha(14), rm.hover)
            : rm.raised,
        borderRadius: BorderRadius.circular(RmTokens.rSm),
        border: Border.all(color: value ? rm.info : rm.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '分场景编辑',
            style: RmText.sans(
              12,
              color: value ? rm.info : rm.fg3,
              weight: FontWeight.w500,
            ),
          ),
          const SizedBox(width: 6),
          Transform.scale(
            scale: 0.72,
            child: Switch(
              value: value,
              onChanged: onChanged,
              activeThumbColor: rm.info,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
        ],
      ),
    );
  }
}

class _SplitPlaylistButton extends StatefulWidget {
  const _SplitPlaylistButton({
    required this.onPressed,
    required this.color,
    required this.bg,
    required this.hoverBg,
    required this.border,
  });

  final VoidCallback? onPressed;
  final Color color;
  final Color bg;
  final Color hoverBg;
  final Color border;

  @override
  State<_SplitPlaylistButton> createState() => _SplitPlaylistButtonState();
}

class _SplitPlaylistButtonState extends State<_SplitPlaylistButton> {
  bool _hover = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final disabled = widget.onPressed == null;
    return MouseRegion(
      cursor: disabled ? SystemMouseCursors.basic : SystemMouseCursors.click,
      onEnter: disabled ? null : (_) => setState(() => _hover = true),
      onExit: disabled ? null : (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTapDown: disabled ? null : (_) => setState(() => _pressed = true),
        onTapUp: disabled ? null : (_) => setState(() => _pressed = false),
        onTapCancel: disabled ? null : () => setState(() => _pressed = false),
        onTap: widget.onPressed,
        child: Opacity(
          opacity: disabled ? 0.45 : 1,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            height: 32,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            transform: _pressed
                ? (Matrix4.identity()..translateByDouble(0, 0.5, 0, 0))
                : Matrix4.identity(),
            decoration: BoxDecoration(
              color: _hover ? widget.hoverBg : widget.bg,
              borderRadius: BorderRadius.circular(RmTokens.rSm),
              border: Border.all(color: widget.border),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                RmIcon('list', size: 12, color: widget.color),
                const SizedBox(width: 8),
                Text(
                  '分场景编辑',
                  style: RmText.sans(
                    12.5,
                    color: widget.color,
                    weight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PlaylistViewSwitch extends StatelessWidget {
  const _PlaylistViewSwitch({required this.value, required this.onChanged});

  final PlaylistCatalogView value;
  final ValueChanged<PlaylistCatalogView> onChanged;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: rm.raised,
        borderRadius: BorderRadius.circular(RmTokens.rSm),
        border: Border.all(color: rm.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _segment(context, PlaylistCatalogView.game, '游戏内'),
          _segment(context, PlaylistCatalogView.package, '准备包'),
        ],
      ),
    );
  }

  Widget _segment(
    BuildContext context,
    PlaylistCatalogView option,
    String label,
  ) {
    final rm = context.rm;
    final active = option == value;
    final accent = option == PlaylistCatalogView.package
        ? rm.accent.base
        : rm.info;
    final activeBg = option == PlaylistCatalogView.package
        ? Color.alphaBlend(rm.accent.base.withAlpha(16), rm.hover)
        : Color.alphaBlend(rm.info.withAlpha(14), rm.hover);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => onChanged(option),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          decoration: BoxDecoration(
            color: active ? activeBg : Colors.transparent,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            label,
            style: RmText.sans(
              12,
              color: active ? accent : rm.fg3,
              weight: active ? FontWeight.w500 : FontWeight.w400,
            ),
          ),
        ),
      ),
    );
  }
}

@immutable
class _PlaylistDragData {
  const _PlaylistDragData({
    required this.track,
    this.originRadioCode,
    this.originPlaylistType,
  });

  final PoolTrack track;
  final String? originRadioCode;
  final String? originPlaylistType;
}
