import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:path/path.dart' as p;
import 'package:fh_radio_studio/core/fh_radio_studio_cli.dart';
import 'package:fh_radio_studio/core/project_refs.dart';
import 'package:fh_radio_studio/core/track_metadata_cache.dart';
import 'package:fh_radio_studio/core/track_timing_config.dart';
import 'package:fh_radio_studio/domain/radio_library.dart';
import 'package:fh_radio_studio/domain/replacement_models.dart';
import 'package:fh_radio_studio/screens/replace_editor/replace_editor.dart'
    show
        ReplaceEditorScreen,
        loopPreviewAuditionStartForTesting,
        pointPreviewWindowForTesting;
import 'package:fh_radio_studio/screens/replace_editor/manual_focus_waveform.dart';
import 'package:fh_radio_studio/screens/replace_editor/replace_state.dart';
import 'package:fh_radio_studio/screens/replace_editor/side_panel.dart';
import 'package:fh_radio_studio/screens/replace_editor/time_group_card.dart';
import 'package:fh_radio_studio/state/app_state.dart';
import 'package:fh_radio_studio/state/audio_analysis_state.dart';
import 'package:fh_radio_studio/state/custom_pool_tracks.dart';
import 'package:fh_radio_studio/theme/accents.dart';
import 'package:fh_radio_studio/theme/app_theme.dart';
import 'package:fh_radio_studio/theme/tokens.dart';
import 'package:fh_radio_studio/widgets/rm_button.dart';
import 'package:fh_radio_studio/widgets/rm_icon.dart';
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
    tester.view.physicalSize = const Size(900, 760);
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
            manualCandidate: null,
            manualSelected: false,
            onManualRefine: () {},
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
    expect(find.text('人工选点'), findsOneWidget);
    expect(find.widgetWithText(RmButton, '人工精修'), findsNothing);
    expect(find.text('这都什么玩意，我自己来！'), findsNothing);
    expect(find.textContaining('点击后居中波形'), findsNothing);

    final manualRow = find.byKey(const ValueKey('editor-manual-refine-tl'));
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(gesture.removePointer);
    await gesture.addPointer(location: tester.getCenter(manualRow));
    await tester.pump();
    await gesture.moveTo(tester.getCenter(manualRow));
    await tester.pump(const Duration(milliseconds: 1100));
    expect(find.text('这都什么玩意，我自己来！'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('ghost button hover fades from hover-toned transparency', (
    tester,
  ) async {
    await tester.pumpWidget(
      _TestTheme(
        child: Center(
          child: RmButton(
            onPressed: () {},
            variant: RmButtonVariant.ghost,
            label: 'Ghost',
          ),
        ),
      ),
    );

    final idle = tester.widget<AnimatedContainer>(
      find.byType(AnimatedContainer),
    );
    expect(
      (idle.decoration as BoxDecoration).color,
      RmTokens.hoverLight.withAlpha(0),
    );

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(gesture.removePointer);
    await gesture.addPointer(location: tester.getCenter(find.text('Ghost')));
    await gesture.moveTo(tester.getCenter(find.text('Ghost')));
    await tester.pump();

    final hovered = tester.widget<AnimatedContainer>(
      find.byType(AnimatedContainer),
    );
    expect((hovered.decoration as BoxDecoration).color, RmTokens.hoverLight);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'manual refine overlay aligns AI panel and previews loop drafts',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1200, 1100);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final tempRoot = Directory.systemTemp.createTempSync(
        'replace_editor_manual_refine_',
      );
      addTearDown(() {
        if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
      });

      await _pumpEditor(tester, tempRoot.path);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(ReplaceEditorScreen)),
      );
      final notifier = container.read(replaceEditorProvider('cp-1').notifier);
      notifier.setConfirmed(GroupKind.tl, false);
      await tester.pump();

      final manualTl = find.byKey(const ValueKey('editor-manual-refine-tl'));
      final expectedLoop = container.read(replaceEditorProvider('cp-1')).tl;
      await Scrollable.ensureVisible(
        tester.element(manualTl),
        alignment: 0.45,
        duration: Duration.zero,
      );
      await tester.pump();
      await tester.tap(manualTl);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 260));

      expect(tester.takeException(), isNull);
      final overlay = find.byKey(const ValueKey('manual-refine-overlay'));
      expect(overlay, findsOneWidget);
      expect(tester.getSize(overlay).width, greaterThan(1000));
      expect(tester.getSize(overlay).height, greaterThan(900));
      expect(
        find.byKey(const ValueKey('manual-refine-ai-panel')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('manual-refine-main-editor')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('manual-refine-footer-divider')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('manual-refine-fine-panel')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('manual-refine-loop-preview')),
        findsOneWidget,
      );
      final finePanel = find.byKey(const ValueKey('manual-refine-fine-panel'));
      expect(
        find.descendant(
          of: finePanel,
          matching: find.text(
            _formatManualFineTimecodeForTest(expectedLoop.start),
          ),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: finePanel,
          matching: find.text(
            _formatManualFineTimecodeForTest(expectedLoop.end),
          ),
        ),
        findsOneWidget,
      );
      expect(_manualMainIcon('skip-back'), findsNothing);
      expect(_manualMainIcon('skip-fwd'), findsNothing);
      expect(find.textContaining('←/→ 1拍'), findsOneWidget);
      expect(find.textContaining('Ctrl+←/→ 1ms'), findsOneWidget);
      expect(find.byKey(const ValueKey('manual-refine-lock')), findsNothing);
      expect(find.text('锁定选点'), findsNothing);
      expect(find.text('套用 AI 建议'), findsOneWidget);
      final aiPanelTop = tester
          .getTopLeft(find.byKey(const ValueKey('manual-refine-ai-panel')))
          .dy;
      final mainEditorTop = tester
          .getTopLeft(find.byKey(const ValueKey('manual-refine-main-editor')))
          .dy;
      final footerDividerLeft = tester
          .getTopLeft(
            find.byKey(const ValueKey('manual-refine-footer-divider')),
          )
          .dx;
      final footerDividerRight = tester
          .getTopRight(
            find.byKey(const ValueKey('manual-refine-footer-divider')),
          )
          .dx;
      final mainEditorLeft = tester
          .getTopLeft(find.byKey(const ValueKey('manual-refine-main-editor')))
          .dx;
      final aiPanelRight = tester
          .getTopRight(find.byKey(const ValueKey('manual-refine-ai-panel')))
          .dx;
      final aiPanelBottom = tester
          .getBottomLeft(find.byKey(const ValueKey('manual-refine-ai-panel')))
          .dy;
      final mainEditorBottom = tester
          .getBottomLeft(
            find.byKey(const ValueKey('manual-refine-main-editor')),
          )
          .dy;
      expect(aiPanelTop, closeTo(mainEditorTop, 1));
      expect(footerDividerLeft, closeTo(mainEditorLeft, 1));
      expect(footerDividerRight, closeTo(aiPanelRight, 1));
      expect(aiPanelBottom, closeTo(mainEditorBottom, 1));
      expect(
        tester
            .getSize(find.byKey(const ValueKey('manual-refine-ai-panel')))
            .height,
        closeTo(
          tester
              .getSize(find.byKey(const ValueKey('manual-refine-main-editor')))
              .height,
          1,
        ),
      );

      final secondAi = container.read(replaceEditorProvider('cp-1')).ai.tl[1];
      await tester.tap(find.byKey(const ValueKey('manual-refine-ai-apply-1')));
      await tester.pump();
      final previewState = container.read(replaceEditorProvider('cp-1'));
      expect(previewState.playbackMode, PlaybackMode.loopPreview);
      expect(previewState.playing, isTrue);
      expect(
        previewState.playhead,
        closeTo(
          loopPreviewAuditionStartForTesting(
            startSec: secondAi.start,
            endSec: secondAi.end,
          ),
          0.001,
        ),
      );

      await tester.tap(find.text('确认选点'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 260));

      final state = container.read(replaceEditorProvider('cp-1'));
      expect(state.tlManual, isNotNull);
      expect(state.tlConfirmed, isTrue);
      expect(state.selectedManualOf(GroupKind.tl), isTrue);
      expect((state.tl.start - secondAi.start).abs(), lessThan(0.001));
      expect((state.tl.end - secondAi.end).abs(), lessThan(0.001));
      expect(find.byKey(const ValueKey('manual-refine-overlay')), findsNothing);
    },
  );

  testWidgets('manual refine point mode puts audition in the transport bar', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 1100);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final tempRoot = Directory.systemTemp.createTempSync(
      'replace_editor_manual_point_transport_',
    );
    addTearDown(() {
      if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
    });

    await _pumpEditor(tester, tempRoot.path);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(ReplaceEditorScreen)),
    );
    final notifier = container.read(replaceEditorProvider('cp-1').notifier);
    notifier.setConfirmed(GroupKind.td, false);
    await tester.pump();

    final manualTd = find.byKey(const ValueKey('editor-manual-refine-td'));
    final expectedPoint = container.read(replaceEditorProvider('cp-1')).td;
    await Scrollable.ensureVisible(
      tester.element(manualTd),
      alignment: 0.45,
      duration: Duration.zero,
    );
    await tester.pump();
    await tester.tap(manualTd);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 260));

    final mainEditor = find.byKey(const ValueKey('manual-refine-main-editor'));
    expect(mainEditor, findsOneWidget);
    expect(
      find.descendant(
        of: mainEditor,
        matching: find.byKey(const ValueKey('manual-refine-point-preview')),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('manual-refine-loop-preview')),
      findsNothing,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('manual-refine-fine-panel')),
        matching: find.text(_formatManualFineTimecodeForTest(expectedPoint.t)),
      ),
      findsOneWidget,
    );
    expect(find.text('端点 A'), findsNothing);
    expect(_manualMainIcon('skip-back'), findsNothing);
    expect(_manualMainIcon('skip-fwd'), findsNothing);

    final secondAi = container.read(replaceEditorProvider('cp-1')).ai.td[1];
    await tester.tap(find.byKey(const ValueKey('manual-refine-ai-apply-1')));
    await tester.pump();
    final previewState = container.read(replaceEditorProvider('cp-1'));
    expect(previewState.playbackMode, PlaybackMode.pointPreview);
    expect(previewState.playing, isTrue);
    expect(
      previewState.playhead,
      closeTo(
        pointPreviewWindowForTesting(
          timeSec: secondAi.t,
          durationSec: previewState.ai.durationSec,
        ).start,
        0.001,
      ),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('manual refine alt indicator responds to rapid toggles', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 1100);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final tempRoot = Directory.systemTemp.createTempSync(
      'replace_editor_manual_alt_toggle_',
    );
    addTearDown(() {
      if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
    });

    await _pumpEditor(tester, tempRoot.path);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(ReplaceEditorScreen)),
    );
    final notifier = container.read(replaceEditorProvider('cp-1').notifier);
    notifier.setConfirmed(GroupKind.tl, false);
    await tester.pump();

    final manualTl = find.byKey(const ValueKey('editor-manual-refine-tl'));
    await Scrollable.ensureVisible(
      tester.element(manualTl),
      alignment: 0.45,
      duration: Duration.zero,
    );
    await tester.pump();
    await tester.tap(manualTl);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 260));

    expect(find.text('磁吸到拍'), findsOneWidget);
    for (var i = 0; i < 3; i += 1) {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.pump();
      try {
        expect(find.text('自由放置 · Alt'), findsOneWidget);
        expect(find.text('磁吸到拍'), findsNothing);
      } finally {
        await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
        await tester.pump();
      }
      expect(find.text('磁吸到拍'), findsOneWidget);
      expect(find.text('自由放置 · Alt'), findsNothing);
    }

    expect(tester.takeException(), isNull);
  });

  testWidgets('manual refine supports synced ctrl and shift keyboard nudges', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 1100);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final tempRoot = Directory.systemTemp.createTempSync(
      'replace_editor_manual_ctrl_nudge_',
    );
    addTearDown(() {
      if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
    });

    await _pumpEditor(tester, tempRoot.path);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(ReplaceEditorScreen)),
    );
    final notifier = container.read(replaceEditorProvider('cp-1').notifier);
    notifier.setConfirmed(GroupKind.td, false);
    await tester.pump();

    final editorState = container.read(replaceEditorProvider('cp-1'));
    final initialPoint = editorState.td.t;
    final beatSec = 60 / editorState.ai.bpm;
    final manualTd = find.byKey(const ValueKey('editor-manual-refine-td'));
    await Scrollable.ensureVisible(
      tester.element(manualTd),
      alignment: 0.45,
      duration: Duration.zero,
    );
    await tester.pump();
    await tester.tap(manualTd);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 260));

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    try {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    } finally {
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    }
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    try {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    } finally {
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    }
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();

    await tester.tap(find.text('确认选点'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 260));

    final state = container.read(replaceEditorProvider('cp-1'));
    expect(state.tdManual, isNotNull);
    expect(state.selectedManualOf(GroupKind.td), isTrue);
    expect(
      state.tdManual!.t,
      closeTo(initialPoint + 0.001 + 0.010 + beatSec, 0.0001),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('manual refine overlay follows the active playback playhead', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 1100);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final tempRoot = Directory.systemTemp.createTempSync(
      'replace_editor_manual_playhead_',
    );
    addTearDown(() {
      if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
    });

    await _pumpEditor(tester, tempRoot.path);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(ReplaceEditorScreen)),
    );
    final notifier = container.read(replaceEditorProvider('cp-1').notifier);
    notifier.setConfirmed(GroupKind.tl, false);
    await tester.pump();

    final manualTl = find.byKey(const ValueKey('editor-manual-refine-tl'));
    await Scrollable.ensureVisible(
      tester.element(manualTl),
      alignment: 0.45,
      duration: Duration.zero,
    );
    await tester.pump();
    await tester.tap(manualTl);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 260));

    notifier.setPlayback(PlaybackMode.full, playing: true);
    notifier.setPlayhead(80);
    await tester.pump();

    final focusWaveform = tester.widget<ManualFocusWaveform>(
      find.byType(ManualFocusWaveform),
    );
    expect(focusWaveform.playhead, 80);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('manual-refine-overlay')),
        matching: find.textContaining('1:20.00', findRichText: true),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('manual refine cancel pauses active playback', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 1100);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final tempRoot = Directory.systemTemp.createTempSync(
      'replace_editor_manual_cancel_pause_',
    );
    addTearDown(() {
      if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
    });

    await _pumpEditor(tester, tempRoot.path);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(ReplaceEditorScreen)),
    );
    final notifier = container.read(replaceEditorProvider('cp-1').notifier);
    notifier.setConfirmed(GroupKind.tl, false);
    await tester.pump();

    final manualTl = find.byKey(const ValueKey('editor-manual-refine-tl'));
    await Scrollable.ensureVisible(
      tester.element(manualTl),
      alignment: 0.45,
      duration: Duration.zero,
    );
    await tester.pump();
    await tester.tap(manualTl);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 260));

    notifier.setPlayback(PlaybackMode.full, playing: true);
    await tester.pump();
    expect(container.read(replaceEditorProvider('cp-1')).playing, isTrue);

    await tester.tap(find.byTooltip('取消人工选点'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 260));

    expect(find.byKey(const ValueKey('manual-refine-overlay')), findsNothing);
    expect(container.read(replaceEditorProvider('cp-1')).playing, isFalse);
    expect(tester.takeException(), isNull);
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

    final audioFile = File(
      p.join(tempRoot.path, 'sources', 'midnight-cascade.flac'),
    );
    audioFile.parent.createSync(recursive: true);
    audioFile.writeAsBytesSync(const [0, 1, 2, 3]);
    _writeTrackMetadataEntry(
      tempRoot.path,
      audioFile,
      artist: 'Telemetry',
      title: 'Midnight Cascade',
      durationSec: 214.3,
      sampleRate: 48000,
      channels: 2,
      samples: 10286400,
    );
    final track = PoolTrack(
      id: realTrackIdForPath(audioFile.path),
      title: 'Midnight Cascade',
      artist: 'Telemetry',
      source: audioFile.path,
      durationSec: 214.3,
      bpm: 128,
      key: 'F#m',
      configured: false,
      confirmed: 2,
      sampleRate: 48000,
      channels: 2,
      samples: 10286400,
      assignedTo: 'HOR',
      slot: 1,
      added: 'test fixture',
    );
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
          return analysis.future;
        }),
      ],
    );
    final container = ProviderScope.containerOf(
      tester.element(find.byType(ReplaceEditorScreen)),
    );
    final provider = replaceEditorProvider(track.id);
    ReplaceEditorNotifier notifier() {
      return container.read(provider.notifier);
    }

    Future<void> confirmPl() async {
      notifier().setConfirmed(GroupKind.pl, true);
      await tester.pump();
      await tester.pump();
    }

    notifier().setConfirmed(GroupKind.tl, true);
    await tester.pump();
    expect(find.text('保存这首歌的配置？'), findsNothing);

    await confirmPl();
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
    await confirmPl();
    expect(find.text('保存这首歌的配置？'), findsNothing);

    notifier().setConfirmed(GroupKind.pl, false);
    await tester.pump();
    expect(container.read(provider).plConfirmed, isFalse);
    notifier().selectCandidate(GroupKind.pl, 1);
    await tester.pump();
    expect(container.read(provider).plIdx, 1);
    await confirmPl();
    final changedState = container.read(provider);
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
    _writeTrackMetadataEntry(
      tempRoot.path,
      track,
      artist: 'Artist',
      title: 'Cached',
      durationSec: 98.75,
      sampleRate: 44100,
      channels: 2,
      samples: 4354875,
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
        realPoolTracksProvider.overrideWithValue(
          buildRealPoolTracks([
            track.path,
          ], metadata: TrackMetadataCache.read(tempRoot.path)),
        ),
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

void _writeTrackMetadataEntry(
  String projectDir,
  File source, {
  required String artist,
  required String title,
  required double durationSec,
  required int sampleRate,
  required int channels,
  required int samples,
}) {
  final sourceRef = projectRefForPath(projectDir, source.path);
  if (sourceRef == null) {
    throw StateError('Test source is not inside the project: ${source.path}');
  }
  final file = File(TrackMetadataCache.configPath(projectDir));
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(
    jsonEncode({
      'schema_version': 2,
      'tracks': [
        {
          'track_key': trackKeyForSourceRef(sourceRef),
          'source_ref': sourceRef,
          'artist': artist,
          'title': title,
          'from_tags': false,
          'duration_sec': durationSec,
          'sample_rate': sampleRate,
          'channels': channels,
          'samples': samples,
        },
      ],
    }),
    encoding: utf8,
  );
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

Finder _manualMainIcon(String name) {
  return find.descendant(
    of: find.byKey(const ValueKey('manual-refine-main-editor')),
    matching: find.byWidgetPredicate(
      (widget) => widget is RmIcon && widget.name == name,
    ),
  );
}

String _formatManualFineTimecodeForTest(double seconds) {
  final neg = seconds < 0;
  final totalMs = (seconds.abs() * 1000).round();
  final minutes = totalMs ~/ 60000;
  final secondsMs = totalMs % 60000;
  final wholeSeconds = secondsMs ~/ 1000;
  final milliseconds = secondsMs % 1000;
  return '${neg ? "-" : ""}$minutes:'
      '${wholeSeconds.toString().padLeft(2, "0")}.'
      '${milliseconds.toString().padLeft(3, "0")}';
}
