import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;
import 'package:fh_radio_studio/theme/accents.dart';
import 'package:fh_radio_studio/theme/app_theme.dart';
import 'package:fh_radio_studio/theme/tokens.dart';
import 'package:fh_radio_studio/widgets/package_loudness_dialog.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  GoogleFonts.config.allowRuntimeFetching = false;
  final config = await _CaptureConfig.fromArgs(args);
  runApp(_CaptureApp(config: config));
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
                child: ColoredBox(
                  color: RmTokens.bgLight,
                  child: Center(
                    child: PackageLoudnessDialog(
                      referenceMedianLufs: -24,
                      initialOffsetLu: 4,
                      previewInputLufs: -9.4,
                      previewSource: widget.config.previewSource,
                      previewTitle: 'Get Lucky (feat. Pharrell)',
                      previewArtist: 'Daft Punk',
                      currentPackageOffsetLu: 1,
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
      debugPrint('package_loudness_dialog_capture_error=$error');
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
      throw StateError(
        'Package loudness dialog capture boundary was not found.',
      );
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
      'package_loudness_dialog_capture_${capture.name}=${output.absolute.path}',
    );
  }
}

class _CaptureConfig {
  const _CaptureConfig({
    required this.captures,
    required this.pixelRatio,
    required this.delay,
    required this.previewSource,
  });

  static Future<_CaptureConfig> fromArgs(List<String> args) async {
    String? valueFor(String name) {
      for (final arg in args) {
        final prefix = '$name=';
        if (arg.startsWith(prefix)) return arg.substring(prefix.length);
      }
      return null;
    }

    final regularOut =
        valueFor('--capture-regular-out') ??
        p.join('build', 'visual_qa', 'package_loudness_dialog_regular.png');
    final fullOut =
        valueFor('--capture-full-out') ??
        p.join('build', 'visual_qa', 'package_loudness_dialog_full.png');
    final previewSource =
        valueFor('--preview-source') ?? await _writePreviewWav();
    return _CaptureConfig(
      pixelRatio: double.tryParse(valueFor('--pixel-ratio') ?? '') ?? 1.5,
      delay: Duration(
        milliseconds: int.tryParse(valueFor('--delay-ms') ?? '') ?? 650,
      ),
      previewSource: previewSource,
      captures: [
        _CaptureSpec(
          name: 'regular',
          logicalSize: const Size(900, 700),
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
  final String previewSource;
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

Future<String> _writePreviewWav() async {
  final file = File(
    p.join(Directory.systemTemp.path, 'fh_radio_studio_loudness_preview.wav'),
  );
  const sampleRate = 44100;
  const seconds = 2;
  const channelCount = 1;
  const bitsPerSample = 16;
  const sampleCount = sampleRate * seconds;
  final dataBytes = sampleCount * channelCount * (bitsPerSample ~/ 8);
  final bytes = BytesBuilder(copy: false);

  void ascii(String value) => bytes.add(value.codeUnits);
  void u16(int value) {
    final data = ByteData(2)..setUint16(0, value, Endian.little);
    bytes.add(data.buffer.asUint8List());
  }

  void u32(int value) {
    final data = ByteData(4)..setUint32(0, value, Endian.little);
    bytes.add(data.buffer.asUint8List());
  }

  ascii('RIFF');
  u32(36 + dataBytes);
  ascii('WAVE');
  ascii('fmt ');
  u32(16);
  u16(1);
  u16(channelCount);
  u32(sampleRate);
  u32(sampleRate * channelCount * (bitsPerSample ~/ 8));
  u16(channelCount * (bitsPerSample ~/ 8));
  u16(bitsPerSample);
  ascii('data');
  u32(dataBytes);

  for (var i = 0; i < sampleCount; i += 1) {
    final sample = math.sin(2 * math.pi * 220 * i / sampleRate);
    final scaled = (sample * 32767 * 0.12).round();
    u16(scaled < 0 ? 0x10000 + scaled : scaled);
  }

  await file.writeAsBytes(bytes.takeBytes(), flush: true);
  return file.path;
}
