import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:fh_radio_studio/screens/playlist.dart';
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
  final config = _CaptureConfig.fromArgs(args);
  final prefs = await SharedPreferences.getInstance();
  final prefsSnapshot = _PrefsSnapshot(
    prefs: prefs,
    projectDir: prefs.getString(_projectDirKey),
    repoRoot: prefs.getString(_repoRootKey),
  );
  await prefs.setString(_projectDirKey, config.projectDir);
  await prefs.setString(_repoRootKey, config.repoRoot);

  runApp(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        if (config.baselineLocked)
          studioProvider.overrideWith((ref) => _LockedStudioController(prefs)),
      ],
      child: _PlaylistCaptureApp(config: config, prefsSnapshot: prefsSnapshot),
    ),
  );
}

class _LockedStudioController extends StudioController {
  _LockedStudioController(super.prefs) {
    state = state.copyWith(baselinePlanSummary: _lockedBaselinePlan);
  }
}

const _lockedBaselinePlan = BaselinePlanSummary(
  fileCount: 1,
  totalSize: 1024,
  gameVersionId: 'steam-b23271700',
  byScope: {'radio_bank': 1},
  byStatus: {'not_backed_up': 1},
  files: [
    BaselinePlanFile(
      scope: 'radio_bank',
      installRelativePath: 'media/audio/FMODBanks/R4_Tracks_CU1.assets.bank',
      sourceGamePath: '',
      size: 1024,
      md5: '00000000000000000000000000000000',
      exists: true,
      baselineStatus: 'not_backed_up',
      backupPath: null,
      backupMd5: null,
      packageMd5: null,
      coverageStatus: 'unchecked',
    ),
  ],
);

class _PlaylistCaptureApp extends StatefulWidget {
  const _PlaylistCaptureApp({
    required this.config,
    required this.prefsSnapshot,
  });

  final _CaptureConfig config;
  final _PrefsSnapshot prefsSnapshot;

  @override
  State<_PlaylistCaptureApp> createState() => _PlaylistCaptureAppState();
}

class _PlaylistCaptureAppState extends State<_PlaylistCaptureApp> {
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
            child: RepaintBoundary(
              key: _repaintKey,
              child: SizedBox.fromSize(
                size: size,
                child: const ColoredBox(
                  color: RmTokens.bgLight,
                  child: PlaylistScreen(),
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
      debugPrint('playlist_flutter_repaint_capture_error=$error');
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
      throw StateError('Playlist capture boundary was not found.');
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
      'playlist_flutter_repaint_capture_${capture.name}=${output.absolute.path}',
    );
  }
}

class _CaptureConfig {
  const _CaptureConfig({
    required this.projectDir,
    required this.repoRoot,
    required this.captures,
    required this.pixelRatio,
    required this.delay,
    required this.baselineLocked,
  });

  factory _CaptureConfig.fromArgs(List<String> args) {
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
    final timestamp = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '')
        .replaceAll('-', '')
        .split('.')
        .first;
    final captures = _parseCaptureSpecs(values, appRoot, timestamp);
    final baselineLocked =
        args.contains('--baseline-locked') ||
        values['baseline-locked'] == 'true' ||
        values['baseline-locked'] == '1';
    return _CaptureConfig(
      projectDir: projectDir,
      repoRoot: repoRoot,
      captures: captures,
      pixelRatio: double.tryParse(values['capture-pixel-ratio'] ?? '') ?? 1.5,
      delay: Duration(
        milliseconds: int.tryParse(values['capture-delay-ms'] ?? '') ?? 800,
      ),
      baselineLocked: baselineLocked,
    );
  }

  static List<_CaptureSpec> _parseCaptureSpecs(
    Map<String, String> values,
    String appRoot,
    String timestamp,
  ) {
    final legacyOutput = values['capture-out'];
    if (legacyOutput != null) {
      return [
        _CaptureSpec(
          name: 'single',
          outputPath: legacyOutput,
          logicalSize:
              _parseSize(values['capture-logical-size']) ??
              const Size(1365, 1800),
        ),
      ];
    }

    return [
      _CaptureSpec(
        name: 'regular',
        outputPath:
            values['capture-regular-out'] ??
            p.join(
              appRoot,
              'build',
              'playlist_flutter_repaint_regular_$timestamp.png',
            ),
        logicalSize:
            _parseSize(values['capture-regular-logical-size']) ??
            const Size(1365, 900),
      ),
      _CaptureSpec(
        name: 'full',
        outputPath:
            values['capture-full-out'] ??
            p.join(
              appRoot,
              'build',
              'playlist_flutter_repaint_full_$timestamp.png',
            ),
        logicalSize:
            _parseSize(values['capture-full-logical-size']) ??
            const Size(1365, 1800),
      ),
    ];
  }

  static Size? _parseSize(String? raw) {
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

  final String projectDir;
  final String repoRoot;
  final List<_CaptureSpec> captures;
  final double pixelRatio;
  final Duration delay;
  final bool baselineLocked;
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
