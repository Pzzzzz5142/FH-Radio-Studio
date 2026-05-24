import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:path/path.dart' as p;
import 'package:fh_radio_studio/core/fh_radio_studio_cli.dart';
import 'package:fh_radio_studio/core/track_timing_config.dart';
import 'package:fh_radio_studio/domain/radio_library.dart';
import 'package:fh_radio_studio/domain/replacement_models.dart';
import 'package:fh_radio_studio/screens/replace_editor.dart';
import 'package:fh_radio_studio/screens/replace_editor/replace_state.dart';
import 'package:fh_radio_studio/screens/replace_editor/side_panel.dart';
import 'package:fh_radio_studio/screens/replace_editor/time_group_card.dart';
import 'package:fh_radio_studio/state/app_state.dart';
import 'package:fh_radio_studio/state/audio_analysis_state.dart';
import 'package:fh_radio_studio/state/custom_pool_tracks.dart';
import 'package:fh_radio_studio/theme/accents.dart';
import 'package:fh_radio_studio/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  testWidgets(
    'replace editor side panel pins with top gap and reserves bottom scroll',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1200, 850);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final tempRoot = Directory.systemTemp.createTempSync(
        'replace_editor_pinned_layout_',
      );
      addTearDown(() {
        if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
      });

      await _pumpEditor(tester, tempRoot.path);
      expect(tester.takeException(), isNull);

      final aiTitle = find.text('AI 分析').first;
      final aiCard = find.byKey(const ValueKey('editor-ai-card')).first;
      final waveformTab = find.text('波形').first;
      final initialAiTop = tester.getTopLeft(aiTitle).dy;
      final waveformTop = tester.getTopLeft(waveformTab).dy;
      expect(initialAiTop, greaterThan(300));
      expect((initialAiTop - waveformTop).abs(), lessThan(24));

      var previousCardTop = tester.getTopLeft(aiCard).dy;
      for (var i = 0; i < 8; i += 1) {
        await tester.dragFrom(const Offset(280, 760), const Offset(0, -48));
        await tester.pump();
        final nextCardTop = tester.getTopLeft(aiCard).dy;
        expect(nextCardTop, lessThanOrEqualTo(previousCardTop + 1));
        previousCardTop = nextCardTop;
      }
      await tester.dragFrom(const Offset(280, 760), const Offset(0, -420));
      await tester.pump();
      final floatingTransport = find.byKey(
        const ValueKey('editor-transport-bar-floating'),
      );
      expect(floatingTransport, findsOneWidget);
      expect(
        tester.getTopLeft(floatingTransport).dy,
        moreOrLessEquals(14, epsilon: 1),
      );
      final pinnedCardTop = tester.getTopLeft(aiCard).dy;
      expect(pinnedCardTop, moreOrLessEquals(14, epsilon: 1));

      for (var i = 0; i < 5; i += 1) {
        await tester.dragFrom(const Offset(280, 760), const Offset(0, -700));
        await tester.pump();
      }

      final shortcutsTop = tester.getTopLeft(find.text('快捷键').first).dy;
      expect(shortcutsTop, lessThan(830));
      expect(floatingTransport, findsOneWidget);
      expect(
        tester.getTopLeft(floatingTransport).dy,
        moreOrLessEquals(14, epsilon: 1),
      );
    },
  );

  testWidgets('AI summary tag expands to fit completed analysis text', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(420, 900);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final state = ReplaceEditorState.initial(
      trackId: 'cp-1',
      track: kCustomPool.first,
      ai: kReplacementEdit.ai,
    );
    final analysis = AudioAnalysisState(
      busy: false,
      progressSteps: [
        for (var i = 0; i < 15; i += 1)
          AudioAnalysisProgressStep(
            id: 'step-$i',
            label: 'Step $i',
            detail: '',
            status: 'done',
            weight: 1,
            runtimeMs: i == 0 ? 33700 : 0,
          ),
      ],
    );

    await tester.pumpWidget(
      _TestTheme(
        child: SizedBox(
          width: 312,
          child: EditorSidePanel(
            state: state,
            analysis: analysis,
            onAnalyze: () {},
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('33.7s · 15 steps'), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const ValueKey('editor-ai-summary-tag'))).width,
      greaterThan(112),
    );
  });

  testWidgets('candidate heading reflects the number of rendered candidates', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 620);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final candidates = [
      ...kReplacementEdit.ai.tl,
      const LoopCandidate(
        start: 63.40,
        end: 170.92,
        score: 0.27,
        bars: 48,
        why: 'extra candidate',
      ),
      const LoopCandidate(
        start: 84.00,
        end: 177.27,
        score: 0.09,
        bars: 32,
        why: 'extra candidate',
      ),
    ];

    await tester.pumpWidget(
      _TestTheme(
        child: SizedBox(
          width: 820,
          child: TimeGroupCard(
            kind: GroupKind.tl,
            candidates: candidates,
            selectedIdx: 0,
            confirmed: false,
            lowConfidence: false,
            onSelect: (_) {},
            onConfirm: (_) {},
            onCancelConfirm: () {},
            onPreview: (_) {},
            onNudge: (_, _) {},
            bpm: kReplacementEdit.ai.bpm,
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('候选 (top 5)'), findsOneWidget);
    expect(find.text('候选 (top 3)'), findsNothing);
  });

  testWidgets('replace editor sticky controls pin below shell chrome', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 850);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final tempRoot = Directory.systemTemp.createTempSync(
      'replace_editor_shell_pinned_layout_',
    );
    addTearDown(() {
      if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
    });

    const chromeHeight = 88.0;
    await _pumpEditor(tester, tempRoot.path, chromeHeight: chromeHeight);
    expect(tester.takeException(), isNull);

    await tester.dragFrom(const Offset(280, 760), const Offset(0, -720));
    await tester.pump();

    final aiCard = find.byKey(const ValueKey('editor-ai-card')).first;
    expect(
      tester.getTopLeft(aiCard).dy,
      moreOrLessEquals(chromeHeight + 14, epsilon: 1),
    );

    final floatingTransport = find.byKey(
      const ValueKey('editor-transport-bar-floating'),
    );
    expect(floatingTransport, findsOneWidget);
    expect(
      tester.getTopLeft(floatingTransport).dy,
      moreOrLessEquals(chromeHeight + 14, epsilon: 1),
    );
  });

  testWidgets(
    'replace editor collapses side panel into a floating rail when narrow',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(900, 850);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final tempRoot = Directory.systemTemp.createTempSync(
        'replace_editor_collapsed_layout_',
      );
      addTearDown(() {
        if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
      });

      await _pumpEditor(tester, tempRoot.path);
      expect(tester.takeException(), isNull);
      expect(find.text('确认进度'), findsNothing);
      final rail = find.text('AI / 快捷键');
      expect(rail, findsOneWidget);

      await tester.tap(rail);
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(
        find.byKey(const ValueKey('editor-side-drawer-clip')),
        findsOneWidget,
      );
      expect(find.text('AI 分析'), findsWidgets);
      expect(find.text('快捷键'), findsOneWidget);
      expect(find.text('确认进度'), findsNothing);
    },
  );

  testWidgets('candidate preview does not change the selected row', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 1100);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final tempRoot = Directory.systemTemp.createTempSync(
      'replace_editor_preview_select_',
    );
    addTearDown(() {
      if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
    });

    await _pumpEditor(tester, tempRoot.path);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(ReplaceEditorScreen)),
    );
    expect(container.read(replaceEditorProvider('cp-1')).tlIdx, 0);

    final secondTlPreview = find.text('试听拼接').at(1);
    await tester.ensureVisible(secondTlPreview);
    await tester.tap(secondTlPreview);
    await tester.pump();

    expect(container.read(replaceEditorProvider('cp-1')).tlIdx, 0);
  });

  testWidgets('confirmed candidates lock until directly unlocked in the UI', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 1100);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final tempRoot = Directory.systemTemp.createTempSync(
      'replace_editor_confirmed_lock_',
    );
    addTearDown(() {
      if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
    });

    await _pumpEditor(tester, tempRoot.path);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(ReplaceEditorScreen)),
    );
    var state = container.read(replaceEditorProvider('cp-1'));
    expect(state.tdConfirmed, isTrue);
    expect(state.tdIdx, 0);
    expect(find.text('当前选择'), findsWidgets);
    expect(find.text('解锁重选'), findsWidgets);

    final secondTd = find.text('第二段副歌起始');
    await tester.ensureVisible(secondTd);
    await tester.tap(secondTd);
    await tester.pump();

    state = container.read(replaceEditorProvider('cp-1'));
    expect(state.tdConfirmed, isTrue);
    expect(state.tdIdx, 0);

    final unlock = find.text('解锁重选').first;
    await tester.ensureVisible(unlock);
    await tester.pump();
    await tester.tap(unlock);
    await tester.pump();
    expect(container.read(replaceEditorProvider('cp-1')).tdConfirmed, isFalse);

    await tester.ensureVisible(secondTd);
    await tester.pump();
    await tester.tap(secondTd);
    await tester.pump();

    state = container.read(replaceEditorProvider('cp-1'));
    expect(state.tdConfirmed, isFalse);
    expect(state.tdIdx, 1);
  });

  testWidgets('replace editor prompts to save only changed completed configs', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 1100);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final tempRoot = Directory.systemTemp.createTempSync(
      'replace_editor_save_prompt_',
    );
    addTearDown(() {
      if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
    });

    await _pumpEditor(tester, tempRoot.path);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(ReplaceEditorScreen)),
    );
    ReplaceEditorNotifier notifier() {
      return container.read(replaceEditorProvider('cp-1').notifier);
    }

    Future<void> tapConfirm() async {
      final confirm = find.text('确认').first;
      await tester.ensureVisible(confirm);
      await tester.pump();
      await tester.tap(confirm);
      await tester.pump();
      await tester.pump();
    }

    notifier().setConfirmed(GroupKind.tl, true);
    await tester.pump();
    expect(find.text('保存这首歌的配置？'), findsNothing);

    await tapConfirm();
    expect(find.text('保存这首歌的配置？'), findsOneWidget);

    await tester.tap(find.text('保存配置'));
    await tester.pump();
    await tester.pump();
    expect(find.text('保存这首歌的配置？'), findsNothing);
    expect(
      TrackTimingStore.readAll(tempRoot.path).values.single.allConfirmed,
      isTrue,
    );

    notifier().setConfirmed(GroupKind.pl, false);
    await tester.pump();
    await tapConfirm();
    expect(find.text('保存这首歌的配置？'), findsNothing);

    notifier().setConfirmed(GroupKind.pl, false);
    await tester.pump();
    expect(container.read(replaceEditorProvider('cp-1')).plConfirmed, isFalse);
    notifier().selectCandidate(GroupKind.pl, 1);
    await tester.pump();
    expect(container.read(replaceEditorProvider('cp-1')).plIdx, 1);
    await tapConfirm();
    final changedState = container.read(replaceEditorProvider('cp-1'));
    final savedConfig = TrackTimingStore.readAll(tempRoot.path).values.single;
    expect(
      (changedState.markerSeconds['PostRaceLoopStart']! -
              savedConfig.markersSec['PostRaceLoopStart']!)
          .abs(),
      greaterThan(0.001),
    );
    expect(find.text('保存这首歌的配置？'), findsOneWidget);
  });

  testWidgets('replace editor seeds pending AI duration from metadata cache', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 850);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final tempRoot = Directory.systemTemp.createTempSync(
      'replace_editor_metadata_seed_',
    );
    addTearDown(() {
      if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
    });
    final sources = Directory(p.join(tempRoot.path, 'sources'))
      ..createSync(recursive: true);
    final track = File(p.join(sources.path, 'Artist - Cached.wav'))
      ..writeAsBytesSync(const [0, 1, 2, 3]);
    final metadataDir = Directory(p.join(tempRoot.path, '.fh-radio-studio'))
      ..createSync(recursive: true);
    File(p.join(metadataDir.path, 'track_metadata.json')).writeAsStringSync(
      jsonEncode({
        'schema_version': 1,
        'tracks': [
          {
            'source': track.path,
            'artist': 'Artist',
            'title': 'Cached',
            'from_tags': false,
            'duration_sec': 98.75,
            'sample_rate': 44100,
            'channels': 2,
            'samples': 4354875,
          },
        ],
      }),
      encoding: utf8,
    );
    final analysis = Completer<CliRunResult>();
    addTearDown(() {
      if (!analysis.isCompleted) {
        analysis.complete(
          const CliRunResult(
            exitCode: -1,
            stdout: '',
            stderr: '',
            commandLine: 'test',
          ),
        );
      }
    });

    await _pumpEditor(
      tester,
      tempRoot.path,
      trackId: realTrackIdForPath(track.path),
      overrides: [
        audioAnalysisCliRunnerProvider.overrideWithValue((
          repoRoot,
          args, {
          cancellationToken,
          onStdout,
          onStderr,
        }) {
          return analysis.future;
        }),
      ],
    );

    final container = ProviderScope.containerOf(
      tester.element(find.byType(ReplaceEditorScreen)),
    );
    final state = container.read(
      replaceEditorProvider(realTrackIdForPath(track.path)),
    );
    expect(state.aiPending, isTrue);
    expect(state.track.durationSec, 98.75);
    expect(state.ai.durationSec, 98.75);
    expect(state.ai.sourceSampleRate, 44100);
    expect(state.ai.channels, 2);
    expect(state.ai.sourceSamples, 4354875);
    expect(find.text('0:00.00 / 1:38.75', findRichText: true), findsOneWidget);
    expect(find.textContaining('/ --:--', findRichText: true), findsNothing);
  });

  testWidgets('replace editor masks pending AI data while transport stays usable', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1200, 850);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final tempRoot = Directory.systemTemp.createTempSync(
        'replace_editor_ai_pending_layout_',
      );
      addTearDown(() {
        if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
      });
      final audioFile = File(p.join(tempRoot.path, 'Artist - Pending.wav'))
        ..writeAsBytesSync(const [0, 1, 2, 3]);
      final track = poolTrackFromFile(audioFile);
      final analysis = Completer<CliRunResult>();
      addTearDown(() {
        if (!analysis.isCompleted) {
          analysis.complete(
            const CliRunResult(
              exitCode: -1,
              stdout: '',
              stderr: 'cancelled by test',
              commandLine: 'fake analyze-audio',
              cancelled: true,
            ),
          );
        }
      });

      await _pumpEditor(
        tester,
        tempRoot.path,
        trackId: track.id,
        overrides: [
          realPoolTracksProvider.overrideWithValue([track]),
          audioAnalysisCliRunnerProvider.overrideWithValue((
            repoRoot,
            args, {
            cancellationToken,
            onStdout,
            onStderr,
          }) {
            expect(repoRoot, isNotEmpty);
            expect(args, contains('analyze-audio'));
            expect(cancellationToken, isNotNull);
            onStderr?.call(
              'FH_RADIO_STUDIO_PROGRESS ${jsonEncode({
                'event': 'plan',
                'steps': [
                  {'id': 'setup', 'label': '启动与输入检查', 'detail': '确认源音频。', 'weight': 1},
                  {'id': 'mert.score_candidates', 'label': 'MERT 候选评分', 'detail': '评估 loop seam。', 'weight': 2},
                ],
              })}',
            );
            onStderr?.call(
              'FH_RADIO_STUDIO_PROGRESS ${jsonEncode({'event': 'step_started', 'step_id': 'mert.score_candidates'})}',
            );
            return analysis.future;
          }),
        ],
      );

      expect(tester.takeException(), isNull);
      expect(
        find.byKey(const ValueKey('editor-ai-pending-waveform')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('editor-ai-pending-td')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('editor-ai-pipeline-progress')),
        findsOneWidget,
      );
      expect(find.text('运行中 · 0/2'), findsOneWidget);
      expect(find.text('MERT 候选评分'), findsWidgets);
      expect(find.textContaining('AI 全局置信度'), findsNothing);
      expect(find.text('段：分析中'), findsOneWidget);
      expect(find.text('BPM --'), findsOneWidget);

      final playButton = find.byKey(const ValueKey('editor-play-inline'));
      expect(playButton, findsOneWidget);
      expect(tester.widget<GestureDetector>(playButton).onTap, isNotNull);
      await tester.tap(playButton);
      await tester.pump(const Duration(milliseconds: 120));
      expect(tester.takeException(), isNull);
    } finally {
      semantics.dispose();
    }
  });
}

Future<void> _pumpEditor(
  WidgetTester tester,
  String projectDir, {
  String trackId = 'cp-1',
  double chromeHeight = 0,
  List<Override> overrides = const [],
}) async {
  SharedPreferences.setMockInitialValues({
    'rm.studio.projectDir': projectDir,
    'rm.studio.repoRoot': p.dirname(p.current),
  });
  final prefs = await SharedPreferences.getInstance();
  final editor = chromeHeight > 0
      ? Column(
          children: [
            SizedBox(height: chromeHeight),
            Expanded(
              child: ReplaceEditorScreen(trackId: trackId, enableAudio: false),
            ),
          ],
        )
      : ReplaceEditorScreen(trackId: trackId, enableAudio: false);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        ...overrides,
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildAppTheme(
          brightness: Brightness.light,
          accent: AppAccent.lime,
        ),
        home: Scaffold(body: editor),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

class _TestTheme extends StatelessWidget {
  const _TestTheme({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(
        brightness: Brightness.light,
        accent: AppAccent.lime,
      ),
      home: Scaffold(body: child),
    );
  }
}
