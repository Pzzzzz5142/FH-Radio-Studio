import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:path/path.dart' as p;
import 'package:fh_radio_studio/theme/accents.dart';
import 'package:fh_radio_studio/theme/app_theme.dart';
import 'package:fh_radio_studio/theme/tokens.dart';
import 'package:fh_radio_studio/widgets/package_build_notice_dialog.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  GoogleFonts.config.allowRuntimeFetching = false;
  runApp(_CaptureApp(config: _CaptureConfig.fromArgs(args)));
}

class _CaptureApp extends StatefulWidget {
  const _CaptureApp({required this.config});

  final _CaptureConfig config;

  @override
  State<_CaptureApp> createState() => _CaptureAppState();
}

class _CaptureAppState extends State<_CaptureApp> {
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
                  child: Center(
                    child: PackageBuildNoticeDialog(
                      title: '没有生成测试准备包',
                      message:
                          '当前没有发现需要单独测试的新游戏文件；这个入口只在游戏文件不同于原始备份或准备包时使用。要按当前播放列表生成普通包，请用「准备电台包」。',
                      languageChanged: false,
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
      debugPrint('package_build_notice_capture_error=$error');
      debugPrintStack(stackTrace: stackTrace);
    } finally {
      if (shouldExit) exit(exitCode);
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
      throw StateError('Package build notice capture boundary was not found.');
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
      'package_build_notice_capture_${capture.name}=${output.absolute.path}',
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
    String? valueFor(String name) {
      for (final arg in args) {
        final prefix = '$name=';
        if (arg.startsWith(prefix)) return arg.substring(prefix.length);
      }
      return null;
    }

    final regularOut =
        valueFor('--capture-regular-out') ??
        p.join('build', 'visual_qa', 'package_build_notice_dialog_regular.png');
    final fullOut =
        valueFor('--capture-full-out') ??
        p.join('build', 'visual_qa', 'package_build_notice_dialog_full.png');
    return _CaptureConfig(
      pixelRatio: double.tryParse(valueFor('--pixel-ratio') ?? '') ?? 1.5,
      delay: Duration(
        milliseconds: int.tryParse(valueFor('--delay-ms') ?? '') ?? 250,
      ),
      captures: [
        _CaptureSpec(
          name: 'regular',
          logicalSize: const Size(900, 640),
          outputPath: regularOut,
        ),
        _CaptureSpec(
          name: 'full',
          logicalSize: const Size(900, 900),
          outputPath: fullOut,
        ),
      ],
    );
  }

  final List<_CaptureSpec> captures;
  final double pixelRatio;
  final Duration delay;
}

class _CaptureSpec {
  const _CaptureSpec({
    required this.name,
    required this.logicalSize,
    required this.outputPath,
  });

  final String name;
  final Size logicalSize;
  final String outputPath;
}
