import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
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

void main() {
  testWidgets(
    'capture dashboard confirm dialog with Flutter render tree',
    (tester) async {
      GoogleFonts.config.allowRuntimeFetching = false;
      final tempRoot = Directory.systemTemp.createTempSync(
        'fh_radio_studio_dashboard_confirm_capture_',
      );
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
      });

      final outDir = Directory(p.join('build', 'visual_qa'))
        ..createSync(recursive: true);
      await _captureConfirmDialog(
        tester,
        tempRoot: tempRoot,
        logicalSize: const Size(1244, 900),
        outputPath: p.join(outDir.path, 'dashboard_confirm_dialog_regular.png'),
      );
      await _captureConfirmDialog(
        tester,
        tempRoot: tempRoot,
        logicalSize: const Size(1365, 1200),
        outputPath: p.join(outDir.path, 'dashboard_confirm_dialog_full.png'),
      );
    },
    skip: Platform.environment['CAPTURE_DASHBOARD_CONFIRM_DIALOG'] != '1',
  );
}

Future<void> _captureConfirmDialog(
  WidgetTester tester, {
  required Directory tempRoot,
  required Size logicalSize,
  required String outputPath,
}) async {
  final repaintKey = GlobalKey();
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = logicalSize;
  final projectDir = p.join(tempRoot.path, 'project-${logicalSize.height}');
  final gameDir = p.join(tempRoot.path, 'game-${logicalSize.height}');
  FhRadioStudioProject.ensure(projectDir);
  FhRadioStudioProject.writeSettings(projectDir, gameDir: gameDir);
  SharedPreferences.setMockInitialValues({
    'rm.studio.projectDir': projectDir,
    'rm.studio.repoRoot': p.dirname(p.current),
  });
  final prefs = await SharedPreferences.getInstance();
  final controller = _ConfirmDialogCaptureController(
    prefs,
    projectDir: projectDir,
    gameDir: gameDir,
  );

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        studioProvider.overrideWith((ref) => controller),
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
                child: DashboardScreen(),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));

  await tester.tap(find.text('更新 build 记录').first);
  await tester.pumpAndSettle();
  expect(find.text('CONFIRM'), findsOneWidget);
  expect(find.text('更新 Steam build 兼容记录？'), findsOneWidget);
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

class _ConfirmDialogCaptureController extends StudioController {
  _ConfirmDialogCaptureController(
    super.prefs, {
    required String projectDir,
    required String gameDir,
  }) {
    state = state.copyWith(
      hasProject: true,
      projectDir: projectDir,
      gameDir: gameDir,
      sourceLang: 'JP',
      targetLang: 'EN',
      gameSourceLang: 'JP',
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
      toolchainStatus: _toolchainReady,
      lastPackageDir: p.join(projectDir, 'packages', 'current'),
      lastPackageSummary: _packageSummary(),
      fileIntegrity: _buildBumpIntegritySummary(),
      log: const ['dashboard confirm capture fixture loaded'],
    );
  }

  @override
  Future<void> startupFullCheckOnce() async {}
}

const _toolchainReady = ToolchainStatusSummary(
  checked: true,
  profile: 'local-heavy',
  status: 'ready',
  label: 'OK',
  summary: '核心工具链可用；AI 和硬件加速会按实际能力降级。',
  sections: [],
  fixes: [],
);

PackageArtifactSummary _packageSummary() {
  return const PackageArtifactSummary(
    radio: 4,
    station: 'Horizon XS',
    bankName: 'R4_Tracks_CU1.assets.bank',
    musicCount: 1,
    bankSlots: 25,
    playlistMode: 'only',
    skipBank: false,
    runtimeVerified: true,
    sourceLang: 'JP',
    targetLang: 'EN',
    previewTracks: ['Test Track'],
    assignments: [],
  );
}

GameFileIntegritySummary _buildBumpIntegritySummary() {
  return GameFileIntegritySummary.fromJson({
    'level': 'build_bump_available',
    'checked_files': 4,
    'package_matches': 0,
    'last_applied_package_matches': 0,
    'baseline_matches': 4,
    'pending_baseline_matches': 0,
    'changed_files': 0,
    'unknown_files': 0,
    'package_files': 4,
    'baseline_manifest_path': 'baseline_manifest.json',
    'pending_baseline_manifest_path': null,
    'package_manifest_path': 'fh_radio_studio_package_manifest.json',
    'last_applied_package_manifest_path': null,
    'current_game_version_id': 'steam-b23271701',
    'baseline_build_compatible': true,
    'baseline_supported_game_version_ids': const ['steam-b23271700'],
    'issues': const [],
  });
}
