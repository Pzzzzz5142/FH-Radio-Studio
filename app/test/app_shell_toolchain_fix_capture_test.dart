import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:path/path.dart' as p;
import 'package:fh_radio_studio/shell/app_shell.dart';
import 'package:fh_radio_studio/state/app_state.dart';
import 'package:fh_radio_studio/state/studio_state.dart';
import 'package:fh_radio_studio/theme/accents.dart';
import 'package:fh_radio_studio/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets(
    'capture toolchain install overlay with install-only log',
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

      await _captureToolchainFixOverlay(
        tester,
        prefs: prefs,
        logicalSize: const Size(1365, 900),
        outputPath: p.join(outDir.path, 'toolchain_fix_overlay_regular.png'),
      );
      await _captureToolchainFixOverlay(
        tester,
        prefs: prefs,
        logicalSize: const Size(1365, 1200),
        outputPath: p.join(outDir.path, 'toolchain_fix_overlay_full.png'),
      );
    },
    skip: Platform.environment['CAPTURE_TOOLCHAIN_FIX_OVERLAY'] != '1',
  );

  testWidgets(
    'capture AI environment sync overlay',
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

      await _captureAiEnvironmentSyncOverlay(
        tester,
        prefs: prefs,
        logicalSize: const Size(1365, 900),
        outputPath: p.join(
          outDir.path,
          'ai_environment_sync_overlay_regular.png',
        ),
      );
      await _captureAiEnvironmentSyncOverlay(
        tester,
        prefs: prefs,
        logicalSize: const Size(1365, 1200),
        outputPath: p.join(outDir.path, 'ai_environment_sync_overlay_full.png'),
      );
    },
    skip: Platform.environment['CAPTURE_AI_ENV_SYNC_OVERLAY'] != '1',
  );
}

Future<void> _captureToolchainFixOverlay(
  WidgetTester tester, {
  required SharedPreferences prefs,
  required Size logicalSize,
  required String outputPath,
}) async {
  final repaintKey = GlobalKey();
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = logicalSize;

  final controller = _CaptureStudioController(prefs);
  final router = GoRouter(
    initialLocation: '/dashboard',
    routes: [
      ShellRoute(
        builder: (context, state, child) => AppShell(child: child),
        routes: [
          GoRoute(
            path: '/dashboard',
            builder: (context, state) => const Center(
              child: Text('Dashboard behind toolchain fix overlay'),
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
    find.byKey(const ValueKey('toolchain-fix-blocking-overlay')),
    findsOneWidget,
  );
  expect(find.byKey(const ValueKey('tool-install-log-panel')), findsOneWidget);
  expect(find.textContaining('ffmpeg-release-essentials.zip'), findsOneWidget);
  expect(find.textContaining('全局高级诊断'), findsNothing);
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

class _CaptureStudioController extends StudioController {
  _CaptureStudioController(super.prefs) {
    state = state.copyWith(
      busy: true,
      busyLabel: '安装本地处理组件',
      log: const ['全局高级诊断日志不应该出现在工具安装浮层'],
      toolInstallLog: [
        '== 安装本地处理组件 ==',
        '执行：安装或修复本地处理组件',
        'Installing audio tools into: C:\\FH Radio Studio\\toolchain\\tools\\audio',
        'download https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip',
        for (var i = 10; i <= 100; i += 10)
          'progress ffmpeg archive: $i% (${i * 4}.0 MiB / 40.0 MiB)',
        'saved C:\\Users\\User\\AppData\\Local\\Temp\\ffmpeg.zip',
        '[extract] locating ffmpeg.exe in archive',
        'writing C:\\FH Radio Studio\\toolchain\\tools\\audio\\ffmpeg\\ffmpeg.exe',
        'download https://github.com/vgmstream/vgmstream/releases/latest/download/vgmstream-win64.zip',
        for (var i = 10; i <= 100; i += 10)
          'progress vgmstream archive: $i% (${i * 2}.0 MiB / 20.0 MiB)',
        '[extract] 312 entries -> C:\\FH Radio Studio\\toolchain\\tools\\audio\\vgmstream',
        for (final file in [
          'fsbankcl.exe',
          'fmod.dll',
          'libfsbvorbis.dll',
          'libmp3lame.dll',
          'twolame.dll',
          'Qt5Core.dll',
          'libEGL.dll',
          'libGLESv2.dll',
          'msvcp110.dll',
          'msvcr110.dll',
        ])
          'download fmod/$file',
        'ERR warning: proxy retry succeeded',
        'Manifest: C:\\FH Radio Studio\\toolchain\\tools\\audio\\audio_tools_manifest.json',
      ],
    );
  }
}

Future<void> _captureAiEnvironmentSyncOverlay(
  WidgetTester tester, {
  required SharedPreferences prefs,
  required Size logicalSize,
  required String outputPath,
}) async {
  final repaintKey = GlobalKey();
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = logicalSize;

  final controller = _CaptureAiSyncStudioController(prefs);
  final router = GoRouter(
    initialLocation: '/dashboard',
    routes: [
      ShellRoute(
        builder: (context, state, child) => AppShell(child: child),
        routes: [
          GoRoute(
            path: '/dashboard',
            builder: (context, state) =>
                const Center(child: Text('Dashboard behind AI sync overlay')),
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
    find.byKey(const ValueKey('toolchain-fix-blocking-overlay')),
    findsOneWidget,
  );
  expect(find.text('正在修复 AI 环境'), findsOneWidget);
  expect(find.text('模型缓存 Warmup'), findsOneWidget);
  expect(find.text('正在下载并加载 4 个 AI Provider。'), findsOneWidget);
  expect(find.text('58%'), findsOneWidget);
  expect(
    find.byKey(const ValueKey('ai-environment-sync-details')),
    findsOneWidget,
  );
  expect(
    find.byKey(const ValueKey('ai-environment-sync-cancel')),
    findsOneWidget,
  );
  expect(find.text('下载明细'), findsOneWidget);
  expect(find.text('最近下载输出'), findsOneWidget);
  expect(find.text('Downloaded matplotlib'), findsOneWidget);
  expect(find.text('ERR Downloaded matplotlib'), findsNothing);
  expect(find.textContaining('MERT-v1-330M'), findsOneWidget);
  expect(find.byKey(const ValueKey('tool-install-log-panel')), findsNothing);
  expect(find.textContaining('全局高级诊断'), findsNothing);
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

class _CaptureAiSyncStudioController extends StudioController {
  _CaptureAiSyncStudioController(super.prefs) {
    state = state.copyWith(
      busy: true,
      busyLabel: '同步 AI 环境',
      aiEnvironmentProgressLabel: '模型缓存 Warmup',
      aiEnvironmentProgressDetail: '正在下载并加载 4 个 AI Provider。',
      aiEnvironmentProgressPercent: 58,
      aiEnvironmentProgressSteps: const [
        AiEnvironmentProgressStep(
          id: 'plan',
          label: '计划下载任务',
          detail: '超大杯 · PyPI Mirror · Torch Wheel Mirror · HF Mirror',
          status: 'done',
        ),
        AiEnvironmentProgressStep(
          id: 'dependencies',
          label: 'Python / AI 依赖',
          detail: '依赖已就绪，本次跳过 uv sync，只继续模型缓存 Warmup。',
          status: 'skipped',
        ),
        AiEnvironmentProgressStep(
          id: 'models',
          label: '模型缓存',
          detail: '正在下载或复用 beat_this, songformer, mert, demucs Provider 缓存。',
          status: 'running',
        ),
        AiEnvironmentProgressStep(
          id: 'verify',
          label: '完成后复检',
          detail: '等待 Warmup 完成后复检 Provider 和硬件能力。',
          status: 'pending',
        ),
      ],
      aiEnvironmentProgressLog: const [
        'Resolved 243 packages in 1.2s',
        'ERR Downloaded matplotlib',
        'Prepared 18 packages in 34.7s',
        'Downloading models--m-a-p--MERT-v1-330M/snapshots/main',
        'Downloading songformer.ckpt: 42% (188.0 MiB / 447.0 MiB)',
      ],
      log: const ['全局高级诊断日志不应该出现在 AI 同步浮层'],
    );
  }
}
