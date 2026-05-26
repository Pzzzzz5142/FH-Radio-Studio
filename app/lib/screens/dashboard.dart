import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;

import '../core/playlist_plan.dart';
import '../state/studio_state.dart';
import '../theme/app_theme.dart';
import '../theme/text_styles.dart';
import '../theme/tokens.dart';
import '../widgets/ai_environment_dialog.dart';
import '../widgets/package_build_notice_dialog.dart';
import '../widgets/rm_button.dart';
import '../widgets/rm_icon.dart';

const _dashboardPlaylistRoute = '/playlist';
const _dashboardHeroSideWidth = 341.0;
const _dashboardHeroStatusSlotHeight = 24.0;
const _dashboardHeroStatusCompactSlotHeight = 48.0;
const _dashboardHeroTitleSlotHeight = 32.0;
const _dashboardHeroTitleCompactSlotHeight = 62.0;
const _dashboardHeroDescriptionSlotHeight = 44.0;
const _dashboardHeroDescriptionCompactSlotHeight = 66.0;
const _dashboardHeroSideHeadingSlotHeight = 16.0;
const _dashboardHeroPrimaryCtaHeight = 38.0;
const _dashboardHeroPrimaryHelperSlotHeight = 34.0;
const _dashboardHeroStatusTitleGap = 4.0;
const _dashboardHeroTitleDescriptionGap = 4.0;
const _dashboardHeroDescriptionActivityGap = 6.0;

class DashboardScreen extends ConsumerStatefulWidget {
  const DashboardScreen({
    super.key,
    this.initialToolOpen = false,
    this.initialFileOpen = false,
    this.initialDiagOpen = false,
  });

  final bool initialToolOpen;
  final bool initialFileOpen;
  final bool initialDiagOpen;

  @override
  ConsumerState<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends ConsumerState<DashboardScreen> {
  late final TextEditingController _gameDirCtrl;
  final _settingsKey = GlobalKey();
  final _toolKey = GlobalKey();
  final _fileKey = GlobalKey();
  final _diagKey = GlobalKey();

  late bool _openTool;
  late bool _openFile;
  late bool _openDiag;

  @override
  void initState() {
    super.initState();
    _openTool = widget.initialToolOpen;
    _openFile = widget.initialFileOpen;
    _openDiag = widget.initialDiagOpen;
    _gameDirCtrl = TextEditingController(
      text: ref.read(studioProvider).gameDir,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(studioProvider.notifier).startupFullCheckOnce();
    });
  }

  @override
  void dispose() {
    _gameDirCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<StudioState>(studioProvider, (previous, next) {
      if (previous?.gameDir != next.gameDir &&
          _gameDirCtrl.text != next.gameDir) {
        _gameDirCtrl.text = next.gameDir;
      }
    });

    final s = ref.watch(studioProvider);
    final c = ref.read(studioProvider.notifier);
    final model = _DashboardModel.fromState(context, s);

    return SingleChildScrollView(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: RmTokens.pageDefault),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(40, 28, 40, 96),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _PageHead(
                  busy: s.busy,
                  scanning: _dashboardScanning(s),
                  onRefresh: s.busy
                      ? null
                      : () => c.refreshStatus(verifyFiles: true),
                ),
                const SizedBox(height: 18),
                _HeroConsole(
                  model: model,
                  state: s,
                  onPrimary: () => _handlePrimary(context, s, c, model),
                  onSecondary: () => _handleSecondary(context, s, c, model),
                  onTertiary: () => _handleTertiary(context, s, model),
                ),
                const SizedBox(height: 16),
                _StatusPillars(
                  model: model,
                  onTool: () => _openAndScroll(_DetailTarget.tool),
                  onGame: () => _openAndScroll(_DetailTarget.settings),
                  onFiles: () => _openAndScroll(_DetailTarget.file),
                ),
                const SizedBox(height: 24),
                _SettingsStrip(
                  key: _settingsKey,
                  state: s,
                  controller: c,
                  gameDirController: _gameDirCtrl,
                  onPickDirectory: () => _pickGameDirectory(c),
                ),
                const SizedBox(height: 24),
                _DetailsStack(
                  toolKey: _toolKey,
                  fileKey: _fileKey,
                  diagKey: _diagKey,
                  state: s,
                  controller: c,
                  toolOpen: _openTool,
                  fileOpen: _openFile,
                  diagOpen: _openDiag,
                  onToggleTool: () => setState(() => _openTool = !_openTool),
                  onToggleFile: () => setState(() => _openFile = !_openFile),
                  onToggleDiag: () => setState(() => _openDiag = !_openDiag),
                  onInstallTools: () => _installToolsFromUi(context, c),
                  onSyncAi: () => _syncAiFromUi(context, s, c),
                  onCreateBaseline: () =>
                      _confirmCreatePristineBaseline(context, c),
                  onDeploy: () => _confirmDeploy(context, s, c),
                  onBackupPending: () =>
                      _confirmBackupPendingBaseline(context, c),
                  onPreparePending: () =>
                      _confirmPreparePendingPackage(context, c),
                  onPromotePending: () =>
                      _confirmPendingPromotion(context, c, state: s),
                  onDiscardPending: () => _confirmDiscardPending(context, c),
                  onApplyCurrentBaseline: () =>
                      _confirmApplyBaseline(context, c, usePending: false),
                  onApplyPendingBaseline: () =>
                      _confirmApplyBaseline(context, c, usePending: true),
                  onDeployOldPackage: () =>
                      _confirmDeployChoice(context, c, pending: false),
                  onDeployPendingPackage: () =>
                      _confirmDeployChoice(context, c, pending: true),
                  onBumpBuild: () => _confirmBumpBuild(context, c),
                  onRebuildBaseline: () =>
                      _confirmRebuildBaselineFromGame(context, c),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _openAndScroll(_DetailTarget target) {
    setState(() {
      if (target == _DetailTarget.tool) _openTool = true;
      if (target == _DetailTarget.file) _openFile = true;
      if (target == _DetailTarget.diag) _openDiag = true;
    });
    final key = switch (target) {
      _DetailTarget.settings => _settingsKey,
      _DetailTarget.tool => _toolKey,
      _DetailTarget.file => _fileKey,
      _DetailTarget.diag => _diagKey,
    };
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final context = key.currentContext;
      if (context == null) return;
      Scrollable.ensureVisible(
        context,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        alignment: 0.04,
      );
    });
  }

  Future<void> _handlePrimary(
    BuildContext context,
    StudioState s,
    StudioController c,
    _DashboardModel model,
  ) async {
    switch (model.scenario) {
      case _DashboardScenario.scanning:
        _openAndScroll(_DetailTarget.diag);
      case _DashboardScenario.fileCheckPending:
        await c.verifyFileIntegrity();
      case _DashboardScenario.blocking:
        await _installToolsFromUi(context, c);
      case _DashboardScenario.gameDirMissing:
        _openAndScroll(_DetailTarget.settings);
      case _DashboardScenario.noBaseline:
        await _confirmCreatePristineBaseline(context, c);
      case _DashboardScenario.baselineBroken:
      case _DashboardScenario.gameUpdate:
      case _DashboardScenario.conflict:
      case _DashboardScenario.pending:
        _openAndScroll(_DetailTarget.file);
      case _DashboardScenario.confirmation:
        final target = _confirmationTargetFor(s);
        if (target == _ConfirmationTarget.oldBaseline ||
            target == _ConfirmationTarget.oldPackage) {
          await _confirmDiscardPending(context, c);
        } else {
          await _confirmPendingPromotion(context, c, state: s);
        }
      case _DashboardScenario.buildBump:
        await _confirmBumpBuild(context, c);
      case _DashboardScenario.readyToWrite:
        await _confirmDeploy(context, s, c);
      case _DashboardScenario.previousDeployed:
      case _DashboardScenario.readyToPrepare:
      case _DashboardScenario.deployed:
        await _preparePackageFromUi(context, c);
    }
  }

  Future<void> _handleSecondary(
    BuildContext context,
    StudioState s,
    StudioController c,
    _DashboardModel model,
  ) async {
    switch (model.scenario) {
      case _DashboardScenario.scanning:
        _openAndScroll(_DetailTarget.diag);
      case _DashboardScenario.fileCheckPending:
        _openAndScroll(_DetailTarget.file);
      case _DashboardScenario.blocking:
        await c.refreshToolchainStatus();
      case _DashboardScenario.gameDirMissing:
        await c.refreshStatus();
      case _DashboardScenario.noBaseline:
      case _DashboardScenario.baselineBroken:
        _openAndScroll(_DetailTarget.file);
      case _DashboardScenario.gameUpdate:
        await _confirmBackupPendingBaseline(context, c);
      case _DashboardScenario.conflict:
        await _confirmBackupPendingBaseline(context, c);
      case _DashboardScenario.pending:
        if (s.pendingPackageReady) {
          await _confirmPendingPromotion(context, c, state: s);
        } else if (!s.currentPackageReady) {
          if (context.mounted) context.go(_dashboardPlaylistRoute);
        } else {
          await _confirmPreparePendingPackage(context, c);
        }
      case _DashboardScenario.confirmation:
        if (_confirmationTargetFor(s) == _ConfirmationTarget.pendingPackage &&
            s.currentPackageReady) {
          await _confirmDeployChoice(context, c, pending: false);
        } else {
          await _confirmApplyBaseline(context, c, usePending: false);
        }
      case _DashboardScenario.buildBump:
        _openAndScroll(_DetailTarget.file);
      case _DashboardScenario.readyToWrite:
        await _preparePackageFromUi(context, c);
      case _DashboardScenario.readyToPrepare:
        if (context.mounted) context.go(_dashboardPlaylistRoute);
      case _DashboardScenario.previousDeployed:
      case _DashboardScenario.deployed:
        if (context.mounted) context.go(_dashboardPlaylistRoute);
    }
  }

  void _handleTertiary(
    BuildContext context,
    StudioState s,
    _DashboardModel model,
  ) {
    switch (model.scenario) {
      case _DashboardScenario.scanning:
        _openAndScroll(_DetailTarget.diag);
      case _DashboardScenario.fileCheckPending:
        _openAndScroll(_DetailTarget.file);
      case _DashboardScenario.blocking:
        _openAndScroll(_DetailTarget.tool);
      case _DashboardScenario.gameDirMissing:
        _openAndScroll(_DetailTarget.settings);
      case _DashboardScenario.gameUpdate:
      case _DashboardScenario.conflict:
      case _DashboardScenario.pending:
      case _DashboardScenario.confirmation:
      case _DashboardScenario.noBaseline:
      case _DashboardScenario.baselineBroken:
      case _DashboardScenario.buildBump:
        _openAndScroll(_DetailTarget.file);
      case _DashboardScenario.readyToPrepare:
      case _DashboardScenario.readyToWrite:
        context.go(_dashboardPlaylistRoute);
      case _DashboardScenario.previousDeployed:
      case _DashboardScenario.deployed:
        _openAndScroll(_DetailTarget.file);
    }
  }

  Future<void> _pickGameDirectory(StudioController c) async {
    final path = await FilePicker.getDirectoryPath(
      dialogTitle: '选择 FH6 安装目录',
      initialDirectory: Directory(_gameDirCtrl.text).existsSync()
          ? _gameDirCtrl.text
          : null,
    );
    if (path == null || path.trim().isEmpty) return;
    c.setGameDir(path);
    unawaited(c.refreshStatus());
  }

  Future<void> _preparePackageFromUi(
    BuildContext context,
    StudioController c,
  ) async {
    final built = await c.buildPackage();
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
    final handledMissing = await _handleMissingPlaylistSources(
      context,
      c,
      latest,
    );
    if (!context.mounted || handledMissing) return;
    final action = await showPackageBuildNoticeDialog(
      context,
      message: _latestBuildPackageMessage(latest),
      languageChanged: !latest.languageSelectionMatchesGame,
    );
    if (action != PackageBuildNoticeAction.openPlaylist) return;
    if (!context.mounted) return;
    context.go(_dashboardPlaylistRoute);
  }

  Future<bool> _handleMissingPlaylistSources(
    BuildContext context,
    StudioController c,
    StudioState latest,
  ) async {
    final missing = PlaylistPlanStore.read(latest.projectDir).missingSources();
    if (missing.isEmpty) return false;
    final action = await showMissingPlaylistSourcesDialog(
      context,
      sources: missing,
    );
    if (!context.mounted) return true;
    if (action != MissingPlaylistSourcesAction.cleanup) return true;
    final cleaned = await c.cleanupMissingPlaylistSources(missing);
    if (!context.mounted) return true;
    _toast(context, cleaned > 0 ? '已删除 $cleaned 首失效歌曲。' : '没有发现需要删除的失效歌曲。');
    return true;
  }

  Future<void> _installToolsFromUi(
    BuildContext context,
    StudioController c,
  ) async {
    final ok = await c.installTools();
    if (!context.mounted || ok) return;
    final latest = ref.read(studioProvider);
    _toast(
      context,
      latest.toolInstallFailureSummary ?? '本地处理组件修复失败，展开高级诊断查看日志。',
      danger: true,
    );
  }

  Future<void> _syncAiFromUi(
    BuildContext context,
    StudioState state,
    StudioController c,
  ) async {
    await showAiEnvironmentSyncDialog(
      context: context,
      state: state,
      controller: c,
      latestState: () => ref.read(studioProvider),
    );
  }

  Future<void> _confirmDeploy(
    BuildContext context,
    StudioState s,
    StudioController c,
  ) async {
    if (!s.fileIntegrity.hasCurrentBaseline) {
      await _confirmCreatePristineBaseline(context, c);
      return;
    }
    if (s.baselineIntegrityBroken) {
      _toast(
        context,
        '${s.baselineWorkflowLockTitle}${s.baselineWorkflowLockMessage}',
        danger: true,
      );
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      barrierColor: RmTokens.modalBackdrop,
      builder: (context) => _DeployPreflightDialog(state: s),
    );
    if (ok == true) await c.deployLastPackage();
  }

  Future<void> _confirmCreatePristineBaseline(
    BuildContext context,
    StudioController c,
  ) async {
    final plan = await c.previewPristineBaselinePlan();
    if (!context.mounted || plan == null) return;
    final ok = await _confirmChecklist(
      context,
      title: '创建原始备份',
      body:
          '这会把当前 FH6 受保护文件记录为原始备份，用来区分官方文件、准备包和新游戏文件。请只在 fresh install 或 Steam 验证完整性之后执行。',
      action: '创建原始备份',
      checks: [
        '我确认 Forza Horizon 6 没有运行',
        '我确认当前游戏文件来自官方完整安装',
        '我理解之后写入和新文件流程都会以这 ${plan.fileCount} 个文件作为安全参照',
      ],
    );
    if (ok) await c.createPristineBaseline();
  }

  Future<void> _confirmBackupPendingBaseline(
    BuildContext context,
    StudioController c,
  ) async {
    final ok = await _confirmChecklist(
      context,
      title: '先保存这批新游戏文件？',
      body:
          '这会把当前游戏目录里的新文件保存成一份待确认记录，方便你之后选择接受新版本、写回旧的基线，或基于新文件构建测试准备包。不会写入游戏。',
      action: '保存新文件记录',
      checks: const [
        '我理解这些文件可能来自 FH6 更新或第三方修改',
        '我确认这一步只保存待验证记录，不写入游戏',
        '我确认 FH6 已退出，当前文件状态可以用于对照',
      ],
    );
    if (ok) await c.createPendingBaselineOnly();
  }

  Future<void> _confirmPreparePendingPackage(
    BuildContext context,
    StudioController c,
  ) async {
    final ok = await _confirmChecklist(
      context,
      title: '生成测试准备包',
      body: 'App 会先保存当前这批新游戏文件，再用当前准备包里的曲目安排重新构建一个测试准备包。构建失败时不会写入游戏。',
      action: '生成测试准备包',
      checks: const ['我理解这些文件可能来自 FH6 更新或第三方修改', '我确认用当前准备包里的曲目安排重新构建测试准备包'],
    );
    if (!ok) return;
    final built = await c.createPendingBaselineAndBuildPackage();
    if (!context.mounted) return;
    final latest = ref.read(studioProvider);
    if (built && latest.pendingPackageSummary != null) {
      final summary = latest.pendingPackageSummary!;
      await showPackageBuildSuccessDialog(
        context,
        title: '测试准备包已完成',
        detail: summary.detail,
        trackPreview: summary.trackPreview,
        packageDir: latest.pendingPackageDir,
      );
    } else {
      final action = await showPackageBuildNoticeDialog(
        context,
        title: '没有生成测试准备包',
        message: latest.pendingPackageBuildFailed
            ? latest.pendingPackageBuildFailureSummary
            : _latestBuildPackageMessage(latest),
        languageChanged: !latest.languageSelectionMatchesGame,
      );
      if (action == PackageBuildNoticeAction.openPlaylist && context.mounted) {
        context.go(_dashboardPlaylistRoute);
      }
    }
  }

  Future<void> _confirmPendingPromotion(
    BuildContext context,
    StudioController c, {
    StudioState? state,
  }) async {
    final target = state == null ? null : _confirmationTargetFor(state);
    final packageConfirmation = target == _ConfirmationTarget.pendingPackage;
    final ok = await _confirmChecklist(
      context,
      title: packageConfirmation ? '确认测试准备包可用' : '确认新游戏文件可用',
      body: packageConfirmation
          ? '当前游戏文件已经等于测试准备包。只有进游戏测试确认可用后，才应该把这批新文件和测试准备包设为当前版本。'
          : '当前游戏文件已经等于这批新游戏文件。只有确认新版本可用后，才应该把它设为新的原始备份。',
      action: '确认这是可用的',
      checks: packageConfirmation
          ? const [
              '我已经进游戏验证测试准备包可以正常播放',
              '我确认这批新文件和测试准备包可以成为当前版本',
              '我理解旧原始备份会移入历史备份',
            ]
          : const [
              '我已经确认当前游戏文件来自可用的新版本',
              '我确认这批新游戏文件可以成为新的原始备份',
              '我理解旧原始备份会移入历史备份',
            ],
    );
    if (ok) await c.confirmPendingBaseline();
  }

  Future<void> _confirmDiscardPending(
    BuildContext context,
    StudioController c,
  ) async {
    final ok = await _confirm(
      context,
      title: '放弃这批新游戏文件？',
      body: '这只会删除这份待确认记录，不会修改游戏目录。适合测试失败后重新等待游戏更新或重新生成。',
      action: '放弃',
      danger: true,
    );
    if (ok) await c.discardPendingBaseline();
  }

  Future<void> _confirmApplyBaseline(
    BuildContext context,
    StudioController c, {
    required bool usePending,
  }) async {
    final ok = await _confirmChecklist(
      context,
      title: usePending ? '写回新游戏文件？' : '写回旧的基线？',
      body: usePending
          ? '这会把已保存的新游戏文件直接覆盖到 FH6。不会创建新的恢复日志。'
          : '这会把原始备份里的旧的基线直接覆盖到 FH6。不会创建新的恢复日志。',
      action: usePending ? '写回新游戏文件' : '写回旧的基线',
      danger: true,
      checks: const [
        '我确认 Forza Horizon 6 没有运行',
        '我理解这会覆盖本地游戏文件',
        '我确认当前游戏文件可以被覆盖',
      ],
    );
    if (!ok) return;
    if (usePending) {
      await c.applyPendingBaseline();
    } else {
      await c.applyCurrentBaseline();
    }
  }

  Future<void> _confirmDeployChoice(
    BuildContext context,
    StudioController c, {
    required bool pending,
  }) async {
    final ok = await _confirmChecklist(
      context,
      title: pending ? '写入测试准备包？' : '写入旧准备包？',
      body: pending
          ? '这会强制写入基于新游戏文件重新构建的测试准备包。测试成功后再确认新版本可用。'
          : '这会强制写入旧准备包。它可能仍能工作，但如果 FH6 文件结构更新过，风险会更高。',
      action: pending ? '写入测试准备包' : '写入旧准备包',
      danger: true,
      checks: const ['我确认 Forza Horizon 6 没有运行', '我理解这是一次强制写入，用于测试当前游戏版本'],
    );
    if (!ok) return;
    if (pending) {
      await c.deployPendingPackage();
    } else {
      await c.deployOldPackage();
    }
  }

  Future<void> _confirmBumpBuild(
    BuildContext context,
    StudioController c,
  ) async {
    final ok = await _confirm(
      context,
      title: '更新 Steam build 兼容记录？',
      body: '受保护文件仍等于原始备份。App 会把当前 Steam build id 追加到原始备份、准备包和上次写入记录的兼容列表里。',
      action: '更新 build',
    );
    if (ok) await c.bumpBaselineBuildCompatibility();
  }

  Future<void> _confirmRebuildBaselineFromGame(
    BuildContext context,
    StudioController c,
  ) async {
    final ok = await _confirmChecklist(
      context,
      title: '用当前游戏文件重建原始备份？',
      body: '这会删除当前 Steam build 对应的原始备份、候选备份、准备包和上次写入记录，然后把当前游戏文件设为新的可信原始备份。',
      action: '重建原始备份',
      danger: true,
      checks: const [
        '我确认当前游戏文件可以作为新的可信起点',
        '我理解对应 build 的原始备份、准备包和上次写入记录会被删除',
        '我理解旧原始备份会保留，用于之后人工追溯',
      ],
    );
    if (ok) await c.rebuildBaselineFromCurrentGame();
  }

  Future<bool> _confirmChecklist(
    BuildContext context, {
    required String title,
    required String body,
    required String action,
    required List<String> checks,
    bool danger = false,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      barrierColor: RmTokens.modalBackdrop,
      builder: (context) => _ChecklistDialog(
        title: title,
        body: body,
        action: action,
        checks: checks,
        danger: danger,
      ),
    );
    return result ?? false;
  }

  Future<bool> _confirm(
    BuildContext context, {
    required String title,
    required String body,
    required String action,
    bool danger = false,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      barrierColor: RmTokens.modalBackdrop,
      builder: (context) => _SimpleConfirmDialog(
        title: title,
        body: body,
        action: action,
        danger: danger,
      ),
    );
    return result ?? false;
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

  void _toast(BuildContext context, String text, {bool danger = false}) {
    if (!context.mounted) return;
    final rm = context.rm;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        backgroundColor: danger ? rm.danger : rm.fg,
        content: Text(text, style: RmText.sans(12.5, color: rm.bg)),
      ),
    );
  }
}

enum _DetailTarget { settings, tool, file, diag }

enum _DashboardScenario {
  scanning,
  fileCheckPending,
  readyToWrite,
  readyToPrepare,
  previousDeployed,
  deployed,
  gameUpdate,
  conflict,
  pending,
  confirmation,
  blocking,
  gameDirMissing,
  noBaseline,
  baselineBroken,
  buildBump,
}

enum _Tone { ok, ready, info, warn, danger, muted }

enum _ConfirmationTarget {
  pendingBaseline,
  pendingPackage,
  oldBaseline,
  oldPackage,
}

class _DashboardModel {
  const _DashboardModel({
    required this.scenario,
    required this.tone,
    required this.pillText,
    required this.title,
    required this.description,
    required this.primary,
    required this.secondary,
    required this.tertiary,
    required this.note,
    required this.safetyFacts,
    required this.activities,
    required this.toolPillar,
    required this.gamePillar,
    required this.filePillar,
  });

  factory _DashboardModel.fromState(BuildContext context, StudioState s) {
    final scenario = _scenarioFor(s);
    final confirmationTarget = _confirmationTargetFor(s);
    final fileCount = s.fileIntegrity.checkedFiles;
    final changedCount = _changedFileCount(s.fileIntegrity);
    final pendingCount = s.fileIntegrity.pendingBaselineMatches;
    final hasPackage = s.currentPackageReady;
    final packageAge = s.lastPackageSummary == null ? '未生成' : '已准备';
    final pendingPackageValue = s.pendingPackageDir == null
        ? '空闲'
        : s.pendingPackageBuildFailed
        ? '生成失败'
        : s.pendingPackageReady
        ? '已生成'
        : '未生成';
    final pendingPackageTone = s.pendingPackageDir == null
        ? _Tone.muted
        : s.pendingPackageBuildFailed
        ? _Tone.danger
        : s.pendingPackageReady
        ? _Tone.ok
        : _Tone.warn;
    final gameUpdateDescription = _gameUpdateDescription(s.fileIntegrity);

    final primary = switch (scenario) {
      _DashboardScenario.scanning => const _HeroAction(
        label: '等待扫描完成',
        icon: 'refresh',
        tone: _Tone.info,
        helper: '正在读取当前状态；完成后这里会恢复下一步操作。',
      ),
      _DashboardScenario.fileCheckPending => const _HeroAction(
        label: '扫描文件',
        icon: 'search',
        tone: _Tone.warn,
        kbd: 'Ctrl+R',
        helper: '先重新计算 FH6 受保护文件指纹；只读取文件，不会写入游戏目录。',
      ),
      _DashboardScenario.blocking => const _HeroAction(
        label: '修复本地组件',
        icon: 'wrench',
        tone: _Tone.danger,
        kbd: 'Ctrl+F',
        helper: '先修复 uv / Python / 核心音频工具；AI Provider 只会降级，不锁主流程。',
      ),
      _DashboardScenario.gameDirMissing => const _HeroAction(
        label: '修改游戏路径',
        icon: 'settings',
        tone: _Tone.danger,
        helper: '在概览页游戏路径设置中填入正确的 FH6 安装目录，然后重新扫描。',
      ),
      _DashboardScenario.noBaseline => const _HeroAction(
        label: '创建原始备份',
        icon: 'shield',
        tone: _Tone.warn,
        kbd: 'Ctrl+B',
        helper: '在 fresh install 或 Steam 验证完整性后记录原始文件。',
      ),
      _DashboardScenario.baselineBroken => const _HeroAction(
        label: '查看原始备份问题',
        icon: 'warn',
        tone: _Tone.danger,
        kbd: 'Ctrl+W',
        helper: '原始备份文件缺失或校验不一致；处理前不会允许写入游戏。',
      ),
      _DashboardScenario.gameUpdate => const _HeroAction(
        label: '查看更新详情',
        icon: 'warn',
        tone: _Tone.warn,
        kbd: 'Ctrl+W',
        helper: '点开只查看新文件记录和测试准备包路线，不会写任何文件。',
      ),
      _DashboardScenario.conflict => const _HeroAction(
        label: '查看冲突详情',
        icon: 'warn',
        tone: _Tone.warn,
        kbd: 'Ctrl+W',
        helper: '点开只查看新文件和原始备份路线，不会写任何文件。',
      ),
      _DashboardScenario.pending => const _HeroAction(
        label: '查看新文件流程',
        icon: 'shield',
        tone: _Tone.warn,
        kbd: 'Ctrl+P',
        helper: '确认、放弃、生成测试准备包或写回旧的基线都在文件校验里完成。',
      ),
      _DashboardScenario.confirmation => _HeroAction(
        label: '确认这是可用的',
        icon: 'check',
        tone: _Tone.ready,
        kbd: 'Ctrl+P',
        helper:
            '${_confirmationMatchedSet(confirmationTarget)} 已命中；确认后会清理待确认记录。',
      ),
      _DashboardScenario.buildBump => const _HeroAction(
        label: '更新 build 记录',
        icon: 'check',
        tone: _Tone.ok,
        kbd: 'Ctrl+U',
        helper: '受保护文件未变化，只追加 Steam build 兼容记录。',
      ),
      _DashboardScenario.readyToWrite => const _HeroAction(
        label: '写入游戏',
        icon: 'export',
        tone: _Tone.ok,
        kbd: 'Ctrl+Enter',
        helper: '弹出安全确认后写入 FH6 目录并更新写入指纹；随时可取消。',
      ),
      _DashboardScenario.readyToPrepare => const _HeroAction(
        label: '准备电台包',
        icon: 'music',
        tone: _Tone.info,
        kbd: 'Ctrl+B',
        helper: '在工作区构建准备包；不会修改 FH6 文件。',
      ),
      _DashboardScenario.previousDeployed => const _HeroAction(
        label: '准备电台包',
        icon: 'music',
        tone: _Tone.ok,
        kbd: 'Ctrl+B',
        helper: '游戏里仍是上次写入的包；重新构建只会更新工作区准备包。',
      ),
      _DashboardScenario.deployed => const _HeroAction(
        label: '再次准备电台包',
        icon: 'music',
        tone: _Tone.ok,
        kbd: 'Ctrl+B',
        helper: '改播放列表或语言后再打一次包；已写入包不会被自动覆盖。',
      ),
    };

    final secondary = switch (scenario) {
      _DashboardScenario.scanning => const _HeroAction(
        label: '扫描进行中',
        icon: 'search',
        tone: _Tone.muted,
      ),
      _DashboardScenario.fileCheckPending => const _HeroAction(
        label: '打开文件校验',
        icon: 'file',
        tone: _Tone.muted,
      ),
      _DashboardScenario.blocking => const _HeroAction(
        label: '检查工具链',
        icon: 'search',
        tone: _Tone.muted,
      ),
      _DashboardScenario.gameDirMissing => const _HeroAction(
        label: '重新扫描目录',
        icon: 'refresh',
        tone: _Tone.muted,
      ),
      _DashboardScenario.noBaseline ||
      _DashboardScenario.baselineBroken ||
      _DashboardScenario.buildBump => const _HeroAction(
        label: '打开文件校验',
        icon: 'file',
        tone: _Tone.muted,
      ),
      _DashboardScenario.gameUpdate => const _HeroAction(
        label: '保存新文件记录',
        icon: 'shield',
        tone: _Tone.muted,
      ),
      _DashboardScenario.conflict => const _HeroAction(
        label: '保存新文件记录',
        icon: 'shield',
        tone: _Tone.muted,
      ),
      _DashboardScenario.pending => _HeroAction(
        label: !s.currentPackageReady
            ? '先准备电台包'
            : s.pendingPackageReady
            ? '确认新版本'
            : s.pendingPackageBuildFailed
            ? '重新生成测试准备包'
            : '生成测试准备包',
        icon: s.pendingPackageReady ? 'check' : 'music',
        tone: _Tone.muted,
      ),
      _DashboardScenario.confirmation => _HeroAction(
        label:
            confirmationTarget == _ConfirmationTarget.pendingPackage &&
                s.currentPackageReady
            ? '写回旧准备包'
            : '写回旧的基线',
        icon:
            confirmationTarget == _ConfirmationTarget.pendingPackage &&
                s.currentPackageReady
            ? 'export'
            : 'shield',
        tone: _Tone.muted,
      ),
      _DashboardScenario.readyToWrite => const _HeroAction(
        label: '重新准备电台包',
        icon: 'music',
        tone: _Tone.muted,
      ),
      _DashboardScenario.readyToPrepare => const _HeroAction(
        label: '打开播放列表',
        icon: 'list',
        tone: _Tone.muted,
      ),
      _DashboardScenario.previousDeployed => const _HeroAction(
        label: '打开播放列表',
        icon: 'list',
        tone: _Tone.muted,
      ),
      _DashboardScenario.deployed => const _HeroAction(
        label: '打开播放列表',
        icon: 'list',
        tone: _Tone.muted,
      ),
    };

    final title = switch (scenario) {
      _DashboardScenario.scanning => '正在验证完整性 · 请稍等',
      _DashboardScenario.fileCheckPending => '文件校验待刷新 · 先确认再写入',
      _DashboardScenario.blocking => '核心工具链缺失 · 准备和写入已锁',
      _DashboardScenario.gameDirMissing => '游戏目录无法访问 · 准备和写入已锁',
      _DashboardScenario.noBaseline => '缺少原始备份 · 先保护官方文件',
      _DashboardScenario.baselineBroken => '原始备份不完整 · 写入已锁',
      _DashboardScenario.gameUpdate => '疑似游戏更新 · $changedCount 个文件待确认',
      _DashboardScenario.conflict => '$changedCount 个游戏文件已变化 · 看完再决定',
      _DashboardScenario.pending => '新游戏文件待验证 · 先测试再确认',
      _DashboardScenario.confirmation =>
        '当前游戏文件等于 ${_confirmationMatchedSet(confirmationTarget)} · 等待确认',
      _DashboardScenario.buildBump => 'Steam build 已变化 · 文件仍安全',
      _DashboardScenario.readyToWrite => '准备包就绪 · 随时可写',
      _DashboardScenario.readyToPrepare => '环境就绪 · 浏览或编辑都行',
      _DashboardScenario.previousDeployed => '上一版准备包已写入',
      _DashboardScenario.deployed => '已写入 · 一切同步',
    };

    final rm = context.rm;
    final description = switch (scenario) {
      _DashboardScenario.scanning => TextSpan(
        text: '正在扫描工具链、语言状态和 FH6 受保护文件。此过程只读取状态，不会写入游戏目录。',
      ),
      _DashboardScenario.fileCheckPending => TextSpan(
        text: '已有原始备份或准备包记录，但当前 FH6 文件还没有完成校验。工具链刷新通过后仍需要单独扫描文件，才能判断是否可写入。',
      ),
      _DashboardScenario.blocking => TextSpan(
        text:
            '${aiProfileUserText(s.toolchainStatus.summary)} Dashboard 和塞壬唱片仍可浏览；准备包和写入流程暂时锁定。',
      ),
      _DashboardScenario.gameDirMissing => TextSpan(
        children: [
          const TextSpan(text: 'FH6 游戏目录不存在：'),
          TextSpan(
            text: s.gameDir,
            style: RmText.mono(13.5, color: rm.danger, height: 1.55),
          ),
          const TextSpan(
            text: '。请在”游戏路径”设置中更新路径；修复前准备包和写入流程已锁定。Dashboard 和塞壬唱片仍可浏览。',
          ),
        ],
      ),
      _DashboardScenario.noBaseline => TextSpan(
        text:
            'FH Radio Studio 需要先记录原始 FH6 文件，后续才能判断”官方文件 / 准备包 / 新游戏文件”。创建原始备份不会修改游戏。',
      ),
      _DashboardScenario.baselineBroken => TextSpan(
        text: '${s.baselineWorkflowLockMessage} 在修复前，写入和强制恢复都会保持锁定。',
      ),
      _DashboardScenario.gameUpdate => TextSpan(
        text:
            gameUpdateDescription ??
            'Steam build 已变化，且受保护文件和已有记录不一致。先保存当前游戏文件，再决定是否基于它生成测试准备包。',
      ),
      _DashboardScenario.conflict => TextSpan(
        text: '文件扫描显示当前游戏文件不属于原始备份、准备包或上次写入包。FH Radio Studio 不会自动覆盖，先查看路线再决定。',
      ),
      _DashboardScenario.pending => TextSpan(
        text: s.pendingPackageBuildFailed
            ? '测试准备包生成失败，当前仍停留在新文件流程。请手动选择写回旧的基线、接受新游戏文件、写入旧准备包、放弃新文件，或修复后重新生成测试准备包。'
            : '已有新游戏文件记录。进游戏测试后可以确认新版本；失败时可放弃新文件或写回旧的基线。',
      ),
      _DashboardScenario.confirmation => TextSpan(
        text: s.pendingPackageBuildFailed
            ? '当前游戏文件已进入确认状态；测试准备包记录存在，但上次生成失败，没有可写入的测试准备包。可以只确认新游戏文件，或修复后重建测试准备包。'
            : _confirmationDescription(confirmationTarget),
      ),
      _DashboardScenario.buildBump => TextSpan(
        text: 'Steam build id 已变化，但受保护文件仍等于原始备份。可以更新兼容记录，不需要重建原始备份。',
      ),
      _DashboardScenario.readyToWrite => TextSpan(
        text: '工具链通过分层检查，准备包已生成，游戏文件当前处于可写入的安全状态。没有任何自动写入。',
      ),
      _DashboardScenario.readyToPrepare => TextSpan(
        text: '工具链和语言状态可用。你可以继续编辑播放列表，或在需要发布时准备电台包。',
      ),
      _DashboardScenario.previousDeployed => TextSpan(
        text: 'FH6 目录文件等于上次成功写入的包。当前工作区还没有新的准备包，可以继续编辑播放列表或重新准备电台包。',
      ),
      _DashboardScenario.deployed => TextSpan(
        text: 'FH6 目录文件与准备包一致。写入指纹已更新，启动游戏即可验证。',
      ),
    };

    final note = switch (scenario) {
      _DashboardScenario.scanning => '扫描完成前不会显示写入或准备操作，避免把旧状态误当成下一步。',
      _DashboardScenario.fileCheckPending =>
        '只有文件校验明确等于原始备份、准备包或上次写入包后，Dashboard 才会显示写入入口。',
      _DashboardScenario.readyToPrepare =>
        'Dashboard 是状态视图，没有非做不可的事。只有“写入游戏”会真的改 FH6 目录。',
      _DashboardScenario.previousDeployed =>
        '这不是原始环境；游戏目录仍是上次写入的准备包。只有“写入游戏”会再次改 FH6 目录。',
      _DashboardScenario.conflict ||
      _DashboardScenario.gameUpdate ||
      _DashboardScenario.pending =>
        'FH Radio Studio 不会自动覆盖：除非你明确选择写回或写入，否则不会触碰这些文件。',
      _DashboardScenario.confirmation =>
        '这是确认状态，不是重新构建：当前命中的版本已明确，下一步只是在确认或回退之间选择。',
      _DashboardScenario.blocking =>
        'AI Provider 降级不会触发阻塞；只有 uv / Python / 核心音频工具缺失才锁主流程。',
      _DashboardScenario.gameDirMissing =>
        '只要游戏目录不存在，FH Radio Studio 就无法读取游戏文件状态；游戏路径填错或游戏未安装均会触发此锁。工具链本身不受影响。',
      _ => null,
    };

    return _DashboardModel(
      scenario: scenario,
      tone: _toneForScenario(scenario),
      pillText: _pillTextForScenario(scenario),
      title: title,
      description: description,
      primary: primary,
      secondary: secondary,
      tertiary: _HeroAction(
        label: switch (scenario) {
          _DashboardScenario.scanning => '展开高级诊断',
          _DashboardScenario.fileCheckPending => '展开文件校验',
          _DashboardScenario.blocking => '展开工具链详情',
          _DashboardScenario.gameDirMissing => '展开游戏路径设置',
          _DashboardScenario.previousDeployed => '展开文件校验',
          _DashboardScenario.deployed => '展开文件校验',
          _DashboardScenario.gameUpdate ||
          _DashboardScenario.conflict ||
          _DashboardScenario.pending ||
          _DashboardScenario.confirmation ||
          _DashboardScenario.noBaseline ||
          _DashboardScenario.baselineBroken ||
          _DashboardScenario.buildBump => '展开文件校验',
          _ => '打开播放列表',
        },
        icon: switch (scenario) {
          _DashboardScenario.scanning => 'settings',
          _DashboardScenario.fileCheckPending => 'file',
          _DashboardScenario.blocking => 'settings',
          _DashboardScenario.gameDirMissing => 'settings',
          _DashboardScenario.previousDeployed => 'shield',
          _DashboardScenario.deployed => 'shield',
          _DashboardScenario.gameUpdate ||
          _DashboardScenario.conflict ||
          _DashboardScenario.pending ||
          _DashboardScenario.confirmation ||
          _DashboardScenario.noBaseline ||
          _DashboardScenario.baselineBroken ||
          _DashboardScenario.buildBump => 'file',
          _ => 'list',
        },
        tone: _Tone.muted,
      ),
      note: note,
      safetyFacts: [
        _SafetyFact(
          label: '原始备份',
          value: s.fileIntegrity.hasCurrentBaseline
              ? s.baselineIntegrityBroken
                    ? '校验断裂'
                    : '已确认'
              : '缺失',
          tone: s.fileIntegrity.hasCurrentBaseline
              ? (s.baselineIntegrityBroken ? _Tone.danger : _Tone.ok)
              : _Tone.warn,
        ),
        _SafetyFact(
          label: '新游戏文件',
          value: s.fileIntegrity.hasPendingBaseline
              ? '等待决定'
              : pendingCount > 0
              ? '$pendingCount 文件'
              : '空闲',
          tone: s.fileIntegrity.hasPendingBaseline || pendingCount > 0
              ? _Tone.warn
              : _Tone.muted,
        ),
        _SafetyFact(
          label: '测试准备包',
          value: pendingPackageValue,
          tone: pendingPackageTone,
          tooltip: s.pendingPackageDir,
        ),
        _SafetyFact(
          label: hasPackage ? '准备包' : '上次准备包',
          value: hasPackage
              ? packageAge
              : s.fileIntegrity.hasLastAppliedPackage
              ? '已写入'
              : '未生成',
          tone: hasPackage || s.fileIntegrity.hasLastAppliedPackage
              ? _Tone.ok
              : _Tone.muted,
          tooltip: hasPackage ? s.lastPackageDir : s.lastAppliedPackageManifest,
        ),
        _SafetyFact(
          label: '指纹路径',
          value: s.fileIntegrity.hasLastAppliedPackage
              ? _compactPath(s.lastAppliedPackageManifest)
              : '暂无',
          tone: s.fileIntegrity.hasLastAppliedPackage ? _Tone.ok : _Tone.muted,
          tooltip: s.lastAppliedPackageManifest,
        ),
      ],
      activities: _activityForState(s, scenario),
      toolPillar: _toolPillar(context, s),
      gamePillar: _gamePillar(context, s),
      filePillar: _filePillar(context, s, fileCount),
    );
  }

  final _DashboardScenario scenario;
  final _Tone tone;
  final String pillText;
  final String title;
  final InlineSpan description;
  final _HeroAction primary;
  final _HeroAction secondary;
  final _HeroAction tertiary;
  final String? note;
  final List<_SafetyFact> safetyFacts;
  final List<_ActivityItem> activities;
  final _PillarModel toolPillar;
  final _PillarModel gamePillar;
  final _PillarModel filePillar;
}

class _HeroAction {
  const _HeroAction({
    required this.label,
    required this.icon,
    required this.tone,
    this.kbd,
    this.helper,
  });

  final String label;
  final String icon;
  final _Tone tone;
  final String? kbd;
  final String? helper;
}

class _SafetyFact {
  const _SafetyFact({
    required this.label,
    required this.value,
    required this.tone,
    this.tooltip,
  });

  final String label;
  final String value;
  final _Tone tone;
  final String? tooltip;
}

class _ActivityItem {
  const _ActivityItem({
    required this.time,
    required this.event,
    required this.meta,
    required this.tone,
  });

  final String time;
  final String event;
  final String meta;
  final _Tone tone;
}

class _PillarModel {
  const _PillarModel({
    required this.label,
    required this.tone,
    required this.scanning,
    required this.title,
    required this.line,
    required this.foot,
    required this.more,
  });

  final String label;
  final _Tone tone;
  final bool scanning;
  final String title;
  final String line;
  final List<_StatusAtom> foot;
  final String more;
}

class _StatusAtom {
  const _StatusAtom({required this.tone, required this.text, this.detail});

  final _Tone tone;
  final String text;
  final String? detail;
}

class _PageHead extends StatelessWidget {
  const _PageHead({
    required this.busy,
    required this.scanning,
    required this.onRefresh,
  });

  final bool busy;
  final bool scanning;
  final VoidCallback? onRefresh;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    return LayoutBuilder(
      builder: (context, box) {
        final actions = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _ScanStatusChip(scanning: scanning, busy: busy),
            const SizedBox(width: 8),
            RmButton(
              onPressed: onRefresh,
              size: RmButtonSize.sm,
              leading: RmIcon(scanning ? 'refresh' : 'search', size: 12),
              label: scanning ? '扫描中' : '全量扫描',
            ),
          ],
        );
        final title = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 12,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  '电台控制台',
                  style: RmText.sans(
                    22,
                    color: rm.fg,
                    weight: FontWeight.w600,
                    letterSpacing: 0,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 620),
              child: Text(
                '从工具链到写入游戏的安全发布流程。Dashboard 只决定下一步该做什么；细节默认折叠。',
                style: RmText.sans(12.5, color: rm.fg3, height: 1.35),
              ),
            ),
          ],
        );
        if (box.maxWidth < 760) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              title,
              const SizedBox(height: 14),
              Align(alignment: Alignment.centerLeft, child: actions),
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(child: title),
            actions,
          ],
        );
      },
    );
  }
}

class _ScanStatusChip extends StatelessWidget {
  const _ScanStatusChip({required this.scanning, required this.busy});

  final bool scanning;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    final color = scanning
        ? rm.accent.base
        : busy
        ? rm.warn
        : rm.fg3;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: rm.raised,
        border: Border.all(color: rm.border),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(color: color.withAlpha(110), blurRadius: 6),
              ],
            ),
          ),
          const SizedBox(width: 7),
          Text(
            scanning
                ? '扫描中'
                : busy
                ? '任务进行中'
                : '手动扫描',
            style: RmText.mono(11, color: rm.fg3, letterSpacing: 0),
          ),
        ],
      ),
    );
  }
}

class _ScanningBorder extends StatefulWidget {
  const _ScanningBorder({
    super.key,
    required this.active,
    required this.radius,
    required this.color,
    required this.child,
  });

  final bool active;
  final double radius;
  final Color color;
  final Widget child;

  @override
  State<_ScanningBorder> createState() => _ScanningBorderState();
}

class _ScanningBorderState extends State<_ScanningBorder>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    );
    _syncController();
  }

  @override
  void didUpdateWidget(_ScanningBorder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active != widget.active) _syncController();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _syncController() {
    if (widget.active) {
      _controller.repeat();
    } else {
      _controller.stop();
      _controller.value = 0;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.active) return widget.child;
    return AnimatedBuilder(
      animation: _controller,
      child: widget.child,
      builder: (context, child) {
        return CustomPaint(
          foregroundPainter: _ScanningBorderPainter(
            progress: _controller.value,
            radius: widget.radius,
            color: widget.color,
          ),
          child: child,
        );
      },
    );
  }
}

class _ScanningBorderPainter extends CustomPainter {
  const _ScanningBorderPainter({
    required this.progress,
    required this.radius,
    required this.color,
  });

  final double progress;
  final double radius;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    const stroke = 2.4;
    final rect = (Offset.zero & size).deflate(stroke / 2);
    final path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(rect, Radius.circular(radius - stroke / 2)),
      );
    final metrics = path.computeMetrics().toList(growable: false);
    if (metrics.isEmpty) return;
    final metric = metrics.first;
    final length = metric.length;
    final start = progress * length;
    final span = length * 0.24;
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..color = color.withAlpha(235);
    void drawSegment(double from, double to) {
      if (to <= from) return;
      final segment = metric.extractPath(from, to);
      canvas.drawPath(segment, line);
    }

    if (start + span <= length) {
      drawSegment(start, start + span);
    } else {
      drawSegment(start, length);
      drawSegment(0, start + span - length);
    }
  }

  @override
  bool shouldRepaint(_ScanningBorderPainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.radius != radius ||
        oldDelegate.color != color;
  }
}

class _HeroConsole extends StatelessWidget {
  const _HeroConsole({
    required this.model,
    required this.state,
    required this.onPrimary,
    required this.onSecondary,
    required this.onTertiary,
  });

  final _DashboardModel model;
  final StudioState state;
  final VoidCallback onPrimary;
  final VoidCallback onSecondary;
  final VoidCallback onTertiary;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    final toneColor = _toneColor(context, model.tone);
    return _ScanningBorder(
      key: const ValueKey('dashboard-hero-scan-border'),
      active: _dashboardScanning(state),
      radius: RmTokens.rXl,
      color: toneColor,
      child: Container(
        decoration: BoxDecoration(
          color: rm.panel,
          borderRadius: BorderRadius.circular(RmTokens.rXl),
        ),
        foregroundDecoration: BoxDecoration(
          border: Border.all(color: toneColor.withAlpha(96)),
          borderRadius: BorderRadius.circular(RmTokens.rXl),
        ),
        clipBehavior: Clip.antiAlias,
        child: LayoutBuilder(
          builder: (context, box) {
            final side = _HeroSide(
              model: model,
              busy: state.busy || _dashboardScanning(state),
              onPrimary: onPrimary,
              onSecondary: onSecondary,
              onTertiary: onTertiary,
            );
            final main = _HeroMain(model: model, state: state);
            if (box.maxWidth < 900) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  main,
                  Divider(height: 1, color: rm.border),
                  side,
                ],
              );
            }
            const sideWidth = _dashboardHeroSideWidth;
            final mainWidth = math.max(0.0, box.maxWidth - sideWidth);
            return Stack(
              children: [
                Positioned.fill(
                  left: mainWidth,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: rm.raised,
                      border: Border(left: BorderSide(color: rm.border)),
                    ),
                  ),
                ),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(width: mainWidth, child: main),
                    SizedBox(width: sideWidth, child: side),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _HeroMain extends StatelessWidget {
  const _HeroMain({required this.model, required this.state});

  final _DashboardModel model;
  final StudioState state;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    return LayoutBuilder(
      builder: (context, box) {
        final compact = box.maxWidth < 560;
        final statusSlotHeight = compact
            ? _dashboardHeroStatusCompactSlotHeight
            : _dashboardHeroStatusSlotHeight;
        final titleSlotHeight = compact
            ? _dashboardHeroTitleCompactSlotHeight
            : _dashboardHeroTitleSlotHeight;
        final descriptionSlotHeight = compact
            ? _dashboardHeroDescriptionCompactSlotHeight
            : _dashboardHeroDescriptionSlotHeight;
        final statusTitleGap = compact ? 10.0 : _dashboardHeroStatusTitleGap;
        final titleDescriptionGap = compact
            ? 8.0
            : _dashboardHeroTitleDescriptionGap;
        final descriptionActivityGap = compact
            ? 14.0
            : _dashboardHeroDescriptionActivityGap;
        return Padding(
          padding: const EdgeInsets.fromLTRB(28, 20, 28, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                height: statusSlotHeight,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Wrap(
                    spacing: 12,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      _StatePill(label: model.pillText, tone: model.tone),
                      Text(
                        _heroScanLine(state),
                        style: RmText.mono(11, color: rm.fg4, letterSpacing: 0),
                      ),
                    ],
                  ),
                ),
              ),
              SizedBox(height: statusTitleGap),
              SizedBox(
                height: titleSlotHeight,
                child: Align(
                  alignment: Alignment.topLeft,
                  child: Text(
                    model.title,
                    key: const ValueKey('dashboard-hero-title'),
                    maxLines: compact ? 2 : 1,
                    overflow: TextOverflow.ellipsis,
                    style: RmText.sans(
                      24,
                      color: rm.fg,
                      weight: FontWeight.w600,
                      letterSpacing: 0,
                      height: 1.2,
                    ),
                  ),
                ),
              ),
              SizedBox(height: titleDescriptionGap),
              SizedBox(
                height: descriptionSlotHeight,
                child: Align(
                  alignment: Alignment.topLeft,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 620),
                    child: Text.rich(
                      model.description,
                      maxLines: compact ? 3 : 2,
                      overflow: TextOverflow.ellipsis,
                      style: RmText.sans(13.5, color: rm.fg2, height: 1.55),
                    ),
                  ),
                ),
              ),
              SizedBox(height: descriptionActivityGap),
              _ActivityStrip(items: model.activities),
              const SizedBox(height: 10),
              _SafetyFacts(facts: model.safetyFacts),
            ],
          ),
        );
      },
    );
  }
}

class _HeroSide extends StatelessWidget {
  const _HeroSide({
    required this.model,
    required this.busy,
    required this.onPrimary,
    required this.onSecondary,
    required this.onTertiary,
  });

  final _DashboardModel model;
  final bool busy;
  final VoidCallback onPrimary;
  final VoidCallback onSecondary;
  final VoidCallback onTertiary;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    return Container(
      color: rm.raised,
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: _dashboardHeroSideHeadingSlotHeight,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '可用操作',
                style: RmText.mono(
                  10.5,
                  color: rm.fg3,
                  letterSpacing: 1.45,
                  weight: FontWeight.w500,
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: _dashboardHeroPrimaryCtaHeight,
            child: _PrimaryCta(
              action: model.primary,
              disabled: busy,
              onPressed: onPrimary,
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: _dashboardHeroPrimaryHelperSlotHeight,
            child: model.primary.helper == null
                ? const SizedBox.shrink()
                : Align(
                    alignment: Alignment.topLeft,
                    child: Text(
                      model.primary.helper!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: RmText.sans(11.5, color: rm.fg3, height: 1.45),
                    ),
                  ),
          ),
          const SizedBox(height: 10),
          _SecondaryCta(
            action: model.secondary,
            onPressed: busy ? null : onSecondary,
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: _TertiaryAction(
              action: model.tertiary,
              onPressed: onTertiary,
            ),
          ),
          if (model.note != null) ...[
            const SizedBox(height: 18),
            _InfoNote(text: model.note!),
          ],
        ],
      ),
    );
  }
}

class _PrimaryCta extends StatelessWidget {
  const _PrimaryCta({
    required this.action,
    required this.disabled,
    required this.onPressed,
  });

  final _HeroAction action;
  final bool disabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    final color = _toneColor(context, action.tone);
    final fg = action.tone == _Tone.ok || action.tone == _Tone.ready
        ? rm.accent.onAccent
        : Colors.white;
    return Opacity(
      opacity: disabled ? 0.45 : 1,
      child: MouseRegion(
        cursor: disabled ? SystemMouseCursors.basic : SystemMouseCursors.click,
        child: GestureDetector(
          onTap: disabled ? null : onPressed,
          child: Container(
            key: const ValueKey('dashboard-primary-cta'),
            constraints: const BoxConstraints(minHeight: 38),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: color,
              border: Border.all(color: color),
              borderRadius: BorderRadius.circular(RmTokens.rMd),
              boxShadow: disabled
                  ? null
                  : [
                      BoxShadow(
                        color: color.withAlpha(70),
                        blurRadius: 8,
                        offset: const Offset(0, 2),
                      ),
                    ],
            ),
            child: Row(
              children: [
                RmIcon(action.icon, size: 14, color: fg),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    action.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: RmText.sans(
                      13.5,
                      color: fg,
                      weight: FontWeight.w700,
                    ),
                  ),
                ),
                if (action.kbd != null)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withAlpha(34),
                      borderRadius: BorderRadius.circular(3),
                    ),
                    child: Text(
                      action.kbd!,
                      style: RmText.mono(10.5, color: fg, letterSpacing: 0),
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

class _SecondaryCta extends StatelessWidget {
  const _SecondaryCta({required this.action, required this.onPressed});

  final _HeroAction action;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return RmButton(
      key: const ValueKey('dashboard-secondary-cta'),
      onPressed: onPressed,
      leading: RmIcon(action.icon, size: 12),
      label: action.label,
      variant: RmButtonVariant.defaultBtn,
    );
  }
}

class _TertiaryAction extends StatelessWidget {
  const _TertiaryAction({required this.action, required this.onPressed});

  final _HeroAction action;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              RmIcon(action.icon, size: 11, color: rm.fg3),
              const SizedBox(width: 6),
              Text(
                action.label,
                style: RmText.mono(11.5, color: rm.fg3, letterSpacing: 0),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _InfoNote extends StatelessWidget {
  const _InfoNote({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: rm.info.withAlpha(16),
        border: Border.all(color: rm.info.withAlpha(52)),
        borderRadius: BorderRadius.circular(RmTokens.rSm),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          RmIcon('info', size: 14, color: rm.info),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: RmText.sans(11.5, color: rm.info, height: 1.5),
            ),
          ),
        ],
      ),
    );
  }
}

class _ActivityStrip extends StatelessWidget {
  const _ActivityStrip({required this.items});

  final List<_ActivityItem> items;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    return Container(
      key: const ValueKey('dashboard-activity-strip'),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: rm.raised,
        border: Border.all(color: rm.border),
        borderRadius: BorderRadius.circular(RmTokens.rMd),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              RmIcon('dashboard', size: 12, color: rm.fg3),
              const SizedBox(width: 6),
              Text(
                'STATUS SNAPSHOT',
                style: RmText.mono(10.5, color: rm.fg3, letterSpacing: 1.05),
              ),
            ],
          ),
          const SizedBox(height: 6),
          for (final item in items) _ActivityRow(item: item),
        ],
      ),
    );
  }
}

class _ActivityRow extends StatelessWidget {
  const _ActivityRow({required this.item});

  final _ActivityItem item;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Container(
            width: 6,
            height: 6,
            margin: const EdgeInsets.only(right: 8),
            decoration: BoxDecoration(
              color: _toneColor(context, item.tone),
              shape: BoxShape.circle,
            ),
          ),
          SizedBox(
            width: 56,
            child: Text(
              item.time,
              style: RmText.mono(11, color: rm.fg3, letterSpacing: 0),
            ),
          ),
          Expanded(
            child: Text(
              item.event,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: RmText.sans(12.5, color: rm.fg, weight: FontWeight.w500),
            ),
          ),
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              item.meta,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.right,
              style: RmText.mono(11, color: rm.fg3, letterSpacing: 0),
            ),
          ),
        ],
      ),
    );
  }
}

class _SafetyFacts extends StatelessWidget {
  const _SafetyFacts({required this.facts});

  final List<_SafetyFact> facts;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    return Container(
      padding: const EdgeInsets.only(top: 14),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: rm.border)),
      ),
      child: Wrap(
        spacing: 22,
        runSpacing: 8,
        children: [
          for (final fact in facts)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  fact.label,
                  style: RmText.mono(11, color: rm.fg4, letterSpacing: 0.8),
                ),
                const SizedBox(width: 7),
                _HoverTooltip(
                  message: fact.tooltip,
                  child: Text(
                    fact.value,
                    style: RmText.mono(
                      11,
                      color: _toneColor(context, fact.tone),
                      letterSpacing: 0,
                    ),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

class _StatusPillars extends StatelessWidget {
  const _StatusPillars({
    required this.model,
    required this.onTool,
    required this.onGame,
    required this.onFiles,
  });

  final _DashboardModel model;
  final VoidCallback onTool;
  final VoidCallback onGame;
  final VoidCallback onFiles;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final models = [
          (model.toolPillar, onTool),
          (model.gamePillar, onGame),
          (model.filePillar, onFiles),
        ];
        if (box.maxWidth < 840) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (int i = 0; i < models.length; i++) ...[
                _StatusPillar(
                  key: ValueKey('dashboard-status-$i'),
                  scanKey: ValueKey('dashboard-status-scan-border-$i'),
                  model: models[i].$1,
                  onTap: models[i].$2,
                  pinFooter: false,
                ),
                if (i != models.length - 1) const SizedBox(height: 12),
              ],
            ],
          );
        }
        const pillarHeight = 158.0;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (int i = 0; i < models.length; i++) ...[
              Expanded(
                child: SizedBox(
                  height: pillarHeight,
                  child: _StatusPillar(
                    key: ValueKey('dashboard-status-$i'),
                    scanKey: ValueKey('dashboard-status-scan-border-$i'),
                    model: models[i].$1,
                    onTap: models[i].$2,
                    pinFooter: true,
                  ),
                ),
              ),
              if (i != models.length - 1) const SizedBox(width: 12),
            ],
          ],
        );
      },
    );
  }
}

class _StatusPillar extends StatefulWidget {
  const _StatusPillar({
    super.key,
    required this.scanKey,
    required this.model,
    required this.onTap,
    required this.pinFooter,
  });

  final Key scanKey;
  final _PillarModel model;
  final VoidCallback onTap;
  final bool pinFooter;

  @override
  State<_StatusPillar> createState() => _StatusPillarState();
}

class _StatusPillarState extends State<_StatusPillar> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    final model = widget.model;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: _ScanningBorder(
          key: widget.scanKey,
          active: model.scanning,
          radius: RmTokens.rLg,
          color: _toneColor(context, model.tone),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
            decoration: BoxDecoration(
              color: rm.panel,
              border: Border.all(color: rm.border),
              borderRadius: BorderRadius.circular(RmTokens.rLg),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    _Led(tone: model.tone, size: 7),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        model.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: RmText.mono(
                          10.5,
                          color: rm.fg3,
                          letterSpacing: 1.2,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  model.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: RmText.sans(
                    18,
                    color: rm.fg,
                    weight: FontWeight.w600,
                    letterSpacing: 0,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  model.line,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: RmText.sans(12, color: rm.fg2, height: 1.42),
                ),
                if (widget.pinFooter)
                  const Spacer()
                else
                  const SizedBox(height: 10),
                Container(height: 1, color: rm.border),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: [
                          for (final item in model.foot)
                            _StatusAtomWidget(item: item),
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      model.more,
                      style: RmText.mono(
                        10.5,
                        color: _hover ? rm.accent.base : rm.fg3,
                        letterSpacing: 0,
                      ),
                    ),
                    RmIcon(
                      'chevron-down',
                      size: 13,
                      color: _hover ? rm.accent.base : rm.fg3,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StatusAtomWidget extends StatelessWidget {
  const _StatusAtomWidget({required this.item});

  final _StatusAtom item;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    final detail = item.detail?.trim();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _Led(tone: item.tone, size: 5),
        const SizedBox(width: 5),
        Text(
          item.text,
          style: RmText.mono(
            10.5,
            color: item.tone == _Tone.muted
                ? rm.fg3
                : _toneColor(context, item.tone),
            letterSpacing: 0,
          ),
        ),
        if (detail != null && detail.isNotEmpty) ...[
          const SizedBox(width: 5),
          Text(
            detail,
            style: RmText.mono(
              8.5,
              color: item.tone == _Tone.muted
                  ? rm.fg4
                  : _toneColor(context, item.tone),
              letterSpacing: 0,
            ),
          ),
        ],
      ],
    );
  }
}

class _SettingsStrip extends StatelessWidget {
  const _SettingsStrip({
    super.key,
    required this.state,
    required this.controller,
    required this.gameDirController,
    required this.onPickDirectory,
  });

  final StudioState state;
  final StudioController controller;
  final TextEditingController gameDirController;
  final VoidCallback onPickDirectory;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    return Container(
      decoration: BoxDecoration(
        color: rm.panel,
        border: Border.all(color: rm.border),
        borderRadius: BorderRadius.circular(RmTokens.rLg),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            child: LayoutBuilder(
              builder: (context, box) {
                final right = Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    _SavedPill(busy: state.busy, label: state.busyLabel),
                    RmButton(
                      onPressed: state.busy
                          ? null
                          : () {
                              controller.setSourceLang(state.gameSourceLang);
                              controller.setTargetLang(state.gameTargetLang);
                            },
                      size: RmButtonSize.sm,
                      variant: RmButtonVariant.ghost,
                      leading: const RmIcon('refresh', size: 11),
                      label: '还原默认',
                    ),
                  ],
                );
                final left = Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '基础设置',
                      style: RmText.sans(
                        13,
                        color: rm.fg,
                        weight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '游戏目录 · 显示 / 语音语言槽 · AI Pipeline · 改完后会重新校验',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: RmText.sans(11.5, color: rm.fg3),
                    ),
                  ],
                );
                if (box.maxWidth < 760) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [left, const SizedBox(height: 12), right],
                  );
                }
                return Row(
                  children: [
                    Expanded(child: left),
                    const SizedBox(width: 16),
                    right,
                  ],
                );
              },
            ),
          ),
          Divider(height: 1, color: rm.border),
          _SettingsCells(
            state: state,
            controller: controller,
            gameDirController: gameDirController,
            onPickDirectory: onPickDirectory,
          ),
        ],
      ),
    );
  }
}

class _SavedPill extends StatelessWidget {
  const _SavedPill({required this.busy, required this.label});

  final bool busy;
  final String? label;

  @override
  Widget build(BuildContext context) {
    return _MicroPill(
      label: busy ? label ?? '任务进行中' : '全部已保存',
      tone: busy ? _Tone.warn : _Tone.ok,
    );
  }
}

class _SettingsCells extends StatelessWidget {
  const _SettingsCells({
    required this.state,
    required this.controller,
    required this.gameDirController,
    required this.onPickDirectory,
  });

  final StudioState state;
  final StudioController controller;
  final TextEditingController gameDirController;
  final VoidCallback onPickDirectory;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    final cells = [
      _SettingCell(
        flex: 16,
        child: _GameDirSetting(
          state: state,
          controller: controller,
          textController: gameDirController,
          onPickDirectory: onPickDirectory,
        ),
      ),
      _SettingCell(
        flex: 10,
        child: _LanguageSetting(
          label: '显示语言',
          value: state.sourceLang,
          languages: state.availableLanguages,
          tone: _displayLanguageTone(state),
          helper: _displayLanguageHelper(state),
          enabled: state.voiceSlotVerified && !state.busy,
          onChanged: controller.setSourceLang,
        ),
      ),
      _SettingCell(
        flex: 10,
        child: _LanguageSetting(
          label: '语音语言',
          value: state.targetLang,
          languages: state.availableLanguages,
          tone: _voiceLanguageTone(state),
          helper: _voiceLanguageHelper(state),
          enabled: !state.busy,
          onChanged: controller.setTargetLang,
        ),
      ),
      _SettingCell(
        flex: 13,
        child: _AiPipelineSetting(state: state, controller: controller),
      ),
    ];
    return LayoutBuilder(
      builder: (context, box) {
        if (box.maxWidth < 900) {
          return Column(
            children: [
              for (int i = 0; i < cells.length; i++) ...[
                cells[i],
                if (i != cells.length - 1) Divider(height: 1, color: rm.border),
              ],
            ],
          );
        }
        return IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (int i = 0; i < cells.length; i++) ...[
                Expanded(flex: cells[i].flex, child: cells[i]),
                if (i != cells.length - 1)
                  Container(width: 1, color: rm.border),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _SettingCell extends StatelessWidget {
  const _SettingCell({required this.flex, required this.child});

  final int flex;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      child: child,
    );
  }
}

class _GameDirSetting extends StatelessWidget {
  const _GameDirSetting({
    required this.state,
    required this.controller,
    required this.textController,
    required this.onPickDirectory,
  });

  final StudioState state;
  final StudioController controller;
  final TextEditingController textController;
  final VoidCallback onPickDirectory;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    final gameDirInvalid = state.gameDirError != null;
    return _SettingColumn(
      label: 'FH6 安装目录',
      footer: gameDirInvalid
          ? _InlineIconText(
              icon: 'danger',
              text: '游戏目录不存在，请更新路径',
              tone: _Tone.danger,
            )
          : Wrap(
              spacing: 6,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _InlineIconText(
                  icon: 'check',
                  text: state.gameSteamBuildLabel,
                  tone: state.effectiveGameVersionId == null
                      ? _Tone.muted
                      : _Tone.ok,
                ),
                _DotSep(),
                Text('项目记录已保存', style: RmText.sans(10.5, color: rm.fg3)),
              ],
            ),
      child: Container(
        height: 34,
        decoration: BoxDecoration(
          color: rm.bg,
          border: Border.all(
            color: gameDirInvalid
                ? _toneColor(context, _Tone.danger).withAlpha(150)
                : rm.border2,
          ),
          borderRadius: BorderRadius.circular(RmTokens.rSm),
        ),
        clipBehavior: Clip.antiAlias,
        child: Row(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: RmIcon('folder', size: 13, color: rm.fg3),
            ),
            Expanded(
              child: TextField(
                controller: textController,
                onChanged: controller.setGameDir,
                enabled: !state.busy,
                decoration: const InputDecoration(
                  isCollapsed: true,
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.zero,
                ),
                style: RmText.mono(12, color: rm.fg, letterSpacing: 0),
              ),
            ),
            Container(width: 1, color: rm.border.withAlpha(180)),
            Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: state.busy ? null : onPickDirectory,
                hoverColor: rm.raised.withAlpha(120),
                splashColor: rm.border.withAlpha(80),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Center(
                    child: Row(
                      children: [
                        RmIcon('folder', size: 12, color: rm.fg2),
                        const SizedBox(width: 6),
                        Text('浏览', style: RmText.sans(12, color: rm.fg2)),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LanguageSetting extends StatelessWidget {
  const _LanguageSetting({
    required this.label,
    required this.value,
    required this.languages,
    required this.tone,
    required this.helper,
    required this.enabled,
    required this.onChanged,
  });

  final String label;
  final String value;
  final List<String> languages;
  final _Tone tone;
  final String helper;
  final bool enabled;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    final normalized = value.trim().toUpperCase();
    final items = languages.isEmpty ? [normalized] : languages;
    final selected = items.contains(normalized) ? normalized : items.first;
    final color = _toneColor(context, tone);
    return _SettingColumn(
      label: label,
      footer: _InlineIconText(
        icon: tone == _Tone.danger
            ? 'danger'
            : tone == _Tone.warn
            ? 'warn'
            : 'check',
        text: helper,
        tone: tone,
      ),
      child: Container(
        height: 34,
        decoration: BoxDecoration(
          color: enabled ? rm.bg : rm.raised.withAlpha(150),
          border: Border.all(color: color.withAlpha(150)),
          borderRadius: BorderRadius.circular(RmTokens.rSm),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<String>(
            value: selected,
            isExpanded: true,
            dropdownColor: rm.panel,
            icon: RmIcon('chevron-down', size: 12, color: color),
            style: RmText.sans(12.5, color: rm.fg),
            onChanged: enabled
                ? (next) {
                    if (next != null) onChanged(next);
                  }
                : null,
            items: [
              for (final language in items)
                DropdownMenuItem(
                  value: language,
                  child: Row(
                    children: [
                      _LanguageFlag(code: language, tone: tone),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _languageLabel(language),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LanguageFlag extends StatelessWidget {
  const _LanguageFlag({required this.code, required this.tone});

  final String code;
  final _Tone tone;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    final color = _toneColor(context, tone);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withAlpha(24),
        border: Border.all(color: color.withAlpha(90)),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        code,
        style: RmText.mono(
          10.5,
          color: tone == _Tone.muted ? rm.fg2 : color,
          letterSpacing: 0.5,
          weight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _AiPipelineSetting extends StatelessWidget {
  const _AiPipelineSetting({required this.state, required this.controller});

  final StudioState state;
  final StudioController controller;

  @override
  Widget build(BuildContext context) {
    return _SettingColumn(
      label: 'AI Pipeline',
      footer: _InlineIconText(
        icon: _aiPipelineTone(state) == _Tone.warn ? 'warn' : 'check',
        text: _aiPipelineHelper(state),
        tone: _aiPipelineTone(state),
      ),
      child: Container(
        height: 34,
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: context.rm.bg,
          border: Border.all(color: context.rm.borderStrong),
          borderRadius: BorderRadius.circular(RmTokens.rSm),
        ),
        child: Row(
          children: [
            _AiSegment(
              value: 'local-base',
              label: '中杯',
              state: state,
              controller: controller,
            ),
            _AiSegment(
              value: 'local-deep',
              label: '大杯',
              state: state,
              controller: controller,
            ),
            _AiSegment(
              value: 'local-heavy',
              label: '超大杯',
              state: state,
              controller: controller,
            ),
          ],
        ),
      ),
    );
  }
}

class _AiSegment extends StatelessWidget {
  const _AiSegment({
    required this.value,
    required this.label,
    required this.state,
    required this.controller,
  });

  final String value;
  final String label;
  final StudioState state;
  final StudioController controller;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    final active = state.aiProfile == value;
    return Expanded(
      child: MouseRegion(
        cursor: state.busy
            ? SystemMouseCursors.basic
            : SystemMouseCursors.click,
        child: GestureDetector(
          onTap: state.busy
              ? null
              : () => unawaited(
                  controller.setAiProfileAndRefreshToolchain(value),
                ),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            margin: const EdgeInsets.symmetric(horizontal: 1),
            decoration: BoxDecoration(
              color: active ? rm.accent.base : Colors.transparent,
              borderRadius: BorderRadius.circular(4),
            ),
            alignment: Alignment.center,
            child: Text(
              label,
              maxLines: 1,
              style: RmText.mono(
                10.5,
                color: active ? rm.accent.onAccent : rm.fg3,
                letterSpacing: 0,
                weight: FontWeight.w700,
                height: 1,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SettingColumn extends StatelessWidget {
  const _SettingColumn({
    required this.label,
    required this.child,
    required this.footer,
  });

  final String label;
  final Widget child;
  final Widget footer;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: RmText.mono(10.5, color: rm.fg3, letterSpacing: 1.05),
        ),
        const SizedBox(height: 8),
        child,
        const SizedBox(height: 8),
        footer,
      ],
    );
  }
}

class _DetailsStack extends StatelessWidget {
  const _DetailsStack({
    required this.toolKey,
    required this.fileKey,
    required this.diagKey,
    required this.state,
    required this.controller,
    required this.toolOpen,
    required this.fileOpen,
    required this.diagOpen,
    required this.onToggleTool,
    required this.onToggleFile,
    required this.onToggleDiag,
    required this.onInstallTools,
    required this.onSyncAi,
    required this.onCreateBaseline,
    required this.onDeploy,
    required this.onBackupPending,
    required this.onPreparePending,
    required this.onPromotePending,
    required this.onDiscardPending,
    required this.onApplyCurrentBaseline,
    required this.onApplyPendingBaseline,
    required this.onDeployOldPackage,
    required this.onDeployPendingPackage,
    required this.onBumpBuild,
    required this.onRebuildBaseline,
  });

  final GlobalKey toolKey;
  final GlobalKey fileKey;
  final GlobalKey diagKey;
  final StudioState state;
  final StudioController controller;
  final bool toolOpen;
  final bool fileOpen;
  final bool diagOpen;
  final VoidCallback onToggleTool;
  final VoidCallback onToggleFile;
  final VoidCallback onToggleDiag;
  final VoidCallback onInstallTools;
  final VoidCallback onSyncAi;
  final VoidCallback onCreateBaseline;
  final VoidCallback onDeploy;
  final VoidCallback onBackupPending;
  final VoidCallback onPreparePending;
  final VoidCallback onPromotePending;
  final VoidCallback onDiscardPending;
  final VoidCallback onApplyCurrentBaseline;
  final VoidCallback onApplyPendingBaseline;
  final VoidCallback onDeployOldPackage;
  final VoidCallback onDeployPendingPackage;
  final VoidCallback onBumpBuild;
  final VoidCallback onRebuildBaseline;

  @override
  Widget build(BuildContext context) {
    final toolSummary = _toolDetailSummary(state);
    final fileSummary = _fileDetailSummary(state);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _CollapsibleDetail(
          key: toolKey,
          open: toolOpen,
          tone: toolSummary.tone,
          icon: state.toolchainRefreshing
              ? 'refresh'
              : toolSummary.tone == _Tone.danger
              ? 'warn'
              : 'check',
          spinIcon: state.toolchainRefreshing,
          title: '工具链健康',
          meta: 'uv / Python / 音频 / AI Providers 分层检查',
          pills: toolSummary.pills,
          onToggle: onToggleTool,
          child: _ToolchainDetail(
            state: state,
            controller: controller,
            onInstallTools: onInstallTools,
            onSyncAi: onSyncAi,
          ),
        ),
        const SizedBox(height: 10),
        _CollapsibleDetail(
          key: fileKey,
          open: fileOpen,
          tone: fileSummary.tone,
          icon: state.fileIntegrityRefreshing
              ? 'refresh'
              : fileSummary.tone == _Tone.ok
              ? 'shield'
              : 'warn',
          spinIcon: state.fileIntegrityRefreshing,
          title: '文件校验',
          meta: 'App 启动和手动校验时重新计算文件指纹',
          pills: fileSummary.pills,
          onToggle: onToggleFile,
          child: _FileVerificationDetail(
            state: state,
            controller: controller,
            onCreateBaseline: onCreateBaseline,
            onDeploy: onDeploy,
            onBackupPending: onBackupPending,
            onPreparePending: onPreparePending,
            onPromotePending: onPromotePending,
            onDiscardPending: onDiscardPending,
            onApplyCurrentBaseline: onApplyCurrentBaseline,
            onApplyPendingBaseline: onApplyPendingBaseline,
            onDeployOldPackage: onDeployOldPackage,
            onDeployPendingPackage: onDeployPendingPackage,
            onBumpBuild: onBumpBuild,
            onRebuildBaseline: onRebuildBaseline,
          ),
        ),
        const SizedBox(height: 10),
        _CollapsibleDetail(
          key: diagKey,
          open: diagOpen,
          tone: _Tone.muted,
          icon: 'command',
          title: '高级诊断',
          meta: '默认收起 · 失败时再打开',
          pills: [
            _MicroPill(
              label: _diagnosticCallCountLabel(state.log),
              tone: state.log.any(_looksLikeError) ? _Tone.danger : _Tone.muted,
            ),
          ],
          onToggle: onToggleDiag,
          child: _DiagnosticDetail(state: state, controller: controller),
        ),
      ],
    );
  }
}

class _CollapsibleDetail extends StatelessWidget {
  const _CollapsibleDetail({
    super.key,
    required this.open,
    required this.tone,
    required this.icon,
    this.spinIcon = false,
    required this.title,
    required this.meta,
    required this.pills,
    required this.onToggle,
    required this.child,
  });

  final bool open;
  final _Tone tone;
  final String icon;
  final bool spinIcon;
  final String title;
  final String meta;
  final List<Widget> pills;
  final VoidCallback onToggle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    return Container(
      decoration: BoxDecoration(
        color: rm.panel,
        border: Border.all(color: rm.border),
        borderRadius: BorderRadius.circular(RmTokens.rLg),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: onToggle,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 14,
                ),
                child: Row(
                  children: [
                    Container(
                      width: 22,
                      height: 22,
                      decoration: BoxDecoration(
                        color: _toneBg(context, tone),
                        border: Border.all(
                          color: _toneColor(context, tone).withAlpha(80),
                        ),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      alignment: Alignment.center,
                      child: spinIcon
                          ? _RotatingStatusIcon(
                              icon: icon,
                              size: 12,
                              color: _toneColor(context, tone),
                            )
                          : RmIcon(
                              icon,
                              size: 12,
                              color: _toneColor(context, tone),
                            ),
                    ),
                    const SizedBox(width: 14),
                    Text(
                      title,
                      style: RmText.sans(
                        13.5,
                        color: rm.fg,
                        weight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        meta,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: RmText.mono(
                          11.5,
                          color: rm.fg3,
                          letterSpacing: 0,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Wrap(spacing: 6, runSpacing: 6, children: pills),
                    const SizedBox(width: 12),
                    AnimatedRotation(
                      turns: open ? 0.5 : 0,
                      duration: const Duration(milliseconds: 150),
                      child: RmIcon('chevron-down', size: 14, color: rm.fg3),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (open) ...[
            Divider(height: 1, color: rm.border),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 18, 18, 12),
              child: child,
            ),
          ],
        ],
      ),
    );
  }
}

class _ToolchainDetail extends StatelessWidget {
  const _ToolchainDetail({
    required this.state,
    required this.controller,
    required this.onInstallTools,
    required this.onSyncAi,
  });

  final StudioState state;
  final StudioController controller;
  final VoidCallback onInstallTools;
  final VoidCallback onSyncAi;

  @override
  Widget build(BuildContext context) {
    final actionsLocked =
        state.projectOperationLocked || state.toolchainRefreshing;
    final scanning = state.toolchainRefreshing;
    final blocking = state.toolchainStatus.sections
        .where((s) => _blockingToolchainSectionIds.contains(s.id))
        .toList(growable: false);
    final optional = _orderedOptionalToolchainSections(
      state.toolchainStatus.sections,
    );
    final missingSections = state.toolchainStatus.sections.isEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (scanning)
          const _EmptyDetailNote(
            icon: 'refresh',
            spinIcon: true,
            title: '检测中',
            body: '正在检查 uv、Python、音频工具和 AI Provider 状态。',
          )
        else if (missingSections)
          _EmptyDetailNote(
            icon: state.toolchainStatus.checking ? 'refresh' : 'info',
            spinIcon: state.toolchainStatus.checking,
            title: state.toolchainStatus.label,
            body: aiProfileUserText(state.toolchainStatus.summary),
          )
        else ...[
          _SectionLabel(
            title: '阻塞项 · 缺失会锁住主流程',
            tail:
                '${blocking.where(_sectionReady).length} / ${blocking.length} 就绪',
          ),
          const SizedBox(height: 8),
          for (var i = 0; i < blocking.length; i += 1)
            _ToolchainSectionRow(
              section: blocking[i],
              showDivider: i != blocking.length - 1,
            ),
          const SizedBox(height: 18),
          _SectionLabel(
            title: '可选增强 · 不影响写入',
            tail: '${optional.where((s) => !_sectionReady(s)).length} 项可升级',
          ),
          const SizedBox(height: 8),
          if (optional.isEmpty)
            const _EmptyDetailNote(
              icon: 'info',
              title: '暂无可选增强状态',
              body: '全量刷新后会显示 AI Provider 和硬件加速能力。',
            )
          else
            for (var i = 0; i < optional.length; i += 1)
              _ToolchainSectionRow(
                section: optional[i],
                showDivider: i != optional.length - 1,
              ),
        ],
        const SizedBox(height: 10),
        _DetailActionBar(
          trailing: scanning
              ? '上次扫描: 检测中'
              : '上次扫描: ${state.toolchainStatus.checked ? '已检查' : '未检查'}',
          children: [
            RmButton(
              onPressed: actionsLocked
                  ? null
                  : controller.refreshToolchainStatus,
              size: RmButtonSize.sm,
              leading: const RmIcon('search', size: 12),
              label: state.toolchainRefreshing ? '检测中' : '检查工具链',
            ),
            RmButton(
              onPressed: actionsLocked ? null : onInstallTools,
              size: RmButtonSize.sm,
              leading: const RmIcon('wrench', size: 12),
              label: '修复本地组件',
            ),
            RmButton(
              onPressed: actionsLocked ? null : onSyncAi,
              size: RmButtonSize.sm,
              leading: const RmIcon('refresh', size: 12),
              label: '同步 AI 环境',
            ),
          ],
        ),
      ],
    );
  }
}

class _ToolchainSectionRow extends StatelessWidget {
  const _ToolchainSectionRow({
    required this.section,
    required this.showDivider,
  });

  final ToolchainStatusSection section;
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    final tone = _toolchainTone(
      section.status,
      optional: !_blockingToolchainSectionIds.contains(section.id),
    );
    final metrics = section.items.take(4).toList(growable: false);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        border: showDivider
            ? Border(bottom: BorderSide(color: rm.border.withAlpha(170)))
            : null,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          _Led(tone: tone, size: 8),
          const SizedBox(width: 14),
          Expanded(
            flex: 5,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  section.title,
                  style: RmText.sans(13, color: rm.fg, weight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(
                  section.summary.isEmpty
                      ? _toolchainStatusLabel(section.status)
                      : aiProfileUserText(section.summary),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: RmText.sans(11.5, color: rm.fg3),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: 6,
            child: Wrap(
              spacing: 5,
              runSpacing: 5,
              alignment: WrapAlignment.end,
              children: [
                if (metrics.isEmpty)
                  _MetricTag(
                    label: 'status',
                    value: _toolchainStatusLabel(section.status),
                    tone: tone,
                  )
                else
                  for (final item in metrics)
                    _MetricTag(
                      label: item.label == 'Profile' ? '杯型' : item.label,
                      value: item.label == 'Profile'
                          ? aiProfileCupLabel(item.value)
                          : aiProfileUserText(
                              item.value.isEmpty ? item.detail : item.value,
                            ),
                      tone: _toolchainTone(
                        item.status,
                        optional: !_blockingToolchainSectionIds.contains(
                          section.id,
                        ),
                      ),
                    ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _FileVerificationDetail extends StatelessWidget {
  const _FileVerificationDetail({
    required this.state,
    required this.controller,
    required this.onCreateBaseline,
    required this.onDeploy,
    required this.onBackupPending,
    required this.onPreparePending,
    required this.onPromotePending,
    required this.onDiscardPending,
    required this.onApplyCurrentBaseline,
    required this.onApplyPendingBaseline,
    required this.onDeployOldPackage,
    required this.onDeployPendingPackage,
    required this.onBumpBuild,
    required this.onRebuildBaseline,
  });

  final StudioState state;
  final StudioController controller;
  final VoidCallback onCreateBaseline;
  final VoidCallback onDeploy;
  final VoidCallback onBackupPending;
  final VoidCallback onPreparePending;
  final VoidCallback onPromotePending;
  final VoidCallback onDiscardPending;
  final VoidCallback onApplyCurrentBaseline;
  final VoidCallback onApplyPendingBaseline;
  final VoidCallback onDeployOldPackage;
  final VoidCallback onDeployPendingPackage;
  final VoidCallback onBumpBuild;
  final VoidCallback onRebuildBaseline;

  @override
  Widget build(BuildContext context) {
    final integrity = state.fileIntegrity;
    final conclusion = _fileConclusion(context, state);
    final scanning = state.fileIntegrityRefreshing;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (scanning)
          const _EmptyDetailNote(
            icon: 'refresh',
            spinIcon: true,
            title: '扫描中',
            body: '正在重新计算 FH6 受保护文件指纹，并比对原始备份、准备包和新游戏文件。',
          )
        else ...[
          _ConclusionRibbon(conclusion: conclusion),
          const SizedBox(height: 16),
          _FileSummaryGrid(integrity: integrity),
          const SizedBox(height: 16),
          _FileStackBar(integrity: integrity),
          const SizedBox(height: 14),
          _FileActionPanel(
            state: state,
            onCreateBaseline: onCreateBaseline,
            onDeploy: onDeploy,
            onBackupPending: onBackupPending,
            onPreparePending: onPreparePending,
            onPromotePending: onPromotePending,
            onDiscardPending: onDiscardPending,
            onApplyCurrentBaseline: onApplyCurrentBaseline,
            onApplyPendingBaseline: onApplyPendingBaseline,
            onDeployOldPackage: onDeployOldPackage,
            onDeployPendingPackage: onDeployPendingPackage,
            onBumpBuild: onBumpBuild,
            onRebuildBaseline: onRebuildBaseline,
          ),
          if (integrity.issues.isNotEmpty) ...[
            const SizedBox(height: 14),
            _SectionLabel(title: '最近差异', tail: '${integrity.issues.length} 项'),
            const SizedBox(height: 8),
            for (final issue in integrity.issues.take(6))
              _IntegrityIssueMini(issue: issue),
          ],
        ],
        const SizedBox(height: 16),
        _DetailActionBar(
          trailing: scanning ? '正在校验...' : '上次校验: 手动刷新后更新',
          children: [
            RmButton(
              onPressed: state.busy || scanning
                  ? null
                  : controller.verifyFileIntegrity,
              size: RmButtonSize.sm,
              leading: const RmIcon('search', size: 12),
              label: scanning ? '扫描中' : '扫描文件',
            ),
            RmButton(
              onPressed: () =>
                  Clipboard.setData(ClipboardData(text: _md5ReportText(state))),
              size: RmButtonSize.sm,
              leading: const RmIcon('copy', size: 12),
              label: '复制校验报告',
            ),
          ],
        ),
      ],
    );
  }
}

class _ConclusionRibbon extends StatelessWidget {
  const _ConclusionRibbon({required this.conclusion});

  final _FileConclusion conclusion;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _toneBg(context, conclusion.tone),
        border: Border.all(
          color: _toneColor(context, conclusion.tone).withAlpha(58),
        ),
        borderRadius: BorderRadius.circular(RmTokens.rMd),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          RmIcon(
            conclusion.tone == _Tone.ok ? 'shield' : 'warn',
            size: 16,
            color: _toneColor(context, conclusion.tone),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  conclusion.title,
                  style: RmText.sans(
                    13.5,
                    color: rm.fg,
                    weight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  conclusion.next,
                  style: RmText.sans(12, color: rm.fg2, height: 1.35),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _FileSummaryGrid extends StatelessWidget {
  const _FileSummaryGrid({required this.integrity});

  final GameFileIntegritySummary integrity;

  @override
  Widget build(BuildContext context) {
    final unknown = integrity.unknownFiles + integrity.changedFiles;
    final cards = [
      _FileSummaryCardData(
        '已校验',
        '${integrity.checkedFiles}',
        ' / ${math.max(integrity.checkedFiles, integrity.packageFiles)}',
        _Tone.ok,
      ),
      _FileSummaryCardData(
        '等于准备包',
        '${integrity.packageMatches}',
        '',
        integrity.packageMatches > 0 ? _Tone.ok : _Tone.muted,
      ),
      _FileSummaryCardData(
        '新游戏文件',
        '${integrity.pendingBaselineMatches}',
        '',
        integrity.pendingBaselineMatches > 0 || integrity.hasPendingBaseline
            ? _Tone.warn
            : _Tone.ok,
      ),
      _FileSummaryCardData(
        '未知改动',
        '$unknown',
        '',
        unknown > 0 ? _Tone.danger : _Tone.ok,
      ),
    ];
    return LayoutBuilder(
      builder: (context, box) {
        final cols = box.maxWidth < 720 ? 2 : 4;
        final gap = 8.0;
        final width = (box.maxWidth - gap * (cols - 1)) / cols;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final card in cards)
              SizedBox(
                width: width,
                child: _FileSummaryCard(data: card),
              ),
          ],
        );
      },
    );
  }
}

class _FileSummaryCardData {
  const _FileSummaryCardData(this.label, this.value, this.of, this.tone);

  final String label;
  final String value;
  final String of;
  final _Tone tone;
}

class _FileSummaryCard extends StatelessWidget {
  const _FileSummaryCard({required this.data});

  final _FileSummaryCardData data;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: rm.raised,
        border: Border.all(color: rm.border),
        borderRadius: BorderRadius.circular(RmTokens.rMd),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            data.label,
            style: RmText.mono(10.5, color: rm.fg3, letterSpacing: 1.05),
          ),
          const SizedBox(height: 4),
          RichText(
            text: TextSpan(
              children: [
                TextSpan(
                  text: data.value,
                  style: RmText.sans(
                    18,
                    color: _toneColor(context, data.tone),
                    weight: FontWeight.w700,
                  ),
                ),
                if (data.of.isNotEmpty)
                  TextSpan(
                    text: data.of,
                    style: RmText.sans(13, color: rm.fg3),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 3),
          Text(
            data.tone == _Tone.ok
                ? '无需处理'
                : data.tone == _Tone.warn
                ? '需要决定'
                : data.tone == _Tone.danger
                ? '需要修复'
                : '暂无记录',
            style: RmText.mono(10.5, color: rm.fg3, letterSpacing: 0),
          ),
        ],
      ),
    );
  }
}

class _FileStackBar extends StatelessWidget {
  const _FileStackBar({required this.integrity});

  final GameFileIntegritySummary integrity;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    final total = math.max(1, integrity.checkedFiles);
    final data = [
      _StackSegment('等于准备包', integrity.packageMatches, _Tone.ok),
      _StackSegment('等于原始备份', integrity.baselineMatches, _Tone.muted),
      _StackSegment('新游戏文件', integrity.pendingBaselineMatches, _Tone.warn),
      _StackSegment(
        '未知改动',
        integrity.changedFiles + integrity.unknownFiles,
        _Tone.danger,
      ),
    ];
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: rm.raised,
        border: Border.all(color: rm.border),
        borderRadius: BorderRadius.circular(RmTokens.rMd),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: Container(
              height: 14,
              decoration: BoxDecoration(
                color: rm.panel,
                border: Border.all(color: rm.border),
              ),
              child: Row(
                children: [
                  for (final item in data)
                    if (item.count > 0)
                      Expanded(
                        flex: math.max(
                          1,
                          ((item.count / total) * 1000).round(),
                        ),
                        child: Container(
                          color: _toneColor(
                            context,
                            item.tone,
                          ).withAlpha(item.tone == _Tone.muted ? 95 : 160),
                        ),
                      ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 9),
          Wrap(
            spacing: 14,
            runSpacing: 6,
            children: [
              for (final item in data)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: _toneColor(
                          context,
                          item.tone,
                        ).withAlpha(item.tone == _Tone.muted ? 95 : 160),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    const SizedBox(width: 5),
                    Text(
                      '${item.label} ${item.count}',
                      style: RmText.mono(11, color: rm.fg2, letterSpacing: 0),
                    ),
                  ],
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _StackSegment {
  const _StackSegment(this.label, this.count, this.tone);

  final String label;
  final int count;
  final _Tone tone;
}

class _FileActionPanel extends StatelessWidget {
  const _FileActionPanel({
    required this.state,
    required this.onCreateBaseline,
    required this.onDeploy,
    required this.onBackupPending,
    required this.onPreparePending,
    required this.onPromotePending,
    required this.onDiscardPending,
    required this.onApplyCurrentBaseline,
    required this.onApplyPendingBaseline,
    required this.onDeployOldPackage,
    required this.onDeployPendingPackage,
    required this.onBumpBuild,
    required this.onRebuildBaseline,
  });

  final StudioState state;
  final VoidCallback onCreateBaseline;
  final VoidCallback onDeploy;
  final VoidCallback onBackupPending;
  final VoidCallback onPreparePending;
  final VoidCallback onPromotePending;
  final VoidCallback onDiscardPending;
  final VoidCallback onApplyCurrentBaseline;
  final VoidCallback onApplyPendingBaseline;
  final VoidCallback onDeployOldPackage;
  final VoidCallback onDeployPendingPackage;
  final VoidCallback onBumpBuild;
  final VoidCallback onRebuildBaseline;

  @override
  Widget build(BuildContext context) {
    final integrity = state.fileIntegrity;
    final hasPreparedPackage = state.currentPackageReady;
    if (!integrity.hasCurrentBaseline) {
      return _RouteCards(
        cards: [
          _RouteCardData(
            eyebrow: 'REQUIRED',
            title: '创建原始游戏备份',
            body: '先把官方 FH6 文件记录下来，后续才能安全判断准备包和新游戏文件。',
            tone: _Tone.warn,
            recommended: true,
            actions: [
              _RouteAction(
                '创建原始备份',
                'shield',
                RmButtonVariant.primary,
                onCreateBaseline,
                disabled: state.busy,
              ),
            ],
          ),
        ],
      );
    }
    if (state.baselineIntegrityBroken) {
      return _RouteCards(
        cards: [
          _RouteCardData(
            eyebrow: 'LOCKED',
            title: state.baselineWorkflowLockTitle,
            body: state.baselineWorkflowLockMessage,
            tone: _Tone.danger,
            recommended: true,
            actions: [
              _RouteAction(
                '重建原始备份',
                'refresh',
                RmButtonVariant.danger,
                onRebuildBaseline,
                disabled: state.busy,
              ),
            ],
          ),
        ],
      );
    }
    if (integrity.level == GameFileIntegrityLevel.buildBumpAvailable) {
      return _RouteCards(
        cards: [
          _RouteCardData(
            eyebrow: 'SAFE BUILD BUMP',
            title: '更新 Steam build 兼容记录',
            body: '受保护文件仍等于原始备份，可以只追加 build id，无需重建备份。',
            tone: _Tone.ok,
            recommended: true,
            actions: [
              _RouteAction(
                '更新 build',
                'check',
                RmButtonVariant.primary,
                onBumpBuild,
                disabled: state.busy,
              ),
            ],
          ),
        ],
      );
    }
    if (integrity.level == GameFileIntegrityLevel.gameChanged) {
      return _RouteCards(
        cards: [
          _RouteCardData(
            eyebrow: '路线 A · 接受新文件',
            title: '只保存新文件记录',
            body: hasPreparedPackage
                ? '把当前 Steam 更新后的游戏文件保存为待确认记录；确认可用后再设为新的原始备份。'
                : '把当前 Steam 更新后的游戏文件保存为待确认记录。还没有准备包，所以暂时不能生成测试准备包。',
            tone: _Tone.warn,
            recommended: true,
            actions: [
              _RouteAction(
                '保存新文件记录',
                'shield',
                RmButtonVariant.primary,
                onBackupPending,
                disabled: state.busy || integrity.hasPendingBaseline,
              ),
            ],
          ),
          if (hasPreparedPackage)
            _RouteCardData(
              eyebrow: '路线 B · 测试准备包',
              title: '基于准备包生成测试准备包',
              body: '先保存当前游戏文件，再用准备包里的曲目安排重新构建测试准备包；不会直接写入游戏。',
              tone: _Tone.info,
              actions: [
                _RouteAction(
                  '生成测试准备包',
                  'music',
                  RmButtonVariant.defaultBtn,
                  onPreparePending,
                  disabled: state.busy || state.baselineWorkflowLocked,
                ),
              ],
            ),
        ],
      );
    }
    if (integrity.level == GameFileIntegrityLevel.externalConflict) {
      return _RouteCards(
        cards: [
          _RouteCardData(
            eyebrow: '路线 A · 回到旧的基线',
            title: hasPreparedPackage ? '写回旧的基线或旧准备包' : '写回旧的基线',
            body: hasPreparedPackage
                ? '同一 Steam build 下出现未知改动；可以写回旧的基线或旧准备包。'
                : '同一 Steam build 下出现未知改动；可以写回旧的基线。还没有准备包，不能写入旧准备包。',
            tone: _Tone.warn,
            recommended: true,
            actions: [
              _RouteAction(
                '旧的基线',
                'shield',
                RmButtonVariant.danger,
                onApplyCurrentBaseline,
                disabled: state.busy || state.baselineWorkflowLocked,
              ),
              if (hasPreparedPackage)
                _RouteAction(
                  '旧准备包',
                  'export',
                  RmButtonVariant.danger,
                  onDeployOldPackage,
                  disabled: state.busy || state.baselineWorkflowLocked,
                ),
            ],
          ),
          _RouteCardData(
            eyebrow: '路线 B · 接受当前文件',
            title: hasPreparedPackage ? '保存当前文件 · 构建测试准备包' : '只保存当前文件',
            body: hasPreparedPackage
                ? '把当前游戏文件作为待确认记录；再用准备包里的曲目安排重新构建测试准备包用于验证。'
                : '把当前游戏文件作为待确认记录。还没有准备包，所以暂时不能生成测试准备包。',
            tone: _Tone.info,
            actions: [
              _RouteAction(
                '保存新文件记录',
                'shield',
                RmButtonVariant.primary,
                onBackupPending,
                disabled: state.busy || integrity.hasPendingBaseline,
              ),
              if (hasPreparedPackage)
                _RouteAction(
                  '生成测试准备包',
                  'music',
                  RmButtonVariant.defaultBtn,
                  onPreparePending,
                  disabled: state.busy || state.baselineWorkflowLocked,
                ),
            ],
          ),
        ],
      );
    }
    final confirmationTarget = _confirmationTargetFor(state);
    if (confirmationTarget != null) {
      return _RouteCards(
        cards: [
          _RouteCardData(
            eyebrow: '确认',
            title: '当前命中 ${_confirmationMatchedSet(confirmationTarget)}',
            body: _confirmationRouteBody(confirmationTarget),
            tone: _Tone.ready,
            recommended: true,
            actions: [
              _RouteAction(
                '确认这是可用的',
                'check',
                RmButtonVariant.primary,
                confirmationTarget == _ConfirmationTarget.oldBaseline ||
                        confirmationTarget == _ConfirmationTarget.oldPackage
                    ? onDiscardPending
                    : onPromotePending,
                disabled: state.busy || state.baselineWorkflowLocked,
              ),
            ],
          ),
          _RouteCardData(
            eyebrow: '回退',
            title: '不接受当前待确认版本',
            body: '测试不通过时，先写回旧的基线或旧准备包；如果决定不保留新文件，再放弃它。',
            tone: _Tone.warn,
            actions: [
              _RouteAction(
                '旧的基线',
                'shield',
                RmButtonVariant.defaultBtn,
                onApplyCurrentBaseline,
                disabled: state.busy || state.baselineWorkflowLocked,
              ),
              if (hasPreparedPackage)
                _RouteAction(
                  '旧准备包',
                  'export',
                  RmButtonVariant.danger,
                  onDeployOldPackage,
                  disabled: state.busy || state.baselineWorkflowLocked,
                ),
              _RouteAction(
                '放弃新文件',
                'x',
                RmButtonVariant.ghost,
                onDiscardPending,
                disabled: state.busy || state.baselineWorkflowLocked,
              ),
            ],
          ),
        ],
      );
    }
    if (integrity.level == GameFileIntegrityLevel.pendingVerify ||
        integrity.hasPendingBaseline) {
      return _RouteCards(
        cards: [
          _RouteCardData(
            eyebrow: '路线 A · 保守',
            title: '回到旧的基线',
            body: hasPreparedPackage
                ? '测试不通过时，写回旧的基线或旧准备包，新文件记录可稍后放弃。'
                : '测试不通过时，写回旧的基线；新文件记录可稍后放弃。',
            tone: _Tone.warn,
            actions: [
              _RouteAction(
                '旧的基线',
                'shield',
                RmButtonVariant.defaultBtn,
                onApplyCurrentBaseline,
                disabled: state.busy || state.baselineWorkflowLocked,
              ),
              if (hasPreparedPackage)
                _RouteAction(
                  '旧准备包',
                  'export',
                  RmButtonVariant.danger,
                  onDeployOldPackage,
                  disabled: state.busy || state.baselineWorkflowLocked,
                ),
            ],
          ),
          _RouteCardData(
            eyebrow: '路线 B · 接受新版本',
            title: hasPreparedPackage ? '测试准备包 · 确认新版本' : '只验证新游戏文件',
            body: hasPreparedPackage
                ? '用准备包里的曲目安排重新构建测试准备包；进游戏确认后，再把新文件设为原始备份。'
                : '还没有准备包，不能生成测试准备包；你仍可只验证新游戏文件，确认后设为原始备份。',
            tone: _Tone.info,
            recommended: true,
            actions: [
              _RouteAction(
                '新游戏文件',
                'shield',
                RmButtonVariant.defaultBtn,
                onApplyPendingBaseline,
                disabled:
                    state.busy ||
                    !integrity.hasPendingBaseline ||
                    state.baselineWorkflowLocked,
              ),
              if (hasPreparedPackage)
                _RouteAction(
                  state.pendingPackageReady
                      ? '重建测试准备包'
                      : state.pendingPackageBuildFailed
                      ? '重新生成'
                      : '生成测试准备包',
                  'music',
                  RmButtonVariant.defaultBtn,
                  onPreparePending,
                  disabled: state.busy || state.baselineWorkflowLocked,
                ),
              _RouteAction(
                '测试准备包',
                'export',
                RmButtonVariant.danger,
                onDeployPendingPackage,
                disabled:
                    state.busy ||
                    !state.pendingPackageReady ||
                    state.baselineWorkflowLocked,
              ),
              _RouteAction(
                '确认可用',
                'check',
                RmButtonVariant.primary,
                onPromotePending,
                disabled:
                    state.busy ||
                    !state.pendingPackageReady ||
                    state.baselineWorkflowLocked,
              ),
              _RouteAction(
                '放弃',
                'x',
                RmButtonVariant.ghost,
                onDiscardPending,
                disabled: state.busy || state.baselineWorkflowLocked,
              ),
            ],
          ),
        ],
      );
    }
    if (integrity.level == GameFileIntegrityLevel.baseline &&
        state.currentPackageReady) {
      return _RouteCards(
        cards: [
          _RouteCardData(
            eyebrow: 'READY',
            title: '准备包可写入',
            body: '游戏文件仍等于原始备份。点击写入会先弹出安全确认。',
            tone: _Tone.ok,
            recommended: true,
            actions: [
              _RouteAction(
                '写入游戏',
                'export',
                RmButtonVariant.primary,
                onDeploy,
                disabled: state.busy || state.baselineWorkflowLocked,
              ),
            ],
          ),
        ],
      );
    }
    return _RouteCards(
      cards: [
        _RouteCardData(
          eyebrow: 'IDLE',
          title: integrity.title,
          body: integrity.detail.isEmpty ? '当前没有必须处理的文件动作。' : integrity.detail,
          tone: _integrityTone(integrity),
          actions: [
            _RouteAction(
              '扫描文件',
              'search',
              RmButtonVariant.defaultBtn,
              () {},
              disabled: true,
            ),
          ],
        ),
      ],
    );
  }
}

class _RouteCards extends StatelessWidget {
  const _RouteCards({required this.cards});

  final List<_RouteCardData> cards;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        if (cards.length == 1 || box.maxWidth < 760) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (int i = 0; i < cards.length; i++) ...[
                _RouteCard(
                  key: ValueKey('dashboard-route-card-$i'),
                  data: cards[i],
                ),
                if (i != cards.length - 1) const SizedBox(height: 10),
              ],
            ],
          );
        }
        return IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (int i = 0; i < cards.length; i++) ...[
                Expanded(
                  child: _RouteCard(
                    key: ValueKey('dashboard-route-card-$i'),
                    data: cards[i],
                    pinActions: true,
                  ),
                ),
                if (i != cards.length - 1) const SizedBox(width: 10),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _RouteCardData {
  const _RouteCardData({
    required this.eyebrow,
    required this.title,
    required this.body,
    required this.tone,
    required this.actions,
    this.recommended = false,
  });

  final String eyebrow;
  final String title;
  final String body;
  final _Tone tone;
  final List<_RouteAction> actions;
  final bool recommended;
}

class _RouteAction {
  const _RouteAction(
    this.label,
    this.icon,
    this.variant,
    this.onPressed, {
    this.disabled = false,
  });

  final String label;
  final String icon;
  final RmButtonVariant variant;
  final VoidCallback onPressed;
  final bool disabled;
}

class _RouteCard extends StatelessWidget {
  const _RouteCard({super.key, required this.data, this.pinActions = false});

  static const _headerHeight = 28.0;
  static const _pinnedBodyHeight = 54.0;

  final _RouteCardData data;
  final bool pinActions;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      decoration: BoxDecoration(
        color: data.recommended ? _toneBg(context, data.tone) : rm.raised,
        border: Border.all(
          color: data.recommended
              ? _toneColor(context, data.tone).withAlpha(115)
              : rm.border,
        ),
        borderRadius: BorderRadius.circular(RmTokens.rMd),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: _headerHeight,
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    data.eyebrow,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: RmText.mono(
                      10.5,
                      color: _toneColor(context, data.tone),
                      letterSpacing: 1.05,
                    ),
                  ),
                ),
                if (data.recommended) ...[
                  const SizedBox(width: 10),
                  _MicroPill(label: '推荐', tone: data.tone),
                ],
              ],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            data.title,
            style: RmText.sans(13.5, color: rm.fg, weight: FontWeight.w700),
          ),
          const SizedBox(height: 5),
          if (pinActions)
            SizedBox(
              height: _pinnedBodyHeight,
              child: Text(
                data.body,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: RmText.sans(12, color: rm.fg2, height: 1.45),
              ),
            )
          else
            Text(
              data.body,
              style: RmText.sans(12, color: rm.fg2, height: 1.45),
            ),
          const SizedBox(height: 16),
          _ActionWrap(actions: data.actions),
        ],
      ),
    );
  }
}

class _ActionWrap extends StatelessWidget {
  const _ActionWrap({required this.actions});

  final List<_RouteAction> actions;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final action in actions)
          RmButton(
            onPressed: action.disabled ? null : action.onPressed,
            size: RmButtonSize.sm,
            variant: action.variant,
            leading: RmIcon(action.icon, size: 11),
            label: action.label,
          ),
      ],
    );
  }
}

class _DiagnosticDetail extends StatelessWidget {
  const _DiagnosticDetail({required this.state, required this.controller});

  final StudioState state;
  final StudioController controller;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    final text = _diagnosticLogText(state.log);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          constraints: const BoxConstraints(minHeight: 120, maxHeight: 300),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: rm.raised,
            border: Border.all(color: rm.border),
            borderRadius: BorderRadius.circular(RmTokens.rMd),
          ),
          child: SingleChildScrollView(
            reverse: true,
            child: SelectableText(
              text,
              style: RmText.mono(
                11.5,
                color: rm.fg2,
                height: 1.4,
                letterSpacing: 0,
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            RmButton(
              onPressed: () => Clipboard.setData(ClipboardData(text: text)),
              size: RmButtonSize.sm,
              leading: const RmIcon('copy', size: 12),
              label: '复制诊断日志',
            ),
            RmButton(
              onPressed: () => Clipboard.setData(
                ClipboardData(text: _diagnosticSnapshot(state)),
              ),
              size: RmButtonSize.sm,
              leading: const RmIcon('export', size: 12),
              label: '打包诊断快照',
            ),
            RmButton(
              onPressed: state.busy ? null : controller.clearLog,
              size: RmButtonSize.sm,
              variant: RmButtonVariant.ghost,
              leading: const RmIcon('trash', size: 12),
              label: '清空日志',
            ),
          ],
        ),
      ],
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.title, required this.tail});

  final String title;
  final String tail;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    return Row(
      children: [
        Text(
          title,
          style: RmText.mono(10.5, color: rm.fg3, letterSpacing: 1.05),
        ),
        const SizedBox(width: 8),
        Expanded(child: Container(height: 1, color: rm.border)),
        const SizedBox(width: 8),
        Text(tail, style: RmText.mono(10.5, color: rm.fg3, letterSpacing: 0)),
      ],
    );
  }
}

class _DetailActionBar extends StatelessWidget {
  const _DetailActionBar({required this.children, required this.trailing});

  final List<Widget> children;
  final String trailing;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    return Container(
      padding: const EdgeInsets.only(top: 10),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: rm.border)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(child: Wrap(spacing: 8, runSpacing: 8, children: children)),
          const SizedBox(width: 12),
          Text(
            trailing,
            style: RmText.mono(11, color: rm.fg3, letterSpacing: 0),
          ),
        ],
      ),
    );
  }
}

class _EmptyDetailNote extends StatelessWidget {
  const _EmptyDetailNote({
    required this.icon,
    required this.title,
    required this.body,
    this.spinIcon = false,
  });

  final String icon;
  final String title;
  final String body;
  final bool spinIcon;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: rm.raised,
        border: Border.all(color: rm.border),
        borderRadius: BorderRadius.circular(RmTokens.rMd),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          spinIcon
              ? _RotatingStatusIcon(
                  key: const ValueKey('detail-scanning-spin-icon'),
                  icon: icon,
                  size: 15,
                  color: rm.fg3,
                )
              : RmIcon(icon, size: 15, color: rm.fg3),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: RmText.sans(
                    12.5,
                    color: rm.fg,
                    weight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 3),
                Text(body, style: RmText.sans(12, color: rm.fg3, height: 1.4)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _RotatingStatusIcon extends StatefulWidget {
  const _RotatingStatusIcon({
    super.key,
    required this.icon,
    required this.size,
    required this.color,
  });

  final String icon;
  final double size;
  final Color color;

  @override
  State<_RotatingStatusIcon> createState() => _RotatingStatusIconState();
}

class _RotatingStatusIconState extends State<_RotatingStatusIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1350),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: RotationTransition(
        turns: _controller,
        child: RmIcon(widget.icon, size: widget.size, color: widget.color),
      ),
    );
  }
}

class _IntegrityIssueMini extends StatelessWidget {
  const _IntegrityIssueMini({required this.issue});

  final GameFileIntegrityIssue issue;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    final tone =
        issue.level == GameFileIntegrityLevel.externalConflict ||
            issue.level == GameFileIntegrityLevel.gameChanged
        ? _Tone.danger
        : _Tone.warn;
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: rm.raised,
        border: Border.all(color: rm.border),
        borderRadius: BorderRadius.circular(RmTokens.rSm),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 148,
            child: Text(
              issue.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: RmText.sans(
                12,
                color: _toneColor(context, tone),
                weight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(issue.detail, style: RmText.sans(12, color: rm.fg2)),
                const SizedBox(height: 2),
                Text(
                  issue.path,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: RmText.mono(10.5, color: rm.fg4, letterSpacing: 0),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MetricTag extends StatelessWidget {
  const _MetricTag({
    required this.label,
    required this.value,
    required this.tone,
  });

  final String label;
  final String value;
  final _Tone tone;

  @override
  Widget build(BuildContext context) {
    final pathLike = _looksLikePathValue(value);
    final hideValue = pathLike || value.length > 32;
    final shownText = hideValue
        ? label
        : '$label ${value.isEmpty ? '—' : value}';
    final fullText = '$label ${value.isEmpty ? '—' : value}';
    return _AnimatedMetricTag(
      compactText: shownText,
      expandedText: fullText,
      tone: tone,
      expandable: hideValue,
    );
  }
}

class _AnimatedMetricTag extends StatefulWidget {
  const _AnimatedMetricTag({
    required this.compactText,
    required this.expandedText,
    required this.tone,
    required this.expandable,
  });

  final String compactText;
  final String expandedText;
  final _Tone tone;
  final bool expandable;

  @override
  State<_AnimatedMetricTag> createState() => _AnimatedMetricTagState();
}

class _AnimatedMetricTagState extends State<_AnimatedMetricTag>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  OverlayEntry? _entry;
  Timer? _hideTimer;
  Rect? _startRect;
  Rect? _endRect;

  bool get _overlayVisible => _entry != null;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 160),
      reverseDuration: const Duration(milliseconds: 110),
    );
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _entry?.remove();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final surface = _MetricTagSurface(
      text: widget.compactText,
      tone: widget.tone,
    );
    if (!widget.expandable) return surface;
    return MouseRegion(
      onEnter: (_) => _show(),
      onExit: (_) => _scheduleHide(),
      child: Opacity(opacity: _overlayVisible ? 0 : 1, child: surface),
    );
  }

  void _show() {
    _hideTimer?.cancel();
    if (_entry != null) {
      _controller.forward();
      return;
    }
    final overlay = Overlay.maybeOf(context);
    final targetBox = context.findRenderObject() as RenderBox?;
    final overlayBox = overlay?.context.findRenderObject() as RenderBox?;
    if (overlay == null ||
        targetBox == null ||
        overlayBox == null ||
        !targetBox.hasSize ||
        !overlayBox.hasSize) {
      return;
    }

    final startTopLeft = overlayBox.globalToLocal(
      targetBox.localToGlobal(Offset.zero),
    );
    _startRect = startTopLeft & targetBox.size;
    _endRect = _expandedRect(context, overlayBox.size, _startRect!);
    _entry = OverlayEntry(builder: _buildOverlay);
    overlay.insert(_entry!);
    setState(() {});
    _controller.forward(from: 0);
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(milliseconds: 110), _hide);
  }

  void _hide() {
    _hideTimer?.cancel();
    _hideTimer = null;
    if (_entry == null) return;
    _controller.reverse().whenComplete(_removeOverlay);
  }

  void _removeOverlay() {
    if (!mounted) return;
    _entry?.remove();
    _entry = null;
    setState(() {});
  }

  Rect _expandedRect(BuildContext context, Size overlaySize, Rect start) {
    final rm = context.rm;
    final textStyle = RmText.mono(
      12,
      color: widget.tone == _Tone.muted
          ? rm.fg2
          : _toneColor(context, widget.tone),
      height: 1.28,
      weight: FontWeight.w500,
    );
    const screenPadding = 12.0;
    final maxWidth = math.max(
      120.0,
      math.min(560.0, overlaySize.width - screenPadding * 2),
    );
    final painter = TextPainter(
      text: TextSpan(text: widget.expandedText, style: textStyle),
      maxLines: 3,
      textDirection: Directionality.of(context),
    )..layout(maxWidth: maxWidth - 22);
    final minWidth = math.min(start.width, maxWidth);
    final desiredWidth = math.max(start.width, painter.width + 22);
    final width = math.max(minWidth, math.min(desiredWidth, maxWidth));
    final minHeight = math.min(start.height, 92.0);
    final desiredHeight = math.max(start.height, painter.height + 14);
    final height = math.max(minHeight, math.min(desiredHeight, 92.0));
    final left = start.left
        .clamp(
          screenPadding,
          math.max(screenPadding, overlaySize.width - width - screenPadding),
        )
        .toDouble();
    final top = (start.top - 4)
        .clamp(
          screenPadding,
          math.max(screenPadding, overlaySize.height - height - screenPadding),
        )
        .toDouble();
    return Rect.fromLTWH(left, top, width, height);
  }

  Widget _buildOverlay(BuildContext context) {
    final start = _startRect;
    final end = _endRect;
    if (start == null || end == null) return const SizedBox.shrink();
    return Positioned.fill(
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          final t = Curves.easeOutCubic.transform(_controller.value);
          final rect = Rect.lerp(start, end, t)!;
          return Stack(
            children: [
              Positioned.fromRect(
                rect: rect,
                child: MouseRegion(
                  onEnter: (_) => _hideTimer?.cancel(),
                  onExit: (_) => _scheduleHide(),
                  child: Material(
                    color: Colors.transparent,
                    child: _MetricTagSurface(
                      text: widget.expandedText,
                      tone: widget.tone,
                      expanded: true,
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _MetricTagSurface extends StatelessWidget {
  const _MetricTagSurface({
    required this.text,
    required this.tone,
    this.expanded = false,
  });

  final String text;
  final _Tone tone;
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    final color = _toneColor(context, tone);
    final bg = tone == _Tone.muted
        ? rm.panel
        : Color.alphaBlend(color.withAlpha(18), rm.panel);
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: expanded ? 10 : 8,
        vertical: expanded ? 6 : 3,
      ),
      constraints: BoxConstraints(minHeight: expanded ? 30 : 22),
      decoration: BoxDecoration(
        color: bg,
        border: Border.all(color: color.withAlpha(expanded ? 126 : 78)),
        borderRadius: BorderRadius.circular(6),
        boxShadow: expanded
            ? [
                BoxShadow(
                  color: color.withAlpha(42),
                  blurRadius: 18,
                  spreadRadius: 1,
                  offset: const Offset(0, 8),
                ),
                BoxShadow(
                  color: Colors.black.withAlpha(28),
                  blurRadius: 18,
                  offset: const Offset(0, 5),
                ),
              ]
            : null,
      ),
      clipBehavior: Clip.antiAlias,
      child: Align(
        alignment: Alignment.centerLeft,
        widthFactor: expanded ? null : 1,
        heightFactor: expanded ? null : 1,
        child: Text(
          text,
          maxLines: expanded ? 3 : 1,
          overflow: TextOverflow.ellipsis,
          softWrap: expanded,
          style: RmText.mono(
            expanded ? 12 : 10.8,
            color: tone == _Tone.muted ? rm.fg3 : color,
            letterSpacing: 0,
            weight: FontWeight.w500,
            height: expanded ? 1.28 : 1.1,
          ),
        ),
      ),
    );
  }
}

class _HoverTooltip extends StatelessWidget {
  const _HoverTooltip({required this.message, required this.child});

  final String? message;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final text = message?.trim();
    if (text == null || text.isEmpty) return child;
    final rm = context.rm;
    return Tooltip(
      message: text,
      waitDuration: const Duration(milliseconds: 280),
      showDuration: const Duration(seconds: 8),
      preferBelow: false,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      margin: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: rm.fg,
        borderRadius: BorderRadius.circular(6),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(28),
            blurRadius: 14,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      textStyle: RmText.mono(11, color: rm.panel, height: 1.35),
      child: child,
    );
  }
}

class _MicroPill extends StatelessWidget {
  const _MicroPill({required this.label, required this.tone});

  final String label;
  final _Tone tone;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    final color = _toneColor(context, tone);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: _toneBg(context, tone),
        border: Border.all(color: color.withAlpha(70)),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (tone != _Tone.muted) ...[
            _Led(tone: tone, size: 6),
            const SizedBox(width: 6),
          ],
          Text(
            label,
            style: RmText.mono(
              10.5,
              color: tone == _Tone.muted ? rm.fg3 : color,
              letterSpacing: tone == _Tone.muted ? 1.1 : 0,
              weight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _StatePill extends StatelessWidget {
  const _StatePill({required this.label, required this.tone});

  final String label;
  final _Tone tone;

  @override
  Widget build(BuildContext context) {
    return _MicroPill(label: label, tone: tone);
  }
}

class _InlineIconText extends StatelessWidget {
  const _InlineIconText({
    required this.icon,
    required this.text,
    required this.tone,
  });

  final String icon;
  final String text;
  final _Tone tone;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        RmIcon(icon, size: 10, color: _toneColor(context, tone)),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: RmText.mono(
              10.5,
              color: _toneColor(context, tone),
              letterSpacing: 0,
            ),
          ),
        ),
      ],
    );
  }
}

class _Led extends StatelessWidget {
  const _Led({required this.tone, required this.size});

  final _Tone tone;
  final double size;

  @override
  Widget build(BuildContext context) {
    final color = _toneColor(context, tone);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        boxShadow: tone == _Tone.muted
            ? null
            : [BoxShadow(color: color.withAlpha(110), blurRadius: 6)],
      ),
    );
  }
}

class _DotSep extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Text('·', style: RmText.mono(10.5, color: context.rm.fg3));
  }
}

class _SimpleConfirmDialog extends StatelessWidget {
  const _SimpleConfirmDialog({
    required this.title,
    required this.body,
    required this.action,
    required this.danger,
  });

  final String title;
  final String body;
  final String action;
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
        width: 480,
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
                    child: RmIcon(
                      danger ? 'danger' : 'check',
                      size: 16,
                      color: tone,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'CONFIRM',
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
                    onPressed: () => Navigator.of(context).pop(false),
                    icon: const RmIcon('x', size: 13),
                    variant: RmButtonVariant.ghost,
                    tooltip: '取消',
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: rm.border),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
              child: Container(
                padding: const EdgeInsets.all(13),
                decoration: BoxDecoration(
                  color: rm.raised,
                  border: Border.all(color: rm.border),
                  borderRadius: BorderRadius.circular(RmTokens.rMd),
                ),
                child: Text(
                  body,
                  style: RmText.sans(12.5, color: rm.fg2, height: 1.45),
                ),
              ),
            ),
            Divider(height: 1, color: rm.border),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 14),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  RmButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    label: '取消',
                    size: RmButtonSize.sm,
                  ),
                  const SizedBox(width: 8),
                  RmButton(
                    onPressed: () => Navigator.of(context).pop(true),
                    label: action,
                    leading: const RmIcon('check', size: 12),
                    size: RmButtonSize.sm,
                    variant: danger
                        ? RmButtonVariant.dangerPrimary
                        : RmButtonVariant.primary,
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

class _ChecklistDialog extends StatefulWidget {
  const _ChecklistDialog({
    required this.title,
    required this.body,
    required this.action,
    required this.checks,
    required this.danger,
  });

  final String title;
  final String body;
  final String action;
  final List<String> checks;
  final bool danger;

  @override
  State<_ChecklistDialog> createState() => _ChecklistDialogState();
}

class _ChecklistDialogState extends State<_ChecklistDialog> {
  late final List<bool> _checks = List.filled(widget.checks.length, false);

  bool get _ready => _checks.every((v) => v);

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 48, vertical: 36),
      child: Container(
        width: 560,
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
            _ModalHead(title: widget.title, eyebrow: 'CHECKLIST'),
            Padding(
              padding: const EdgeInsets.all(22),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    widget.body,
                    style: RmText.sans(13, color: rm.fg2, height: 1.55),
                  ),
                  const SizedBox(height: 14),
                  Container(
                    decoration: BoxDecoration(
                      color: rm.raised,
                      border: Border.all(color: rm.border),
                      borderRadius: BorderRadius.circular(RmTokens.rMd),
                    ),
                    child: Column(
                      children: [
                        for (int i = 0; i < widget.checks.length; i++)
                          _ChecklistItem(
                            label: widget.checks[i],
                            value: _checks[i],
                            onChanged: (v) => setState(() => _checks[i] = v),
                            last: i == widget.checks.length - 1,
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            _ModalFoot(
              action: widget.action,
              danger: widget.danger,
              enabled: _ready,
              onConfirm: () => Navigator.of(context).pop(true),
            ),
          ],
        ),
      ),
    );
  }
}

class _DeployPreflightDialog extends StatefulWidget {
  const _DeployPreflightDialog({required this.state});

  final StudioState state;

  @override
  State<_DeployPreflightDialog> createState() => _DeployPreflightDialogState();
}

class _DeployPreflightDialogState extends State<_DeployPreflightDialog> {
  late bool _exit = !widget.state.gameRunning;
  bool _latest = false;
  bool _modify = false;

  bool get _ready =>
      widget.state.currentPackageReady &&
      !widget.state.baselineIntegrityBroken &&
      _exit &&
      _latest &&
      _modify;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    final s = widget.state;
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 48, vertical: 36),
      child: Container(
        width: 560,
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
            const _ModalHead(title: '写入游戏前请确认', eyebrow: 'PRE-FLIGHT'),
            Padding(
              padding: const EdgeInsets.all(22),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'FH Radio Studio 即将把准备包写入 FH6 目录并更新写入指纹。确认下面三项后才能继续。',
                    style: RmText.sans(13, color: rm.fg2, height: 1.55),
                  ),
                  const SizedBox(height: 14),
                  Container(
                    decoration: BoxDecoration(
                      color: rm.raised,
                      border: Border.all(color: rm.border),
                      borderRadius: BorderRadius.circular(RmTokens.rMd),
                    ),
                    child: Column(
                      children: [
                        _ChecklistItem(
                          label: 'FH6 已退出（包括 Steam 后台 / 云同步队列）',
                          value: _exit,
                          onChanged: (v) => setState(() => _exit = v),
                        ),
                        _ChecklistItem(
                          label: '写入的是最近准备好的电台包',
                          value: _latest,
                          onChanged: (v) => setState(() => _latest = v),
                        ),
                        _ChecklistItem(
                          label: '理解这会修改本地游戏文件，上次写入指纹会在成功后更新',
                          value: _modify,
                          onChanged: (v) => setState(() => _modify = v),
                          last: true,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  _ModalFacts(
                    rows: [
                      ('部署路径', s.lastPackageDeployDir ?? '还没有准备电台包'),
                      ('写入指纹', s.lastAppliedPackageManifest),
                      (
                        '受影响文件',
                        '${math.max(s.fileIntegrity.packageFiles, s.fileIntegrity.checkedFiles)} 个保护文件',
                      ),
                    ],
                  ),
                ],
              ),
            ),
            _ModalFoot(
              action: '确认写入',
              danger: false,
              enabled: _ready,
              icon: 'export',
              onConfirm: () => Navigator.of(context).pop(true),
            ),
          ],
        ),
      ),
    );
  }
}

class _ModalHead extends StatelessWidget {
  const _ModalHead({required this.title, required this.eyebrow});

  final String title;
  final String eyebrow;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 18, 16, 14),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  eyebrow,
                  style: RmText.mono(10.5, color: rm.fg3, letterSpacing: 1.45),
                ),
                const SizedBox(height: 4),
                Text(
                  title,
                  style: RmText.sans(17, color: rm.fg, weight: FontWeight.w700),
                ),
              ],
            ),
          ),
          RmButton.icon(
            onPressed: () => Navigator.of(context).pop(false),
            icon: const RmIcon('x', size: 13),
            variant: RmButtonVariant.ghost,
            tooltip: '关闭',
          ),
        ],
      ),
    );
  }
}

class _ModalFoot extends StatelessWidget {
  const _ModalFoot({
    required this.action,
    required this.danger,
    required this.enabled,
    required this.onConfirm,
    this.icon = 'check',
  });

  final String action;
  final bool danger;
  final bool enabled;
  final String icon;
  final VoidCallback onConfirm;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    return Container(
      padding: const EdgeInsets.fromLTRB(22, 12, 22, 14),
      decoration: BoxDecoration(
        color: rm.raised,
        border: Border(top: BorderSide(color: rm.border)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          RmButton(
            onPressed: () => Navigator.of(context).pop(false),
            label: '取消',
            size: RmButtonSize.sm,
          ),
          const SizedBox(width: 8),
          RmButton(
            onPressed: enabled ? onConfirm : null,
            label: action,
            leading: RmIcon(icon, size: 12),
            size: RmButtonSize.sm,
            variant: danger
                ? RmButtonVariant.dangerPrimary
                : RmButtonVariant.primary,
          ),
        ],
      ),
    );
  }
}

class _ChecklistItem extends StatelessWidget {
  const _ChecklistItem({
    required this.label,
    required this.value,
    required this.onChanged,
    this.last = false,
  });

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    return InkWell(
      onTap: () => onChanged(!value),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          border: last ? null : Border(bottom: BorderSide(color: rm.border)),
        ),
        child: Row(
          children: [
            Checkbox(
              value: value,
              onChanged: (v) => onChanged(v ?? false),
              activeColor: rm.accent.base,
              side: BorderSide(color: rm.borderStrong),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(label, style: RmText.sans(13, color: rm.fg)),
            ),
          ],
        ),
      ),
    );
  }
}

class _ModalFacts extends StatelessWidget {
  const _ModalFacts({required this.rows});

  final List<(String, String)> rows;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: rm.bg,
        border: Border.all(color: rm.border),
        borderRadius: BorderRadius.circular(RmTokens.rMd),
      ),
      child: Column(
        children: [
          for (final row in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                children: [
                  SizedBox(
                    width: 78,
                    child: Text(
                      row.$1,
                      style: RmText.mono(
                        10.5,
                        color: rm.fg3,
                        letterSpacing: 0.8,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      row.$2,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: RmText.mono(11.5, color: rm.fg2, letterSpacing: 0),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

bool _dashboardScanning(StudioState s) {
  return s.refreshingStatus ||
      s.fileIntegrityRefreshing ||
      s.toolchainRefreshing;
}

_ConfirmationTarget? _confirmationTargetFor(StudioState s) {
  final integrity = s.fileIntegrity;
  final checked = integrity.checkedFiles;
  if (!integrity.hasPendingBaseline || checked <= 0) return null;
  final pendingPackageReady = s.pendingPackageReady;
  final packageIsPending =
      pendingPackageReady &&
      (_pathWithin(integrity.packageManifestPath, s.pendingPackageDir) ||
          integrity.level == GameFileIntegrityLevel.pendingVerify);
  final packageIsOld =
      _pathWithin(integrity.packageManifestPath, s.lastPackageDir) ||
      (s.pendingPackageDir == null && s.currentPackageReady);
  if (integrity.packageMatches == checked && packageIsPending) {
    return _ConfirmationTarget.pendingPackage;
  }
  if (integrity.pendingBaselineMatches == checked) {
    if (!s.pendingPackageBuildFailed ||
        s.pendingBaselineSelectedForConfirmation) {
      return _ConfirmationTarget.pendingBaseline;
    }
  }
  if (integrity.baselineMatches == checked) {
    return _ConfirmationTarget.oldBaseline;
  }
  if (integrity.packageMatches == checked && packageIsOld) {
    return _ConfirmationTarget.oldPackage;
  }
  if (integrity.lastAppliedPackageMatches == checked) {
    return _ConfirmationTarget.oldPackage;
  }
  return null;
}

bool _pathWithin(String? child, String? parent) {
  if (child == null || parent == null) return false;
  final normalizedChild = p.normalize(child).toLowerCase();
  final normalizedParent = p.normalize(parent).toLowerCase();
  return normalizedChild == normalizedParent ||
      p.isWithin(normalizedParent, normalizedChild);
}

String _confirmationMatchedSet(_ConfirmationTarget? target) {
  return switch (target) {
    _ConfirmationTarget.pendingPackage => '测试准备包',
    _ConfirmationTarget.pendingBaseline => '新游戏文件',
    _ConfirmationTarget.oldPackage => '旧准备包',
    _ConfirmationTarget.oldBaseline => '旧的基线',
    null => '待确认版本',
  };
}

String _confirmationDescription(_ConfirmationTarget? target) {
  return switch (target) {
    _ConfirmationTarget.pendingPackage =>
      '测试准备包已经写入到游戏目录。进游戏验证无误后，确认会把新文件和测试准备包设为当前版本；失败时可写回旧的基线或旧准备包。',
    _ConfirmationTarget.pendingBaseline =>
      '当前游戏文件等于这批新游戏文件。确认后会把它设为新的原始备份并清理待确认记录；失败时可写回旧的基线。',
    _ConfirmationTarget.oldPackage =>
      '当前游戏文件等于旧准备包。确认保留旧准备包时会放弃新文件；如果要接受新版本，请先写入新游戏文件或测试准备包。',
    _ConfirmationTarget.oldBaseline =>
      '当前游戏文件等于旧的基线。确认保留旧的基线时会放弃新文件；如果要接受新版本，请先写入新游戏文件或测试准备包。',
    null => '当前游戏文件已经命中待确认版本。确认后会清理待确认记录。',
  };
}

String _confirmationRouteBody(_ConfirmationTarget target) {
  return switch (target) {
    _ConfirmationTarget.pendingPackage => '当前游戏文件等于测试准备包。确认后，新文件和测试准备包会成为当前版本。',
    _ConfirmationTarget.pendingBaseline =>
      '当前游戏文件等于这批新游戏文件。确认后只接受新游戏文件为原始备份，并清理未采用的测试准备包。',
    _ConfirmationTarget.oldPackage =>
      '当前游戏文件等于旧准备包。确认保留旧准备包时应放弃新文件；接受新版本前请先写入测试准备包。',
    _ConfirmationTarget.oldBaseline =>
      '当前游戏文件等于旧的基线。确认保留旧的基线时应放弃新文件；接受新版本前请先写入新游戏文件或测试准备包。',
  };
}

String _heroScanLine(StudioState s) {
  if (s.fileIntegrityRefreshing) return 'scan · 扫描中 · integrity';
  if (s.toolchainRefreshing) return 'scan · 扫描中 · toolchain';
  if (s.fileIntegrity.hasPendingBaseline ||
      s.fileIntegrity.level == GameFileIntegrityLevel.pendingVerify) {
    return _confirmationTargetFor(s) == null ? 'scan · 新文件待确认' : 'scan · 等待确认';
  }
  if (s.fileIntegrity.checkedFiles == 0) return 'scan · 待校验';
  return 'scan · 手动校验';
}

_DashboardScenario _scenarioFor(StudioState s) {
  if (_dashboardScanning(s)) return _DashboardScenario.scanning;
  if (s.toolchainStatus.coreBlocking) return _DashboardScenario.blocking;
  if (s.gameDirWorkflowLocked) return _DashboardScenario.gameDirMissing;
  if (!s.fileIntegrity.hasCurrentBaseline) return _DashboardScenario.noBaseline;
  if (s.baselineIntegrityBroken) return _DashboardScenario.baselineBroken;
  if (_confirmationTargetFor(s) != null) {
    return _DashboardScenario.confirmation;
  }
  return switch (s.fileIntegrity.level) {
    GameFileIntegrityLevel.packageApplied => _DashboardScenario.deployed,
    GameFileIntegrityLevel.buildBumpAvailable => _DashboardScenario.buildBump,
    GameFileIntegrityLevel.gameChanged => _DashboardScenario.gameUpdate,
    GameFileIntegrityLevel.externalConflict => _DashboardScenario.conflict,
    GameFileIntegrityLevel.pendingVerify => _DashboardScenario.pending,
    GameFileIntegrityLevel.baseline =>
      !s.currentPackageReady
          ? _DashboardScenario.readyToPrepare
          : _DashboardScenario.readyToWrite,
    GameFileIntegrityLevel.previousPackageApplied =>
      !s.currentPackageReady
          ? _DashboardScenario.previousDeployed
          : _DashboardScenario.readyToWrite,
    GameFileIntegrityLevel.noPackage => _DashboardScenario.readyToPrepare,
    GameFileIntegrityLevel.noBaseline => _DashboardScenario.noBaseline,
    GameFileIntegrityLevel.unknown => _DashboardScenario.fileCheckPending,
  };
}

_Tone _toneForScenario(_DashboardScenario scenario) {
  return switch (scenario) {
    _DashboardScenario.scanning => _Tone.info,
    _DashboardScenario.fileCheckPending => _Tone.warn,
    _DashboardScenario.readyToWrite => _Tone.ready,
    _DashboardScenario.readyToPrepare => _Tone.info,
    _DashboardScenario.previousDeployed => _Tone.ok,
    _DashboardScenario.deployed => _Tone.ok,
    _DashboardScenario.confirmation => _Tone.ready,
    _DashboardScenario.gameUpdate ||
    _DashboardScenario.conflict ||
    _DashboardScenario.pending ||
    _DashboardScenario.noBaseline ||
    _DashboardScenario.buildBump => _Tone.warn,
    _DashboardScenario.blocking ||
    _DashboardScenario.gameDirMissing ||
    _DashboardScenario.baselineBroken => _Tone.danger,
  };
}

String _pillTextForScenario(_DashboardScenario scenario) {
  return switch (scenario) {
    _DashboardScenario.scanning => '扫描状态',
    _DashboardScenario.fileCheckPending => '待校验',
    _DashboardScenario.readyToWrite => '包就绪',
    _DashboardScenario.readyToPrepare => '环境就绪',
    _DashboardScenario.previousDeployed => '上一版已写入',
    _DashboardScenario.deployed => '已写入',
    _DashboardScenario.gameUpdate => '游戏更新',
    _DashboardScenario.conflict => '需要决定',
    _DashboardScenario.pending => '待验证',
    _DashboardScenario.confirmation => '待确认',
    _DashboardScenario.blocking => '工具链缺失',
    _DashboardScenario.gameDirMissing => '目录无效',
    _DashboardScenario.noBaseline => '缺备份',
    _DashboardScenario.baselineBroken => '备份异常',
    _DashboardScenario.buildBump => 'build 更新',
  };
}

int _changedFileCount(GameFileIntegritySummary integrity) {
  final direct = integrity.changedFiles + integrity.unknownFiles;
  if (direct > 0) return direct;
  if (integrity.issues.isNotEmpty) return integrity.issues.length;
  return integrity.checkedFiles == 0 ? 0 : integrity.checkedFiles;
}

List<_ActivityItem> _activityForState(
  StudioState s,
  _DashboardScenario scenario,
) {
  final latestLog = s.log.isEmpty ? null : s.log.last.trim();
  final first = switch (scenario) {
    _DashboardScenario.scanning => _ActivityItem(
      time: '现在',
      event: '扫描状态',
      meta: s.busyLabel ?? '正在读取当前环境',
      tone: _Tone.info,
    ),
    _DashboardScenario.fileCheckPending => const _ActivityItem(
      time: '刚刚',
      event: '等待文件校验',
      meta: '刷新文件指纹后再判断可写入状态',
      tone: _Tone.warn,
    ),
    _DashboardScenario.blocking => _ActivityItem(
      time: '刚刚',
      event: '工具链检查未通过',
      meta: s.toolchainStatus.label,
      tone: _Tone.danger,
    ),
    _DashboardScenario.gameDirMissing => _ActivityItem(
      time: '刚刚',
      event: '游戏目录无法访问',
      meta: s.gameDir,
      tone: _Tone.danger,
    ),
    _DashboardScenario.noBaseline => const _ActivityItem(
      time: '刚刚',
      event: '等待创建原始备份',
      meta: 'fresh install / Steam verify 后执行',
      tone: _Tone.warn,
    ),
    _DashboardScenario.baselineBroken => _ActivityItem(
      time: '刚刚',
      event: '原始备份校验异常',
      meta: s.baselinePlanSummary == null
          ? '需要刷新文件校验'
          : '${s.baselinePlanSummary!.integrityBreakCount} 文件异常',
      tone: _Tone.danger,
    ),
    _DashboardScenario.gameUpdate => _ActivityItem(
      time: '刚刚',
      event: '疑似游戏更新',
      meta:
          _gameUpdateActivityMeta(s.fileIntegrity) ??
          '${_changedFileCount(s.fileIntegrity)} 文件待确认',
      tone: _Tone.warn,
    ),
    _DashboardScenario.conflict => _ActivityItem(
      time: '刚刚',
      event: '文件扫描发现差异',
      meta: '${_changedFileCount(s.fileIntegrity)} 文件 ≠ 已知记录',
      tone: _Tone.warn,
    ),
    _DashboardScenario.pending =>
      s.pendingPackageBuildFailed
          ? const _ActivityItem(
              time: '刚刚',
              event: '测试准备包生成失败',
              meta: '停留在新文件流程，等待手动选择路线',
              tone: _Tone.danger,
            )
          : const _ActivityItem(
              time: '刚刚',
              event: '新游戏文件已保存',
              meta: '等待进游戏测试后确认',
              tone: _Tone.warn,
            ),
    _DashboardScenario.confirmation => _ActivityItem(
      time: '刚刚',
      event: '等待你确认',
      meta: s.pendingPackageBuildFailed
          ? '测试准备包生成失败 · 当前命中 ${_confirmationMatchedSet(_confirmationTargetFor(s))}'
          : '当前命中 ${_confirmationMatchedSet(_confirmationTargetFor(s))}',
      tone: s.pendingPackageBuildFailed ? _Tone.danger : _Tone.ready,
    ),
    _DashboardScenario.buildBump => const _ActivityItem(
      time: '刚刚',
      event: 'Steam build id 变化',
      meta: '受保护文件仍等于原始备份',
      tone: _Tone.warn,
    ),
    _DashboardScenario.readyToWrite => _ActivityItem(
      time: '最近',
      event: '准备包可写入',
      meta: s.lastPackageSummary?.detail ?? '文件指纹已缓存',
      tone: _Tone.ok,
    ),
    _DashboardScenario.readyToPrepare => const _ActivityItem(
      time: '最近',
      event: '环境状态可用',
      meta: '可以编辑播放列表或准备包',
      tone: _Tone.info,
    ),
    _DashboardScenario.previousDeployed => const _ActivityItem(
      time: '最近',
      event: '上一版准备包已写入',
      meta: '文件等于上次写入记录',
      tone: _Tone.ok,
    ),
    _DashboardScenario.deployed => const _ActivityItem(
      time: '最近',
      event: '写入游戏完成',
      meta: '文件等于准备包',
      tone: _Tone.ok,
    ),
  };
  return [
    first,
    _ActivityItem(
      time: '状态',
      event: s.languageSummary,
      meta: s.preferredLang == '未知'
          ? 'UserPreferredLang 未读取'
          : 'UserPreferredLang ${s.preferredLang}',
      tone: _languageOverallTone(s),
    ),
    _ActivityItem(
      time: '日志',
      event: latestLog == null || latestLog.isEmpty ? '无最近诊断输出' : latestLog,
      meta: s.busyLabel ?? '空闲',
      tone: latestLog != null && _looksLikeError(latestLog)
          ? _Tone.danger
          : _Tone.muted,
    ),
  ];
}

_PillarModel _toolPillar(BuildContext context, StudioState s) {
  final toolchain = s.toolchainStatus;
  final scanning = s.toolchainRefreshing;
  final tone = toolchain.checking
      ? _Tone.info
      : toolchain.coreBlocking
      ? _Tone.danger
      : toolchain.ready
      ? _Tone.ok
      : toolchain.needsAttention
      ? _Tone.warn
      : _Tone.muted;
  final coreSections = toolchain.sections
      .where((section) => _blockingToolchainSectionIds.contains(section.id))
      .toList(growable: false);
  final coreReady = coreSections.where(_sectionReady).length;
  final optionalWarn = toolchain.sections
      .where((section) => !_blockingToolchainSectionIds.contains(section.id))
      .where((section) => !_sectionReady(section))
      .length;
  final cudaAccelerated = _hardwareAccelerationReady(toolchain);
  return _PillarModel(
    label: '工具链',
    tone: scanning ? _Tone.info : tone,
    scanning: scanning,
    title: scanning
        ? '扫描中'
        : toolchain.checking
        ? '检测中'
        : toolchain.coreBlocking
        ? '缺失关键组件'
        : toolchain.ready
        ? '工具链就绪'
        : toolchain.checked
        ? toolchain.label
        : '未检查',
    line: scanning
        ? '正在检测 uv、Python、音频工具和 AI Provider'
        : toolchain.checked || toolchain.checking
        ? aiProfileUserText(toolchain.summary)
        : '点击全量扫描检查 uv、Python、音频工具和 AI Provider',
    foot: [
      _StatusAtom(
        tone: scanning
            ? _Tone.info
            : toolchain.coreBlocking
            ? _Tone.danger
            : _Tone.ok,
        text: scanning
            ? '核心检查中'
            : coreSections.isEmpty
            ? 'Core ?/3'
            : 'Core $coreReady/${coreSections.length}',
      ),
      _StatusAtom(
        tone: scanning
            ? _Tone.muted
            : optionalWarn > 0
            ? _Tone.warn
            : cudaAccelerated
            ? _Tone.ok
            : _Tone.muted,
        text: scanning
            ? 'AI 检查中'
            : optionalWarn > 0
            ? 'Optional $optionalWarn'
            : 'AI OK',
        detail: scanning || optionalWarn > 0 || !cudaAccelerated
            ? null
            : 'CUDA Accelerated',
      ),
    ],
    more: scanning ? '处理中' : '详情',
  );
}

_PillarModel _gamePillar(BuildContext context, StudioState s) {
  final scanning = s.refreshingStatus;
  final tone = _languageOverallTone(s);
  return _PillarModel(
    label: '游戏 · 语言',
    tone: scanning
        ? _Tone.info
        : s.gameRunning
        ? _Tone.warn
        : tone,
    scanning: scanning,
    title: scanning
        ? '扫描中'
        : s.gameRunning
        ? '游戏运行中'
        : '游戏未运行',
    line: scanning ? '正在读取游戏运行状态、Steam build 和语言槽' : s.languageSummary,
    foot: [
      _StatusAtom(
        tone: scanning
            ? _Tone.muted
            : s.gameRunning
            ? _Tone.warn
            : _Tone.muted,
        text: scanning
            ? 'Steam 检查中'
            : s.gameSteamBuildLabel.replaceFirst('Steam build ', 'Steam '),
      ),
      _StatusAtom(
        tone: scanning ? _Tone.info : tone,
        text: scanning
            ? '语言检查中'
            : s.languageReady && s.languageSelectionMatchesGame
            ? '语言对齐'
            : s.languageSelectionMatchesGame
            ? '槽未同步'
            : s.languageSelectionPrepared
            ? '包已准备'
            : '待准备',
      ),
    ],
    more: scanning ? '处理中' : '编辑设置',
  );
}

_PillarModel _filePillar(BuildContext context, StudioState s, int fileCount) {
  final integrity = s.fileIntegrity;
  final scanning = s.fileIntegrityRefreshing;
  final tone = _integrityTone(integrity);
  return _PillarModel(
    label: '文件状态',
    tone: scanning ? _Tone.info : tone,
    scanning: scanning,
    title: scanning ? '扫描中' : _fileShortValue(integrity),
    line: scanning
        ? '正在验证 FH6 受保护文件完整性'
        : integrity.detail.isEmpty
        ? integrity.title
        : integrity.detail,
    foot: [
      _StatusAtom(
        tone: scanning
            ? _Tone.info
            : integrity.hasCurrentBaseline
            ? _Tone.ok
            : _Tone.warn,
        text: scanning
            ? '原始备份待检查'
            : integrity.hasCurrentBaseline
            ? '原始备份完整'
            : '无原始备份',
      ),
      _StatusAtom(
        tone: scanning
            ? _Tone.muted
            : integrity.hasPendingBaseline
            ? _Tone.warn
            : _Tone.muted,
        text: scanning
            ? '新文件待检查'
            : integrity.hasPendingBaseline
            ? '新文件待确认'
            : '无新文件',
      ),
    ],
    more: scanning ? '处理中' : '详情',
  );
}

_Tone _integrityTone(GameFileIntegritySummary integrity) {
  return switch (integrity.level) {
    GameFileIntegrityLevel.packageApplied ||
    GameFileIntegrityLevel.baseline => _Tone.ok,
    GameFileIntegrityLevel.noPackage ||
    GameFileIntegrityLevel.noBaseline ||
    GameFileIntegrityLevel.buildBumpAvailable ||
    GameFileIntegrityLevel.pendingVerify ||
    GameFileIntegrityLevel.previousPackageApplied ||
    GameFileIntegrityLevel.unknown => _Tone.warn,
    GameFileIntegrityLevel.gameChanged ||
    GameFileIntegrityLevel.externalConflict => _Tone.danger,
  };
}

String _fileShortValue(GameFileIntegritySummary integrity) {
  return switch (integrity.level) {
    GameFileIntegrityLevel.packageApplied => '已写入',
    GameFileIntegrityLevel.previousPackageApplied => '上一版已写入',
    GameFileIntegrityLevel.baseline => '等于原始备份',
    GameFileIntegrityLevel.noPackage => '无准备包',
    GameFileIntegrityLevel.noBaseline => '缺原始备份',
    GameFileIntegrityLevel.buildBumpAvailable => 'build 可更新',
    GameFileIntegrityLevel.gameChanged =>
      '${_changedFileCount(integrity)} 文件变化',
    GameFileIntegrityLevel.externalConflict => '文件冲突',
    GameFileIntegrityLevel.pendingVerify => '待验证',
    GameFileIntegrityLevel.unknown => '未知',
  };
}

String? _gameUpdateDescription(GameFileIntegritySummary integrity) {
  if (integrity.level != GameFileIntegrityLevel.gameChanged ||
      integrity.baselineBuildCompatible) {
    return null;
  }
  final current = _compactGameVersionId(integrity.currentGameVersionId);
  final baseline = _compactGameVersionList(
    integrity.baselineSupportedGameVersionIds,
  );
  return 'Steam build 疑似已更新：当前 $current，原始备份支持 $baseline；同时文件不等于原始备份、准备包或上次写入包。先保存新文件记录，再决定只接受新文件还是生成测试准备包。';
}

String? _gameUpdateActivityMeta(GameFileIntegritySummary integrity) {
  if (integrity.level != GameFileIntegrityLevel.gameChanged ||
      integrity.baselineBuildCompatible) {
    return null;
  }
  final current = _compactGameVersionId(integrity.currentGameVersionId);
  final baseline = _compactGameVersionList(
    integrity.baselineSupportedGameVersionIds,
  );
  return '当前 $current · 原始备份 $baseline';
}

String _compactGameVersionId(String? versionId) {
  final value = versionId?.trim();
  if (value == null || value.isEmpty) return '未知 build';
  return value.replaceFirst('steam-b', 'Steam ');
}

String _compactGameVersionList(List<String> versionIds) {
  final values = versionIds
      .map(_compactGameVersionId)
      .where((value) => value.trim().isNotEmpty)
      .toList(growable: false);
  if (values.isEmpty) return '未记录';
  if (values.length <= 2) return values.join(' / ');
  return '${values.take(2).join(' / ')} 等 ${values.length} 个 build';
}

_DetailSummary _toolDetailSummary(StudioState s) {
  if (s.toolchainRefreshing) {
    return const _DetailSummary(
      tone: _Tone.info,
      pills: [_MicroPill(label: '检测中', tone: _Tone.info)],
    );
  }
  final sections = s.toolchainStatus.sections;
  final ok = sections.where(_sectionReady).length;
  final warn = sections
      .where((section) => !_sectionReady(section) && !_sectionDanger(section))
      .length;
  final danger = sections.where(_sectionDanger).length;
  return _DetailSummary(
    tone: danger > 0
        ? _Tone.danger
        : warn > 0
        ? _Tone.warn
        : _Tone.ok,
    pills: [
      if (ok > 0) _MicroPill(label: '$ok Ready', tone: _Tone.ok),
      if (warn > 0) _MicroPill(label: '$warn Optional', tone: _Tone.warn),
      if (danger > 0) _MicroPill(label: '$danger Blocking', tone: _Tone.danger),
      if (sections.isEmpty)
        _MicroPill(
          label: s.toolchainStatus.checked ? s.toolchainStatus.label : '未检查',
          tone: _Tone.muted,
        ),
    ],
  );
}

_DetailSummary _fileDetailSummary(StudioState s) {
  if (s.fileIntegrityRefreshing) {
    return const _DetailSummary(
      tone: _Tone.info,
      pills: [_MicroPill(label: '扫描中', tone: _Tone.info)],
    );
  }
  final confirmationTarget = _confirmationTargetFor(s);
  final tone = confirmationTarget == null
      ? _integrityTone(s.fileIntegrity)
      : _Tone.ready;
  return _DetailSummary(
    tone: tone,
    pills: [
      _MicroPill(
        label: s.fileIntegrity.checkedFiles > 0
            ? '${s.fileIntegrity.checkedFiles} 已校验'
            : '未校验',
        tone: s.fileIntegrity.checkedFiles > 0 ? _Tone.ok : _Tone.muted,
      ),
      _MicroPill(
        label: confirmationTarget != null
            ? '待确认'
            : s.fileIntegrity.hasPendingBaseline
            ? '新文件'
            : '无新文件',
        tone: confirmationTarget != null
            ? _Tone.ready
            : s.fileIntegrity.hasPendingBaseline
            ? _Tone.warn
            : _Tone.muted,
      ),
    ],
  );
}

class _DetailSummary {
  const _DetailSummary({required this.tone, required this.pills});

  final _Tone tone;
  final List<Widget> pills;
}

class _FileConclusion {
  const _FileConclusion({
    required this.tone,
    required this.title,
    required this.next,
  });

  final _Tone tone;
  final String title;
  final String next;
}

_FileConclusion _fileConclusion(BuildContext context, StudioState s) {
  final integrity = s.fileIntegrity;
  return switch (integrity.level) {
    GameFileIntegrityLevel.packageApplied => const _FileConclusion(
      tone: _Tone.ok,
      title: '写入完成 · 文件 = 准备包',
      next: '可以启动游戏验证；如需回到官方文件，使用原始备份或 Steam 验证完整性。',
    ),
    GameFileIntegrityLevel.baseline => _FileConclusion(
      tone: _Tone.ok,
      title: integrity.hasPackage ? '游戏文件 = 原始备份' : '原始备份已建立',
      next: integrity.hasPackage ? '可以安全写入准备包；写入前仍会弹出安全确认。' : '可以去播放列表准备电台包。',
    ),
    GameFileIntegrityLevel.previousPackageApplied => _FileConclusion(
      tone: s.currentPackageReady ? _Tone.warn : _Tone.ok,
      title: '上一版准备包已写入',
      next: s.currentPackageReady
          ? '当前准备包还没有覆盖进去；确认后可以写入新的准备包。'
          : '当前工作区还没有新的准备包；可以继续编辑并重新准备，也可以直接进游戏验证上一版。',
    ),
    GameFileIntegrityLevel.noPackage => _FileConclusion(
      tone: integrity.hasCurrentBaseline ? _Tone.warn : _Tone.danger,
      title: integrity.hasCurrentBaseline ? '还没有准备包' : '需要创建原始备份',
      next: integrity.hasCurrentBaseline
          ? '准备电台包后会显示它是否已写入游戏。'
          : '先创建原始备份，后续才能安全写入。',
    ),
    GameFileIntegrityLevel.noBaseline => const _FileConclusion(
      tone: _Tone.danger,
      title: '缺少原始备份',
      next: '请在 fresh install 或 Steam 验证完整性后创建原始备份。',
    ),
    GameFileIntegrityLevel.buildBumpAvailable => const _FileConclusion(
      tone: _Tone.warn,
      title: 'Steam build id 已变化，但文件仍等于原始备份',
      next: '可以更新 build 兼容记录，无需重建原始备份。',
    ),
    GameFileIntegrityLevel.gameChanged => _FileConclusion(
      tone: _Tone.warn,
      title: '${_changedFileCount(integrity)} 个文件待确认',
      next: '先保存新文件记录，再选择只接受新文件或构建测试准备包。',
    ),
    GameFileIntegrityLevel.externalConflict => const _FileConclusion(
      tone: _Tone.danger,
      title: '游戏文件冲突',
      next: 'Steam build 未变化但文件不属于任何可信状态；请选择写回旧的基线或保存当前文件。',
    ),
    GameFileIntegrityLevel.pendingVerify => _FileConclusion(
      tone: s.pendingPackageBuildFailed && _confirmationTargetFor(s) == null
          ? _Tone.danger
          : _confirmationTargetFor(s) == null
          ? _Tone.warn
          : _Tone.ready,
      title: s.pendingPackageBuildFailed && _confirmationTargetFor(s) == null
          ? '新文件 · 测试准备包生成失败'
          : s.pendingPackageBuildFailed
          ? '确认 · 测试准备包生成失败'
          : _confirmationTargetFor(s) == null
          ? '新游戏文件等待验证'
          : '确认 · 当前命中 ${_confirmationMatchedSet(_confirmationTargetFor(s))}',
      next: s.pendingPackageBuildFailed && _confirmationTargetFor(s) == null
          ? '测试准备包记录已保留但没有可写入文件；请手动选择写回旧的基线、接受新游戏文件或重新生成。'
          : s.pendingPackageBuildFailed
          ? '测试准备包记录已保留但没有可写入文件；确认后只会接受新游戏文件。'
          : _confirmationTargetFor(s) == null
          ? '写入测试准备包后确认新版本；失败时放弃新文件或写回旧的基线。'
          : '确认这是可用的后，会清理待确认记录；失败时写回旧的基线或放弃新文件。',
    ),
    GameFileIntegrityLevel.unknown => const _FileConclusion(
      tone: _Tone.warn,
      title: '部分文件缺少校验记录',
      next: '建议重新扫描文件，必要时重新准备包或重建原始备份。',
    ),
  };
}

_Tone _displayLanguageTone(StudioState s) {
  if (!s.voiceSlotVerified || !s.sourceLanguageExists) return _Tone.warn;
  if (s.languageSelectionMatchesGame) return _Tone.ok;
  if (s.languageSelectionPrepared) return _Tone.info;
  return _Tone.danger;
}

_Tone _voiceLanguageTone(StudioState s) {
  if (!s.targetLanguageExists) return _Tone.warn;
  if (s.languageSelectionMatchesGame) return _Tone.ok;
  if (s.languageSelectionPrepared) return _Tone.info;
  return _Tone.danger;
}

_Tone _languageOverallTone(StudioState s) {
  if (s.languageReady && s.languageSelectionMatchesGame) return _Tone.ok;
  if (s.languageSelectionPrepared) return _Tone.info;
  if (!s.sourceLanguageExists ||
      !s.targetLanguageExists ||
      !s.voiceSlotVerified) {
    return _Tone.warn;
  }
  return _Tone.danger;
}

String _displayLanguageHelper(StudioState s) {
  if (!s.voiceSlotVerified) {
    return '缺少原始备份，无法判断 ${s.gameTargetLang}.zip';
  }
  if (!s.sourceLanguageExists) return '缺少 ${s.sourceLang}.zip';
  if (s.languageSelectionMatchesGame) {
    return '游戏当前显示 ${s.gameSourceLang}';
  }
  if (s.languageSelectionPrepared) {
    return '准备包已包含 ${s.sourceLang} 显示';
  }
  return '已改为 ${s.sourceLang}，尚未准备';
}

String _voiceLanguageHelper(StudioState s) {
  if (!s.targetLanguageExists) return '缺少 ${s.targetLang}.zip';
  if (s.languageSelectionMatchesGame) {
    return s.preferredLang == '未设置' || s.preferredLang.toLowerCase() == 'auto'
        ? 'UserPreferredLang auto'
        : 'UserPreferredLang ${s.preferredLang}';
  }
  if (s.languageSelectionPrepared) {
    return '准备包会写入 ${s.targetLang}';
  }
  return '已改为 ${s.targetLang}，尚未准备';
}

_Tone _aiPipelineTone(StudioState s) {
  if (s.aiProfileNotice != null) return _Tone.warn;
  final ai = s.toolchainStatus.section('ai');
  if (ai == null) return _Tone.muted;
  return _toolchainTone(ai.status, optional: true);
}

String _aiPipelineHelper(StudioState s) {
  if (s.aiProfileNotice != null) return '已自动降级';
  final providers = aiWarmupProvidersForProfile(s.aiProfile);
  final ai = s.toolchainStatus.section('ai');
  if (ai == null) return '全量刷新后检查 Provider';
  if (_sectionReady(ai)) {
    return providers.isEmpty ? '中杯无需深度 Provider' : 'Provider 已加载';
  }
  return '大杯 / 超大杯 Provider 未加载';
}

String _languageLabel(String code) {
  return switch (code.toUpperCase()) {
    'CHS' => 'CHS · 简体中文',
    'CHT' => 'CHT · 繁體中文',
    'EN' => 'EN · English',
    'JP' || 'JA' => '$code · 日本語',
    'KR' || 'KO' => '$code · 한국어',
    'FR' => 'FR · Français',
    'DE' => 'DE · Deutsch',
    'ES' => 'ES · Español',
    'IT' => 'IT · Italiano',
    'PT' => 'PT · Português',
    _ => code.toUpperCase(),
  };
}

String _compactPath(String path) {
  final normalized = path.replaceAll('\\', '/');
  final base = p.basename(normalized);
  final parent = p.basename(p.dirname(normalized));
  if (parent.isEmpty || parent == '.') return base;
  return '.../$parent/$base';
}

bool _looksLikePathValue(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) return false;
  if (RegExp(r'^[A-Za-z]:[\\/]').hasMatch(trimmed)) return true;
  if (trimmed.contains(r'\') || trimmed.contains('/')) return true;
  return RegExp(
    r'(\.exe|\.json|\.toml|\.lock|\.py|\.wav|\.flac)$',
    caseSensitive: false,
  ).hasMatch(trimmed);
}

String _md5ReportText(StudioState s) {
  final i = s.fileIntegrity;
  return [
    'FH Radio Studio 文件校验报告',
    '状态: ${i.title}',
    '详情: ${i.detail}',
    '已校验: ${i.checkedFiles}',
    '等于准备包: ${i.packageMatches}',
    '等于原始备份: ${i.baselineMatches}',
    '等于新游戏文件: ${i.pendingBaselineMatches}',
    '未知/变化: ${i.unknownFiles + i.changedFiles}',
    '原始备份记录: ${i.baselineManifestPath ?? '无'}',
    '新游戏文件记录: ${i.pendingBaselineManifestPath ?? '无'}',
    '准备包记录: ${i.packageManifestPath ?? '无'}',
  ].join('\n');
}

String _diagnosticSnapshot(StudioState s) {
  return [
    'FH Radio Studio dashboard diagnostic snapshot',
    'busy=${s.busy} label=${s.busyLabel ?? ''}',
    'cli_calls=${_diagnosticCallCount(s.log)}',
    'toolchain=${s.toolchainStatus.status} ${aiProfileUserText(s.toolchainStatus.summary)}',
    'language=${s.languageSummary}',
    'integrity=${s.fileIntegrity.title} ${s.fileIntegrity.detail}',
    'package=${s.lastPackageDir ?? 'none'}',
    'pendingPackage=${s.pendingPackageDir ?? 'none'}',
    '',
    ..._diagnosticLogLines(s.log).take(240),
  ].join('\n');
}

String _diagnosticCallCountLabel(List<String> log) {
  final count = _diagnosticCallCount(log);
  if (log.isEmpty) return '0 次 CLI call · 空闲';
  return '$count 次 CLI call';
}

int _diagnosticCallCount(List<String> log) =>
    log.where(_isDiagnosticCallStart).length;

String _diagnosticLogText(List<String> log) =>
    _diagnosticLogLines(log).join('\n');

List<String> _diagnosticLogLines(List<String> log) {
  if (log.isEmpty) return const ['无最近日志。'];
  final lines = <String>[];
  var call = 0;
  for (final line in log) {
    if (_isDiagnosticCallStart(line)) {
      call += 1;
      if (lines.isNotEmpty && lines.last.trim().isNotEmpty) lines.add('');
      lines.add('---------- CLI CALL #$call ----------');
    }
    lines.add(line);
  }
  return lines;
}

bool _isDiagnosticCallStart(String line) => line.trimLeft().startsWith('执行：');

bool _looksLikeError(String line) {
  final lower = line.toLowerCase();
  return lower.contains('err ') ||
      lower.contains('error') ||
      lower.contains('failed') ||
      lower.contains('traceback') ||
      line.contains('失败') ||
      line.contains('异常');
}

const _blockingToolchainSectionIds = {'uv', 'python', 'audio_tools'};

List<ToolchainStatusSection> _orderedOptionalToolchainSections(
  List<ToolchainStatusSection> sections,
) {
  final optional = sections
      .where((section) => !_blockingToolchainSectionIds.contains(section.id))
      .toList();
  final hardwareIndex = optional.indexWhere(
    (section) => section.id == 'hardware',
  );
  if (hardwareIndex == -1) return optional;

  final hardware = optional.removeAt(hardwareIndex);
  final aiIndex = optional.indexWhere((section) => section.id == 'ai');
  if (aiIndex == -1) {
    optional.insert(hardwareIndex, hardware);
  } else {
    optional.insert(aiIndex + 1, hardware);
  }
  return optional;
}

bool _sectionReady(ToolchainStatusSection section) {
  return section.status == 'ready' || section.status == 'ok';
}

bool _hardwareAccelerationReady(ToolchainStatusSummary toolchain) {
  final hardware = toolchain.section('hardware');
  if (hardware == null || !_sectionReady(hardware)) return false;

  final summary = hardware.summary.trim().toLowerCase();
  if (summary.contains('cuda') &&
      (summary.contains('可用') || summary.contains('available'))) {
    return true;
  }

  return hardware.items.any((item) {
    final label = item.label.trim().toLowerCase();
    final value = item.value.trim().toLowerCase();
    final detail = item.detail.trim().toLowerCase();
    if (label == 'cuda') return _truthyCudaValue(value);
    if (label == 'device' && value == 'cuda') return true;
    if (label == 'nvidia' &&
        (value.contains('cuda true') || detail.contains('cuda true'))) {
      return true;
    }
    return false;
  });
}

bool _truthyCudaValue(String value) {
  return value == 'true' ||
      value == 'yes' ||
      value == '1' ||
      value == 'available' ||
      value == 'cuda' ||
      value == 'cuda true';
}

bool _sectionDanger(ToolchainStatusSection section) {
  return _blockingToolchainSectionIds.contains(section.id) &&
      (section.status == 'missing' ||
          section.status == 'error' ||
          section.status == 'danger');
}

_Tone _toolchainTone(String status, {required bool optional}) {
  return switch (status) {
    'checking' => _Tone.info,
    'ready' || 'ok' => _Tone.ok,
    'missing' || 'error' || 'danger' => optional ? _Tone.warn : _Tone.danger,
    'degraded' || 'partial' || 'needs_sync' || 'warn' => _Tone.warn,
    _ => _Tone.muted,
  };
}

String _toolchainStatusLabel(String status) {
  return switch (status) {
    'checking' => '检测中',
    'ready' || 'ok' => 'OK',
    'degraded' => '降级',
    'partial' => '部分',
    'needs_sync' => '需同步',
    'missing' => '缺失',
    'error' || 'danger' => '异常',
    'warn' => '注意',
    _ => '信息',
  };
}

Color _toneColor(BuildContext context, _Tone tone) {
  final rm = context.rm;
  return switch (tone) {
    _Tone.ok || _Tone.ready => rm.accent.base,
    _Tone.info => rm.info,
    _Tone.warn => rm.warn,
    _Tone.danger => rm.danger,
    _Tone.muted => rm.fg3,
  };
}

Color _toneBg(BuildContext context, _Tone tone) {
  final rm = context.rm;
  return switch (tone) {
    _Tone.ok || _Tone.ready => rm.accent.bg,
    _Tone.info => rm.info.withAlpha(18),
    _Tone.warn => rm.warnBg,
    _Tone.danger => rm.dangerBg,
    _Tone.muted => rm.raised,
  };
}
