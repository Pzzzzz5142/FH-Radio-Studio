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

const _projectDirKey = 'rm.studio.projectDir';
const _repoRootKey = 'rm.studio.repoRoot';

void main() {
  testWidgets(
    'capture dashboard checklist dialog with Flutter render tree',
    (tester) async {
      GoogleFonts.config.allowRuntimeFetching = false;
      final tempRoot = Directory.systemTemp.createTempSync(
        'fh_radio_studio_dashboard_checklist_capture_',
      );
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
      });

      final projectDir = p.join(tempRoot.path, 'project');
      final gameDir = p.join(tempRoot.path, 'game');
      FhRadioStudioProject.ensure(projectDir);
      FhRadioStudioProject.writeSettings(projectDir, gameDir: gameDir);
      SharedPreferences.setMockInitialValues({
        _projectDirKey: projectDir,
        _repoRootKey: p.dirname(p.current),
      });
      final prefs = await SharedPreferences.getInstance();
      final outDir = Directory(p.join('build', 'visual_qa'))
        ..createSync(recursive: true);

      await _captureDashboardChecklistDialog(
        tester,
        prefs: prefs,
        projectDir: projectDir,
        gameDir: gameDir,
        logicalSize: const Size(1244, 900),
        outputPath: p.join(
          outDir.path,
          'dashboard_checklist_dialog_regular.png',
        ),
      );
      await _captureDashboardChecklistDialog(
        tester,
        prefs: prefs,
        projectDir: projectDir,
        gameDir: gameDir,
        logicalSize: const Size(1365, 1200),
        outputPath: p.join(outDir.path, 'dashboard_checklist_dialog_full.png'),
      );
    },
    skip: Platform.environment['CAPTURE_DASHBOARD_CHECKLIST_DIALOG'] != '1',
  );
}

Future<void> _captureDashboardChecklistDialog(
  WidgetTester tester, {
  required SharedPreferences prefs,
  required String projectDir,
  required String gameDir,
  required Size logicalSize,
  required String outputPath,
}) async {
  final repaintKey = GlobalKey();
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = logicalSize;
  final controller = _DashboardChecklistCaptureController(
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

  await tester.tap(find.text('创建原始备份').first);
  await tester.pumpAndSettle();

  expect(find.text('CHECKLIST'), findsOneWidget);
  expect(find.text('我确认 Forza Horizon 6 没有运行'), findsOneWidget);
  expect(find.text('我确认当前游戏文件来自官方完整安装'), findsOneWidget);
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

class _DashboardChecklistCaptureController extends StudioController {
  _DashboardChecklistCaptureController(
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
      voiceSlotVerified: false,
      languageReady: false,
      languageSummary: 'JP 显示 · EN 语音（等待原始备份）',
      toolchainStatus: _toolchainReady,
      lastPackageDir: null,
      lastPackageSummary: null,
      pendingPackageDir: null,
      pendingPackageSummary: null,
      fileIntegrity: _noBaselineIntegritySummary(),
      baselinePlanSummary: _pristineBaselinePlan,
      log: const ['dashboard checklist capture fixture loaded'],
    );
  }

  @override
  Future<void> startupFullCheckOnce() async {}

  @override
  Future<BaselinePlanSummary?> previewPristineBaselinePlan() async {
    state = state.copyWith(baselinePlanSummary: _pristineBaselinePlan);
    return _pristineBaselinePlan;
  }

  @override
  Future<void> createPristineBaseline() async {}
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

const _pristineBaselinePlan = BaselinePlanSummary(
  fileCount: 62,
  totalSize: 734003200,
  gameVersionId: 'steam-b23271700',
  byScope: {'radio_info': 1, 'radio_bank': 25, 'string_table': 36},
  byStatus: {'ok': 62},
  files: [],
);

GameFileIntegritySummary _noBaselineIntegritySummary() {
  return GameFileIntegritySummary.fromJson({
    'level': 'no_baseline',
    'checked_files': 62,
    'package_matches': 0,
    'last_applied_package_matches': 0,
    'baseline_matches': 0,
    'pending_baseline_matches': 0,
    'changed_files': 0,
    'unknown_files': 0,
    'package_files': 62,
    'baseline_manifest_path': null,
    'pending_baseline_manifest_path': null,
    'package_manifest_path': null,
    'last_applied_package_manifest_path': null,
    'current_game_version_id': 'steam-b23271700',
    'baseline_build_compatible': true,
    'baseline_supported_game_version_ids': const [],
    'issues': const [],
  });
}
