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
import 'package:fh_radio_studio/shell/nav_item.dart';
import 'package:fh_radio_studio/shell/sidebar.dart';
import 'package:fh_radio_studio/state/app_state.dart';
import 'package:fh_radio_studio/state/studio_state.dart';
import 'package:fh_radio_studio/theme/accents.dart';
import 'package:fh_radio_studio/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('nav data places content before tools', () {
    final contentIndex = kNavItems.indexWhere((item) => item.group == '内容');
    final toolsIndex = kNavItems.indexWhere((item) => item.group == '工具');

    expect(contentIndex, isNonNegative);
    expect(toolsIndex, isNonNegative);
    expect(contentIndex, lessThan(toolsIndex));
    expect(kNavItems[contentIndex].label, '自建歌曲');
    expect(kNavItems[toolsIndex].label, '塞壬唱片');
    expect(kNavItems.map((item) => item.label), ['概览', '自建歌曲', '播放列表', '塞壬唱片']);
    expect(kNavItems.where((item) => item.kbd != null), isEmpty);
  });

  testWidgets('sidebar app info uses release id and dev build fallback', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();

    await _pumpSidebarWithInfo(
      tester,
      prefs: prefs,
      appInfo: const AppInfo(
        releaseId: '0.1.0-dev.7',
        buildCommitSha256: 'None',
        showBuild: true,
      ),
    );

    expect(find.text('FH Radio Studio 0.1.0-dev.7'), findsOneWidget);
    expect(find.text('build None'), findsOneWidget);
    expect(find.textContaining('FH6 build'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('sidebar hides build line outside dev mode', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();

    await _pumpSidebarWithInfo(
      tester,
      prefs: prefs,
      appInfo: const AppInfo(
        releaseId: '0.1.0-rc.1',
        buildCommitSha256: 'abc123',
        showBuild: false,
      ),
    );

    expect(find.text('FH Radio Studio 0.1.0-rc.1'), findsOneWidget);
    expect(find.text('build abc123'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'capture app shell sidebar navigation',
    (tester) async {
      GoogleFonts.config.allowRuntimeFetching = false;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final outDir = Directory(p.join('build', 'visual_qa'))
        ..createSync(recursive: true);

      await _captureSidebar(
        tester,
        prefs: prefs,
        logicalSize: const Size(1244, 900),
        outputPath: p.join(outDir.path, 'app_shell_sidebar_regular.png'),
      );
      await _captureSidebar(
        tester,
        prefs: prefs,
        logicalSize: const Size(1365, 1200),
        outputPath: p.join(outDir.path, 'app_shell_sidebar_full.png'),
      );
    },
    skip: Platform.environment['CAPTURE_APP_SHELL_SIDEBAR'] != '1',
  );
}

Future<void> _pumpSidebarWithInfo(
  WidgetTester tester, {
  required SharedPreferences prefs,
  required AppInfo appInfo,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        studioProvider.overrideWith((ref) => _SidebarCaptureController(prefs)),
        appInfoProvider.overrideWith((ref) async => appInfo),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildAppTheme(
          brightness: Brightness.light,
          accent: AppAccent.lime,
        ),
        home: const Scaffold(
          body: SizedBox(width: 240, child: Sidebar(activeId: 'dashboard')),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
}

Future<void> _captureSidebar(
  WidgetTester tester, {
  required SharedPreferences prefs,
  required Size logicalSize,
  required String outputPath,
}) async {
  final repaintKey = GlobalKey();
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = logicalSize;

  final router = GoRouter(
    initialLocation: '/dashboard',
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
            path: '/siren',
            builder: (context, state) =>
                const Center(child: Text('siren reached')),
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
        ],
      ),
    ],
  );
  addTearDown(router.dispose);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        studioProvider.overrideWith((ref) => _SidebarCaptureController(prefs)),
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

  expect(find.text('工具'), findsOneWidget);
  expect(find.text('塞壬唱片'), findsWidgets);
  expect(find.text('内容'), findsOneWidget);
  expect(find.text('自建歌曲'), findsOneWidget);
  expect(find.text('播放列表'), findsOneWidget);
  expect(
    tester.getTopLeft(find.text('内容')).dy,
    lessThan(tester.getTopLeft(find.text('工具')).dy),
  );
  expect(find.text('DEPRECATED'), findsNothing);
  expect(find.text('旧恢复记录'), findsNothing);
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

class _SidebarCaptureController extends StudioController {
  _SidebarCaptureController(super.prefs) {
    state = state.copyWith(
      toolchainStatus: const ToolchainStatusSummary(
        checked: true,
        profile: 'local-heavy',
        status: 'ready',
        label: 'OK',
        summary: '工具链检查通过。',
        sections: [],
        fixes: [],
      ),
    );
  }

  @override
  Future<void> startupFullCheckOnce() async {}
}
