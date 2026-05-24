import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:path/path.dart' as p;
import 'package:fh_radio_studio/core/project_workspace.dart';
import 'package:fh_radio_studio/screens/dashboard.dart';
import 'package:fh_radio_studio/state/app_state.dart';
import 'package:fh_radio_studio/state/studio_state.dart';
import 'package:fh_radio_studio/theme/accents.dart';
import 'package:fh_radio_studio/theme/app_theme.dart';
import 'package:fh_radio_studio/theme/tokens.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _projectDirKey = 'rm.studio.projectDir';
const _repoRootKey = 'rm.studio.repoRoot';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  GoogleFonts.config.allowRuntimeFetching = false;
  final config = _DashboardCaptureConfig.fromArgs(args);
  FhRadioStudioProject.ensure(config.projectDir);

  final prefs = await SharedPreferences.getInstance();
  final prefsSnapshot = _PrefsSnapshot(
    prefs: prefs,
    projectDir: prefs.getString(_projectDirKey),
    repoRoot: prefs.getString(_repoRootKey),
  );
  await prefs.setString(_projectDirKey, config.projectDir);
  await prefs.setString(_repoRootKey, config.repoRoot);

  final controller = _DashboardCaptureController(prefs, config);
  runApp(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        studioProvider.overrideWith((ref) => controller),
      ],
      child: _DashboardCaptureApp(config: config, prefsSnapshot: prefsSnapshot),
    ),
  );
}

class _DashboardCaptureController extends StudioController {
  _DashboardCaptureController(super.prefs, _DashboardCaptureConfig config) {
    final readyToolchain = _toolchainReady(config);
    state = state.copyWith(
      gameDir: p.join(config.projectDir, 'game'),
      sourceLang: 'JP',
      targetLang: 'EN',
      gameSourceLang: 'CHS',
      gameTargetLang: 'EN',
      availableLanguages: const ['CHS', 'EN', 'JP'],
      preferredLang: 'EN',
      sourceLanguageExists: true,
      targetLanguageExists: true,
      targetMatchesSource: false,
      preferredMatchesTarget: true,
      voiceSlotVerified: true,
      languageReady: false,
      languageSummary: 'JP 显示 · EN 语音（准备包待写入）',
      busy: config.scanning,
      busyLabel: config.scanning ? '完整校验当前环境' : null,
      toolchainStatus: config.scanning
          ? ToolchainStatusSummary.checking(previous: readyToolchain)
          : readyToolchain,
      lastPackageDir: config.hasCurrentPackage
          ? p.join(config.projectDir, 'packages', 'current')
          : null,
      lastPackageSummary: config.hasCurrentPackage
          ? _packageSummary(sourceLang: 'CHS')
          : null,
      pendingPackageDir: config.hasPendingPackage
          ? p.join(config.projectDir, 'packages', 'pending')
          : null,
      pendingPackageSummary: config.hasPendingPackage
          ? _packageSummary(sourceLang: 'JP')
          : null,
      fileIntegrity: _integritySummary(
        level: config.integrityLevel,
        checkedFiles: config.checkedFiles,
        changedFiles: config.changedFiles,
        packageMatches: config.packageMatches,
        lastAppliedPackageMatches: config.lastAppliedPackageMatches,
        pendingBaselineMatches: config.pendingBaselineMatches,
        baselineMatches: config.baselineMatches,
        hasPendingBaseline: config.hasPendingBaseline,
        currentGameVersionId: config.currentGameVersionId,
        baselineBuildCompatible: config.baselineBuildCompatible,
        baselineSupportedGameVersionIds: config.baselineSupportedGameVersionIds,
        issues: config.issues,
      ),
      log: [
        config.scanning
            ? 'dashboard scanning capture fixture loaded'
            : 'dashboard capture fixture loaded',
      ],
    );
  }

  @override
  Future<void> startupFullCheckOnce() async {}
}

class _DashboardCaptureApp extends StatefulWidget {
  const _DashboardCaptureApp({
    required this.config,
    required this.prefsSnapshot,
  });

  final _DashboardCaptureConfig config;
  final _PrefsSnapshot prefsSnapshot;

  @override
  State<_DashboardCaptureApp> createState() => _DashboardCaptureAppState();
}

class _DashboardCaptureAppState extends State<_DashboardCaptureApp> {
  final _repaintKey = GlobalKey();
  var _captureIndex = 0;

  _CaptureSpec get _currentCapture => widget.config.captures[_captureIndex];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _captureCurrent());
  }

  @override
  Widget build(BuildContext context) {
    final size = _currentCapture.logicalSize;
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(
        brightness: Brightness.light,
        accent: AppAccent.lime,
      ),
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: OverflowBox(
            alignment: Alignment.topLeft,
            minWidth: size.width,
            maxWidth: size.width,
            minHeight: size.height,
            maxHeight: size.height,
            child: ExcludeSemantics(
              child: RepaintBoundary(
                key: _repaintKey,
                child: SizedBox.fromSize(
                  size: size,
                  child: ColoredBox(
                    color: RmTokens.bgLight,
                    child: DashboardScreen(
                      initialToolOpen: widget.config.initialToolOpen,
                      initialFileOpen: widget.config.initialFileOpen,
                      initialDiagOpen: widget.config.initialDiagOpen,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _captureCurrent() async {
    var exitCode = 0;
    var shouldExit = true;
    try {
      await _waitForPaint();
      await Future<void>.delayed(widget.config.delay);
      await _writeCapture(_currentCapture);
      if (_captureIndex + 1 < widget.config.captures.length) {
        setState(() => _captureIndex += 1);
        WidgetsBinding.instance.addPostFrameCallback((_) => _captureCurrent());
        shouldExit = false;
        return;
      }
    } catch (error, stackTrace) {
      exitCode = 1;
      debugPrint('dashboard_flutter_repaint_capture_error=$error');
      debugPrintStack(stackTrace: stackTrace);
    } finally {
      if (shouldExit) {
        await widget.prefsSnapshot.restore();
        exit(exitCode);
      }
    }
  }

  Future<void> _waitForPaint() async {
    for (var i = 0; i < 20; i += 1) {
      await WidgetsBinding.instance.endOfFrame;
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final boundary = _repaintKey.currentContext?.findRenderObject();
      if (boundary is RenderRepaintBoundary && !boundary.debugNeedsPaint) {
        return;
      }
    }
  }

  Future<void> _writeCapture(_CaptureSpec capture) async {
    final boundary = _repaintKey.currentContext?.findRenderObject();
    if (boundary is! RenderRepaintBoundary) {
      throw StateError('Dashboard capture boundary was not found.');
    }
    final image = await boundary.toImage(pixelRatio: widget.config.pixelRatio);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    if (png == null) {
      throw StateError('Flutter did not return PNG bytes.');
    }
    final output = File(capture.outputPath);
    await output.parent.create(recursive: true);
    await output.writeAsBytes(png.buffer.asUint8List(), flush: true);
    debugPrint(
      'dashboard_flutter_repaint_capture_${capture.name}=${output.absolute.path}',
    );
  }
}

class _DashboardCaptureConfig {
  const _DashboardCaptureConfig({
    required this.projectDir,
    required this.repoRoot,
    required this.captures,
    required this.pixelRatio,
    required this.delay,
    required this.scanning,
    required this.aiReady,
    required this.initialToolOpen,
    required this.initialFileOpen,
    required this.initialDiagOpen,
    required this.integrityLevel,
    required this.checkedFiles,
    required this.changedFiles,
    required this.packageMatches,
    required this.lastAppliedPackageMatches,
    required this.baselineMatches,
    required this.pendingBaselineMatches,
    required this.hasPendingBaseline,
    required this.hasCurrentPackage,
    required this.hasPendingPackage,
    required this.currentGameVersionId,
    required this.baselineBuildCompatible,
    required this.baselineSupportedGameVersionIds,
    required this.issues,
  });

  factory _DashboardCaptureConfig.fromArgs(List<String> args) {
    final values = <String, String>{};
    for (final arg in args) {
      final separator = arg.indexOf('=');
      if (!arg.startsWith('--') || separator <= 2) continue;
      values[arg.substring(2, separator)] = arg.substring(separator + 1);
    }
    final appRoot = Directory.current.path;
    final repoRoot = values['repo-root'] ?? p.dirname(appRoot);
    final projectDir =
        values['project-dir'] ??
        p.join(repoRoot, 'test', 'project', 'cli-full-flow');
    final openDetails = (values['open-details'] ?? '')
        .split(',')
        .map((value) => value.trim().toLowerCase())
        .where((value) => value.isNotEmpty)
        .toSet();
    return _DashboardCaptureConfig(
      projectDir: projectDir,
      repoRoot: repoRoot,
      captures: [
        _CaptureSpec(
          name: 'regular',
          outputPath:
              values['capture-regular-out'] ??
              p.join(appRoot, 'build', 'visual_qa', 'dashboard_regular.png'),
          logicalSize:
              _parseSize(values['capture-regular-logical-size']) ??
              const Size(1365, 900),
        ),
        _CaptureSpec(
          name: 'full',
          outputPath:
              values['capture-full-out'] ??
              p.join(appRoot, 'build', 'visual_qa', 'dashboard_full.png'),
          logicalSize:
              _parseSize(values['capture-full-logical-size']) ??
              const Size(1365, 1800),
        ),
      ],
      pixelRatio: double.tryParse(values['capture-pixel-ratio'] ?? '') ?? 1.5,
      delay: Duration(
        milliseconds: int.tryParse(values['capture-delay-ms'] ?? '') ?? 800,
      ),
      scanning: _parseBool(values['scanning'] ?? values['scan']),
      aiReady: _parseBool(values['ai-ready'] ?? values['ai-ok']),
      initialToolOpen: openDetails.contains('tool'),
      initialFileOpen:
          openDetails.contains('file') ||
          _parseBool(values['initial-file-open']),
      initialDiagOpen: openDetails.contains('diag'),
      integrityLevel:
          _parseIntegrityLevel(values['integrity-level']) ??
          GameFileIntegrityLevel.pendingVerify,
      checkedFiles: int.tryParse(values['checked-files'] ?? '') ?? 63,
      changedFiles: int.tryParse(values['changed-files'] ?? '') ?? 0,
      packageMatches: int.tryParse(values['package-matches'] ?? '') ?? 0,
      lastAppliedPackageMatches:
          int.tryParse(values['last-applied-matches'] ?? '') ?? 0,
      baselineMatches: int.tryParse(values['baseline-matches'] ?? '') ?? 54,
      pendingBaselineMatches:
          int.tryParse(values['pending-baseline-matches'] ?? '') ?? 9,
      hasPendingBaseline: _parseBool(
        values['has-pending-baseline'] ?? values['pending-baseline'] ?? 'true',
      ),
      hasCurrentPackage: values.containsKey('has-current-package')
          ? _parseBool(values['has-current-package'])
          : true,
      hasPendingPackage: _parseBool(
        values['has-pending-package'] ?? values['pending-package'] ?? 'true',
      ),
      currentGameVersionId:
          values['current-game-version-id'] ?? 'steam-b23271700',
      baselineBuildCompatible: values.containsKey('baseline-build-compatible')
          ? _parseBool(values['baseline-build-compatible'])
          : true,
      baselineSupportedGameVersionIds:
          _parseCsv(values['baseline-supported-game-version-ids']) ??
          const ['steam-b23271700'],
      issues: _issuesFromArgs(values),
    );
  }

  final String projectDir;
  final String repoRoot;
  final List<_CaptureSpec> captures;
  final double pixelRatio;
  final Duration delay;
  final bool scanning;
  final bool aiReady;
  final bool initialToolOpen;
  final bool initialFileOpen;
  final bool initialDiagOpen;
  final GameFileIntegrityLevel integrityLevel;
  final int checkedFiles;
  final int changedFiles;
  final int packageMatches;
  final int lastAppliedPackageMatches;
  final int baselineMatches;
  final int pendingBaselineMatches;
  final bool hasPendingBaseline;
  final bool hasCurrentPackage;
  final bool hasPendingPackage;
  final String currentGameVersionId;
  final bool baselineBuildCompatible;
  final List<String> baselineSupportedGameVersionIds;
  final List<Map<String, Object?>> issues;
}

bool _parseBool(String? value) {
  return switch (value?.trim().toLowerCase()) {
    '1' || 'true' || 'yes' || 'on' => true,
    _ => false,
  };
}

GameFileIntegrityLevel? _parseIntegrityLevel(String? value) {
  final normalized = value?.trim().toLowerCase().replaceAll('-', '_');
  if (normalized == null || normalized.isEmpty) return null;
  return switch (normalized) {
    'no_package' => GameFileIntegrityLevel.noPackage,
    'no_baseline' => GameFileIntegrityLevel.noBaseline,
    'package_applied' => GameFileIntegrityLevel.packageApplied,
    'previous_package_applied' => GameFileIntegrityLevel.previousPackageApplied,
    'baseline' => GameFileIntegrityLevel.baseline,
    'build_bump_available' => GameFileIntegrityLevel.buildBumpAvailable,
    'game_changed' => GameFileIntegrityLevel.gameChanged,
    'external_conflict' => GameFileIntegrityLevel.externalConflict,
    'pending_verify' => GameFileIntegrityLevel.pendingVerify,
    'unknown' => GameFileIntegrityLevel.unknown,
    _ => null,
  };
}

List<String>? _parseCsv(String? value) {
  final items = value
      ?.split(',')
      .map((item) => item.trim())
      .where((item) => item.isNotEmpty)
      .toList(growable: false);
  if (items == null || items.isEmpty) return null;
  return items;
}

List<Map<String, Object?>> _issuesFromArgs(Map<String, String> values) {
  final detail = values['issue-detail'];
  if (detail == null || detail.trim().isEmpty) return const [];
  return [
    {
      'label': values['issue-label'] ?? 'media/audio/RadioInfo_CN.xml',
      'path': values['issue-path'] ?? r'C:\FH6\media\audio\RadioInfo_CN.xml',
      'detail': detail,
      'level': values['issue-level'] ?? values['integrity-level'] ?? 'unknown',
    },
  ];
}

class _CaptureSpec {
  const _CaptureSpec({
    required this.name,
    required this.outputPath,
    required this.logicalSize,
  });

  final String name;
  final String outputPath;
  final Size logicalSize;
}

class _PrefsSnapshot {
  const _PrefsSnapshot({
    required this.prefs,
    required this.projectDir,
    required this.repoRoot,
  });

  final SharedPreferences prefs;
  final String? projectDir;
  final String? repoRoot;

  Future<void> restore() async {
    await _restoreString(_projectDirKey, projectDir);
    await _restoreString(_repoRootKey, repoRoot);
  }

  Future<void> _restoreString(String key, String? value) {
    if (value == null) return prefs.remove(key);
    return prefs.setString(key, value);
  }
}

ToolchainStatusSummary _toolchainReady(_DashboardCaptureConfig config) {
  final toolchain = p.join(
    config.repoRoot,
    '.fh-radio-studio-dev',
    'toolchain',
  );
  return ToolchainStatusSummary(
    checked: true,
    profile: 'local-heavy',
    status: 'ready',
    label: 'OK',
    summary: '核心工具链可用；AI 和硬件加速会按实际能力降级。',
    sections: [
      ToolchainStatusSection(
        id: 'uv',
        title: 'uv 运行时',
        status: 'ready',
        summary: 'uv 可用',
        items: [
          ToolchainStatusItem(
            label: '环境',
            value: p.join(toolchain, 'envs', 'base'),
            detail: '',
            status: 'info',
          ),
          ToolchainStatusItem(
            label: '缓存',
            value: p.join(toolchain, 'uv', 'cache'),
            detail: '',
            status: 'info',
          ),
        ],
        warnings: const [],
      ),
      ToolchainStatusSection(
        id: 'python',
        title: 'Python 环境',
        status: 'ready',
        summary: '依赖已覆盖当前 profile',
        items: [
          ToolchainStatusItem(
            label: 'Python',
            value: p.join(config.repoRoot, '.venv', 'Scripts', 'python.exe'),
            detail: '',
            status: 'ready',
          ),
          const ToolchainStatusItem(
            label: 'numpy',
            value: '2.4.6',
            detail: '',
            status: 'ready',
          ),
        ],
        warnings: const [],
      ),
      ToolchainStatusSection(
        id: 'audio_tools',
        title: '核心音频工具',
        status: 'ready',
        summary: 'ffmpeg / vgmstream / fsbankcl 全部可用',
        items: [
          ToolchainStatusItem(
            label: 'ffmpeg',
            value: p.join(toolchain, 'tools', 'audio', 'ffmpeg', 'ffmpeg.exe'),
            detail: '',
            status: 'ready',
          ),
          ToolchainStatusItem(
            label: 'vgmstream-cli',
            value: p.join(
              toolchain,
              'tools',
              'audio',
              'vgmstream',
              'vgmstream-cli.exe',
            ),
            detail: '',
            status: 'ready',
          ),
          ToolchainStatusItem(
            label: 'fsbankcl',
            value: p.join(toolchain, 'tools', 'audio', 'fmod', 'fsbankcl.exe'),
            detail: '',
            status: 'ready',
          ),
        ],
        warnings: const [],
      ),
      const ToolchainStatusSection(
        id: 'hardware',
        title: '硬件加速',
        status: 'ready',
        summary: 'CUDA 可用',
        items: [
          ToolchainStatusItem(
            label: 'NVIDIA',
            value: 'CUDA true',
            detail: '',
            status: 'ready',
          ),
          ToolchainStatusItem(
            label: 'Torch',
            value: '2.7.1+cu128',
            detail: '',
            status: 'ready',
          ),
        ],
        warnings: [],
      ),
      ToolchainStatusSection(
        id: 'ai',
        title: 'AI Provider',
        status: config.aiReady ? 'ready' : 'missing',
        summary: config.aiReady ? 'AI Providers 已就绪' : '深度 Provider 未加载',
        items: [
          ToolchainStatusItem(
            label: 'Model Dir',
            value: p.join(toolchain, 'tools', 'ai', 'models'),
            detail: '',
            status: 'info',
          ),
          if (config.aiReady) ...const [
            ToolchainStatusItem(
              label: 'baseline_mir',
              value: 'ready',
              detail: 'baseline',
              status: 'ready',
            ),
            ToolchainStatusItem(
              label: 'beat_this',
              value: 'ready',
              detail: 'beat-this 0.0.1',
              status: 'ready',
            ),
            ToolchainStatusItem(
              label: 'songformer',
              value: 'ready',
              detail: 'ASLP-lab/SongFormer',
              status: 'ready',
            ),
          ] else
            const ToolchainStatusItem(
              label: 'base',
              value: 'baseline_mir ok',
              detail: '',
              status: 'ready',
            ),
        ],
        warnings: const [],
      ),
    ],
    fixes: const [],
  );
}

PackageArtifactSummary _packageSummary({required String sourceLang}) {
  return PackageArtifactSummary(
    radio: 4,
    station: 'Horizon XS',
    bankName: 'R4_Tracks_CU1.assets.bank',
    musicCount: 1,
    bankSlots: 25,
    playlistMode: 'only',
    skipBank: false,
    runtimeVerified: true,
    sourceLang: sourceLang,
    targetLang: 'EN',
    previewTracks: const ['Test Track'],
    assignments: const [],
  );
}

GameFileIntegritySummary _integritySummary({
  required GameFileIntegrityLevel level,
  required int checkedFiles,
  int changedFiles = 0,
  int packageMatches = 0,
  int lastAppliedPackageMatches = 0,
  int baselineMatches = 0,
  int pendingBaselineMatches = 0,
  bool hasPendingBaseline = false,
  String currentGameVersionId = 'steam-b23271700',
  bool baselineBuildCompatible = true,
  List<String> baselineSupportedGameVersionIds = const ['steam-b23271700'],
  List<Map<String, Object?>> issues = const [],
}) {
  String levelName(GameFileIntegrityLevel value) {
    return switch (value) {
      GameFileIntegrityLevel.noPackage => 'no_package',
      GameFileIntegrityLevel.noBaseline => 'no_baseline',
      GameFileIntegrityLevel.packageApplied => 'package_applied',
      GameFileIntegrityLevel.previousPackageApplied =>
        'previous_package_applied',
      GameFileIntegrityLevel.baseline => 'baseline',
      GameFileIntegrityLevel.buildBumpAvailable => 'build_bump_available',
      GameFileIntegrityLevel.gameChanged => 'game_changed',
      GameFileIntegrityLevel.externalConflict => 'external_conflict',
      GameFileIntegrityLevel.pendingVerify => 'pending_verify',
      GameFileIntegrityLevel.unknown => 'unknown',
    };
  }

  return GameFileIntegritySummary.fromJson({
    'level': levelName(level),
    'checked_files': checkedFiles,
    'package_matches': packageMatches,
    'last_applied_package_matches': lastAppliedPackageMatches,
    'baseline_matches': baselineMatches,
    'pending_baseline_matches': pendingBaselineMatches,
    'changed_files': changedFiles,
    'unknown_files': 0,
    'package_files': checkedFiles,
    'baseline_manifest_path': 'baseline_manifest.json',
    'pending_baseline_manifest_path': hasPendingBaseline
        ? 'pending_baseline_manifest.json'
        : null,
    'package_manifest_path': 'fh_radio_studio_package_manifest.json',
    'last_applied_package_manifest_path': null,
    'current_game_version_id': currentGameVersionId,
    'baseline_build_compatible': baselineBuildCompatible,
    'baseline_supported_game_version_ids': baselineSupportedGameVersionIds,
    'issues': issues,
  });
}

Size? _parseSize(String? raw) {
  if (raw == null) return null;
  final separator = raw.indexOf('x');
  if (separator <= 0) return null;
  final width = double.tryParse(raw.substring(0, separator));
  final height = double.tryParse(raw.substring(separator + 1));
  if (width == null || height == null || width <= 0 || height <= 0) {
    return null;
  }
  return Size(width, height);
}
