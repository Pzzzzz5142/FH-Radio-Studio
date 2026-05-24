import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:path/path.dart' as p;
import 'package:fh_radio_studio/core/project_workspace.dart';
import 'package:fh_radio_studio/state/studio_state.dart';
import 'package:fh_radio_studio/theme/accents.dart';
import 'package:fh_radio_studio/theme/app_theme.dart';
import 'package:fh_radio_studio/theme/tokens.dart';
import 'package:fh_radio_studio/widgets/ai_environment_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets(
    'capture AI environment dialog with ready deep profile',
    (tester) async {
      GoogleFonts.config.allowRuntimeFetching = false;
      final tempRoot = Directory.systemTemp.createTempSync(
        'fh_radio_studio_ai_environment_dialog_capture_',
      );
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
      });

      final outDir = Directory(p.join('build', 'visual_qa'))
        ..createSync(recursive: true);
      await _captureAiEnvironmentDialog(
        tester,
        tempRoot: tempRoot,
        logicalSize: const Size(1244, 900),
        outputPath: p.join(outDir.path, 'ai_environment_dialog_regular.png'),
      );
      await _captureAiEnvironmentDialog(
        tester,
        tempRoot: tempRoot,
        logicalSize: const Size(1365, 1200),
        outputPath: p.join(outDir.path, 'ai_environment_dialog_full.png'),
      );
    },
    skip: Platform.environment['CAPTURE_AI_ENVIRONMENT_DIALOG'] != '1',
  );
}

Future<void> _captureAiEnvironmentDialog(
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
  FhRadioStudioProject.writeSettings(
    projectDir,
    gameDir: gameDir,
    aiProfile: 'local-deep',
  );
  SharedPreferences.setMockInitialValues({
    'rm.studio.projectDir': projectDir,
    'rm.studio.repoRoot': p.dirname(p.current),
  });
  final prefs = await SharedPreferences.getInstance();
  final controller = _AiEnvironmentDialogCaptureController(prefs);
  controller.setStateForTest(
    controller.state.copyWith(
      aiProfile: 'local-deep',
      gameDir: gameDir,
      toolchainStatus: _toolchainDeepReady,
      log: const ['AI environment dialog capture fixture loaded'],
    ),
  );

  await tester.pumpWidget(
    RepaintBoundary(
      key: repaintKey,
      child: SizedBox.fromSize(
        size: logicalSize,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildAppTheme(
            brightness: Brightness.light,
            accent: AppAccent.lime,
          ),
          home: _AiEnvironmentDialogLauncher(controller: controller),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.tap(find.text('Open AI environment dialog'));
  await tester.pumpAndSettle();

  expect(find.text('Pipeline 已就绪'), findsOneWidget);
  expect(find.text('需同步'), findsNothing);
  expect(find.text('待检查'), findsOneWidget);
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

class _AiEnvironmentDialogLauncher extends StatelessWidget {
  const _AiEnvironmentDialogLauncher({required this.controller});

  final _AiEnvironmentDialogCaptureController controller;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: ColoredBox(
        color: RmTokens.bgLight,
        child: Center(
          child: Builder(
            builder: (context) {
              return ElevatedButton(
                onPressed: () {
                  unawaited(
                    showAiEnvironmentSyncDialog(
                      context: context,
                      state: controller.state,
                      controller: controller,
                      latestState: () => controller.state,
                    ),
                  );
                },
                child: const Text('Open AI environment dialog'),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _AiEnvironmentDialogCaptureController extends StudioController {
  _AiEnvironmentDialogCaptureController(super.prefs);

  void setStateForTest(StudioState value) {
    state = value;
  }

  @override
  Future<void> startupFullCheckOnce() async {}
}

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
