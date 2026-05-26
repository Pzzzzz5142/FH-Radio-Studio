import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:path/path.dart' as p;
import 'package:fh_radio_studio/core/app_info.dart';
import 'package:fh_radio_studio/shell/app_shell.dart';
import 'package:fh_radio_studio/state/app_state.dart';
import 'package:fh_radio_studio/state/studio_state.dart';
import 'package:fh_radio_studio/theme/accents.dart';
import 'package:fh_radio_studio/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _projectDirKey = 'rm.studio.projectDir';

void main() {
  testWidgets(
    'capture package build blocking overlay',
    (tester) async {
      GoogleFonts.config.allowRuntimeFetching = false;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      SharedPreferences.setMockInitialValues({_projectDirKey: 'capture'});
      final prefs = await SharedPreferences.getInstance();
      final outDir = Directory(p.join('build', 'visual_qa'))
        ..createSync(recursive: true);

      await _capturePackageBuildOverlay(
        tester,
        prefs: prefs,
        logicalSize: const Size(1110, 354),
        outputPath: p.join(outDir.path, 'package_build_overlay_regular.png'),
      );
      await _capturePackageBuildOverlay(
        tester,
        prefs: prefs,
        logicalSize: const Size(1110, 700),
        outputPath: p.join(outDir.path, 'package_build_overlay_full.png'),
      );
    },
    skip: Platform.environment['CAPTURE_PACKAGE_BUILD_OVERLAY'] != '1',
  );
}

Future<void> _capturePackageBuildOverlay(
  WidgetTester tester, {
  required SharedPreferences prefs,
  required Size logicalSize,
  required String outputPath,
}) async {
  final repaintKey = GlobalKey();
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = logicalSize;

  final controller = _PackageBuildOverlayCaptureController(prefs);
  final router = GoRouter(
    initialLocation: '/dashboard',
    routes: [
      ShellRoute(
        builder: (context, state, child) => AppShell(child: child),
        routes: [
          GoRoute(
            path: '/dashboard',
            builder: (context, state) => const Center(
              child: Text('Dashboard behind package build overlay'),
            ),
          ),
        ],
      ),
    ],
  );

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        studioProvider.overrideWith((ref) => controller),
        appInfoProvider.overrideWith((ref) async => AppInfo.fallback),
      ],
      child: RepaintBoundary(
        key: repaintKey,
        child: SizedBox.fromSize(
          size: logicalSize,
          child: MaterialApp.router(
            debugShowCheckedModeBanner: false,
            theme: buildAppTheme(
              brightness: Brightness.light,
              accent: AppAccent.lime,
            ),
            routerConfig: router,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));

  expect(
    find.byKey(const ValueKey('package-build-blocking-overlay')),
    findsOneWidget,
  );
  expect(find.text('Horizon XS 重建 FMOD bank'), findsOneWidget);
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
  router.dispose();
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
}

class _PackageBuildOverlayCaptureController extends StudioController {
  _PackageBuildOverlayCaptureController(super.prefs) {
    state = state.copyWith(
      busy: true,
      busyLabel: '构建电台包',
      packageBuildProgressSteps: const [
        PackageBuildProgressStep(
          id: 'inspect_inputs',
          label: '读取构建输入',
          detail: '解析 RadioInfo、播放列表草稿、目标 bank 和本地工具路径。',
          status: 'done',
          weight: 1,
        ),
        PackageBuildProgressStep(
          id: 'radio.4.rebuild_bank',
          label: 'Horizon XS 重建 FMOD bank',
          detail: '运行 fsbankcl，修正 sample 名称，再拼回 .assets.bank。',
          status: 'running',
          weight: 8,
          processCount: 4,
          workItemCount: 9,
        ),
        PackageBuildProgressStep(
          id: 'patch_xml',
          label: '写入 RadioInfo XML',
          detail: '把新 sample、播放列表和 loop marker 写入所有语言 XML。',
          status: 'pending',
          weight: 2,
        ),
      ],
    );
  }
}
