import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;
import 'package:fh_radio_studio/core/playlist_plan.dart';
import 'package:fh_radio_studio/core/project_workspace.dart';
import 'package:fh_radio_studio/core/track_metadata_cache.dart';
import 'package:fh_radio_studio/core/track_timing_config.dart';
import 'package:fh_radio_studio/domain/radio_library.dart';
import 'package:fh_radio_studio/screens/custom_pool.dart';
import 'package:fh_radio_studio/screens/playlist.dart';
import 'package:fh_radio_studio/screens/playlist/radio_column.dart';
import 'package:fh_radio_studio/screens/playlist/track_card.dart';
import 'package:fh_radio_studio/shell/app_shell.dart';
import 'package:fh_radio_studio/shell/title_bar.dart';
import 'package:fh_radio_studio/state/app_state.dart';
import 'package:fh_radio_studio/state/studio_state.dart';
import 'package:fh_radio_studio/state/custom_pool_tracks.dart';
import 'package:fh_radio_studio/state/playlist_catalog_state.dart';
import 'package:fh_radio_studio/state/playlist_plan_state.dart';
import 'package:fh_radio_studio/state/siren_import_queue_state.dart';
import 'package:fh_radio_studio/theme/accents.dart';
import 'package:fh_radio_studio/theme/app_theme.dart';
import 'package:fh_radio_studio/widgets/package_build_notice_dialog.dart';
import 'package:fh_radio_studio/widgets/package_loudness_dialog.dart';
import 'package:fh_radio_studio/widgets/rm_button.dart';
import 'package:fh_radio_studio/widgets/rm_panel.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _projectDirKey = 'rm.studio.projectDir';

void main() {
  test('placeholder', () {
    expect(1 + 1, 2);
  });

  testWidgets('TrackCard marks MSR imported pool tracks', (tester) async {
    const track = PoolTrack(
      id: 'siren-card',
      title: 'Siren Card',
      artist: '塞壬唱片-MSR',
      source: r'C:\project\siren\MSR-232251.wav',
      durationSec: 121,
      bpm: 0,
      key: '待分析',
      configured: false,
      confirmed: 0,
      sourceKind: 'siren',
      sourceLabel: 'MSR-232251',
      sirenCid: '232251',
      added: '刚刚',
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(
          brightness: Brightness.light,
          accent: AppAccent.lime,
        ),
        home: Scaffold(body: Center(child: TrackCard.fromPoolTrack(track))),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('MSR'), findsOneWidget);
    expect(find.text('0/4'), findsOneWidget);
  });

  testWidgets('package loudness dialog uses discrete offset choices', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(
          brightness: Brightness.light,
          accent: AppAccent.lime,
        ),
        home: const Scaffold(
          body: PackageLoudnessDialog(
            referenceMedianLufs: -24,
            initialOffsetLu: 3,
            previewInputLufs: -24,
            currentPackageOffsetLu: 1,
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('+0'), findsOneWidget);
    expect(find.text('+1'), findsOneWidget);
    expect(find.text('+2'), findsOneWidget);
    expect(find.text('+3 LU'), findsOneWidget);
    expect(find.text('+3'), findsOneWidget);
    expect(find.text('+4'), findsOneWidget);
    expect(find.text('+5'), findsOneWidget);
    expect(find.text('+6'), findsOneWidget);
    expect(find.text('当前准备包'), findsOneWidget);
    expect(find.text('推荐起步'), findsOneWidget);
    expect(find.text('目标文件 LUFS'), findsOneWidget);

    await tester.tap(find.text('+6'));
    await tester.pumpAndSettle();

    expect(find.text('→ -18.0 LUFS'), findsOneWidget);
    expect(find.text('听感差不多翻倍！'), findsOneWidget);
  });

  testWidgets('builtin playlist header uses visible original track count', (
    tester,
  ) async {
    const radio = RadioStation(
      code: 'R5',
      name: 'Hospital Records',
      hue: 'cyan',
      genre: 'R5',
      slot: 25,
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(
          brightness: Brightness.light,
          accent: AppAccent.lime,
        ),
        home: Scaffold(
          body: SizedBox(
            width: 360,
            height: 560,
            child: PlaylistColumn.radio(
              radio: radio,
              isCustom: false,
              count: 24,
              capacity: 24,
              isDragOver: false,
              children: [Text('baseline track')],
            ),
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('24 / 24'), findsOneWidget);
    expect(find.text('24 / 25'), findsNothing);
  });

  testWidgets('RmPanel keeps compact header actions right aligned', (
    tester,
  ) async {
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 420);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(
          brightness: Brightness.light,
          accent: AppAccent.lime,
        ),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 760,
              child: RmPanel(
                title: '工具链健康',
                subtitle: 'uv / Python / 音频工具 / AI Providers 分层检查',
                headerTrailing: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  alignment: WrapAlignment.end,
                  children: [
                    RmButton(
                      key: const Key('panel_check_action'),
                      onPressed: () {},
                      size: RmButtonSize.sm,
                      label: '检查工具链',
                    ),
                    RmButton(
                      key: const Key('panel_sync_action'),
                      onPressed: () {},
                      size: RmButtonSize.sm,
                      variant: RmButtonVariant.ghost,
                      label: '同步 AI 环境',
                    ),
                  ],
                ),
                child: const SizedBox(height: 64),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.pump();

    final panel = tester.getRect(find.byType(RmPanel));
    final lastAction = tester.getRect(
      find.byKey(const Key('panel_sync_action')),
    );
    expect((panel.right - 18 - lastAction.right).abs(), lessThanOrEqualTo(1));
  });

  testWidgets('title bar derives toolchain badge from CLI health summary', (
    tester,
  ) async {
    final tempRoot = Directory.systemTemp.createTempSync(
      'fh_radio_studio_titlebar_toolchain_',
    );
    final semantics = tester.ensureSemantics();
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
    });
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 80);

    final projectDir = p.join(tempRoot.path, 'project');
    FhRadioStudioProject.ensure(projectDir);
    SharedPreferences.setMockInitialValues({_projectDirKey: projectDir});
    final prefs = await SharedPreferences.getInstance();
    final controller = _StaticStudioController(prefs);
    controller.setStateForTest(
      controller.state.copyWith(
        toolsOk: true,
        toolchainStatus: const ToolchainStatusSummary(
          checked: true,
          profile: 'local-heavy',
          status: 'degraded',
          label: '可降级运行',
          summary: '基础功能可用，AI 或加速能力需要修复。',
          sections: [],
          fixes: [],
        ),
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
          home: const Scaffold(body: TitleBar()),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('工具链可降级'), findsOneWidget);
    expect(find.text('工具链可用'), findsNothing);

    controller.setStateForTest(
      controller.state.copyWith(
        toolsOk: false,
        toolchainStatus: const ToolchainStatusSummary(
          checked: true,
          profile: 'local-heavy',
          status: 'ready',
          label: 'OK',
          summary: '工具链检查通过。',
          sections: [],
          fixes: [],
        ),
      ),
    );
    await tester.pump();

    expect(find.text('工具链可用'), findsOneWidget);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets(
    'custom songs stay editable when the original backup is missing',
    (tester) async {
      final tempRoot = Directory.systemTemp.createTempSync(
        'fh_radio_studio_custom_pool_missing_backup_',
      );
      final semantics = tester.ensureSemantics();
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
      });

      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(2048, 1100);

      final projectDir = p.join(tempRoot.path, 'project');
      FhRadioStudioProject.ensure(projectDir);
      final audio = File(p.join(projectDir, 'sources', 'User Song.wav'))
        ..createSync(recursive: true)
        ..writeAsStringSync('audio', encoding: utf8);
      SharedPreferences.setMockInitialValues({_projectDirKey: projectDir});
      final prefs = await SharedPreferences.getInstance();
      final controller = _StaticStudioController(prefs);
      controller.setStateForTest(
        controller.state.copyWith(
          musicPaths: [audio.path],
          baselinePlanSummary: _lockedBaselinePlan(),
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
            home: const Scaffold(body: CustomPoolScreen()),
          ),
        ),
      );
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(controller.state.fileIntegrity.hasCurrentBaseline, isFalse);
      expect(controller.state.baselineWorkflowLocked, isTrue);
      expect(controller.state.projectEditingLocked, isTrue);
      expect(controller.state.customSongEditingLocked, isFalse);
      expect(find.text('自建歌曲'), findsOneWidget);
      expect(find.textContaining('编辑已锁定', findRichText: true), findsNothing);
      expect(find.text('User Song'), findsOneWidget);
      expect(
        tester
            .widget<RmButton>(find.widgetWithText(RmButton, '导入新曲目'))
            .onPressed,
        isNotNull,
      );
      semantics.dispose();
    },
  );

  testWidgets('custom song import masks the whole pool page while importing', (
    tester,
  ) async {
    final tempRoot = Directory.systemTemp.createTempSync(
      'fh_radio_studio_custom_pool_import_gate_',
    );
    final semantics = tester.ensureSemantics();
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
    });

    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(2048, 1100);

    final projectDir = p.join(tempRoot.path, 'project');
    FhRadioStudioProject.ensure(projectDir);
    final audio = File(p.join(projectDir, 'sources', 'User Song.wav'))
      ..createSync(recursive: true)
      ..writeAsStringSync('audio', encoding: utf8);
    SharedPreferences.setMockInitialValues({_projectDirKey: projectDir});
    final prefs = await SharedPreferences.getInstance();
    final controller = _StaticStudioController(prefs);
    controller.setStateForTest(
      controller.state.copyWith(
        busy: true,
        busyLabel: '导入自建歌曲',
        musicPaths: [audio.path],
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
          home: const Scaffold(body: CustomPoolScreen()),
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(
      find.byKey(const ValueKey('custom-pool-import-gate')),
      findsOneWidget,
    );
    expect(find.text('正在导入自建歌曲'), findsOneWidget);
    expect(
      find.text('正在导入音频到项目 sources，必要时转换到 48 kHz，并刷新曲目信息。'),
      findsOneWidget,
    );
    final overlayRect = tester.getRect(
      find.byKey(const ValueKey('custom-pool-import-gate')),
    );
    expect(overlayRect.height, greaterThan(1000));
    expect(
      overlayRect.top,
      lessThanOrEqualTo(tester.getRect(find.text('自建歌曲')).top),
    );
    expect(
      overlayRect.bottom,
      greaterThanOrEqualTo(tester.getRect(find.text('池子总数')).bottom),
    );
    expect(
      overlayRect.bottom,
      greaterThanOrEqualTo(tester.getRect(find.text('曲目').first).bottom),
    );
    expect(find.text('User Song'), findsOneWidget);
    expect(
      tester.widget<RmButton>(find.widgetWithText(RmButton, '导入中')).onPressed,
      isNull,
    );
    semantics.dispose();
  });

  testWidgets('siren import shows pool header status without page mask', (
    tester,
  ) async {
    final tempRoot = Directory.systemTemp.createTempSync(
      'fh_radio_studio_custom_pool_siren_import_status_',
    );
    final semantics = tester.ensureSemantics();
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
    });

    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1600, 900);

    final projectDir = p.join(tempRoot.path, 'project');
    FhRadioStudioProject.ensure(projectDir);
    SharedPreferences.setMockInitialValues({_projectDirKey: projectDir});
    final prefs = await SharedPreferences.getInstance();
    final controller = _StaticStudioController(prefs);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          studioProvider.overrideWith((ref) => controller),
          sirenImportQueueProvider.overrideWith(
            (ref) => _StaticSirenImportQueueController(ref),
          ),
        ],
        child: MaterialApp(
          theme: buildAppTheme(
            brightness: Brightness.light,
            accent: AppAccent.lime,
          ),
          home: const Scaffold(body: CustomPoolScreen()),
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('custom-pool-import-gate')), findsNothing);
    expect(find.text('塞壬导入中'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(
      tester.widget<RmButton>(find.widgetWithText(RmButton, '塞壬导入中')).onPressed,
      isNotNull,
    );
    expect(
      tester.widget<RmButton>(find.widgetWithText(RmButton, '导入新曲目')).onPressed,
      isNull,
    );
    expect(
      tester.widget<RmButton>(find.widgetWithText(RmButton, '导入新曲目')).tooltip,
      '塞壬唱片正在导入，完成后可导入本地歌曲',
    );
    semantics.dispose();
  });

  testWidgets('custom song import overlay keeps shell tabs reachable', (
    tester,
  ) async {
    final tempRoot = Directory.systemTemp.createTempSync(
      'fh_radio_studio_custom_pool_import_tabs_',
    );
    final semantics = tester.ensureSemantics();
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
    });

    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1400, 900);

    final projectDir = p.join(tempRoot.path, 'project');
    FhRadioStudioProject.ensure(projectDir);
    final audio = File(p.join(projectDir, 'sources', 'User Song.wav'))
      ..createSync(recursive: true)
      ..writeAsStringSync('audio', encoding: utf8);
    SharedPreferences.setMockInitialValues({
      _projectDirKey: projectDir,
      'rm.navStyle': 'tabs',
    });
    final prefs = await SharedPreferences.getInstance();
    final controller = _StaticStudioController(prefs);
    controller.setStateForTest(
      controller.state.copyWith(
        busy: true,
        busyLabel: '导入自建歌曲',
        musicPaths: [audio.path],
      ),
    );
    final router = GoRouter(
      initialLocation: '/pool',
      routes: [
        ShellRoute(
          builder: (context, state, child) => AppShell(child: child),
          routes: [
            GoRoute(
              path: '/pool',
              builder: (context, state) => const CustomPoolScreen(),
            ),
            GoRoute(
              path: '/playlist',
              builder: (context, state) =>
                  const Center(child: Text('playlist reached')),
            ),
          ],
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          studioProvider.overrideWith((ref) => controller),
          effectivePlaylistPlanProvider.overrideWithValue(
            const PlaylistPlan.empty(),
          ),
        ],
        child: MaterialApp.router(
          theme: buildAppTheme(
            brightness: Brightness.light,
            accent: AppAccent.lime,
          ),
          routerConfig: router,
        ),
      ),
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey('custom-pool-import-gate')),
      findsOneWidget,
    );
    await tester.tap(find.text('播放列表'));
    await tester.pumpAndSettle();

    expect(find.text('playlist reached'), findsOneWidget);
    expect(find.byKey(const ValueKey('custom-pool-import-gate')), findsNothing);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets(
    'custom song editor sorts least configured first and filters completed',
    (tester) async {
      final semantics = tester.ensureSemantics();
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(2048, 1100);

      const zero = PoolTrack(
        id: 'zero-config',
        title: 'Zero Config',
        artist: 'Local Artist',
        source: r'C:\music\zero.wav',
        durationSec: 121,
        bpm: 0,
        key: '待分析',
        configured: false,
        confirmed: 0,
        added: '刚刚',
      );
      const half = PoolTrack(
        id: 'half-config',
        title: 'Half Config',
        artist: 'Local Artist',
        source: r'C:\music\half.wav',
        durationSec: 121,
        bpm: 0,
        key: '待分析',
        configured: false,
        confirmed: 2,
        added: '刚刚',
      );
      const done = PoolTrack(
        id: 'done-config',
        title: 'Done Config',
        artist: 'Local Artist',
        source: r'C:\music\done.wav',
        durationSec: 121,
        bpm: 0,
        key: '待分析',
        configured: true,
        confirmed: 4,
        assignedTo: 'XS',
        slot: 1,
        added: '刚刚',
      );

      SharedPreferences.setMockInitialValues({_projectDirKey: 'project'});
      final prefs = await SharedPreferences.getInstance();
      final controller = _StaticStudioController(prefs);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(prefs),
            studioProvider.overrideWith((ref) => controller),
            realPoolTracksProvider.overrideWithValue(const [done, half, zero]),
            effectivePlaylistPlanProvider.overrideWithValue(
              const PlaylistPlan.empty(),
            ),
          ],
          child: MaterialApp(
            theme: buildAppTheme(
              brightness: Brightness.light,
              accent: AppAccent.lime,
            ),
            home: const Scaffold(body: CustomPoolScreen()),
          ),
        ),
      );
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.text('待完成 · 2'), findsOneWidget);
      expect(find.text('已完成 · 1'), findsOneWidget);
      expect(find.text('未分配 · 2'), findsNothing);

      final zeroTop = tester.getTopLeft(find.text('Zero Config')).dy;
      final halfTop = tester.getTopLeft(find.text('Half Config')).dy;
      final doneTop = tester.getTopLeft(find.text('Done Config')).dy;
      expect(zeroTop, lessThan(halfTop));
      expect(halfTop, lessThan(doneTop));

      await tester.tap(find.text('已完成 · 1'));
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.text('Done Config'), findsOneWidget);
      expect(find.text('Zero Config'), findsNothing);
      expect(find.text('Half Config'), findsNothing);
      semantics.dispose();
    },
  );

  testWidgets('custom pool filters MSR imports and sorts MSR first on ties', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(2048, 1100);

    const localTie = PoolTrack(
      id: 'local-tie',
      title: 'Local Tie',
      artist: 'Local Artist',
      source: r'C:\music\local-tie.wav',
      durationSec: 121,
      bpm: 0,
      key: '待分析',
      configured: false,
      confirmed: 0,
      added: '刚刚',
    );
    const sirenTie = PoolTrack(
      id: 'siren-tie',
      title: 'Siren Tie',
      artist: '塞壬唱片-MSR',
      source: r'C:\project\siren\MSR-232251.wav',
      durationSec: 121,
      bpm: 0,
      key: '待分析',
      configured: false,
      confirmed: 0,
      sourceKind: 'siren',
      sourceLabel: 'MSR-232251',
      sirenCid: '232251',
      albumName: '巴别塔OST',
      added: '刚刚',
    );
    const half = PoolTrack(
      id: 'half-config',
      title: 'Half Config',
      artist: 'Local Artist',
      source: r'C:\music\half.wav',
      durationSec: 121,
      bpm: 0,
      key: '待分析',
      configured: false,
      confirmed: 2,
      added: '刚刚',
    );

    SharedPreferences.setMockInitialValues({_projectDirKey: 'project'});
    final prefs = await SharedPreferences.getInstance();
    final controller = _StaticStudioController(prefs);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          studioProvider.overrideWith((ref) => controller),
          realPoolTracksProvider.overrideWithValue(const [
            localTie,
            sirenTie,
            half,
          ]),
          effectivePlaylistPlanProvider.overrideWithValue(
            const PlaylistPlan.empty(),
          ),
        ],
        child: MaterialApp(
          theme: buildAppTheme(
            brightness: Brightness.light,
            accent: AppAccent.lime,
          ),
          home: const Scaffold(body: CustomPoolScreen()),
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('MSR · 1'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Siren Tie')).dy,
      lessThan(tester.getTopLeft(find.text('Local Tie')).dy),
    );

    await tester.tap(find.byKey(const ValueKey('custom-pool-msr-only-switch')));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('全部 · 1'), findsOneWidget);
    expect(find.text('待完成 · 1'), findsOneWidget);
    expect(find.text('Siren Tie'), findsOneWidget);
    expect(find.text('Local Tie'), findsNothing);
    expect(find.text('Half Config'), findsNothing);
    semantics.dispose();
  });

  testWidgets('custom pool MSR empty action opens the siren library', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1600, 900);

    SharedPreferences.setMockInitialValues({_projectDirKey: 'project'});
    final prefs = await SharedPreferences.getInstance();
    final controller = _StaticStudioController(prefs);
    final router = GoRouter(
      initialLocation: '/pool',
      routes: [
        GoRoute(
          path: '/pool',
          builder: (context, state) => const CustomPoolScreen(),
        ),
        GoRoute(
          path: '/siren',
          builder: (context, state) => const Center(child: Text('msr reached')),
        ),
      ],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          studioProvider.overrideWith((ref) => controller),
          realPoolTracksProvider.overrideWithValue(const []),
          effectivePlaylistPlanProvider.overrideWithValue(
            const PlaylistPlan.empty(),
          ),
        ],
        child: MaterialApp.router(
          theme: buildAppTheme(
            brightness: Brightness.light,
            accent: AppAccent.lime,
          ),
          routerConfig: router,
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('custom-pool-msr-only-switch')));
    await tester.pump();

    expect(find.text('前往 MSR'), findsOneWidget);

    await tester.tap(find.text('前往 MSR'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('msr reached'), findsOneWidget);
    semantics.dispose();
    router.dispose();
  });

  testWidgets('custom song delete button removes the project copy', (
    tester,
  ) async {
    final tempRoot = Directory.systemTemp.createTempSync(
      'fh_radio_studio_custom_pool_delete_',
    );
    final semantics = tester.ensureSemantics();
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
    });

    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(2048, 1100);

    final projectDir = p.join(tempRoot.path, 'project');
    FhRadioStudioProject.ensure(projectDir);
    final audio = File(p.join(projectDir, 'sources', 'User Song.wav'))
      ..createSync(recursive: true)
      ..writeAsStringSync('audio', encoding: utf8);
    TrackTimingStore.save(
      projectDir,
      TrackTimingConfig(
        source: audio.path,
        bpm: 120,
        markersSec: const {
          'TrackDrop': 0,
          'PostDrop': 0.2,
          'TrackLoopStart': 0.2,
          'TrackLoopEnd': 0.8,
          'PostRaceLoopStart': 0.8,
          'PostRaceLoopEnd': 0.95,
        },
        confirmed: const {'td': true, 'pd': true, 'tl': true, 'pl': true},
        updatedAt: DateTime.utc(2026, 5, 22),
      ),
    );
    PlaylistPlanStore.write(
      projectDir,
      const PlaylistPlan.empty().assign(
        source: audio.path,
        radioCode: 'XS',
        playlistType: 'FreeRoam',
        slot: 1,
      ),
    );
    final cacheFile = File(TrackMetadataCache.configPath(projectDir));
    cacheFile.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        'schema_version': 1,
        'tracks': [
          {
            'source': audio.path,
            'path_key': TrackTimingConfig.keyForPath(audio.path),
            'artist': 'Local Artist',
            'title': 'User Song',
            'from_tags': true,
          },
        ],
      }),
      encoding: utf8,
    );

    SharedPreferences.setMockInitialValues({_projectDirKey: projectDir});
    final prefs = await SharedPreferences.getInstance();
    final controller = _StaticStudioController(prefs);
    controller.setStateForTest(
      controller.state.copyWith(musicPaths: [audio.path]),
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
          home: const Scaffold(body: CustomPoolScreen()),
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('User Song'), findsOneWidget);

    final deleteButton = find.byWidgetPredicate(
      (widget) => widget is RmButton && widget.tooltip == '删除',
    );
    expect(deleteButton, findsOneWidget);
    await tester.tap(deleteButton);
    await tester.pump();

    expect(find.text('删除这首自建歌曲？'), findsOneWidget);
    await tester.tap(find.text('确认删除'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));

    expect(tester.takeException(), isNull);
    expect(audio.existsSync(), isFalse);
    expect(controller.state.musicPaths, isNot(contains(audio.path)));
    expect(find.text('User Song'), findsNothing);
    expect(TrackTimingStore.readAll(projectDir), isEmpty);
    expect(
      PlaylistPlanStore.read(projectDir).assignmentsForPath(audio.path),
      isEmpty,
    );
    expect(
      TrackMetadataCache.read(projectDir),
      isNot(contains(TrackTimingConfig.keyForPath(audio.path))),
    );
    semantics.dispose();
  });

  testWidgets('playlist screen initializes from the latest package', (
    tester,
  ) async {
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(2048, 1100);

    final repoRoot = p.dirname(p.current);
    final projectDir = p.join(repoRoot, 'test', 'project', 'cli-full-flow');
    SharedPreferences.setMockInitialValues({
      _projectDirKey: projectDir,
      'rm.studio.repoRoot': repoRoot,
    });
    final prefs = await SharedPreferences.getInstance();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
        child: MaterialApp(
          theme: buildAppTheme(
            brightness: Brightness.light,
            accent: AppAccent.lime,
          ),
          home: const Scaffold(body: PlaylistScreen()),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(tester.takeException(), isNull);
    expect(find.text('播放列表'), findsOneWidget);
    expect(find.text('分场景编辑'), findsOneWidget);
    expect(find.text('统一写入漫游和比赛'), findsNothing);
    expect(find.text('Full Flow Test'), findsWidgets);
  });

  testWidgets(
    'playlist toolbar keeps list controls stable when switching view',
    (tester) async {
      final tempRoot = Directory.systemTemp.createTempSync(
        'fh_radio_studio_playlist_toolbar_widget_',
      );
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
      });

      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 900);

      const radio = RadioStation(
        code: 'XS',
        name: 'Horizon XS',
        hue: 'violet',
        genre: 'Rock',
        slot: 3,
      );
      const tracks = [
        TrackRef(
          id: 'xs-original',
          title: 'Original XS',
          artist: 'Forza',
          durationSec: 200,
        ),
      ];
      const packageCatalog = PlaylistCatalog(
        view: PlaylistCatalogView.package,
        origin: PlaylistCatalogOrigin.package,
        sourcePath: null,
        radios: [radio],
        modes: {'XS': StationMode.custom},
        freeRoamTracks: {'XS': tracks},
        eventTracks: {'XS': tracks},
      );
      const gameCatalog = PlaylistCatalog(
        view: PlaylistCatalogView.game,
        origin: PlaylistCatalogOrigin.game,
        sourcePath: null,
        radios: [radio],
        modes: {'XS': StationMode.builtin},
        freeRoamTracks: {'XS': tracks},
        eventTracks: {'XS': tracks},
      );

      final projectDir = p.join(tempRoot.path, 'project');
      _writeIntegrityFixture(projectDir, gameBytes: 'original');
      SharedPreferences.setMockInitialValues({_projectDirKey: projectDir});
      final prefs = await SharedPreferences.getInstance();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(prefs),
            playlistCatalogForViewProvider(
              PlaylistCatalogView.package,
            ).overrideWithValue(packageCatalog),
            playlistCatalogForViewProvider(
              PlaylistCatalogView.game,
            ).overrideWithValue(gameCatalog),
            realPoolTracksProvider.overrideWithValue(const []),
            effectivePlaylistPlanProvider.overrideWithValue(
              const PlaylistPlan.empty(),
            ),
          ],
          child: MaterialApp(
            theme: buildAppTheme(
              brightness: Brightness.light,
              accent: AppAccent.lime,
            ),
            home: const Scaffold(body: PlaylistScreen()),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(tester.takeException(), isNull);
      expect(find.text('当前准备包'), findsOneWidget);
      expect(find.text('准备包'), findsOneWidget);
      expect(find.text('复制游戏内排布'), findsOneWidget);
      expect(find.text('分场景编辑'), findsOneWidget);
      expect(find.text('FreeRoam · 漫游'), findsNothing);
      expect(find.text('Event · 比赛'), findsNothing);
      expect(find.text('搜索曲目 / 艺术家'), findsOneWidget);
      expect(find.text('custom · 自建'), findsOneWidget);
      expect(find.text('builtin · 锁定'), findsWidgets);
      expect(find.text('统一写入漫游和比赛'), findsNothing);

      await tester.tap(find.text('分场景编辑'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('分开编辑漫游和比赛？'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.text('分开编辑漫游和比赛？'), findsNothing);

      await tester.tap(find.text('游戏内'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(tester.takeException(), isNull);
      expect(find.text('当前游戏内'), findsOneWidget);
      expect(find.text('游戏内'), findsOneWidget);
      expect(find.text('复制游戏内排布'), findsNothing);
      expect(find.text('分场景编辑'), findsOneWidget);
      expect(find.text('FreeRoam · 漫游'), findsNothing);
      expect(find.text('Event · 比赛'), findsNothing);
      expect(find.text('搜索曲目 / 艺术家'), findsOneWidget);
      expect(find.text('custom · 自建'), findsOneWidget);
      expect(find.text('builtin · 锁定'), findsWidgets);
      expect(find.text('统一写入漫游和比赛'), findsNothing);
    },
  );

  testWidgets('playlist draft turns a builtin radio into a custom column', (
    tester,
  ) async {
    final tempRoot = Directory.systemTemp.createTempSync(
      'fh_radio_studio_playlist_draft_widget_',
    );
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
    });

    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 900);

    const radio = RadioStation(
      code: 'XS',
      name: 'Horizon XS',
      hue: 'violet',
      genre: 'Rock',
      slot: 3,
    );
    const track = PoolTrack(
      id: 'real:test-user-song',
      title: 'User Song',
      artist: 'Local Artist',
      source: r'C:\music\user-song.wav',
      durationSec: 121,
      bpm: 0,
      key: '待分析',
      configured: true,
      confirmed: 4,
      added: '刚刚',
    );
    final plan = const PlaylistPlan.empty().assign(
      source: track.source,
      radioCode: 'XS',
      playlistType: 'FreeRoam',
      slot: 1,
    );
    final catalog = PlaylistCatalog(
      origin: PlaylistCatalogOrigin.game,
      sourcePath: null,
      radios: const [radio],
      modes: const {'XS': StationMode.builtin},
      freeRoamTracks: const {
        'XS': [
          TrackRef(
            id: 'xs-original',
            title: 'Original XS',
            artist: 'Forza',
            durationSec: 200,
          ),
        ],
      },
      eventTracks: const {
        'XS': [
          TrackRef(
            id: 'xs-original-event',
            title: 'Original XS Event',
            artist: 'Forza',
            durationSec: 200,
          ),
        ],
      },
    );

    final projectDir = p.join(tempRoot.path, 'project');
    _writeIntegrityFixture(projectDir, gameBytes: 'original');
    SharedPreferences.setMockInitialValues({_projectDirKey: projectDir});
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          playlistCatalogProvider.overrideWithValue(catalog),
          realPoolTracksProvider.overrideWithValue(const [track]),
          effectivePlaylistPlanProvider.overrideWithValue(plan),
        ],
        child: MaterialApp(
          theme: buildAppTheme(
            brightness: Brightness.light,
            accent: AppAccent.lime,
          ),
          home: const Scaffold(body: PlaylistScreen()),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(tester.takeException(), isNull);
    expect(find.text('User Song'), findsNWidgets(2));
    expect(find.text('Original XS'), findsNothing);
    expect(find.text('XS · 1'), findsOneWidget);
    expect(find.text('custom'), findsWidgets);
    expect(find.byTooltip('恢复当前列表为 builtin'), findsOneWidget);
  });

  testWidgets('playlist pool labels assignments from the current list', (
    tester,
  ) async {
    final tempRoot = Directory.systemTemp.createTempSync(
      'fh_radio_studio_playlist_pool_current_list_widget_',
    );
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
    });

    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 900);

    const radio = RadioStation(
      code: 'XS',
      name: 'Horizon XS',
      hue: 'violet',
      genre: 'Rock',
      slot: 3,
    );
    const track = PoolTrack(
      id: 'real:test-user-song',
      title: 'User Song',
      artist: 'Local Artist',
      source: r'C:\music\user-song.wav',
      durationSec: 121,
      bpm: 0,
      key: '待分析',
      configured: true,
      confirmed: 4,
      added: '刚刚',
    );
    const catalog = PlaylistCatalog(
      origin: PlaylistCatalogOrigin.game,
      sourcePath: null,
      radios: [radio],
      modes: {'XS': StationMode.custom},
      freeRoamTracks: {
        'XS': [
          TrackRef(
            id: 'xs-current',
            title: 'User Song',
            artist: 'Local Artist',
            durationSec: 121,
            modded: true,
          ),
        ],
      },
      eventTracks: {
        'XS': [
          TrackRef(
            id: 'xs-current-event',
            title: 'User Song',
            artist: 'Local Artist',
            durationSec: 121,
            modded: true,
          ),
        ],
      },
    );

    final projectDir = p.join(tempRoot.path, 'project');
    _writeIntegrityFixture(projectDir, gameBytes: 'original');
    SharedPreferences.setMockInitialValues({_projectDirKey: projectDir});
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          playlistCatalogProvider.overrideWithValue(catalog),
          realPoolTracksProvider.overrideWithValue(const [track]),
          effectivePlaylistPlanProvider.overrideWithValue(
            const PlaylistPlan.empty(),
          ),
        ],
        child: MaterialApp(
          theme: buildAppTheme(
            brightness: Brightness.light,
            accent: AppAccent.lime,
          ),
          home: const Scaffold(body: PlaylistScreen()),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(tester.takeException(), isNull);
    expect(find.text('User Song'), findsWidgets);
    expect(find.text('XS · 1'), findsOneWidget);
    expect(
      find.byWidgetPredicate((widget) => widget is Draggable).evaluate().length,
      greaterThanOrEqualTo(2),
    );
  });

  testWidgets(
    'playlist builtin restore uses baseline list count as header total',
    (tester) async {
      final tempRoot = Directory.systemTemp.createTempSync(
        'fh_radio_studio_playlist_builtin_count_widget_',
      );
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
      });

      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 900);

      const radio = RadioStation(
        code: 'R5',
        name: 'Hospital Records',
        hue: 'cyan',
        genre: 'R5',
        slot: 25,
      );
      final packageTracks = [
        for (var index = 0; index < 25; index += 1)
          TrackRef(
            id: 'r5-custom-$index',
            title: 'Custom $index',
            artist: 'User',
            durationSec: 180,
            modded: true,
          ),
      ];
      final baselineTracks = [
        for (var index = 0; index < 24; index += 1)
          TrackRef(
            id: 'r5-original-$index',
            title: 'Original $index',
            artist: 'Forza',
            durationSec: 180,
          ),
      ];
      final packageCatalog = PlaylistCatalog(
        origin: PlaylistCatalogOrigin.package,
        sourcePath: null,
        radios: const [radio],
        modes: const {'R5': StationMode.custom},
        freeRoamTracks: {'R5': packageTracks},
        eventTracks: {'R5': packageTracks},
      );
      final baselineCatalog = PlaylistCatalog(
        view: PlaylistCatalogView.game,
        origin: PlaylistCatalogOrigin.game,
        sourcePath: null,
        radios: const [radio],
        modes: const {'R5': StationMode.builtin},
        freeRoamTracks: {'R5': baselineTracks},
        eventTracks: {'R5': baselineTracks},
      );
      const plan = PlaylistPlan(
        assignments: {},
        builtinTargets: {'R5|FreeRoam', 'R5|Event'},
      );

      final projectDir = p.join(tempRoot.path, 'project');
      _writeIntegrityFixture(projectDir, gameBytes: 'original');
      SharedPreferences.setMockInitialValues({_projectDirKey: projectDir});
      final prefs = await SharedPreferences.getInstance();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(prefs),
            playlistCatalogProvider.overrideWithValue(packageCatalog),
            baselinePlaylistCatalogProvider.overrideWithValue(baselineCatalog),
            realPoolTracksProvider.overrideWithValue(const []),
            effectivePlaylistPlanProvider.overrideWithValue(plan),
          ],
          child: MaterialApp(
            theme: buildAppTheme(
              brightness: Brightness.light,
              accent: AppAccent.lime,
            ),
            home: const Scaffold(body: PlaylistScreen()),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(tester.takeException(), isNull);
      expect(find.text('Original 0'), findsOneWidget);
      expect(find.text('Custom 0'), findsNothing);
      expect(find.text('24 / 24'), findsOneWidget);
      expect(find.text('24 / 25'), findsNothing);
    },
  );

  testWidgets(
    'playlist custom column uses baseline playlist count as hard cap',
    (tester) async {
      final tempRoot = Directory.systemTemp.createTempSync(
        'fh_radio_studio_playlist_custom_cap_widget_',
      );
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
      });

      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 900);

      const radio = RadioStation(
        code: 'R5',
        name: 'Hospital Records',
        hue: 'cyan',
        genre: 'R5',
        slot: 25,
      );
      final customTracks = [
        for (var index = 0; index < 5; index += 1)
          TrackRef(
            id: 'r5-custom-$index',
            title: 'Custom $index',
            artist: 'User',
            durationSec: 180,
            modded: true,
          ),
      ];
      final baselineTracks = [
        for (var index = 0; index < 24; index += 1)
          TrackRef(
            id: 'r5-original-$index',
            title: 'Original $index',
            artist: 'Forza',
            durationSec: 180,
          ),
      ];
      final packageCatalog = PlaylistCatalog(
        origin: PlaylistCatalogOrigin.package,
        sourcePath: null,
        radios: const [radio],
        modes: const {'R5': StationMode.custom},
        freeRoamTracks: {'R5': customTracks},
        eventTracks: {'R5': customTracks},
      );
      final baselineCatalog = PlaylistCatalog(
        view: PlaylistCatalogView.game,
        origin: PlaylistCatalogOrigin.game,
        sourcePath: null,
        radios: const [radio],
        modes: const {'R5': StationMode.builtin},
        freeRoamTracks: {'R5': baselineTracks},
        eventTracks: {'R5': baselineTracks},
      );

      final projectDir = p.join(tempRoot.path, 'project');
      _writeIntegrityFixture(projectDir, gameBytes: 'original');
      SharedPreferences.setMockInitialValues({_projectDirKey: projectDir});
      final prefs = await SharedPreferences.getInstance();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(prefs),
            playlistCatalogProvider.overrideWithValue(packageCatalog),
            baselinePlaylistCatalogProvider.overrideWithValue(baselineCatalog),
            realPoolTracksProvider.overrideWithValue(const []),
            effectivePlaylistPlanProvider.overrideWithValue(
              const PlaylistPlan.empty(),
            ),
          ],
          child: MaterialApp(
            theme: buildAppTheme(
              brightness: Brightness.light,
              accent: AppAccent.lime,
            ),
            home: const Scaffold(body: PlaylistScreen()),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(tester.takeException(), isNull);
      expect(find.text('Custom 0'), findsOneWidget);
      expect(find.text('5 / 24'), findsOneWidget);
      expect(find.text('5 / 25'), findsNothing);
    },
  );

  testWidgets('playlist editing is locked when baseline is incomplete', (
    tester,
  ) async {
    final tempRoot = Directory.systemTemp.createTempSync(
      'fh_radio_studio_playlist_lock_widget_',
    );
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
    });

    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 900);

    const radio = RadioStation(
      code: 'XS',
      name: 'Horizon XS',
      hue: 'violet',
      genre: 'Rock',
      slot: 3,
    );
    const track = PoolTrack(
      id: 'real:test-user-song',
      title: 'User Song',
      artist: 'Local Artist',
      source: r'C:\music\user-song.wav',
      durationSec: 121,
      bpm: 0,
      key: '待分析',
      configured: true,
      confirmed: 4,
      added: '刚刚',
    );
    final plan = const PlaylistPlan.empty().assign(
      source: track.source,
      radioCode: 'XS',
      playlistType: 'FreeRoam',
      slot: 1,
    );
    const catalog = PlaylistCatalog(
      origin: PlaylistCatalogOrigin.game,
      sourcePath: null,
      radios: [radio],
      modes: {'XS': StationMode.builtin},
      freeRoamTracks: {
        'XS': [
          TrackRef(
            id: 'xs-original',
            title: 'Original XS',
            artist: 'Forza',
            durationSec: 200,
          ),
        ],
      },
      eventTracks: {
        'XS': [
          TrackRef(
            id: 'xs-original-event',
            title: 'Original XS Event',
            artist: 'Forza',
            durationSec: 200,
          ),
        ],
      },
    );

    final projectDir = p.join(tempRoot.path, 'project');
    _writeIntegrityFixture(projectDir, gameBytes: 'original');
    SharedPreferences.setMockInitialValues({_projectDirKey: projectDir});
    final prefs = await SharedPreferences.getInstance();
    final controller = _StaticStudioController(prefs);
    controller.setStateForTest(
      controller.state.copyWith(baselinePlanSummary: _lockedBaselinePlan()),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          studioProvider.overrideWith((ref) => controller),
          playlistCatalogProvider.overrideWithValue(catalog),
          realPoolTracksProvider.overrideWithValue(const [track]),
          effectivePlaylistPlanProvider.overrideWithValue(plan),
        ],
        child: MaterialApp(
          theme: buildAppTheme(
            brightness: Brightness.light,
            accent: AppAccent.lime,
          ),
          home: const Scaffold(body: PlaylistScreen()),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(tester.takeException(), isNull);
    expect(find.textContaining('编辑已锁定', findRichText: true), findsOneWidget);
    expect(find.text('User Song'), findsNWidgets(2));
    expect(find.byTooltip('恢复当前列表为 builtin'), findsNothing);
    expect(
      find.byWidgetPredicate((widget) => widget is Draggable),
      findsNothing,
    );
  });

  testWidgets('playlist screen shows read failure instead of mock fallback', (
    tester,
  ) async {
    final tempRoot = Directory.systemTemp.createTempSync(
      'fh_radio_studio_playlist_failed_widget_',
    );
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
    });

    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(2048, 1100);

    final projectDir = p.join(tempRoot.path, 'project');
    final gameDir = p.join(tempRoot.path, 'game-without-radioinfo');
    FhRadioStudioProject.ensure(projectDir);
    FhRadioStudioProject.writeSettings(projectDir, gameDir: gameDir);
    SharedPreferences.setMockInitialValues({_projectDirKey: projectDir});
    final prefs = await SharedPreferences.getInstance();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
        child: MaterialApp(
          theme: buildAppTheme(
            brightness: Brightness.light,
            accent: AppAccent.lime,
          ),
          home: const Scaffold(body: PlaylistScreen()),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(tester.takeException(), isNull);
    expect(find.text('播放列表读取失败'), findsOneWidget);
    expect(find.text('Horizon Pulse'), findsNothing);
  });

  testWidgets('app shell locks content pages when core toolchain is missing', (
    tester,
  ) async {
    final tempRoot = Directory.systemTemp.createTempSync(
      'fh_radio_studio_toolchain_nav_lock_',
    );
    final semantics = tester.ensureSemantics();
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
    });

    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 760);

    final projectDir = p.join(tempRoot.path, 'project');
    FhRadioStudioProject.ensure(projectDir);
    SharedPreferences.setMockInitialValues({_projectDirKey: projectDir});
    final prefs = await SharedPreferences.getInstance();
    final controller = _StaticStudioController(prefs);
    controller.setStateForTest(
      controller.state.copyWith(
        toolchainStatus: const ToolchainStatusSummary(
          checked: true,
          profile: 'local-base',
          status: 'missing',
          label: '需要处理',
          summary: '核心工具链有缺失项，请先修复基础处理组件。',
          sections: [
            ToolchainStatusSection(
              id: 'audio_tools',
              title: '核心音频工具',
              status: 'missing',
              summary: '缺少 ffmpeg',
              items: [],
              warnings: [],
            ),
            ToolchainStatusSection(
              id: 'ai',
              title: 'AI 分析',
              status: 'missing',
              summary: '深度 AI Providers 尚未就绪',
              items: [],
              warnings: [],
            ),
          ],
          fixes: [],
        ),
      ),
    );

    final router = GoRouter(
      initialLocation: '/pool',
      routes: [
        ShellRoute(
          builder: (context, state, child) => AppShell(child: child),
          routes: [
            GoRoute(
              path: '/dashboard',
              builder: (context, state) =>
                  const Center(child: Text('dashboard reached')),
            ),
            GoRoute(
              path: '/pool',
              builder: (context, state) =>
                  const Center(child: Text('pool reached')),
            ),
            GoRoute(
              path: '/playlist',
              builder: (context, state) =>
                  const Center(child: Text('playlist reached')),
            ),
            GoRoute(
              path: '/siren',
              builder: (context, state) =>
                  const Center(child: Text('siren reached')),
            ),
          ],
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          studioProvider.overrideWith((ref) => controller),
        ],
        child: MaterialApp.router(
          theme: buildAppTheme(
            brightness: Brightness.light,
            accent: AppAccent.lime,
          ),
          routerConfig: router,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('核心工具链缺失，内容页面已锁定。'), findsOneWidget);
    expect(find.text('dashboard reached'), findsNothing);
    expect(find.text('pool reached'), findsNothing);

    await tester.tap(find.text('自建歌曲'));
    await tester.pump();
    expect(find.text('核心工具链缺失，内容页面已锁定。'), findsOneWidget);
    expect(find.text('pool reached'), findsNothing);

    router.go('/siren');
    await tester.pump();
    await tester.pump();
    expect(find.text('siren reached'), findsOneWidget);

    router.go('/dashboard');
    await tester.pump();
    await tester.pump();
    expect(find.text('dashboard reached'), findsOneWidget);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('app shell blocks all input while package build is busy', (
    tester,
  ) async {
    final tempRoot = Directory.systemTemp.createTempSync(
      'fh_radio_studio_package_busy_overlay_',
    );
    final semantics = tester.ensureSemantics();
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
    });

    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1400, 900);

    final projectDir = p.join(tempRoot.path, 'project');
    FhRadioStudioProject.ensure(projectDir);
    SharedPreferences.setMockInitialValues({_projectDirKey: projectDir});
    final prefs = await SharedPreferences.getInstance();
    final controller = _StaticStudioController(prefs);
    controller.setStateForTest(
      controller.state.copyWith(
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
      ),
    );

    var taps = 0;
    final router = GoRouter(
      initialLocation: '/dashboard',
      routes: [
        ShellRoute(
          builder: (context, state, child) => AppShell(child: child),
          routes: [
            GoRoute(
              path: '/dashboard',
              builder: (context, state) => Center(
                child: ElevatedButton(
                  key: const ValueKey('blocked-package-action'),
                  onPressed: () => taps += 1,
                  child: const Text('behind overlay'),
                ),
              ),
            ),
          ],
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          studioProvider.overrideWith((ref) => controller),
        ],
        child: MaterialApp.router(
          theme: buildAppTheme(
            brightness: Brightness.light,
            accent: AppAccent.lime,
          ),
          routerConfig: router,
        ),
      ),
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey('package-build-blocking-overlay')),
      findsOneWidget,
    );
    expect(find.text('正在准备电台包'), findsOneWidget);
    final progress = find.descendant(
      of: find.byKey(const ValueKey('package-build-blocking-overlay')),
      matching: find.byKey(const ValueKey('pending-overlay-progress-track')),
    );
    final detail = find.text('正在转码、重建 bank 并校验包文件。这一步通常需要几十秒，完成后会弹出结果提示。');
    expect(progress, findsOneWidget);
    expect(detail, findsOneWidget);
    expect(find.text('当前'), findsOneWidget);
    expect(find.text('Horizon XS 重建 FMOD bank'), findsOneWidget);
    expect(
      find.text('运行 fsbankcl，修正 sample 名称，再拼回 .assets.bank。'),
      findsOneWidget,
    );
    expect(find.text('多进程 ×4'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('package-build-parallel-summary')),
      findsOneWidget,
    );
    expect(find.text('9%'), findsOneWidget);
    expect(
      tester.getSize(progress).width,
      greaterThanOrEqualTo(tester.getSize(detail).width),
    );

    final gesture = await tester.createGesture();
    await gesture.down(
      tester.getCenter(find.byKey(const ValueKey('blocked-package-action'))),
    );
    await gesture.up();
    await tester.pump();

    expect(taps, 0);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('package build overlay lists every radio running in parallel', (
    tester,
  ) async {
    final tempRoot = Directory.systemTemp.createTempSync(
      'fh_radio_studio_package_parallel_overlay_',
    );
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
    });
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1400, 900);

    final projectDir = p.join(tempRoot.path, 'project');
    FhRadioStudioProject.ensure(projectDir);
    SharedPreferences.setMockInitialValues({_projectDirKey: projectDir});
    final prefs = await SharedPreferences.getInstance();
    final controller = _StaticStudioController(prefs);
    controller.setStateForTest(
      controller.state.copyWith(
        busy: true,
        busyLabel: '构建电台包',
        packageBuildProgressSteps: const [
          PackageBuildProgressStep(
            id: 'inspect_inputs',
            label: '读取构建输入',
            detail: '解析构建输入。',
            status: 'done',
            weight: 1,
          ),
          PackageBuildProgressStep(
            id: 'radio.4.rebuild_bank',
            label: 'Horizon XS 重建 FMOD bank',
            detail: '运行 fsbankcl。',
            status: 'running',
            weight: 8,
            processCount: 3,
          ),
          PackageBuildProgressStep(
            id: 'radio.5.stage_bank',
            label: 'Horizon Wilds 铺满 bank 槽位',
            detail: '生成 fsbank staging WAV。',
            status: 'running',
            weight: 2,
            processCount: 3,
          ),
          PackageBuildProgressStep(
            id: 'radio.6.measure_loudness',
            label: 'Horizon Pulse 响度匹配与时间点',
            detail: '分析响度并写入 marker。',
            status: 'running',
            weight: 4,
            processCount: 3,
          ),
        ],
      ),
    );

    final router = GoRouter(
      initialLocation: '/dashboard',
      routes: [
        ShellRoute(
          builder: (context, state, child) => AppShell(child: child),
          routes: [
            GoRoute(
              path: '/dashboard',
              builder: (context, state) =>
                  const Center(child: Text('behind overlay')),
            ),
          ],
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          studioProvider.overrideWith((ref) => controller),
        ],
        child: MaterialApp.router(
          theme: buildAppTheme(
            brightness: Brightness.light,
            accent: AppAccent.lime,
          ),
          routerConfig: router,
        ),
      ),
    );
    await tester.pump();

    expect(find.text('并行处理 3 个电台'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('package-build-concurrent-steps')),
      findsOneWidget,
    );
    expect(find.text('Horizon XS 重建 FMOD bank'), findsOneWidget);
    expect(find.text('Horizon Wilds 铺满 bank 槽位'), findsOneWidget);
    expect(find.text('Horizon Pulse 响度匹配与时间点'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('package build success dialog renders completion summary', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 640);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(
          brightness: Brightness.light,
          accent: AppAccent.lime,
        ),
        home: const Scaffold(
          body: Center(
            child: PackageBuildSuccessDialog(
              title: '准备包已完成',
              detail: '3 首输入 · 25 个槽位 · 替换播放列表 · 可写入音频包',
              trackPreview: 'Track A, Track B, Track C',
              packageDir: r'C:\FH Radio Studio\packages\current',
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('准备包已完成'), findsOneWidget);
    expect(find.text('准备内容'), findsOneWidget);
    expect(find.text('Track A, Track B, Track C'), findsOneWidget);
    expect(find.text('包目录'), findsOneWidget);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('package build notice explains skipped test package plainly', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 640);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(
          brightness: Brightness.light,
          accent: AppAccent.lime,
        ),
        home: const Scaffold(
          body: Center(
            child: PackageBuildNoticeDialog(
              title: '没有生成测试准备包',
              message: '当前没有发现需要单独测试的新游戏文件；这个入口只在游戏文件不同于原始备份或准备包时使用。',
              languageChanged: false,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('没有生成测试准备包'), findsOneWidget);
    expect(find.text('没有需要单独测试的新文件'), findsOneWidget);
    expect(find.text('普通电台包从播放列表生成'), findsOneWidget);
    expect(find.text('构建命令返回错误'), findsNothing);
    expect(find.text('只改语言也可以准备'), findsNothing);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets(
    'missing playlist sources dialog offers cleanup or keep actions',
    (tester) async {
      final semantics = tester.ensureSemantics();
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(900, 640);

      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(
            brightness: Brightness.light,
            accent: AppAccent.lime,
          ),
          home: const Scaffold(
            body: Center(
              child: MissingPlaylistSourcesDialog(
                sources: [
                  r'C:\FH Radio Studio\project\sources\deleted-a.wav',
                  r'C:\FH Radio Studio\project\sources\deleted-b.flac',
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('播放列表里有 2 首已删除的歌曲'), findsOneWidget);
      expect(find.text('deleted-a.wav'), findsOneWidget);
      expect(find.text('删除所有失效歌曲'), findsOneWidget);
      expect(find.text('保持不动'), findsOneWidget);
      expect(tester.takeException(), isNull);
      semantics.dispose();
    },
  );
}

class _StaticStudioController extends StudioController {
  _StaticStudioController(super.prefs) {
    state = state.copyWith(log: const ['测试状态已加载']);
  }

  int refreshCount = 0;
  int aiEnvironmentSyncCount = 0;
  int checkToolchainProfileCount = 0;
  AiEnvironmentSyncOptions? lastAiEnvironmentSyncOptions;
  bool failAiEnvironmentSync = false;

  void setStateForTest(StudioState value) {
    state = value;
  }

  @override
  Future<void> refreshStatus({bool verifyFiles = false}) async {
    refreshCount++;
  }

  @override
  Future<ToolchainStatusSummary?> checkToolchainStatusForProfile(
    String profile,
  ) async {
    checkToolchainProfileCount++;
    return state.toolchainStatus;
  }

  @override
  Future<bool> syncToolchainEnvironment({
    AiEnvironmentSyncOptions? options,
  }) async {
    aiEnvironmentSyncCount++;
    lastAiEnvironmentSyncOptions = options;
    if (failAiEnvironmentSync) {
      state = state.copyWith(
        toolchainStatus: const ToolchainStatusSummary(
          checked: true,
          profile: 'local-heavy',
          status: 'ready',
          label: 'OK',
          summary: '核心工具链可用；AI 和硬件加速会按实际能力降级。',
          sections: [
            ToolchainStatusSection(
              id: 'python',
              title: 'Python 环境',
              status: 'ready',
              summary: 'Python 依赖已覆盖当前 profile',
              items: [],
              warnings: [],
            ),
            ToolchainStatusSection(
              id: 'ai',
              title: 'AI 分析',
              status: 'missing',
              summary: '深度 AI Providers 尚未就绪',
              items: [
                ToolchainStatusItem(
                  label: 'beat_this',
                  value: 'missing',
                  detail: '',
                  status: 'missing',
                ),
                ToolchainStatusItem(
                  label: 'songformer',
                  value: 'missing',
                  detail: '',
                  status: 'missing',
                ),
                ToolchainStatusItem(
                  label: 'mert',
                  value: 'missing',
                  detail: '',
                  status: 'missing',
                ),
                ToolchainStatusItem(
                  label: 'demucs',
                  value: 'missing',
                  detail: '',
                  status: 'missing',
                ),
              ],
              warnings: [],
            ),
          ],
          fixes: [],
        ),
        log: [
          ...state.log,
          '执行：强制重装 超大杯 Python / AI 环境',
          'ERR error: Failed to fetch: https://mirrors.example/simple/demucs-4.0.1.tar.gz',
          'ERR Caused by: HTTP status client error (403 Forbidden)',
          '退出码：2',
        ],
      );
      return false;
    }
    return true;
  }
}

class _StaticSirenImportQueueController extends SirenImportQueueController {
  _StaticSirenImportQueueController(super.ref) {
    state = SirenImportQueueState(
      queuedCids: const {'232251'},
      importingCids: const {'232251'},
      importing: true,
    );
  }
}

BaselinePlanSummary _lockedBaselinePlan() {
  return const BaselinePlanSummary(
    fileCount: 1,
    totalSize: 1024,
    gameVersionId: 'steam-b23271700',
    byScope: {'radio_bank': 1},
    byStatus: {'backup_missing': 1},
    files: [
      BaselinePlanFile(
        scope: 'radio_bank',
        installRelativePath: 'media/audio/FMODBanks/R4_Tracks_CU1.assets.bank',
        sourceGamePath: '',
        size: 1024,
        md5: '00000000000000000000000000000000',
        exists: true,
        baselineStatus: 'backup_missing',
        backupPath: null,
        backupMd5: null,
        packageMd5: null,
        coverageStatus: 'unchecked',
      ),
    ],
  );
}

void _writeIntegrityFixture(
  String projectDir, {
  required String gameBytes,
  String packageBytes = 'modded',
  String? pendingBaselineBytes,
  String? pendingPackageBytes,
}) {
  FhRadioStudioProject.ensure(projectDir);
  final gameDir = p.join(projectDir, 'game');
  FhRadioStudioProject.writeSettings(projectDir, gameDir: gameDir);

  void writePackage(String root, String bytes) {
    final packageAudio = p.join(root, 'package', 'media', 'audio');
    final packageXml = File(p.join(packageAudio, 'RadioInfo_CN.xml'))
      ..createSync(recursive: true)
      ..writeAsStringSync(bytes, encoding: utf8);
    final packageMd5 = _md5(packageXml);
    File(p.join(root, 'package', 'fh_radio_studio_package_manifest.json'))
      ..createSync(recursive: true)
      ..writeAsStringSync('''
{
  "schema_version": 2,
  "radio": 4,
  "station": "Horizon XS",
  "target_bank_name": "R4_Tracks_CU1.assets.bank",
  "radios": [
    {
      "radio": 4,
      "radio_code": "XS",
      "station": "Horizon XS",
      "target_bank_name": "R4_Tracks_CU1.assets.bank",
      "music": [],
      "assignments": []
    }
  ],
  "package_files": [
    {
      "relative_path": "RadioInfo_CN.xml",
      "path": "${_jsonPath(packageXml.path)}",
      "md5": "$packageMd5"
    }
  ]
}
''', encoding: utf8);
  }

  writePackage(
    FhRadioStudioProject.currentPackageDir(projectDir),
    packageBytes,
  );
  if (pendingPackageBytes != null) {
    writePackage(
      FhRadioStudioProject.pendingPackageDir(projectDir),
      pendingPackageBytes,
    );
  }

  final gameXml = File(p.join(gameDir, 'media', 'audio', 'RadioInfo_CN.xml'))
    ..createSync(recursive: true)
    ..writeAsStringSync(gameBytes, encoding: utf8);

  void writeBaseline({
    required String state,
    required String versionId,
    required String bytes,
  }) {
    final dir = p.join(
      projectDir,
      'backups',
      'baseline-${FhRadioStudioProject.safeName(state)}',
    );
    final baselineXml = File(p.join(dir, 'media', 'audio', 'RadioInfo_CN.xml'))
      ..createSync(recursive: true)
      ..writeAsStringSync(bytes, encoding: utf8);
    File(p.join(dir, 'baseline_manifest.json')).writeAsStringSync('''
{
  "schema_version": 1,
  "kind": "game_baseline",
  "state": "$state",
  "backup_name": "fh6-$versionId-baseline-$state",
  "created_at": "2026-05-20T00:00:00.000Z",
  "game_version_id": "$versionId",
  "game_version": {
    "source": "steam",
    "version_id": "$versionId",
    "app_id": "2483190",
    "build_id": "${versionId.replaceFirst('steam-b', '')}"
  },
  "game_dir": "${_jsonPath(gameDir)}",
  "files": [
    {
      "relative_path": "RadioInfo_CN.xml",
      "source_game_path": "${_jsonPath(gameXml.path)}",
      "backup_path": "${_jsonPath(baselineXml.path)}",
      "size": ${baselineXml.lengthSync()},
      "md5": "${_md5(baselineXml)}"
    }
  ]
}
''', encoding: utf8);
  }

  writeBaseline(
    state: 'current',
    versionId: 'steam-b23271700',
    bytes: 'original',
  );
  if (pendingBaselineBytes != null) {
    writeBaseline(
      state: 'pending-verify',
      versionId: 'steam-b23271800',
      bytes: pendingBaselineBytes,
    );
  }
}

String _md5(File file) {
  return crypto.md5.convert(file.readAsBytesSync()).toString();
}

String _jsonPath(String path) => path.replaceAll(r'\', r'\\');
