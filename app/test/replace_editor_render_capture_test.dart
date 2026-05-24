import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:path/path.dart' as p;
import 'package:fh_radio_studio/domain/replacement_models.dart';
import 'package:fh_radio_studio/screens/replace_editor.dart';
import 'package:fh_radio_studio/screens/replace_editor/replace_state.dart';
import 'package:fh_radio_studio/state/app_state.dart';
import 'package:fh_radio_studio/theme/accents.dart';
import 'package:fh_radio_studio/theme/app_theme.dart';
import 'package:fh_radio_studio/theme/tokens.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets(
    'capture replace editor route with Flutter render tree',
    (tester) async {
      GoogleFonts.config.allowRuntimeFetching = false;
      SharedPreferences.setMockInitialValues({
        'rm.studio.projectDir': 'capture',
        'rm.studio.repoRoot': p.dirname(p.current),
      });
      final prefs = await SharedPreferences.getInstance();
      final outDir = Directory(p.join('build', 'visual_qa'))
        ..createSync(recursive: true);

      await _captureReplaceEditor(
        tester,
        prefs: prefs,
        logicalSize: const Size(1365, 900),
        outputPath: p.join(outDir.path, 'replace_editor_regular.png'),
      );
      await _captureReplaceEditor(
        tester,
        prefs: prefs,
        logicalSize: const Size(1365, 1800),
        outputPath: p.join(outDir.path, 'replace_editor_full.png'),
      );
      await _captureReplaceEditorSavePrompt(
        tester,
        logicalSize: const Size(1365, 900),
        outputPath: p.join(
          outDir.path,
          'replace_editor_save_prompt_regular.png',
        ),
      );
      await _captureReplaceEditorSavePrompt(
        tester,
        logicalSize: const Size(1365, 1800),
        outputPath: p.join(outDir.path, 'replace_editor_save_prompt_full.png'),
      );
    },
    skip: Platform.environment['CAPTURE_REPLACE_EDITOR'] != '1',
  );
}

Future<void> _captureReplaceEditor(
  WidgetTester tester, {
  required SharedPreferences prefs,
  required Size logicalSize,
  required String outputPath,
}) async {
  final repaintKey = GlobalKey();
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = logicalSize;

  await tester.pumpWidget(
    ProviderScope(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      child: RepaintBoundary(
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
                child: ReplaceEditorScreen(trackId: 'cp-1', enableAudio: false),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));

  expect(tester.takeException(), isNull);
  expect(find.text('解锁重选'), findsWidgets);
  expect(find.text('当前选择'), findsWidgets);
  expect(find.text('锁定'), findsWidgets);

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

Future<void> _captureReplaceEditorSavePrompt(
  WidgetTester tester, {
  required Size logicalSize,
  required String outputPath,
}) async {
  final tempRoot = Directory.systemTemp.createTempSync(
    'replace_editor_save_prompt_capture_',
  );
  addTearDown(() {
    if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
  });
  SharedPreferences.setMockInitialValues({
    'rm.studio.projectDir': tempRoot.path,
    'rm.studio.repoRoot': p.dirname(p.current),
  });
  final prefs = await SharedPreferences.getInstance();
  final repaintKey = GlobalKey();
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = logicalSize;

  await tester.pumpWidget(
    ProviderScope(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      child: RepaintBoundary(
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
                child: ReplaceEditorScreen(trackId: 'cp-1', enableAudio: false),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));

  final container = ProviderScope.containerOf(
    tester.element(find.byType(ReplaceEditorScreen)),
  );
  container
      .read(replaceEditorProvider('cp-1').notifier)
      .setConfirmed(GroupKind.tl, true);
  await tester.pump();
  final confirm = find.text('确认').first;
  await tester.ensureVisible(confirm);
  await tester.pump();
  await tester.tap(confirm);
  await tester.pump();
  await tester.pump();

  expect(tester.takeException(), isNull);
  expect(find.text('保存这首歌的配置？'), findsOneWidget);

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
