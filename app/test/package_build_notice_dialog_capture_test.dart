import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:path/path.dart' as p;
import 'package:fh_radio_studio/theme/accents.dart';
import 'package:fh_radio_studio/theme/app_theme.dart';
import 'package:fh_radio_studio/theme/tokens.dart';
import 'package:fh_radio_studio/widgets/package_build_notice_dialog.dart';

void main() {
  testWidgets(
    'capture package build notice dialog with Flutter render tree',
    (tester) async {
      GoogleFonts.config.allowRuntimeFetching = false;
      final outDir = Directory(p.join('build', 'visual_qa'))
        ..createSync(recursive: true);

      await _captureNoticeDialog(
        tester,
        logicalSize: const Size(900, 640),
        outputPath: p.join(
          outDir.path,
          'package_build_notice_dialog_regular.png',
        ),
      );
      await _captureNoticeDialog(
        tester,
        logicalSize: const Size(900, 900),
        outputPath: p.join(outDir.path, 'package_build_notice_dialog_full.png'),
      );
      await _captureMissingSourcesDialog(
        tester,
        logicalSize: const Size(900, 640),
        outputPath: p.join(
          outDir.path,
          'missing_playlist_sources_dialog_regular.png',
        ),
      );
      await _captureMissingSourcesDialog(
        tester,
        logicalSize: const Size(900, 900),
        outputPath: p.join(
          outDir.path,
          'missing_playlist_sources_dialog_full.png',
        ),
      );
    },
    skip: Platform.environment['CAPTURE_PACKAGE_BUILD_NOTICE_DIALOG'] != '1',
  );
}

Future<void> _captureNoticeDialog(
  WidgetTester tester, {
  required Size logicalSize,
  required String outputPath,
}) async {
  final repaintKey = GlobalKey();
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = logicalSize;

  await tester.pumpWidget(
    RepaintBoundary(
      key: repaintKey,
      child: SizedBox.fromSize(
        size: logicalSize,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildAppTheme(
            brightness: Brightness.light,
            accent: AppAccent.lime,
          ),
          home: const Scaffold(
            body: ColoredBox(
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
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));

  expect(find.text('没有生成测试准备包'), findsOneWidget);
  expect(find.text('没有需要单独测试的新文件'), findsOneWidget);
  expect(find.text('普通电台包从播放列表生成'), findsOneWidget);
  expect(find.text('构建命令返回错误'), findsNothing);
  expect(find.text('只改语言也可以准备'), findsNothing);
  expect(tester.takeException(), isNull);

  final boundary = repaintKey.currentContext?.findRenderObject();
  expect(boundary, isA<RenderRepaintBoundary>());
  await tester.runAsync(() async {
    final image = await (boundary! as RenderRepaintBoundary).toImage(
      pixelRatio: 1.5,
    );
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    expect(data, isNotNull);

    final output = File(outputPath);
    await output.parent.create(recursive: true);
    await output.writeAsBytes(data!.buffer.asUint8List(), flush: true);
    // ignore: avoid_print
    print('${p.basenameWithoutExtension(outputPath)}=${output.absolute.path}');
  });
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
}

Future<void> _captureMissingSourcesDialog(
  WidgetTester tester, {
  required Size logicalSize,
  required String outputPath,
}) async {
  final repaintKey = GlobalKey();
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = logicalSize;

  await tester.pumpWidget(
    RepaintBoundary(
      key: repaintKey,
      child: SizedBox.fromSize(
        size: logicalSize,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildAppTheme(
            brightness: Brightness.light,
            accent: AppAccent.lime,
          ),
          home: const Scaffold(
            body: ColoredBox(
              color: RmTokens.bgLight,
              child: Center(
                child: MissingPlaylistSourcesDialog(
                  sources: [
                    r'C:\FH Radio Studio\project\sources\deleted-a.wav',
                    r'C:\FH Radio Studio\project\sources\deleted-b.flac',
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));

  expect(find.text('播放列表里有 2 首已删除的歌曲'), findsOneWidget);
  expect(find.text('删除所有失效歌曲'), findsOneWidget);
  expect(find.text('保持不动'), findsOneWidget);
  expect(tester.takeException(), isNull);

  final boundary = repaintKey.currentContext?.findRenderObject();
  expect(boundary, isA<RenderRepaintBoundary>());
  await tester.runAsync(() async {
    final image = await (boundary! as RenderRepaintBoundary).toImage(
      pixelRatio: 1.5,
    );
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    expect(data, isNotNull);

    final output = File(outputPath);
    await output.parent.create(recursive: true);
    await output.writeAsBytes(data!.buffer.asUint8List(), flush: true);
    // ignore: avoid_print
    print('${p.basenameWithoutExtension(outputPath)}=${output.absolute.path}');
  });
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
}
