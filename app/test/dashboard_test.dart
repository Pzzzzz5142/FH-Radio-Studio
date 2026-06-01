import 'dart:convert';
import 'dart:io';
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:path/path.dart' as p;
import 'package:fh_radio_studio/core/playlist_plan.dart';
import 'package:fh_radio_studio/core/project_workspace.dart';
import 'package:fh_radio_studio/screens/dashboard.dart';
import 'package:fh_radio_studio/state/app_state.dart';
import 'package:fh_radio_studio/state/studio_state.dart';
import 'package:fh_radio_studio/theme/accents.dart';
import 'package:fh_radio_studio/theme/app_theme.dart';
import 'package:fh_radio_studio/theme/tokens.dart';
import 'package:fh_radio_studio/widgets/rm_button.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('dashboard exposes pending package confirmation', (tester) async {
    GoogleFonts.config.allowRuntimeFetching = false;
    final tempRoot = Directory.systemTemp.createTempSync(
      'fh_radio_studio_dashboard_',
    );
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
    });

    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1365, 900);

    final projectDir = p.join(tempRoot.path, 'project');
    final gameDir = p.join(tempRoot.path, 'game');
    FhRadioStudioProject.ensure(projectDir);
    FhRadioStudioProject.writeSettings(projectDir, gameDir: gameDir);
    SharedPreferences.setMockInitialValues({
      'rm.studio.projectDir': projectDir,
      'rm.studio.repoRoot': p.dirname(p.current),
    });
    final prefs = await SharedPreferences.getInstance();
    final controller = _DashboardTestController(prefs);
    controller.setStateForTest(
      controller.state.copyWith(
        gameDir: gameDir,
        sourceLang: 'JP',
        targetLang: 'EN',
        gameSourceLang: 'CHS',
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
        lastPackageSummary: _packageSummary(sourceLang: 'CHS'),
        pendingPackageDir: p.join(projectDir, 'packages', 'pending'),
        pendingPackageSummary: _packageSummary(sourceLang: 'JP'),
        fileIntegrity: _integritySummary(
          level: GameFileIntegrityLevel.pendingVerify,
          checkedFiles: 4,
          packageMatches: 4,
          hasPendingBaseline: true,
        ),
        log: const ['测试状态已加载'],
      ),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          studioProvider.overrideWith((ref) => controller),
        ],
        child: MaterialApp(
          theme: buildAppTheme(
            brightness: Brightness.light,
            accent: AppAccent.lime,
          ),
          home: const Scaffold(body: DashboardScreen()),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('电台控制台'), findsOneWidget);
    expect(find.text('SAFETY CONSOLE'), findsNothing);
    expect(find.text('当前游戏文件等于 测试准备包 · 等待确认'), findsOneWidget);
    expect(find.text('scan · 等待确认'), findsOneWidget);
    expect(find.text('确认这是可用的'), findsOneWidget);
    expect(find.text('查看新文件流程'), findsNothing);
    expect(find.text('准备包会写入 EN'), findsOneWidget);
    expect(find.textContaining('auto-refresh'), findsNothing);
    expect(find.textContaining('自动刷新'), findsNothing);
    expect(find.textContaining('30s'), findsNothing);
    expect(find.text('中杯'), findsOneWidget);
    expect(find.text('大杯'), findsOneWidget);
    expect(find.text('超大杯'), findsOneWidget);
    expect(find.text('节拍响度'), findsNothing);
    expect(find.text('三模型'), findsNothing);
    expect(find.text('四模型'), findsNothing);

    final statusHeights = [
      for (var i = 0; i < 3; i += 1)
        tester.getSize(find.byKey(ValueKey('dashboard-status-$i'))).height,
    ];
    expect(statusHeights.toSet(), hasLength(1));

    await tester.tap(find.byKey(const ValueKey('dashboard-status-0')));
    await tester.pumpAndSettle();
    expect(find.text('ffmpeg'), findsOneWidget);
    expect(
      find.textContaining(r'C:\FH Radio Studio\tools\audio\ffmpeg'),
      findsNothing,
    );
    expect(
      tester.getTopLeft(find.text('AI Provider')).dy,
      lessThan(tester.getTopLeft(find.text('硬件加速')).dy),
    );

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: tester.getCenter(find.text('ffmpeg')));
    await tester.pumpAndSettle();
    expect(
      find.text(r'ffmpeg C:\FH Radio Studio\tools\audio\ffmpeg\ffmpeg.exe'),
      findsOneWidget,
    );
    final hoverRect = tester.getRect(
      find.text(r'ffmpeg C:\FH Radio Studio\tools\audio\ffmpeg\ffmpeg.exe'),
    );
    expect(hoverRect.left, greaterThanOrEqualTo(0));
    expect(hoverRect.right, lessThanOrEqualTo(tester.view.physicalSize.width));
    await mouse.removePointer();
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(RmButton, '同步 AI 环境'));
    await tester.pumpAndSettle();
    expect(find.text('AI 环境设置'), findsOneWidget);
    expect(find.text('选择杯型，Warmup 按杯型固定执行'), findsOneWidget);
    await tester.tap(find.widgetWithText(RmButton, '取消'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('文件状态'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('文件状态'));
    await tester.pumpAndSettle();

    expect(find.text('确认'), findsOneWidget);
    expect(find.text('当前命中 测试准备包'), findsWidgets);
    expect(find.text('确认这是可用的'), findsWidgets);
    expect(find.text('旧准备包'), findsOneWidget);
    expect(find.text('放弃新文件'), findsOneWidget);
    final forceBackup = find.widgetWithText(RmButton, '强制备份');
    final forceApplyBaseline = find.widgetWithText(RmButton, '强制写入本地备份至游戏');
    expect(forceBackup, findsOneWidget);
    expect(forceApplyBaseline, findsOneWidget);
    expect(
      tester.widget<RmButton>(forceBackup).variant,
      RmButtonVariant.dangerOutline,
    );
    expect(
      tester.widget<RmButton>(forceApplyBaseline).variant,
      RmButtonVariant.dangerPrimary,
    );
    expect(find.text('测试准备包 · 确认新版本'), findsNothing);
    expect(find.text('生成测试准备包'), findsNothing);
    expect(
      tester
          .getSize(find.byKey(const ValueKey('dashboard-route-card-0')))
          .height,
      tester
          .getSize(find.byKey(const ValueKey('dashboard-route-card-1')))
          .height,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('force backup clears playlist draft after baseline overwrite', (
    tester,
  ) async {
    GoogleFonts.config.allowRuntimeFetching = false;
    final tempRoot = Directory.systemTemp.createTempSync(
      'fh_radio_studio_dashboard_force_backup_',
    );
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
    });

    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1365, 900);

    final projectDir = p.join(tempRoot.path, 'project');
    final gameDir = p.join(tempRoot.path, 'game');
    FhRadioStudioProject.ensure(projectDir);
    FhRadioStudioProject.writeSettings(projectDir, gameDir: gameDir);
    final source = File(p.join(projectDir, 'sources', 'draft.wav'))
      ..createSync(recursive: true);
    final assignment = PlaylistAssignment(
      trackKey: PlaylistAssignment.keyForPath(source.path),
      source: source.path,
      radioCode: 'R4',
      playlistType: 'FreeRoam',
      slot: 1,
    );
    _writeLegacyPlaylistPlan(
      projectDir,
      PlaylistPlan(assignments: {assignment.assignmentKey: assignment}),
    );
    final planFile = File(PlaylistPlanStore.configPath(projectDir));
    expect(planFile.existsSync(), isTrue);

    SharedPreferences.setMockInitialValues({
      'rm.studio.projectDir': projectDir,
      'rm.studio.repoRoot': p.dirname(p.current),
    });
    final prefs = await SharedPreferences.getInstance();
    final controller = _DashboardTestController(prefs);
    controller.setStateForTest(
      controller.state.copyWith(
        gameDir: gameDir,
        sourceLang: 'JP',
        targetLang: 'EN',
        gameSourceLang: 'JP',
        gameTargetLang: 'EN',
        availableLanguages: const ['EN', 'JP'],
        preferredLang: 'EN',
        sourceLanguageExists: true,
        targetLanguageExists: true,
        targetMatchesSource: false,
        preferredMatchesTarget: true,
        voiceSlotVerified: true,
        languageReady: true,
        languageSummary: 'JP 显示 · EN 语音',
        toolchainStatus: _toolchainReady,
        lastPackageDir: p.join(projectDir, 'packages', 'current'),
        lastPackageSummary: _packageSummary(sourceLang: 'JP'),
        fileIntegrity: _integritySummary(
          level: GameFileIntegrityLevel.baseline,
          checkedFiles: 4,
          baselineMatches: 4,
        ),
        log: const ['工具链检查通过'],
      ),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          studioProvider.overrideWith((ref) => controller),
        ],
        child: MaterialApp(
          theme: buildAppTheme(
            brightness: Brightness.light,
            accent: AppAccent.lime,
          ),
          home: const Scaffold(body: DashboardScreen(initialFileOpen: true)),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    await tester.ensureVisible(find.widgetWithText(RmButton, '强制备份'));
    await tester.tap(find.widgetWithText(RmButton, '强制备份'));
    await tester.pumpAndSettle();
    expect(find.text('用当前游戏文件覆写原始备份？'), findsOneWidget);
    expect(find.text('危险操作'), findsOneWidget);
    expect(find.text('DANGER CHECK'), findsOneWidget);

    await tester.tap(find.text('我确认 Forza Horizon 6 没有运行'));
    await tester.tap(find.text('我理解当前原始备份会被覆盖'));
    await tester.tap(find.text('我理解准备包和播放列表草稿会被清空'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(RmButton, '强制备份').last);
    await tester.pumpAndSettle();

    expect(controller.rebuildBaselineCount, 1);
    expect(planFile.existsSync(), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('force baseline actions are disabled without original backup', (
    tester,
  ) async {
    GoogleFonts.config.allowRuntimeFetching = false;
    final tempRoot = Directory.systemTemp.createTempSync(
      'fh_radio_studio_dashboard_no_baseline_actions_',
    );
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
    });

    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1365, 900);

    final projectDir = p.join(tempRoot.path, 'project');
    final gameDir = p.join(tempRoot.path, 'game');
    FhRadioStudioProject.ensure(projectDir);
    FhRadioStudioProject.writeSettings(projectDir, gameDir: gameDir);

    SharedPreferences.setMockInitialValues({
      'rm.studio.projectDir': projectDir,
      'rm.studio.repoRoot': p.dirname(p.current),
    });
    final prefs = await SharedPreferences.getInstance();
    final controller = _DashboardTestController(prefs);
    controller.setStateForTest(
      controller.state.copyWith(
        gameDir: gameDir,
        sourceLang: 'JP',
        targetLang: 'EN',
        gameSourceLang: 'JP',
        gameTargetLang: 'EN',
        availableLanguages: const ['EN', 'JP'],
        preferredLang: 'EN',
        sourceLanguageExists: true,
        targetLanguageExists: true,
        targetMatchesSource: false,
        preferredMatchesTarget: true,
        voiceSlotVerified: true,
        languageReady: true,
        languageSummary: 'JP 显示 · EN 语音',
        toolchainStatus: _toolchainReady,
        fileIntegrity: _integritySummary(
          level: GameFileIntegrityLevel.noBaseline,
          checkedFiles: 0,
          baselineManifestPath: null,
          packageManifestPath: null,
        ),
        log: const ['缺少原始备份'],
      ),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          studioProvider.overrideWith((ref) => controller),
        ],
        child: MaterialApp(
          theme: buildAppTheme(
            brightness: Brightness.light,
            accent: AppAccent.lime,
          ),
          home: const Scaffold(body: DashboardScreen(initialFileOpen: true)),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final forceBackup = find.widgetWithText(RmButton, '强制备份');
    final forceApplyBaseline = find.widgetWithText(RmButton, '强制写入本地备份至游戏');
    expect(forceBackup, findsOneWidget);
    expect(forceApplyBaseline, findsOneWidget);
    expect(tester.widget<RmButton>(forceBackup).onPressed, isNull);
    expect(tester.widget<RmButton>(forceApplyBaseline).onPressed, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'AI environment dialog does not mark unchecked profiles as sync-needed',
    (tester) async {
      GoogleFonts.config.allowRuntimeFetching = false;
      final tempRoot = Directory.systemTemp.createTempSync(
        'fh_radio_studio_ai_dialog_',
      );
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
      });

      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1365, 900);

      final projectDir = p.join(tempRoot.path, 'project');
      final gameDir = p.join(tempRoot.path, 'game');
      FhRadioStudioProject.ensure(projectDir);
      FhRadioStudioProject.writeSettings(projectDir, gameDir: gameDir);
      SharedPreferences.setMockInitialValues({
        'rm.studio.projectDir': projectDir,
        'rm.studio.repoRoot': p.dirname(p.current),
      });
      final prefs = await SharedPreferences.getInstance();
      final controller = _DashboardTestController(prefs);
      controller.setStateForTest(
        controller.state.copyWith(
          aiProfile: 'local-deep',
          gameDir: gameDir,
          sourceLang: 'CHS',
          targetLang: 'EN',
          availableLanguages: const ['CHS', 'EN'],
          sourceLanguageExists: true,
          targetLanguageExists: true,
          targetMatchesSource: false,
          preferredMatchesTarget: true,
          voiceSlotVerified: true,
          languageReady: true,
          toolchainStatus: _toolchainDeepReady,
          fileIntegrity: _integritySummary(
            level: GameFileIntegrityLevel.noPackage,
            checkedFiles: 0,
          ),
          log: const ['测试状态已加载'],
        ),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(prefs),
            studioProvider.overrideWith((ref) => controller),
          ],
          child: MaterialApp(
            theme: buildAppTheme(
              brightness: Brightness.light,
              accent: AppAccent.lime,
            ),
            home: const Scaffold(body: DashboardScreen(initialToolOpen: true)),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('AI OK'), findsOneWidget);
      expect(find.text('CUDA Accelerated'), findsOneWidget);
      expect(
        tester.widget<Text>(find.text('AI OK')).style?.color,
        accentColors(AppAccent.lime, Brightness.light).base,
      );

      final syncAiButton = find.widgetWithText(RmButton, '同步 AI 环境');
      await tester.ensureVisible(syncAiButton);
      await tester.pumpAndSettle();
      await tester.tap(syncAiButton);
      await tester.pumpAndSettle();

      expect(find.text('Pipeline 已就绪'), findsOneWidget);
      expect(find.text('Force Reinstall'), findsOneWidget);
      expect(find.text('需同步'), findsNothing);
      expect(find.text('待检查'), findsOneWidget);
      expect(find.text('已就绪'), findsAtLeastNWidgets(3));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('dashboard diagnostics count CLI calls and separate log blocks', (
    tester,
  ) async {
    GoogleFonts.config.allowRuntimeFetching = false;
    final tempRoot = Directory.systemTemp.createTempSync(
      'fh_radio_studio_dashboard_diagnostics_',
    );
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
    });

    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1365, 900);

    final projectDir = p.join(tempRoot.path, 'project');
    final gameDir = p.join(tempRoot.path, 'game');
    FhRadioStudioProject.ensure(projectDir);
    FhRadioStudioProject.writeSettings(projectDir, gameDir: gameDir);
    SharedPreferences.setMockInitialValues({
      'rm.studio.projectDir': projectDir,
      'rm.studio.repoRoot': p.dirname(p.current),
    });
    final prefs = await SharedPreferences.getInstance();
    final controller = _DashboardTestController(prefs);
    controller.setStateForTest(
      controller.state.copyWith(
        gameDir: gameDir,
        sourceLang: 'JP',
        targetLang: 'EN',
        gameSourceLang: 'JP',
        gameTargetLang: 'EN',
        availableLanguages: const ['EN', 'JP'],
        preferredLang: 'EN',
        sourceLanguageExists: true,
        targetLanguageExists: true,
        targetMatchesSource: false,
        preferredMatchesTarget: true,
        voiceSlotVerified: true,
        languageReady: true,
        languageSummary: 'JP 显示 · EN 语音',
        toolchainStatus: _toolchainReady,
        fileIntegrity: _integritySummary(
          level: GameFileIntegrityLevel.baseline,
          checkedFiles: 4,
          baselineMatches: 4,
        ),
        log: const [
          '执行：刷新当前状态',
          'status ok',
          '退出码：0',
          '执行：准备电台替换包',
          'build ok',
          '退出码：0',
        ],
      ),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          studioProvider.overrideWith((ref) => controller),
        ],
        child: MaterialApp(
          theme: buildAppTheme(
            brightness: Brightness.light,
            accent: AppAccent.lime,
          ),
          home: const Scaffold(body: DashboardScreen()),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('2 次 CLI call'), findsOneWidget);
    expect(find.text('6 条日志'), findsNothing);

    await tester.ensureVisible(find.text('高级诊断'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('高级诊断'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('---------- CLI CALL #1 ----------'),
      findsOneWidget,
    );
    expect(
      find.textContaining('---------- CLI CALL #2 ----------'),
      findsOneWidget,
    );
    expect(find.textContaining('执行：刷新当前状态'), findsOneWidget);
    expect(find.textContaining('执行：准备电台替换包'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('dashboard route cards keep route labels aligned with badges', (
    tester,
  ) async {
    GoogleFonts.config.allowRuntimeFetching = false;
    final tempRoot = Directory.systemTemp.createTempSync(
      'fh_radio_studio_dashboard_route_alignment_',
    );
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
    });

    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1365, 900);

    final projectDir = p.join(tempRoot.path, 'project');
    final gameDir = p.join(tempRoot.path, 'game');
    FhRadioStudioProject.ensure(projectDir);
    FhRadioStudioProject.writeSettings(projectDir, gameDir: gameDir);
    SharedPreferences.setMockInitialValues({
      'rm.studio.projectDir': projectDir,
      'rm.studio.repoRoot': p.dirname(p.current),
    });
    final prefs = await SharedPreferences.getInstance();
    final controller = _DashboardTestController(prefs);
    controller.setStateForTest(
      controller.state.copyWith(
        gameDir: gameDir,
        toolchainStatus: _toolchainReady,
        lastPackageDir: p.join(projectDir, 'packages', 'current'),
        lastPackageSummary: _packageSummary(sourceLang: 'JP'),
        fileIntegrity: _integritySummary(
          level: GameFileIntegrityLevel.gameChanged,
          checkedFiles: 4,
        ),
        log: const ['路线卡片布局测试'],
      ),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          studioProvider.overrideWith((ref) => controller),
        ],
        child: MaterialApp(
          theme: buildAppTheme(
            brightness: Brightness.light,
            accent: AppAccent.lime,
          ),
          home: const Scaffold(body: DashboardScreen(initialFileOpen: true)),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final routeA = find.text('路线 A · 接受新文件');
    final routeB = find.text('路线 B · 测试准备包');
    final titleA = find.text('只保存新文件记录');
    final titleB = find.text('基于准备包生成测试准备包');
    final bodyA = find.text('把当前 Steam 更新后的游戏文件保存为待确认记录；确认可用后再设为新的原始备份。');
    final bodyB = find.text('先保存当前游戏文件，再用准备包里的曲目安排重新构建测试准备包；不会直接写入游戏。');
    final cardAFinder = find.byKey(const ValueKey('dashboard-route-card-0'));
    final cardBFinder = find.byKey(const ValueKey('dashboard-route-card-1'));
    final buttonA = find.descendant(
      of: cardAFinder,
      matching: find.widgetWithText(RmButton, '保存新文件记录'),
    );
    final buttonB = find.descendant(
      of: cardBFinder,
      matching: find.widgetWithText(RmButton, '生成测试准备包'),
    );
    final cardA = tester.getRect(cardAFinder);
    final cardB = tester.getRect(cardBFinder);

    expect(routeA, findsOneWidget);
    expect(routeB, findsOneWidget);
    expect(titleA, findsOneWidget);
    expect(titleB, findsOneWidget);
    expect(bodyA, findsOneWidget);
    expect(bodyB, findsOneWidget);
    expect(buttonA, findsOneWidget);
    expect(buttonB, findsOneWidget);
    expect(find.text('旧的基线'), findsNothing);
    expect(find.text('旧准备包'), findsNothing);
    expect(find.text('重建原始备份'), findsNothing);
    expect(
      tester.getTopLeft(routeA).dx - cardA.left,
      moreOrLessEquals(tester.getTopLeft(routeB).dx - cardB.left),
    );
    expect(
      tester.getTopLeft(titleA).dx - cardA.left,
      moreOrLessEquals(tester.getTopLeft(titleB).dx - cardB.left),
    );
    expect(
      tester.getTopLeft(titleA).dy - cardA.top,
      moreOrLessEquals(tester.getTopLeft(titleB).dy - cardB.top),
    );
    expect(
      tester.getTopLeft(buttonA).dy - tester.getBottomLeft(bodyA).dy,
      greaterThanOrEqualTo(12),
    );
    expect(
      tester.getTopLeft(buttonB).dy - tester.getBottomLeft(bodyB).dy,
      greaterThanOrEqualTo(12),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('dashboard external conflict shows old and current file routes', (
    tester,
  ) async {
    GoogleFonts.config.allowRuntimeFetching = false;
    final tempRoot = Directory.systemTemp.createTempSync(
      'fh_radio_studio_dashboard_external_conflict_routes_',
    );
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
    });

    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1365, 900);

    final projectDir = p.join(tempRoot.path, 'project');
    final gameDir = p.join(tempRoot.path, 'game');
    FhRadioStudioProject.ensure(projectDir);
    FhRadioStudioProject.writeSettings(projectDir, gameDir: gameDir);
    SharedPreferences.setMockInitialValues({
      'rm.studio.projectDir': projectDir,
      'rm.studio.repoRoot': p.dirname(p.current),
    });
    final prefs = await SharedPreferences.getInstance();
    final controller = _DashboardTestController(prefs);
    controller.setStateForTest(
      controller.state.copyWith(
        gameDir: gameDir,
        toolchainStatus: _toolchainReady,
        lastPackageDir: p.join(projectDir, 'packages', 'current'),
        lastPackageSummary: _packageSummary(sourceLang: 'JP'),
        fileIntegrity: _integritySummary(
          level: GameFileIntegrityLevel.externalConflict,
          checkedFiles: 4,
          changedFiles: 1,
        ),
        log: const ['外部文件冲突路线测试'],
      ),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          studioProvider.overrideWith((ref) => controller),
        ],
        child: MaterialApp(
          theme: buildAppTheme(
            brightness: Brightness.light,
            accent: AppAccent.lime,
          ),
          home: const Scaffold(body: DashboardScreen(initialFileOpen: true)),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('路线 A · 回到旧的基线'), findsOneWidget);
    expect(find.text('写回旧的基线或旧准备包'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('dashboard-route-card-0')),
        matching: find.widgetWithText(RmButton, '旧的基线'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('dashboard-route-card-0')),
        matching: find.widgetWithText(RmButton, '旧准备包'),
      ),
      findsOneWidget,
    );
    expect(find.text('路线 B · 接受当前文件'), findsOneWidget);
    expect(find.text('保存当前文件 · 构建测试准备包'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('dashboard-route-card-1')),
        matching: find.widgetWithText(RmButton, '保存新文件记录'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('dashboard-route-card-1')),
        matching: find.widgetWithText(RmButton, '生成测试准备包'),
      ),
      findsOneWidget,
    );
    expect(find.text('重建原始备份'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('dashboard hides test package route without a prepared package', (
    tester,
  ) async {
    GoogleFonts.config.allowRuntimeFetching = false;
    final tempRoot = Directory.systemTemp.createTempSync(
      'fh_radio_studio_dashboard_game_update_no_package_',
    );
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
    });

    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1365, 900);

    final projectDir = p.join(tempRoot.path, 'project');
    final gameDir = p.join(tempRoot.path, 'game');
    FhRadioStudioProject.ensure(projectDir);
    FhRadioStudioProject.writeSettings(projectDir, gameDir: gameDir);
    SharedPreferences.setMockInitialValues({
      'rm.studio.projectDir': projectDir,
      'rm.studio.repoRoot': p.dirname(p.current),
    });
    final prefs = await SharedPreferences.getInstance();
    final controller = _DashboardTestController(prefs);
    controller.setStateForTest(
      controller.state.copyWith(
        gameDir: gameDir,
        toolchainStatus: _toolchainReady,
        lastPackageDir: null,
        lastPackageSummary: null,
        fileIntegrity: _integritySummary(
          level: GameFileIntegrityLevel.gameChanged,
          checkedFiles: 4,
          changedFiles: 1,
        ),
        log: const ['无准备包路线测试'],
      ),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          studioProvider.overrideWith((ref) => controller),
        ],
        child: MaterialApp(
          theme: buildAppTheme(
            brightness: Brightness.light,
            accent: AppAccent.lime,
          ),
          home: const Scaffold(body: DashboardScreen(initialFileOpen: true)),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('路线 A · 接受新文件'), findsOneWidget);
    expect(find.text('只保存新文件记录'), findsOneWidget);
    expect(find.textContaining('还没有准备包'), findsOneWidget);
    expect(find.text('路线 B · 测试准备包'), findsNothing);
    expect(find.widgetWithText(RmButton, '生成测试准备包'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'dashboard keeps failed pending package in pending until selected',
    (tester) async {
      GoogleFonts.config.allowRuntimeFetching = false;
      final tempRoot = Directory.systemTemp.createTempSync(
        'fh_radio_studio_dashboard_pending_failed_',
      );
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
      });

      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1365, 900);

      final projectDir = p.join(tempRoot.path, 'project');
      final gameDir = p.join(tempRoot.path, 'game');
      final failedPendingDir = p.join(projectDir, 'packages', 'pending');
      FhRadioStudioProject.ensure(projectDir);
      FhRadioStudioProject.writeSettings(projectDir, gameDir: gameDir);
      SharedPreferences.setMockInitialValues({
        'rm.studio.projectDir': projectDir,
        'rm.studio.repoRoot': p.dirname(p.current),
      });
      final prefs = await SharedPreferences.getInstance();
      final controller = _DashboardTestController(prefs);
      File(
          p.join(failedPendingDir, 'fh_radio_studio_package_build_failed.json'),
        )
        ..createSync(recursive: true)
        ..writeAsStringSync('''
{
  "schema_version": 1,
  "kind": "pending_package_build_failure",
  "message": "fsbankcl failed"
}
''', encoding: utf8);
      controller.setStateForTest(
        controller.state.copyWith(
          gameDir: gameDir,
          toolchainStatus: _toolchainReady,
          lastPackageDir: p.join(projectDir, 'packages', 'current'),
          lastPackageSummary: _packageSummary(sourceLang: 'CHS'),
          pendingPackageDir: failedPendingDir,
          pendingPackageSummary: null,
          fileIntegrity: _integritySummary(
            level: GameFileIntegrityLevel.pendingVerify,
            checkedFiles: 4,
            pendingBaselineMatches: 4,
            hasPendingBaseline: true,
          ),
          log: const ['测试准备包构建失败'],
        ),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(prefs),
            studioProvider.overrideWith((ref) => controller),
          ],
          child: MaterialApp(
            theme: buildAppTheme(
              brightness: Brightness.light,
              accent: AppAccent.lime,
            ),
            home: const Scaffold(body: DashboardScreen()),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('新游戏文件待验证 · 先测试再确认'), findsOneWidget);
      expect(find.text('测试准备包'), findsOneWidget);
      expect(find.text('生成失败'), findsOneWidget);
      expect(find.text('测试准备包生成失败'), findsOneWidget);
      expect(find.text('停留在新文件流程，等待手动选择路线'), findsOneWidget);
      expect(find.text('确认'), findsNothing);

      File(
          p.join(
            failedPendingDir,
            'fh_radio_studio_pending_baseline_selected.json',
          ),
        )
        ..createSync(recursive: true)
        ..writeAsStringSync('''
{
  "schema_version": 1,
  "kind": "pending_baseline_selection"
}
''', encoding: utf8);
      controller.setStateForTest(controller.state.copyWith());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('当前游戏文件等于 新游戏文件 · 等待确认'), findsOneWidget);
      expect(find.text('确认这是可用的'), findsWidgets);
      await tester.ensureVisible(find.text('文件状态'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('文件状态'));
      await tester.pumpAndSettle();
      expect(find.text('确认'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('dashboard surfaces scanning copy while refreshing', (
    tester,
  ) async {
    GoogleFonts.config.allowRuntimeFetching = false;
    final tempRoot = Directory.systemTemp.createTempSync(
      'fh_radio_studio_dashboard_scanning_',
    );
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
    });

    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1365, 900);

    final projectDir = p.join(tempRoot.path, 'project');
    final gameDir = p.join(tempRoot.path, 'game');
    FhRadioStudioProject.ensure(projectDir);
    FhRadioStudioProject.writeSettings(projectDir, gameDir: gameDir);
    SharedPreferences.setMockInitialValues({
      'rm.studio.projectDir': projectDir,
      'rm.studio.repoRoot': p.dirname(p.current),
    });
    final prefs = await SharedPreferences.getInstance();
    final controller = _DashboardTestController(prefs);
    controller.setStateForTest(
      controller.state.copyWith(
        gameDir: gameDir,
        busy: true,
        busyLabel: '完整校验当前环境',
        languageSummary: '正在读取语言槽',
        toolchainStatus: ToolchainStatusSummary.checking(
          previous: _toolchainReady,
        ),
        fileIntegrity: _integritySummary(
          level: GameFileIntegrityLevel.baseline,
          checkedFiles: 4,
          baselineMatches: 4,
        ),
        log: const ['扫描状态已启动'],
      ),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          studioProvider.overrideWith((ref) => controller),
        ],
        child: MaterialApp(
          theme: buildAppTheme(
            brightness: Brightness.light,
            accent: AppAccent.lime,
          ),
          home: const Scaffold(
            body: DashboardScreen(initialToolOpen: true, initialFileOpen: true),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.text('正在验证完整性 · 请稍等'), findsOneWidget);
    expect(find.text('扫描状态'), findsWidgets);
    expect(find.text('等待扫描完成'), findsOneWidget);
    expect(find.text('扫描进行中'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('detail-scanning-spin-icon')),
      findsWidgets,
    );
    expect(find.text('正在检查 uv、Python、音频工具和 AI Provider 状态。'), findsOneWidget);
    expect(find.text('正在重新计算 FH6 受保护文件指纹，并比对原始备份、准备包和新游戏文件。'), findsOneWidget);
    expect(find.text('阻塞项 · 缺失会锁住主流程'), findsNothing);
    expect(find.text('游戏文件 = 原始备份'), findsNothing);
    expect(find.text('scan · 扫描中 · integrity'), findsOneWidget);
    expect(find.text('原始备份待检查'), findsOneWidget);
    expect(find.text('新文件待检查'), findsOneWidget);
    expect(find.text('自动刷新 · 30s'), findsNothing);
    expect(find.text('再次准备电台包'), findsNothing);
    expect(find.text('写入游戏'), findsNothing);
    expect(
      find.byKey(const ValueKey('dashboard-hero-scan-border')),
      findsOneWidget,
    );
    for (var i = 0; i < 3; i += 1) {
      expect(
        find.byKey(ValueKey('dashboard-status-scan-border-$i')),
        findsOneWidget,
      );
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'dashboard labels matched language slots as unsynced until ready',
    (tester) async {
      GoogleFonts.config.allowRuntimeFetching = false;
      final tempRoot = Directory.systemTemp.createTempSync(
        'fh_radio_studio_dashboard_language_unsynced_',
      );
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
      });

      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1365, 900);

      final projectDir = p.join(tempRoot.path, 'project');
      final gameDir = p.join(tempRoot.path, 'game');
      FhRadioStudioProject.ensure(projectDir);
      FhRadioStudioProject.writeSettings(projectDir, gameDir: gameDir);
      SharedPreferences.setMockInitialValues({
        'rm.studio.projectDir': projectDir,
        'rm.studio.repoRoot': p.dirname(p.current),
      });
      final prefs = await SharedPreferences.getInstance();
      final controller = _DashboardTestController(prefs);
      controller.setStateForTest(
        controller.state.copyWith(
          gameDir: gameDir,
          sourceLang: 'CHS',
          targetLang: 'EN',
          gameSourceLang: 'CHS',
          gameTargetLang: 'EN',
          availableLanguages: const ['CHS', 'EN'],
          preferredLang: 'EN',
          sourceLanguageExists: true,
          targetLanguageExists: true,
          targetMatchesSource: false,
          preferredMatchesTarget: true,
          voiceSlotVerified: true,
          languageReady: false,
          languageSummary: 'EN 槽尚未同步 CHS 显示',
          toolchainStatus: _toolchainReady,
          fileIntegrity: _integritySummary(
            level: GameFileIntegrityLevel.baseline,
            checkedFiles: 4,
            baselineMatches: 4,
          ),
          log: const ['语言槽待同步'],
        ),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(prefs),
            studioProvider.overrideWith((ref) => controller),
          ],
          child: MaterialApp(
            theme: buildAppTheme(
              brightness: Brightness.light,
              accent: AppAccent.lime,
            ),
            home: const Scaffold(body: DashboardScreen()),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('EN 槽尚未同步 CHS 显示'), findsWidgets);
      expect(find.text('槽未同步'), findsOneWidget);
      expect(find.text('语言对齐'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'dashboard keeps file integrity pending after toolchain refresh',
    (tester) async {
      GoogleFonts.config.allowRuntimeFetching = false;
      final tempRoot = Directory.systemTemp.createTempSync(
        'fh_radio_studio_dashboard_file_pending_',
      );
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
      });

      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1365, 900);

      final projectDir = p.join(tempRoot.path, 'project');
      final gameDir = p.join(tempRoot.path, 'game');
      FhRadioStudioProject.ensure(projectDir);
      FhRadioStudioProject.writeSettings(projectDir, gameDir: gameDir);
      SharedPreferences.setMockInitialValues({
        'rm.studio.projectDir': projectDir,
        'rm.studio.repoRoot': p.dirname(p.current),
      });
      final prefs = await SharedPreferences.getInstance();
      final controller = _DashboardTestController(prefs);
      controller.setStateForTest(
        controller.state.copyWith(
          gameDir: gameDir,
          sourceLang: 'JP',
          targetLang: 'EN',
          gameSourceLang: 'JP',
          gameTargetLang: 'EN',
          availableLanguages: const ['EN', 'JP'],
          preferredLang: 'EN',
          sourceLanguageExists: true,
          targetLanguageExists: true,
          targetMatchesSource: false,
          preferredMatchesTarget: true,
          voiceSlotVerified: true,
          languageReady: true,
          languageSummary: 'JP 显示 · EN 语音',
          toolchainStatus: _toolchainReady,
          lastPackageDir: p.join(projectDir, 'packages', 'current'),
          lastPackageSummary: _packageSummary(sourceLang: 'JP'),
          fileIntegrity: _integritySummary(
            level: GameFileIntegrityLevel.unknown,
            checkedFiles: 0,
          ),
          log: const ['工具链检查通过'],
        ),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(prefs),
            studioProvider.overrideWith((ref) => controller),
          ],
          child: MaterialApp(
            theme: buildAppTheme(
              brightness: Brightness.light,
              accent: AppAccent.lime,
            ),
            home: const Scaffold(body: DashboardScreen()),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('文件校验待刷新 · 先确认再写入'), findsOneWidget);
      expect(find.text('待校验'), findsWidgets);
      expect(find.text('扫描文件'), findsWidgets);
      expect(find.text('打开文件校验'), findsOneWidget);
      expect(find.text('scan · 待校验'), findsOneWidget);
      expect(find.text('准备包就绪 · 随时可写'), findsNothing);
      expect(find.text('包就绪'), findsNothing);
      expect(find.text('写入游戏'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('dashboard hero keeps key anchors aligned across scenarios', (
    tester,
  ) async {
    GoogleFonts.config.allowRuntimeFetching = false;
    final tempRoot = Directory.systemTemp.createTempSync(
      'fh_radio_studio_dashboard_hero_anchors_',
    );
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
    });

    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1365, 900);

    final projectDir = p.join(tempRoot.path, 'project');
    final gameDir = p.join(tempRoot.path, 'game');
    FhRadioStudioProject.ensure(projectDir);
    FhRadioStudioProject.writeSettings(projectDir, gameDir: gameDir);
    SharedPreferences.setMockInitialValues({
      'rm.studio.projectDir': projectDir,
      'rm.studio.repoRoot': p.dirname(p.current),
    });
    final prefs = await SharedPreferences.getInstance();
    final controller = _DashboardTestController(prefs);

    void setFixture(GameFileIntegrityLevel level, {required String log}) {
      controller.setStateForTest(
        controller.state.copyWith(
          gameDir: gameDir,
          sourceLang: 'JP',
          targetLang: 'EN',
          gameSourceLang: 'JP',
          gameTargetLang: 'EN',
          availableLanguages: const ['EN', 'JP'],
          preferredLang: 'EN',
          sourceLanguageExists: true,
          targetLanguageExists: true,
          targetMatchesSource: false,
          preferredMatchesTarget: true,
          voiceSlotVerified: true,
          languageReady: true,
          languageSummary: 'JP 显示 · EN 语音',
          toolchainStatus: _toolchainReady,
          lastPackageDir: p.join(projectDir, 'packages', 'current'),
          lastPackageSummary: _packageSummary(sourceLang: 'JP'),
          fileIntegrity: _integritySummary(
            level: level,
            checkedFiles: level == GameFileIntegrityLevel.unknown ? 0 : 4,
            packageMatches: level == GameFileIntegrityLevel.packageApplied
                ? 4
                : 0,
            baselineMatches: level == GameFileIntegrityLevel.baseline ? 4 : 0,
          ),
          log: [log],
        ),
      );
    }

    setFixture(GameFileIntegrityLevel.packageApplied, log: '写入游戏完成');
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          studioProvider.overrideWith((ref) => controller),
        ],
        child: MaterialApp(
          theme: buildAppTheme(
            brightness: Brightness.light,
            accent: AppAccent.lime,
          ),
          home: const Scaffold(body: DashboardScreen()),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final deployedTitle = tester.getRect(
      find.byKey(const ValueKey('dashboard-hero-title')),
    );
    final deployedCta = tester.getRect(
      find.byKey(const ValueKey('dashboard-primary-cta')),
    );
    final deployedSecondaryCta = tester.getRect(
      find.byKey(const ValueKey('dashboard-secondary-cta')),
    );
    final deployedActivity = tester.getRect(
      find.byKey(const ValueKey('dashboard-activity-strip')),
    );

    setFixture(GameFileIntegrityLevel.unknown, log: '等待文件校验');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final pendingTitle = tester.getRect(
      find.byKey(const ValueKey('dashboard-hero-title')),
    );
    final pendingCta = tester.getRect(
      find.byKey(const ValueKey('dashboard-primary-cta')),
    );
    final pendingSecondaryCta = tester.getRect(
      find.byKey(const ValueKey('dashboard-secondary-cta')),
    );
    final pendingActivity = tester.getRect(
      find.byKey(const ValueKey('dashboard-activity-strip')),
    );

    expect(pendingTitle.left, moreOrLessEquals(deployedTitle.left));
    expect(pendingTitle.top, moreOrLessEquals(deployedTitle.top));
    expect(pendingCta.left, moreOrLessEquals(deployedCta.left));
    expect(pendingCta.top, moreOrLessEquals(deployedCta.top));
    expect(pendingActivity.left, moreOrLessEquals(deployedActivity.left));
    expect(pendingActivity.top, moreOrLessEquals(deployedActivity.top));
    expect(deployedActivity.top, moreOrLessEquals(deployedSecondaryCta.top));
    expect(pendingActivity.top, moreOrLessEquals(pendingSecondaryCta.top));
    expect(tester.takeException(), isNull);
  });

  testWidgets('dashboard ready-to-prepare primary CTA uses info blue', (
    tester,
  ) async {
    GoogleFonts.config.allowRuntimeFetching = false;
    final tempRoot = Directory.systemTemp.createTempSync(
      'fh_radio_studio_dashboard_ready_cta_',
    );
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
    });

    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1365, 900);

    final projectDir = p.join(tempRoot.path, 'project');
    final gameDir = p.join(tempRoot.path, 'game');
    FhRadioStudioProject.ensure(projectDir);
    FhRadioStudioProject.writeSettings(projectDir, gameDir: gameDir);
    SharedPreferences.setMockInitialValues({
      'rm.studio.projectDir': projectDir,
      'rm.studio.repoRoot': p.dirname(p.current),
    });
    final prefs = await SharedPreferences.getInstance();
    final controller = _DashboardTestController(prefs);
    controller.setStateForTest(
      controller.state.copyWith(
        gameDir: gameDir,
        sourceLang: 'JP',
        targetLang: 'EN',
        gameSourceLang: 'JP',
        gameTargetLang: 'EN',
        availableLanguages: const ['EN', 'JP'],
        preferredLang: 'EN',
        sourceLanguageExists: true,
        targetLanguageExists: true,
        targetMatchesSource: false,
        preferredMatchesTarget: true,
        voiceSlotVerified: true,
        languageReady: true,
        languageSummary: 'JP 显示 · EN 语音',
        toolchainStatus: _toolchainReady,
        fileIntegrity: _integritySummary(
          level: GameFileIntegrityLevel.baseline,
          checkedFiles: 4,
          baselineMatches: 4,
        ),
        log: const ['环境状态可用'],
      ),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          studioProvider.overrideWith((ref) => controller),
        ],
        child: MaterialApp(
          theme: buildAppTheme(
            brightness: Brightness.light,
            accent: AppAccent.lime,
          ),
          home: const Scaffold(body: DashboardScreen()),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('环境就绪 · 浏览或编辑都行'), findsOneWidget);
    expect(find.text('准备电台包'), findsOneWidget);
    expect(find.text('STATUS SNAPSHOT'), findsOneWidget);
    expect(find.text('RECENT ACTIVITY'), findsNothing);

    final cta = tester.widget<Container>(
      find.byKey(const ValueKey('dashboard-primary-cta')),
    );
    final ctaSize = tester.getSize(
      find.byKey(const ValueKey('dashboard-primary-cta')),
    );
    final decoration = cta.decoration as BoxDecoration;
    expect(ctaSize.height, 38);
    expect(decoration.color, RmTokens.infoLight);
    expect(
      decoration.color,
      isNot(accentColors(AppAccent.lime, Brightness.light).base),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'dashboard shows last applied package when current package is gone',
    (tester) async {
      GoogleFonts.config.allowRuntimeFetching = false;
      final tempRoot = Directory.systemTemp.createTempSync(
        'fh_radio_studio_dashboard_previous_applied_',
      );
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
      });

      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1365, 900);

      final projectDir = p.join(tempRoot.path, 'project');
      final gameDir = p.join(tempRoot.path, 'game');
      FhRadioStudioProject.ensure(projectDir);
      FhRadioStudioProject.writeSettings(projectDir, gameDir: gameDir);
      SharedPreferences.setMockInitialValues({
        'rm.studio.projectDir': projectDir,
        'rm.studio.repoRoot': p.dirname(p.current),
      });
      final prefs = await SharedPreferences.getInstance();
      final controller = _DashboardTestController(prefs);
      controller.setStateForTest(
        controller.state.copyWith(
          gameDir: gameDir,
          sourceLang: 'JP',
          targetLang: 'EN',
          gameSourceLang: 'JP',
          gameTargetLang: 'EN',
          availableLanguages: const ['EN', 'JP'],
          preferredLang: 'EN',
          sourceLanguageExists: true,
          targetLanguageExists: true,
          targetMatchesSource: false,
          preferredMatchesTarget: true,
          voiceSlotVerified: true,
          languageReady: true,
          languageSummary: 'JP 显示 · EN 语音',
          toolchainStatus: _toolchainReady,
          lastPackageDir: null,
          lastPackageSummary: null,
          fileIntegrity: _integritySummary(
            level: GameFileIntegrityLevel.previousPackageApplied,
            checkedFiles: 4,
            lastAppliedPackageMatches: 4,
            packageManifestPath: null,
            lastAppliedPackageManifestPath: p.join(
              projectDir,
              '.fh-radio-studio',
              'last_applied.json',
            ),
          ),
          log: const ['上一版准备包已写入'],
        ),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(prefs),
            studioProvider.overrideWith((ref) => controller),
          ],
          child: MaterialApp(
            theme: buildAppTheme(
              brightness: Brightness.light,
              accent: AppAccent.lime,
            ),
            home: const Scaffold(body: DashboardScreen()),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('上一版准备包已写入'), findsWidgets);
      expect(find.text('上一版已写入'), findsWidgets);
      expect(find.text('环境就绪 · 浏览或编辑都行'), findsNothing);
      expect(find.text('环境状态可用'), findsNothing);
      expect(find.text('准备电台包'), findsWidgets);
      expect(
        find.text('这不是原始环境；游戏目录仍是上次写入的准备包。只有“写入游戏”会再次改 FH6 目录。'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );
}

class _DashboardTestController extends StudioController {
  _DashboardTestController(super.prefs);

  int rebuildBaselineCount = 0;

  void setStateForTest(StudioState value) {
    state = value;
  }

  @override
  Future<void> startupFullCheckOnce() async {}

  @override
  Future<bool> rebuildBaselineFromCurrentGame() async {
    rebuildBaselineCount += 1;
    return true;
  }
}

const _toolchainReady = ToolchainStatusSummary(
  checked: true,
  profile: 'local-heavy',
  status: 'ready',
  label: 'OK',
  summary: '核心工具链可用；AI 和硬件加速会按实际能力降级。',
  sections: [
    ToolchainStatusSection(
      id: 'uv',
      title: 'uv 运行时',
      status: 'ready',
      summary: 'uv 可用',
      items: [
        ToolchainStatusItem(
          label: '环境',
          value: r'C:\FH Radio Studio\toolchain\envs\base',
          detail: '',
          status: 'info',
        ),
      ],
      warnings: [],
    ),
    ToolchainStatusSection(
      id: 'python',
      title: 'Python 环境',
      status: 'ready',
      summary: '依赖已覆盖当前 profile',
      items: [],
      warnings: [],
    ),
    ToolchainStatusSection(
      id: 'audio_tools',
      title: '核心音频工具',
      status: 'ready',
      summary: 'ffmpeg / vgmstream / fsbankcl 全部可用',
      items: [
        ToolchainStatusItem(
          label: 'ffmpeg',
          value: r'C:\FH Radio Studio\tools\audio\ffmpeg\ffmpeg.exe',
          detail: '',
          status: 'ready',
        ),
      ],
      warnings: [],
    ),
    ToolchainStatusSection(
      id: 'hardware',
      title: '硬件加速',
      status: 'ready',
      summary: 'CUDA 可用',
      items: [
        ToolchainStatusItem(
          label: 'NVIDIA',
          value: 'CUDA true',
          detail: '',
          status: 'ready',
        ),
      ],
      warnings: [],
    ),
    ToolchainStatusSection(
      id: 'ai',
      title: 'AI Provider',
      status: 'missing',
      summary: '深度 Provider 未加载',
      items: [],
      warnings: [],
    ),
  ],
  fixes: [],
);

const _toolchainDeepReady = ToolchainStatusSummary(
  checked: true,
  profile: 'local-deep',
  status: 'ready',
  label: 'OK',
  summary: '工具链检查通过。',
  sections: [
    ToolchainStatusSection(
      id: 'uv',
      title: 'uv 运行时',
      status: 'ready',
      summary: 'uv 可用',
      items: [
        ToolchainStatusItem(
          label: 'Torch Extra',
          value: 'torch-cu128',
          detail: '',
          status: 'info',
        ),
      ],
      warnings: [],
    ),
    ToolchainStatusSection(
      id: 'python',
      title: 'Python 环境',
      status: 'ready',
      summary: 'Python 依赖已覆盖当前杯型',
      items: [],
      warnings: [],
    ),
    ToolchainStatusSection(
      id: 'hardware',
      title: '硬件加速',
      status: 'ready',
      summary: 'CUDA 可用',
      items: [
        ToolchainStatusItem(
          label: 'Torch',
          value: '2.7.1+cu128',
          detail: '',
          status: 'ready',
        ),
        ToolchainStatusItem(
          label: 'Device',
          value: 'cuda',
          detail: '',
          status: 'info',
        ),
      ],
      warnings: [],
    ),
    ToolchainStatusSection(
      id: 'ai',
      title: 'AI 分析',
      status: 'ready',
      summary: 'AI Providers 已就绪',
      items: [
        ToolchainStatusItem(
          label: 'Model Dir',
          value: r'C:\FH Radio Studio\models',
          detail: '',
          status: 'info',
        ),
        ToolchainStatusItem(
          label: 'beat_this',
          value: 'ready',
          detail: 'beat-this 0.0.1',
          status: 'ready',
        ),
        ToolchainStatusItem(
          label: 'songformer',
          value: 'ready',
          detail: 'ASLP-lab/SongFormer',
          status: 'ready',
        ),
        ToolchainStatusItem(
          label: 'mert',
          value: 'ready',
          detail: 'm-a-p/MERT-v1-95M',
          status: 'ready',
        ),
      ],
      warnings: [],
    ),
  ],
  fixes: [],
);

PackageArtifactSummary _packageSummary({required String sourceLang}) {
  return PackageArtifactSummary(
    radio: 4,
    station: 'Horizon XS',
    bankName: 'R4_Tracks_CU1.assets.bank',
    musicCount: 1,
    bankSlots: 25,
    playlistMode: 'only',
    skipBank: false,
    runtimeVerified: true,
    sourceLang: sourceLang,
    targetLang: 'EN',
    previewTracks: const ['Test Track'],
    assignments: const [],
  );
}

void _writeLegacyPlaylistPlan(String projectDir, PlaylistPlan plan) {
  final file = File(PlaylistPlanStore.configPath(projectDir));
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(plan.encodeForCli(), encoding: utf8);
}

GameFileIntegritySummary _integritySummary({
  required GameFileIntegrityLevel level,
  required int checkedFiles,
  int packageMatches = 0,
  int lastAppliedPackageMatches = 0,
  int baselineMatches = 0,
  int pendingBaselineMatches = 0,
  int changedFiles = 0,
  bool hasPendingBaseline = false,
  String? baselineManifestPath = 'baseline_manifest.json',
  String? packageManifestPath = 'fh_radio_studio_package_manifest.json',
  String? lastAppliedPackageManifestPath,
}) {
  String levelName(GameFileIntegrityLevel value) {
    return switch (value) {
      GameFileIntegrityLevel.noPackage => 'no_package',
      GameFileIntegrityLevel.noBaseline => 'no_baseline',
      GameFileIntegrityLevel.packageApplied => 'package_applied',
      GameFileIntegrityLevel.previousPackageApplied =>
        'previous_package_applied',
      GameFileIntegrityLevel.baseline => 'baseline',
      GameFileIntegrityLevel.buildBumpAvailable => 'build_bump_available',
      GameFileIntegrityLevel.gameChanged => 'game_changed',
      GameFileIntegrityLevel.externalConflict => 'external_conflict',
      GameFileIntegrityLevel.pendingVerify => 'pending_verify',
      GameFileIntegrityLevel.unknown => 'unknown',
    };
  }

  return GameFileIntegritySummary.fromJson({
    'level': levelName(level),
    'checked_files': checkedFiles,
    'package_matches': packageMatches,
    'last_applied_package_matches': lastAppliedPackageMatches,
    'baseline_matches': baselineMatches,
    'pending_baseline_matches': pendingBaselineMatches,
    'changed_files': changedFiles,
    'unknown_files': 0,
    'package_files': checkedFiles,
    'baseline_manifest_path': baselineManifestPath,
    'pending_baseline_manifest_path': hasPendingBaseline
        ? 'pending_baseline_manifest.json'
        : null,
    'package_manifest_path': packageManifestPath,
    'last_applied_package_manifest_path': lastAppliedPackageManifestPath,
    'current_game_version_id': 'steam-b23271700',
    'baseline_build_compatible': true,
    'baseline_supported_game_version_ids': const ['steam-b23271700'],
    'issues': const [],
  });
}
