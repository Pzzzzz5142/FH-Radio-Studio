import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:path/path.dart' as p;
import 'package:fh_radio_studio/core/project_workspace.dart';
import 'package:fh_radio_studio/screens/custom_pool.dart';
import 'package:fh_radio_studio/state/app_state.dart';
import 'package:fh_radio_studio/state/studio_state.dart';
import 'package:fh_radio_studio/theme/accents.dart';
import 'package:fh_radio_studio/theme/app_theme.dart';
import 'package:fh_radio_studio/theme/tokens.dart';
import 'package:fh_radio_studio/widgets/rm_button.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _projectDirKey = 'rm.studio.projectDir';

void main() {
  testWidgets(
    'capture custom pool delete dialog with Flutter render tree',
    (tester) async {
      GoogleFonts.config.allowRuntimeFetching = false;
      final tempRoot = Directory.systemTemp.createTempSync(
        'fh_radio_studio_custom_pool_delete_capture_',
      );
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
      });

      final projectDir = p.join(tempRoot.path, 'project');
      FhRadioStudioProject.ensure(projectDir);
      final audio =
          File(p.join(projectDir, 'sources', 'I Will Touch the Sky.wav'))
            ..createSync(recursive: true)
            ..writeAsBytesSync(const [0, 1, 2, 3]);
      SharedPreferences.setMockInitialValues({_projectDirKey: projectDir});
      final prefs = await SharedPreferences.getInstance();
      final outDir = Directory(p.join('build', 'visual_qa'))
        ..createSync(recursive: true);

      await _captureCustomPoolDeleteDialog(
        tester,
        prefs: prefs,
        controller: _CaptureStudioController(prefs, audio.path),
        logicalSize: const Size(1365, 900),
        outputPath: p.join(
          outDir.path,
          'custom_pool_delete_dialog_regular.png',
        ),
      );
      await _captureCustomPoolDeleteDialog(
        tester,
        prefs: prefs,
        controller: _CaptureStudioController(prefs, audio.path),
        logicalSize: const Size(1365, 1200),
        outputPath: p.join(outDir.path, 'custom_pool_delete_dialog_full.png'),
      );
    },
    skip: Platform.environment['CAPTURE_CUSTOM_POOL_DELETE_DIALOG'] != '1',
  );
}

Future<void> _captureCustomPoolDeleteDialog(
  WidgetTester tester, {
  required SharedPreferences prefs,
  required _CaptureStudioController controller,
  required Size logicalSize,
  required String outputPath,
}) async {
  final repaintKey = GlobalKey();
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = logicalSize;

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        studioProvider.overrideWith((ref) => controller),
        sharedPreferencesProvider.overrideWithValue(prefs),
      ],
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
                child: CustomPoolScreen(),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));

  final deleteButton = find.byWidgetPredicate(
    (widget) => widget is RmButton && widget.tooltip == '删除',
  );
  expect(deleteButton, findsOneWidget);
  await tester.tap(deleteButton);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  expect(find.text('删除这首自建歌曲？'), findsOneWidget);
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

class _CaptureStudioController extends StudioController {
  _CaptureStudioController(super.prefs, String audioPath) {
    state = state.copyWith(
      musicPaths: [audioPath],
      log: const ['视觉检查 fixture 已加载'],
    );
  }

  @override
  Future<void> refreshStatus({bool verifyFiles = false}) async {}
}
