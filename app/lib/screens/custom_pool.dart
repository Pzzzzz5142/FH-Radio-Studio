import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/playlist_plan.dart';
import '../domain/radio_library.dart';
import '../state/studio_state.dart';
import '../state/custom_pool_tracks.dart';
import '../state/playlist_plan_state.dart';
import '../state/router.dart';
import '../state/track_timing_state.dart';
import '../theme/app_theme.dart';
import '../theme/text_styles.dart';
import '../theme/tokens.dart';
import '../widgets/progress_bars.dart';
import '../widgets/pending_gate.dart';
import '../widgets/rm_banner.dart';
import '../widgets/rm_button.dart';
import '../widgets/rm_chip.dart';
import '../widgets/rm_icon.dart';
import '../widgets/rm_panel.dart';
import '../widgets/rm_segmented.dart';
import '../widgets/stat_card.dart';

enum _PoolFilter { all, unconfigured, configured }

class CustomPoolScreen extends ConsumerStatefulWidget {
  const CustomPoolScreen({super.key});

  @override
  ConsumerState<CustomPoolScreen> createState() => _CustomPoolScreenState();
}

class _CustomPoolScreenState extends ConsumerState<CustomPoolScreen> {
  _PoolFilter _filter = _PoolFilter.all;
  bool _msrOnly = false;

  @override
  Widget build(BuildContext context) {
    final all = ref.watch(realPoolTracksProvider);
    final cli = ref.watch(studioProvider);
    final playlistPlan = ref.watch(effectivePlaylistPlanProvider);
    final latestPackage = cli.pendingPackageSummary ?? cli.lastPackageSummary;
    final gameMatchesLatestPackage =
        cli.fileIntegrity.checkedFiles > 0 &&
        cli.fileIntegrity.packageMatches == cli.fileIntegrity.checkedFiles;
    final configured = all.where((t) => t.configured).toList();
    final unconfigured = all.where((t) => !t.configured).toList();
    final unassigned = all.where((t) => t.assignedTo == null).toList();
    final msrTracks = all.where((t) => t.isSiren).toList();
    final panelTracks = _msrOnly ? msrTracks : all;
    final panelConfigured = panelTracks.where((t) => t.configured).toList();
    final panelUnconfigured = panelTracks.where((t) => !t.configured).toList();
    final visible = _sortForEditing(switch (_filter) {
      _PoolFilter.all => panelTracks,
      _PoolFilter.unconfigured => panelUnconfigured,
      _PoolFilter.configured => panelConfigured,
    });
    final customRadios = kRadios
        .where((r) => kStationModes[r.code] == StationMode.custom)
        .toList();
    final importing =
        cli.busy && (cli.busyLabel == '导入自建歌曲' || cli.busyLabel == '导入塞壬唱片');

    return PendingGate(
      pending: importing,
      label: cli.busyLabel == '导入塞壬唱片' ? '正在导入塞壬唱片' : '正在导入自建歌曲',
      detail: cli.busyLabel == '导入塞壬唱片'
          ? '正在从 AppData 缓存规范化音频到项目 siren，并刷新曲目信息。'
          : '正在导入音频到项目 sources，必要时转换到 48 kHz，并刷新曲目信息。',
      overlayKey: const ValueKey('custom-pool-import-gate'),
      childOpacity: 0.42,
      borderRadius: BorderRadius.zero,
      child: SizedBox.expand(
        child: SingleChildScrollView(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: RmTokens.pageDefault),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(40, 36, 40, 96),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _pageHead(context, cli),
                    const SizedBox(height: 28),
                    _statRow(
                      context,
                      total: all.length,
                      configured: configured.length,
                      unconfigured: unconfigured.length,
                      unassigned: unassigned.length,
                    ),
                    const SizedBox(height: 24),
                    _tracksPanel(
                      context,
                      totalCount: panelTracks.length,
                      visible: visible,
                      cli: cli,
                      unconfiguredCount: panelUnconfigured.length,
                      configuredCount: panelConfigured.length,
                      msrCount: msrTracks.length,
                      latestPackage: latestPackage,
                      playlistPlan: playlistPlan,
                      gameMatchesLatestPackage: gameMatchesLatestPackage,
                    ),
                    const SizedBox(height: 14),
                    _infoBanner(context, customRadios: customRadios),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _pageHead(BuildContext context, StudioState cli) {
    final rm = context.rm;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('自建歌曲', style: RmText.pageH1(color: rm.fg)),
              const SizedBox(height: 6),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: Text(
                  '你导入的所有曲目。每首歌都需要配置 6 个时间点后才能用于游戏。在「播放列表」里把它们分配到电台。',
                  style: RmText.body(color: rm.fg3),
                ),
              ),
            ],
          ),
        ),
        Row(
          children: [
            RmButton(
              onPressed: _openFirstInputFolder,
              leading: const RmIcon('folder', size: 12),
              label: '打开目录',
            ),
            const SizedBox(width: 8),
            RmButton(
              onPressed: () => context.go(RmRoutes.siren),
              leading: const RmIcon('spark', size: 12),
              label: '塞壬唱片',
            ),
            const SizedBox(width: 8),
            RmButton(
              onPressed: cli.busy ? null : _pickMusicFiles,
              variant: RmButtonVariant.primary,
              leading: const RmIcon('import', size: 12),
              label: '导入新曲目',
            ),
          ],
        ),
      ],
    );
  }

  Widget _statRow(
    BuildContext context, {
    required int total,
    required int configured,
    required int unconfigured,
    required int unassigned,
  }) {
    final rm = context.rm;
    return LayoutBuilder(
      builder: (context, c) {
        const minCellW = 180.0;
        final cols = (c.maxWidth / (minCellW + 12)).floor().clamp(1, 4);
        final cellW = (c.maxWidth - 12 * (cols - 1)) / cols;
        Widget cell(Widget w) => SizedBox(width: cellW, child: w);
        return Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            cell(
              StatCard(
                label: '池子总数',
                value: '$total',
                delta: '来自 $total 个本地文件',
              ),
            ),
            cell(
              StatCard(
                label: '已配置 · 可用',
                value: '$configured  /  $total',
                delta: '6 个时间点全部确认',
              ),
            ),
            cell(
              StatCard(
                label: '待完成',
                value: '$unconfigured',
                valueColor: unconfigured > 0 ? rm.warn : null,
                delta: '需进入编辑器确认',
              ),
            ),
            cell(
              StatCard(label: '未分配', value: '$unassigned', delta: '不在任何电台中'),
            ),
          ],
        );
      },
    );
  }

  Widget _tracksPanel(
    BuildContext context, {
    required int totalCount,
    required List<PoolTrack> visible,
    required StudioState cli,
    required int unconfiguredCount,
    required int configuredCount,
    required int msrCount,
    required PackageArtifactSummary? latestPackage,
    required PlaylistPlan playlistPlan,
    required bool gameMatchesLatestPackage,
  }) {
    final rm = context.rm;
    return RmPanel(
      title: '曲目',
      titleTrailing: _MsrOnlySwitch(
        value: _msrOnly,
        count: msrCount,
        onChanged: (value) => setState(() => _msrOnly = value),
      ),
      noPad: true,
      headerTrailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          RmSegmented<_PoolFilter>(
            value: _filter,
            onChanged: (v) => setState(() => _filter = v),
            options: [
              RmSegmentedOption(
                value: _PoolFilter.all,
                label: '全部 · $totalCount',
              ),
              RmSegmentedOption(
                value: _PoolFilter.unconfigured,
                label: '待完成 · $unconfiguredCount',
              ),
              RmSegmentedOption(
                value: _PoolFilter.configured,
                label: '已完成 · $configuredCount',
              ),
            ],
          ),
          const SizedBox(width: 12),
          RmChip(
            label: '仅自建歌曲可编辑',
            variant: RmChipVariant.muted,
            showDot: true,
          ),
        ],
      ),
      child: Column(
        children: [
          _PoolHeaderRow(),
          if (visible.isEmpty)
            _empty(context, cli, msrOnly: _msrOnly)
          else
            for (int i = 0; i < visible.length; i++)
              _PoolRow(
                track: visible[i],
                isLast: i == visible.length - 1,
                divider: rm.border,
                editingLocked: false,
                editLockMessage: '',
                latestPackage: latestPackage,
                stagedAssignment: playlistPlan.assignmentForPath(
                  visible[i].source,
                ),
                gameMatchesLatestPackage: gameMatchesLatestPackage,
                onTap: () => context.go(RmRoutes.editor(visible[i].id)),
                onDelete: () => _confirmAndDeleteTrack(context, visible[i]),
              ),
        ],
      ),
    );
  }

  Widget _empty(
    BuildContext context,
    StudioState cli, {
    required bool msrOnly,
  }) {
    final rm = context.rm;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 80),
      child: Column(
        children: [
          Text('这里空空的', style: RmText.emptyTitle(color: rm.fg)),
          const SizedBox(height: 6),
          Text(
            msrOnly ? '从塞壬唱片导入歌曲后会显示在这里' : '导入 .mp3 / .flac / .wav 开始构建你的池子',
            style: RmText.body(color: rm.fg3),
          ),
          const SizedBox(height: 16),
          RmButton(
            onPressed: cli.busy
                ? null
                : (msrOnly
                      ? () => context.go(RmRoutes.siren)
                      : _pickMusicFiles),
            variant: RmButtonVariant.primary,
            leading: RmIcon(msrOnly ? 'spark' : 'import', size: 12),
            label: msrOnly ? '前往 MSR' : '导入曲目',
          ),
        ],
      ),
    );
  }

  Widget _infoBanner(
    BuildContext context, {
    required List<RadioStation> customRadios,
  }) {
    final rm = context.rm;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: rm.panel,
        border: Border.all(color: rm.border),
        borderRadius: BorderRadius.circular(RmTokens.rMd),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              color: rm.info.withAlpha(36),
              borderRadius: BorderRadius.circular(RmTokens.rSm),
            ),
            alignment: Alignment.center,
            child: RmIcon('info', size: 14, color: rm.info),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 6,
              runSpacing: 6,
              children: [
                Text(
                  '怎么"用"这些歌？',
                  style: RmText.body(weight: FontWeight.w600, color: rm.fg),
                ),
                Text(
                  '每个电台是二选一：原版 (builtin) 或全部自建 (custom)。当前已切换为 custom 的电台：',
                  style: RmText.body(color: rm.fg2),
                ),
                if (customRadios.isEmpty)
                  Text('（无）', style: RmText.body(color: rm.fg3))
                else
                  for (final r in customRadios)
                    RmChip(
                      label: r.code,
                      variant: RmChipVariant.accent,
                      showDot: true,
                    ),
                Text(
                  '——这些电台原版 8 首已被替换。前往「播放列表」把池中曲目分配到 slot。',
                  style: RmText.body(color: rm.fg2),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _pickMusicFiles() async {
    final result = await FilePicker.pickFiles(
      dialogTitle: '导入自建歌曲',
      type: FileType.custom,
      allowedExtensions: const ['flac', 'wav', 'mp3', 'm4a', 'ogg', 'aac'],
      allowMultiple: true,
    );
    final paths = result?.files
        .map((file) => file.path)
        .whereType<String>()
        .toList(growable: false);
    if (paths == null || paths.isEmpty) return;
    await ref.read(studioProvider.notifier).importMusicPaths(paths);
  }

  void _openFirstInputFolder() {
    final dir = Directory(ref.read(studioProvider).sourcesDir);
    if (!dir.existsSync()) return;
    if (Platform.isWindows) {
      Process.start('explorer', [dir.path]);
    } else if (Platform.isMacOS) {
      Process.start('open', [dir.path]);
    } else if (Platform.isLinux) {
      Process.start('xdg-open', [dir.path]);
    }
  }

  Future<void> _confirmAndDeleteTrack(
    BuildContext context,
    PoolTrack track,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      barrierColor: RmTokens.modalBackdrop,
      builder: (context) => _DeleteTrackDialog(track: track),
    );
    if (ok != true || !mounted) return;
    try {
      final handled = await ref
          .read(studioProvider.notifier)
          .deleteMusicPath(track.source);
      if (!context.mounted) return;
      if (!handled) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('删除失败：项目当前不可编辑或文件无法处理。')));
        return;
      }
      ref.read(trackTimingProvider.notifier).reload();
      ref.read(playlistPlanProvider.notifier).removeDeletedSource(track.source);
    } on FileSystemException catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('删除失败：${error.message}')));
    }
  }
}

class _PoolHeaderRow extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: rm.border)),
      ),
      child: Row(
        children: [
          const SizedBox(width: 36 + 16),
          Expanded(flex: 14, child: _h(context, '曲目')),
          const SizedBox(width: 16),
          Expanded(flex: 12, child: _h(context, '来源文件')),
          const SizedBox(width: 16),
          SizedBox(width: 220, child: _h(context, '分配至')),
          const SizedBox(width: 16),
          SizedBox(width: 110, child: _h(context, '配置')),
          const SizedBox(width: 16),
          SizedBox(width: 90, child: _h(context, '添加')),
          const SizedBox(width: 110),
        ],
      ),
    );
  }

  Widget _h(BuildContext context, String s) => Text(
    s.toUpperCase(),
    style: RmText.mono(10.5, color: context.rm.fg3, letterSpacing: 0.1 * 10.5),
  );
}

class _PoolRow extends StatefulWidget {
  const _PoolRow({
    required this.track,
    required this.isLast,
    required this.divider,
    required this.editingLocked,
    required this.editLockMessage,
    required this.latestPackage,
    required this.stagedAssignment,
    required this.gameMatchesLatestPackage,
    required this.onTap,
    required this.onDelete,
  });

  final PoolTrack track;
  final bool isLast;
  final Color divider;
  final bool editingLocked;
  final String editLockMessage;
  final PackageArtifactSummary? latestPackage;
  final PlaylistAssignment? stagedAssignment;
  final bool gameMatchesLatestPackage;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  State<_PoolRow> createState() => _PoolRowState();
}

class _PoolRowState extends State<_PoolRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    final t = widget.track;
    final packageAssignment = widget.latestPackage?.assignmentForSource(
      t.source,
    );
    final gameAssignment = widget.gameMatchesLatestPackage
        ? packageAssignment
        : null;
    final preparedTag = _preparedTag(
      staged: widget.stagedAssignment,
      packaged: packageAssignment,
      hasPackage: widget.latestPackage != null,
    );
    final art = _hover ? rm.accent.base : rm.fg3;
    final sourceDisplay = t.isSiren
        ? '${t.sourceLabel ?? 'MSR'} · ${t.albumName ?? t.source}'
        : t.source;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          decoration: BoxDecoration(
            color: _hover ? rm.raised : Colors.transparent,
            border: widget.isLast
                ? null
                : Border(bottom: BorderSide(color: widget.divider)),
          ),
          child: Row(
            children: [
              _PoolArtwork(track: t, iconColor: art),
              const SizedBox(width: 16),
              Expanded(
                flex: 14,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            t.title,
                            style: RmText.rowTitle(color: rm.fg),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (t.isSiren) ...[
                          const SizedBox(width: 8),
                          const RmChip(
                            label: 'MSR',
                            variant: RmChipVariant.accent,
                            showDot: true,
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      t.isSiren && t.albumName != null
                          ? '${t.artist} · ${t.albumName} · ${formatDurationShort(t.durationSec)} · ${t.bpm} BPM · ${t.key}'
                          : '${t.artist} · ${formatDurationShort(t.durationSec)} · ${t.bpm} BPM · ${t.key}',
                      style: RmText.mono(11.5, color: rm.fg3),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                flex: 12,
                child: Text(
                  sourceDisplay,
                  style: RmText.mono(11, color: rm.fg3),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 16),
              SizedBox(
                width: 220,
                child: Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    _assignmentChip(
                      prefix: '游戏',
                      assignment: gameAssignment,
                      known:
                          widget.gameMatchesLatestPackage &&
                          widget.latestPackage != null,
                      assignedVariant: RmChipVariant.accent,
                    ),
                    Tooltip(
                      message: preparedTag.tooltip,
                      waitDuration: const Duration(milliseconds: 350),
                      child: RmChip(
                        label: preparedTag.label,
                        variant: preparedTag.variant,
                        showDot: true,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              SizedBox(
                width: 110,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ProgressBars(value: t.confirmed),
                    const SizedBox(height: 4),
                    Text(
                      t.configured ? '已配置' : '${t.confirmed}/4',
                      style: RmText.mono(
                        10.5,
                        color: t.configured ? rm.accent.base : rm.fg3,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              SizedBox(
                width: 90,
                child: Text(t.added, style: RmText.mono(11, color: rm.fg3)),
              ),
              SizedBox(
                width: 110,
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 120),
                  opacity: _hover ? 1 : 0.4,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      RmButton(
                        onPressed: widget.onTap,
                        size: RmButtonSize.sm,
                        label: t.configured ? '查看' : '继续配置',
                      ),
                      const SizedBox(width: 4),
                      RmButton.icon(
                        onPressed: widget.editingLocked
                            ? null
                            : widget.onDelete,
                        icon: const RmIcon('trash', size: 12),
                        variant: RmButtonVariant.ghost,
                        tooltip: widget.editingLocked
                            ? widget.editLockMessage
                            : '删除',
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _assignmentChip({
    required String prefix,
    required PackageTrackAssignment? assignment,
    required bool known,
    required RmChipVariant assignedVariant,
  }) {
    final label = assignment == null
        ? (known ? '$prefix 未包含' : '$prefix 未检测')
        : '$prefix ${assignment.label}';
    final tooltip = assignment == null
        ? (known
              ? '游戏中位置\n当前游戏文件等于最新准备包，但这首歌不在准备包播放列表里。'
              : '游戏中位置\n当前游戏文件未检测为最新准备包，无法可靠判断这首歌在游戏里的位置。')
        : '游戏中位置\n当前游戏文件已检测为最新准备包：${assignment.label}。';
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 350),
      child: RmChip(
        label: label,
        variant: assignment == null ? RmChipVariant.muted : assignedVariant,
        showDot: true,
      ),
    );
  }

  _PreparedTag _preparedTag({
    required PlaylistAssignment? staged,
    required PackageTrackAssignment? packaged,
    required bool hasPackage,
  }) {
    if (staged != null) {
      final dirty = !_samePreparedTarget(staged, packaged);
      final target = staged.isAssigned
          ? '${staged.radioCode} · ${PlaylistAssignment.playlistLabel(staged.playlistType)} slot ${staged.slot}'
          : '未包含';
      return _PreparedTag(
        label: '包 $target${dirty ? '*' : ''}',
        variant: dirty
            ? RmChipVariant.warn
            : (staged.isAssigned
                  ? RmChipVariant.defaultC
                  : RmChipVariant.muted),
        tooltip: dirty
            ? (staged.isAssigned
                  ? '准备包位置\n已在播放列表中改到 $target，但还没重新准备包。* 表示当前只是本地改动。'
                  : '准备包位置\n已在播放列表中移出这首歌，但还没重新准备包。* 表示当前只是本地改动。')
            : '准备包位置\n本地播放列表计划和最新准备包一致：$target。',
      );
    }
    if (packaged != null) {
      return _PreparedTag(
        label: '包 ${packaged.label}',
        variant: RmChipVariant.defaultC,
        tooltip: '准备包位置\n已经写入最新准备包：${packaged.label}。',
      );
    }
    return _PreparedTag(
      label: hasPackage ? '包 未包含' : '包 未检测',
      variant: RmChipVariant.muted,
      tooltip: hasPackage ? '准备包位置\n最新准备包没有包含这首歌。' : '准备包位置\n还没有可读取的最新准备包。',
    );
  }

  bool _samePreparedTarget(
    PlaylistAssignment staged,
    PackageTrackAssignment? packaged,
  ) {
    if (!staged.isAssigned) return packaged == null;
    return packaged != null &&
        packaged.radioLabel == staged.radioCode &&
        packaged.slot == staged.slot &&
        packaged.normalizedPlaylistTypes.contains(staged.playlistType);
  }
}

class _PoolArtwork extends StatelessWidget {
  const _PoolArtwork({required this.track, required this.iconColor});

  final PoolTrack track;
  final Color iconColor;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    final coverPath = track.coverArtPath?.trim();
    final coverFile = coverPath == null || coverPath.isEmpty
        ? null
        : File(coverPath);
    final hasCover = coverFile != null && coverFile.existsSync();
    final borderColor = hasCover
        ? rm.border
        : track.isSiren
        ? rm.accent.base.withAlpha(160)
        : rm.border;

    return Container(
      width: 32,
      height: 32,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: track.isSiren ? Colors.black : rm.raised,
        border: Border.all(color: borderColor),
        borderRadius: BorderRadius.circular(RmTokens.rSm),
      ),
      alignment: Alignment.center,
      child: hasCover
          ? Image.file(
              coverFile,
              width: 32,
              height: 32,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => _fallback(),
            )
          : _fallback(),
    );
  }

  Widget _fallback() {
    if (track.isSiren) {
      return Image.asset(
        'assets/images/monster_siren_share_logo.png',
        width: 32,
        height: 32,
        fit: BoxFit.cover,
      );
    }
    return RmIcon('music', size: 14, color: iconColor);
  }
}

class _DeleteTrackDialog extends StatelessWidget {
  const _DeleteTrackDialog({required this.track});

  final PoolTrack track;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    final assignment = track.assignedTo == null
        ? '未分配'
        : '${track.assignedTo} · slot ${track.slot ?? '-'}';
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
                      color: rm.dangerBg,
                      border: Border.all(color: rm.danger.withAlpha(77)),
                      borderRadius: BorderRadius.circular(RmTokens.rMd),
                    ),
                    child: RmIcon('trash', size: 17, color: rm.danger),
                  ),
                  const SizedBox(width: 13),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'DELETE TRACK',
                          style: RmText.mono(
                            11,
                            color: rm.danger,
                            letterSpacing: 0.12 * 11,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text('删除这首自建歌曲？', style: RmText.modalH2(color: rm.fg)),
                      ],
                    ),
                  ),
                  RmButton.icon(
                    onPressed: () => Navigator.of(context).pop(false),
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
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      '这会删除项目 sources 里的音频文件，并清理这首歌的时间点配置、metadata 缓存和播放列表草稿引用。已经写入游戏的文件不会在这一步被修改。',
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
                            track.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: RmText.sans(
                              13,
                              weight: FontWeight.w700,
                              color: rm.fg,
                            ),
                          ),
                          const SizedBox(height: 5),
                          Text(
                            track.artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: RmText.mono(11.5, color: rm.fg2),
                          ),
                          const SizedBox(height: 5),
                          Text(
                            assignment,
                            style: RmText.mono(11.5, color: rm.fg3),
                          ),
                          const SizedBox(height: 5),
                          Text(
                            track.source,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: RmText.mono(11, color: rm.fg3),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),
                    const RmBanner(
                      kind: RmBannerKind.danger,
                      title: '删除提醒：',
                      body:
                          '删除后无法从 FH Radio Studio 内恢复这份项目副本。需要保留时，请先打开目录手动复制。',
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
                    variant: RmButtonVariant.danger,
                    label: '确认删除',
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

List<PoolTrack> _sortForEditing(Iterable<PoolTrack> tracks) {
  final items = tracks.toList(growable: false);
  final indexed = <({int index, PoolTrack track})>[
    for (var index = 0; index < items.length; index += 1)
      (index: index, track: items[index]),
  ];
  indexed.sort((a, b) {
    final byCompleteness = _configurationCompleteness(
      a.track,
    ).compareTo(_configurationCompleteness(b.track));
    if (byCompleteness != 0) return byCompleteness;
    if (a.track.configured != b.track.configured) {
      return a.track.configured ? 1 : -1;
    }
    if (a.track.isSiren != b.track.isSiren) {
      return a.track.isSiren ? -1 : 1;
    }
    return a.index.compareTo(b.index);
  });
  return [for (final item in indexed) item.track];
}

int _configurationCompleteness(PoolTrack track) {
  if (track.configured) return 4;
  return track.confirmed.clamp(0, 4).toInt();
}

class _PreparedTag {
  const _PreparedTag({
    required this.label,
    required this.variant,
    required this.tooltip,
  });

  final String label;
  final RmChipVariant variant;
  final String tooltip;
}

class _MsrOnlySwitch extends StatelessWidget {
  const _MsrOnlySwitch({
    required this.value,
    required this.count,
    required this.onChanged,
  });

  final bool value;
  final int count;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    final color = value ? rm.accent.base : rm.fg3;
    final border = value ? rm.accent.ring : rm.border;
    final bg = value
        ? Color.alphaBlend(rm.accent.base.withAlpha(10), rm.panel)
        : Colors.transparent;
    return Tooltip(
      message: '仅显示从塞壬唱片 MSR 导入的歌曲',
      waitDuration: const Duration(milliseconds: 350),
      child: Semantics(
        label: '仅显示 MSR 导入歌曲',
        toggled: value,
        button: true,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            key: const ValueKey('custom-pool-msr-only-switch'),
            behavior: HitTestBehavior.opaque,
            onTap: () => onChanged(!value),
            child: Container(
              height: 24,
              padding: const EdgeInsets.symmetric(horizontal: 9),
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
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'MSR · $count',
                    style: RmText.sans(
                      11.5,
                      color: color,
                      weight: value ? FontWeight.w600 : FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
