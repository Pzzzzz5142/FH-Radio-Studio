import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:fh_radio_studio/shell/app_shell.dart';
import 'package:fh_radio_studio/state/app_state.dart';
import 'package:fh_radio_studio/state/studio_state.dart';
import 'package:fh_radio_studio/theme/accents.dart';
import 'package:fh_radio_studio/theme/app_theme.dart';
import 'package:fh_radio_studio/widgets/rm_chip.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUpAll(() {
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  testWidgets('app shell shows animated overlay while fixing toolchain', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 760);

    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final controller = _StaticStudioController(prefs);
    controller.setStateForTest(
      controller.state.copyWith(
        busy: true,
        busyLabel: '安装本地处理组件',
        log: const ['全局高级诊断日志不应该出现在这里'],
        toolInstallLog: const [
          '== 安装本地处理组件 ==',
          '执行：安装或修复本地处理组件',
          'download https://example.test/ffmpeg.zip',
          'ERR warning: proxy retry',
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
                  key: const ValueKey('behind-toolchain-fix-action'),
                  onPressed: () => taps += 1,
                  child: const Text('behind fixing overlay'),
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
      find.byKey(const ValueKey('toolchain-fix-blocking-overlay')),
      findsOneWidget,
    );
    expect(find.text('正在安装本地处理组件'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(
      find.byKey(const ValueKey('tool-install-log-panel')),
      findsOneWidget,
    );
    expect(
      find.text('download https://example.test/ffmpeg.zip'),
      findsOneWidget,
    );
    expect(find.text('ERR warning: proxy retry'), findsOneWidget);
    expect(find.text('全局高级诊断日志不应该出现在这里'), findsNothing);
    expect(find.byType(Scrollbar), findsOneWidget);

    final gesture = await tester.createGesture();
    await gesture.down(
      tester.getCenter(
        find.byKey(const ValueKey('behind-toolchain-fix-action')),
      ),
    );
    await gesture.up();
    await tester.pump();

    expect(taps, 0);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('tool install log panel is scrollable when output is long', (
    tester,
  ) async {
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 760);

    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final controller = _StaticStudioController(prefs);
    controller.setStateForTest(
      controller.state.copyWith(
        busy: true,
        busyLabel: '安装本地处理组件',
        toolInstallLog: [
          for (var i = 1; i <= 60; i += 1)
            'install-tools log line ${i.toString().padLeft(2, "0")}',
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
              builder: (context, state) => const SizedBox.shrink(),
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

    final scrollableFinder = find.descendant(
      of: find.byKey(const ValueKey('tool-install-log-panel')),
      matching: find.byType(Scrollable),
    );
    expect(scrollableFinder, findsOneWidget);
    final scrollable = tester.state<ScrollableState>(scrollableFinder);
    expect(scrollable.position.maxScrollExtent, greaterThan(0));
    expect(find.text('install-tools log line 60'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('app shell shows AI environment sync progress', (tester) async {
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 760);

    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final controller = _StaticStudioController(prefs);
    controller.setStateForTest(
      controller.state.copyWith(
        busy: true,
        busyLabel: '同步 AI 环境',
        aiEnvironmentProgressLabel: '模型缓存 Warmup',
        aiEnvironmentProgressDetail: '正在下载并加载 4 个 AI Provider。',
        aiEnvironmentProgressPercent: 58,
        aiEnvironmentProgressLog: const [
          'Resolved 243 packages in 1.2s',
          'ERR Downloaded transformers',
          'Downloading models--m-a-p--MERT-v1-330M',
        ],
        aiEnvironmentProgressSteps: const [
          AiEnvironmentProgressStep(
            id: 'plan',
            label: '计划下载任务',
            detail: '超大杯 · PyPI Mirror · Torch Wheel Mirror',
            status: 'done',
          ),
          AiEnvironmentProgressStep(
            id: 'dependencies',
            label: 'Python / AI 依赖',
            detail: '当前选项不需要运行 uv sync。',
            status: 'skipped',
          ),
          AiEnvironmentProgressStep(
            id: 'models',
            label: '模型缓存',
            detail: '正在下载或复用 4 个 Provider 缓存。',
            status: 'running',
          ),
          AiEnvironmentProgressStep(
            id: 'verify',
            label: '完成后复检',
            detail: '重新检查 uv、Python、AI Provider 和硬件能力。',
            status: 'pending',
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
              builder: (context, state) => const SizedBox.shrink(),
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

    expect(find.text('正在修复 AI 环境'), findsOneWidget);
    expect(find.text('模型缓存 Warmup'), findsOneWidget);
    expect(find.text('正在下载并加载 4 个 AI Provider。'), findsOneWidget);
    expect(find.text('58%'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('ai-environment-sync-details')),
      findsOneWidget,
    );
    expect(find.text('下载明细'), findsOneWidget);
    expect(find.text('计划下载任务'), findsOneWidget);
    expect(find.text('Python / AI 依赖'), findsOneWidget);
    final doneChip = tester.widget<RmChip>(
      find.ancestor(of: find.text('完成'), matching: find.byType(RmChip)),
    );
    expect(doneChip.variant, RmChipVariant.info);
    final skippedChip = tester.widget<RmChip>(
      find.ancestor(of: find.text('跳过'), matching: find.byType(RmChip)),
    );
    expect(skippedChip.variant, RmChipVariant.skip);
    expect(find.text('最近下载输出'), findsOneWidget);
    expect(find.text('Downloaded transformers'), findsOneWidget);
    expect(find.text('ERR Downloaded transformers'), findsNothing);
    expect(find.textContaining('MERT-v1-330M'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('ai-environment-sync-cancel')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('tool-install-log-panel')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('ai-environment-sync-cancel')));
    await tester.pump();
    expect(controller.cancelAiEnvironmentSyncRequested, isTrue);

    final progress = tester.widget<LinearProgressIndicator>(
      find.descendant(
        of: find.byKey(const ValueKey('pending-overlay-progress-track')),
        matching: find.byType(LinearProgressIndicator),
      ),
    );
    expect(progress.value, 0.58);
    expect(tester.takeException(), isNull);
  });
}

class _StaticStudioController extends StudioController {
  _StaticStudioController(super.prefs);

  var cancelAiEnvironmentSyncRequested = false;

  void setStateForTest(StudioState value) {
    state = value;
  }

  @override
  Future<void> cancelAiEnvironmentSync() async {
    cancelAiEnvironmentSyncRequested = true;
  }
}
