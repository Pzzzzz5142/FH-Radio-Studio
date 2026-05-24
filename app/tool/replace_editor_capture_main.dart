import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;
import 'package:fh_radio_studio/screens/replace_editor.dart';
import 'package:fh_radio_studio/state/app_state.dart';
import 'package:fh_radio_studio/theme/accents.dart';
import 'package:fh_radio_studio/theme/app_theme.dart';
import 'package:fh_radio_studio/theme/tokens.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  GoogleFonts.config.allowRuntimeFetching = false;

  final config = _CaptureConfig.fromArgs(args);
  final prefs = await SharedPreferences.getInstance();

  runApp(
    ProviderScope(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      child: _ReplaceEditorCaptureApp(config: config),
    ),
  );
}

class _ReplaceEditorCaptureApp extends StatefulWidget {
  const _ReplaceEditorCaptureApp({required this.config});

  final _CaptureConfig config;

  @override
  State<_ReplaceEditorCaptureApp> createState() =>
      _ReplaceEditorCaptureAppState();
}

class _ReplaceEditorCaptureAppState extends State<_ReplaceEditorCaptureApp> {
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
        backgroundColor: RmTokens.bgLight,
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
                  child: ReplaceEditorScreen(trackId: 'cp-1'),
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
      debugPrint('replace_editor_capture_error=$error');
      debugPrintStack(stackTrace: stackTrace);
    } finally {
      if (shouldExit) {
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
      throw StateError('Replace editor capture boundary was not found.');
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
      'replace_editor_capture_${capture.name}=${output.absolute.path}',
    );
  }
}

class _CaptureConfig {
  const _CaptureConfig({
    required this.captures,
    required this.pixelRatio,
    required this.delay,
  });

  factory _CaptureConfig.fromArgs(List<String> args) {
    final values = <String, String>{};
    for (final arg in args) {
      final separator = arg.indexOf('=');
      if (!arg.startsWith('--') || separator <= 2) continue;
      values[arg.substring(2, separator)] = arg.substring(separator + 1);
    }

    final appRoot = Directory.current.path;
    final timestamp = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '')
        .replaceAll('-', '')
        .split('.')
        .first;
    return _CaptureConfig(
      captures: [
        _CaptureSpec(
          name: 'regular',
          outputPath:
              values['capture-regular-out'] ??
              p.join(
                appRoot,
                'build',
                'replace_editor_repaint_regular_$timestamp.png',
              ),
          logicalSize:
              _parseSize(values['capture-regular-logical-size']) ??
              const Size(1365, 850),
        ),
        _CaptureSpec(
          name: 'full',
          outputPath:
              values['capture-full-out'] ??
              p.join(
                appRoot,
                'build',
                'replace_editor_repaint_full_$timestamp.png',
              ),
          logicalSize:
              _parseSize(values['capture-full-logical-size']) ??
              const Size(1365, 1800),
        ),
      ],
      pixelRatio: double.tryParse(values['capture-pixel-ratio'] ?? '') ?? 1.5,
      delay: Duration(
        milliseconds: int.tryParse(values['capture-delay-ms'] ?? '') ?? 800,
      ),
    );
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

  final List<_CaptureSpec> captures;
  final double pixelRatio;
  final Duration delay;
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
