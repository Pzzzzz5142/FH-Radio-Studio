import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';

import '../../core/system_audio_output.dart';
import '../../core/track_timing_config.dart';
import '../../domain/replacement_models.dart';
import '../../state/audio_analysis_state.dart';
import '../../state/studio_state.dart';
import '../../state/track_timing_state.dart';
import '../../theme/app_theme.dart';
import '../../theme/text_styles.dart';
import '../../theme/tokens.dart';
import '../../widgets/rm_banner.dart';
import '../../widgets/rm_button.dart';
import '../../widgets/rm_icon.dart';
import 'ai_pending_overlay.dart';
import 'breadcrumb.dart';
import 'group_colors.dart';
import 'manual_focus_waveform.dart';
import 'progress_strip.dart';
import 'replace_state.dart';
import 'side_panel.dart';
import 'target_source_card.dart';
import 'time_group_card.dart';
import 'transport_bar.dart';
import 'waveform_card.dart';

@visibleForTesting
const double pointPreviewDurationSec = 6;

@visibleForTesting
const double loopSeamPreviewLeadInSec = 2;

@visibleForTesting
const double previewSeekPositionToleranceSec = 0.35;

@visibleForTesting
const Duration previewSeekPositionHold = Duration(seconds: 2);

@visibleForTesting
({double start, double end}) pointPreviewWindowForTesting({
  required double timeSec,
  required double durationSec,
}) {
  final duration = math.max(0, durationSec);
  final start = timeSec.clamp(0, duration).toDouble();
  final end = math.min(start + pointPreviewDurationSec, duration).toDouble();
  return (start: start, end: end);
}

@visibleForTesting
double loopPreviewAuditionStartForTesting({
  required double startSec,
  required double endSec,
}) {
  return (endSec - loopSeamPreviewLeadInSec).clamp(startSec, endSec).toDouble();
}

@visibleForTesting
bool isStalePreviewStartupPositionForTesting({
  required double positionSec,
  required double targetSec,
}) {
  return _isStalePreviewStartupPosition(positionSec, targetSec);
}

bool _isStalePreviewStartupPosition(double positionSec, double targetSec) {
  if (!positionSec.isFinite || !targetSec.isFinite) return false;
  return (positionSec - targetSec).abs() > previewSeekPositionToleranceSec;
}

class ReplaceEditorScreen extends ConsumerStatefulWidget {
  const ReplaceEditorScreen({
    super.key,
    required this.trackId,
    this.enableAudio = true,
  });
  final String trackId;
  final bool enableAudio;

  @override
  ConsumerState<ReplaceEditorScreen> createState() =>
      _ReplaceEditorScreenState();
}

class _ReplaceEditorScreenState extends ConsumerState<ReplaceEditorScreen> {
  final ScrollController _pageScrollController = ScrollController();
  final GlobalKey _editorViewportKey = GlobalKey(
    debugLabel: 'replace-editor-viewport',
  );
  final GlobalKey _scrollContentKey = GlobalKey(
    debugLabel: 'replace-editor-scroll-content',
  );
  final FocusNode _hotkeysFocus = FocusNode(
    debugLabel: 'replace-editor-hotkeys',
  );
  Player? _player;
  SystemAudioOutputFollower? _audioOutputFollower;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<bool>? _playingSub;
  StreamSubscription<bool>? _completedSub;
  StreamSubscription<String>? _errorSub;
  String? _loadedSource;
  Future<void>? _loadAudioFuture;
  int _loadVersion = 0;
  int _playbackVersion = 0;
  bool _pausedByUser = false;
  bool _rangeSeeking = false;
  int? _positionHoldCommand;
  double? _positionHoldTargetSec;
  Timer? _positionHoldTimer;
  String? _analysisStartedFor;
  _PreviewRange? _previewRange;
  bool _sideDrawerOpen = false;
  bool _savePromptOpen = false;
  bool _lastObservedAllConfirmed = false;
  double _sidePanelExtraScroll = 0;
  _TransportDockMetrics? _transportDockMetrics;
  _ManualRefineSession? _manualSession;
  bool _altHeld = false;

  @override
  void initState() {
    super.initState();
    if (widget.enableAudio) {
      final player = _audioPlayer;
      _positionSub = player.stream.position.listen(_handlePosition);
      _playingSub = player.stream.playing.listen((playing) {
        if (!mounted) return;
        final n = ref.read(replaceEditorProvider(widget.trackId).notifier);
        n.setPlaying(playing && !player.state.completed);
      });
      _completedSub = player.stream.completed.listen((completed) {
        if (!mounted || !completed) return;
        final n = ref.read(replaceEditorProvider(widget.trackId).notifier);
        n.setPlayback(PlaybackMode.idle, playing: false);
      });
      _errorSub = player.stream.error.listen((message) {
        if (!mounted) return;
        final n = ref.read(replaceEditorProvider(widget.trackId).notifier);
        _clearLocalPlaybackState();
        n.setPlayback(PlaybackMode.idle, playing: false);
        n.setError('内置播放器错误：$message');
      });
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _hotkeysFocus.requestFocus();
      _startInitialAnalysis();
    });
  }

  @override
  void didUpdateWidget(covariant ReplaceEditorScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.trackId == widget.trackId) return;
    _analysisStartedFor = null;
    _clearLocalPlaybackState();
    final player = _player;
    if (player != null) {
      unawaited(player.stop());
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref
          .read(replaceEditorProvider(widget.trackId).notifier)
          .setPlayback(PlaybackMode.idle, playing: false);
      _startInitialAnalysis();
    });
  }

  @override
  void dispose() {
    _positionSub?.cancel();
    _playingSub?.cancel();
    _completedSub?.cancel();
    _errorSub?.cancel();
    _audioOutputFollower?.dispose();
    final player = _player;
    if (player != null) {
      unawaited(player.dispose());
    }
    _clearPreviewPositionHold();
    _pageScrollController.dispose();
    _hotkeysFocus.dispose();
    super.dispose();
  }

  Player get _audioPlayer {
    if (!widget.enableAudio) {
      throw StateError('Audio playback is disabled for this editor instance.');
    }
    final player = _player;
    if (player != null) return player;
    final next = Player();
    _audioOutputFollower = followSystemAudioOutput(next);
    return _player = next;
  }

  /// 跟随 Alt 键的按下状态，仅在人工选点面板开启时刷新磁吸指示灯。
  void _syncAltHeld() {
    if (_manualSession == null) return;
    final held = HardwareKeyboard.instance.isAltPressed;
    if (held != _altHeld) {
      setState(() => _altHeld = held);
    }
  }

  void _onKey(KeyEvent e) {
    if (e is! KeyDownEvent) return;
    final n = ref.read(replaceEditorProvider(widget.trackId).notifier);
    final s = ref.read(replaceEditorProvider(widget.trackId));
    final shift = HardwareKeyboard.instance.isShiftPressed;
    if (_manualSession != null && e.logicalKey == LogicalKeyboardKey.escape) {
      _cancelManualRefine();
    } else if (_manualSession != null &&
        e.logicalKey == LogicalKeyboardKey.enter) {
      _confirmManualRefine(n);
    } else if (_manualSession != null &&
        e.logicalKey == LogicalKeyboardKey.arrowLeft) {
      _nudgeManualDraft(shift ? -0.010 : -(60 / s.ai.bpm));
    } else if (_manualSession != null &&
        e.logicalKey == LogicalKeyboardKey.arrowRight) {
      _nudgeManualDraft(shift ? 0.010 : (60 / s.ai.bpm));
    } else if (e.logicalKey == LogicalKeyboardKey.space) {
      unawaited(_togglePlayback(s, n));
    } else if ((HardwareKeyboard.instance.isControlPressed ||
            HardwareKeyboard.instance.isMetaPressed) &&
        e.logicalKey == LogicalKeyboardKey.keyZ) {
      n.undo();
    } else if (e.logicalKey == LogicalKeyboardKey.enter) {
      n.confirmActive();
      _scheduleSavePromptIfNeeded(
        ref.read(replaceEditorProvider(widget.trackId)),
      );
    } else if (_segmentIndexForKey(e.logicalKey) case final index?) {
      n.jumpToSegment(index);
      if (index >= 0 && index < s.ai.segments.length) {
        unawaited(_seekTo(s, n, s.ai.segments[index].start));
      }
    } else if (e.logicalKey == LogicalKeyboardKey.arrowLeft) {
      final step = shift ? -0.001 : -(60 / s.ai.bpm);
      unawaited(_seekTo(s, n, s.playhead + step));
    } else if (e.logicalKey == LogicalKeyboardKey.arrowRight) {
      final step = shift ? 0.001 : (60 / s.ai.bpm);
      unawaited(_seekTo(s, n, s.playhead + step));
    }
  }

  int? _segmentIndexForKey(LogicalKeyboardKey key) {
    const keys = [
      LogicalKeyboardKey.digit1,
      LogicalKeyboardKey.digit2,
      LogicalKeyboardKey.digit3,
      LogicalKeyboardKey.digit4,
      LogicalKeyboardKey.digit5,
      LogicalKeyboardKey.digit6,
      LogicalKeyboardKey.digit7,
      LogicalKeyboardKey.digit8,
      LogicalKeyboardKey.digit9,
    ];
    final index = keys.indexOf(key);
    return index < 0 ? null : index;
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(replaceEditorProvider(widget.trackId));
    final n = ref.read(replaceEditorProvider(widget.trackId).notifier);
    final cli = ref.watch(studioProvider);
    final analysis = _activeAnalysisFor(s, ref.watch(audioAnalysisProvider));
    ref.listen<ReplaceEditorState>(replaceEditorProvider(widget.trackId), (
      previous,
      next,
    ) {
      final wasAllConfirmed =
          previous?.allConfirmed ?? _lastObservedAllConfirmed;
      _lastObservedAllConfirmed = next.allConfirmed;
      if (wasAllConfirmed || !next.allConfirmed) {
        return;
      }
      _scheduleSavePromptIfNeeded(next);
    });
    _lastObservedAllConfirmed = s.allConfirmed;

    return Focus(
      focusNode: _hotkeysFocus,
      autofocus: true,
      onKeyEvent: (_, e) {
        _syncAltHeld();
        _onKey(e);
        return KeyEventResult.handled;
      },
      child: LayoutBuilder(
        builder: (context, viewport) {
          final metrics = _layoutMetrics(viewport.maxWidth);
          final pinSidebar = _canPinSidebar(metrics);
          return Stack(
            key: _editorViewportKey,
            children: [
              _scrollingEditorContent(
                context,
                s,
                n,
                analysis,
                cli: cli,
                metrics: metrics,
                reserveSidebar: pinSidebar,
                viewportHeight: viewport.maxHeight,
              ),
              _TransportFloatingOverlay(
                scrollController: _pageScrollController,
                metrics: _transportDockMetrics,
                pinGap: _EditorLayoutMetrics.verticalGap,
                child: _transportBar(s, n, floating: true),
              ),
              if (!pinSidebar)
                _collapsedSidePanel(
                  context,
                  s,
                  n,
                  analysis,
                  viewport: viewport,
                ),
              Positioned.fill(
                child: _manualRefineOverlay(context, s, n, viewport: viewport),
              ),
            ],
          );
        },
      ),
    );
  }

  AudioAnalysisState? _activeAnalysisFor(
    ReplaceEditorState s,
    AudioAnalysisState analysis,
  ) {
    final path = s.track.source.trim();
    if (path.isEmpty || analysis.path != path) return null;
    return analysis;
  }

  _EditorLayoutMetrics _layoutMetrics(double maxWidth) {
    final pageWidth = math.min(maxWidth, RmTokens.pageWide);
    final horizontalPadding = maxWidth < 900 ? 24.0 : 40.0;
    final innerWidth = math.max(0.0, pageWidth - horizontalPadding * 2);
    final sideWidth = innerWidth >= 1180 ? 340.0 : 312.0;
    return _EditorLayoutMetrics(
      pageWidth: pageWidth,
      horizontalPadding: horizontalPadding,
      innerWidth: innerWidth,
      sideWidth: sideWidth,
    );
  }

  bool _canPinSidebar(_EditorLayoutMetrics metrics) {
    const minMainWidth = 620.0;
    return metrics.innerWidth >=
        minMainWidth + _EditorLayoutMetrics.sideGap + metrics.sideWidth;
  }

  Widget _scrollingEditorContent(
    BuildContext context,
    ReplaceEditorState s,
    ReplaceEditorNotifier n,
    AudioAnalysisState? analysis, {
    required StudioState cli,
    required _EditorLayoutMetrics metrics,
    required bool reserveSidebar,
    required double viewportHeight,
  }) {
    final mainColumn = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        EditorBreadcrumb(
          trackTitle: s.track.title,
          assignedTo: s.track.assignedTo,
          slot: s.track.slot,
        ),
        _pageHead(context, s, n),
        const SizedBox(height: 12),
        TargetSourceCard(
          source: s.track.source,
          sourceSampleRate: s.ai.sourceSampleRate,
          aiPending: s.aiPending,
          peakDbfs: s.ai.peakDbfs,
          rmsDbfs: s.ai.rmsDbfs,
        ),
        if (s.analyzing || s.error != null || s.saved || s.dirty) ...[
          const SizedBox(height: 12),
          _statusBanner(context, s, analysis),
        ],
        const SizedBox(height: 14),
        ProgressStrip(state: s),
        const SizedBox(height: _EditorLayoutMetrics.verticalGap),
        _editorBody(
          context,
          s,
          n,
          analysis,
          reserveSidebar: reserveSidebar,
          sideWidth: metrics.sideWidth,
          viewportHeight: viewportHeight,
        ),
      ],
    );

    return SingleChildScrollView(
      controller: _pageScrollController,
      child: Center(
        child: SizedBox(
          width: metrics.pageWidth,
          key: _scrollContentKey,
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              metrics.horizontalPadding,
              36,
              metrics.horizontalPadding,
              96,
            ),
            child: mainColumn,
          ),
        ),
      ),
    );
  }

  Widget _pageHead(
    BuildContext context,
    ReplaceEditorState s,
    ReplaceEditorNotifier n,
  ) {
    final rm = context.rm;
    final t = s.track;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(t.title, style: RmText.pageH1(color: rm.fg)),
              const SizedBox(height: 6),
              Text(
                '${t.artist} · ${formatTimecode(t.durationSec)} · ${t.bpm} BPM · ${t.key} · 配置 6 个时间点，确认后这首歌即可用于游戏。',
                style: RmText.body(color: rm.fg3),
              ),
            ],
          ),
        ),
        Row(
          children: [
            RmButton(
              onPressed: () =>
                  _saveConfig(context, n, title: s.track.title, export: true),
              leading: const RmIcon('export', size: 12),
              label: '导出此曲配置',
            ),
            const SizedBox(width: 8),
            RmButton(
              onPressed: s.allConfirmed
                  ? () => _saveConfig(context, n, title: s.track.title)
                  : null,
              disabled: !s.allConfirmed,
              variant: RmButtonVariant.primary,
              leading: const RmIcon('check', size: 12),
              label: '标记为已配置',
            ),
          ],
        ),
      ],
    );
  }

  Widget _statusBanner(
    BuildContext context,
    ReplaceEditorState s,
    AudioAnalysisState? analysis,
  ) {
    if (s.error != null) {
      return RmBanner(
        kind: RmBannerKind.danger,
        title: '音频分析失败。',
        body: s.error!,
      );
    }
    if (s.analyzing) {
      final active = analysis?.activeProgressStep;
      return RmBanner(
        kind: RmBannerKind.info,
        title: '正在分析真实音频。',
        body: active == null
            ? '完成后会刷新波形、时长、BPM 和 6 个候选时间点。'
            : '当前：${active.label} · ${analysis!.progressPercent}%。完成后会刷新候选时间点。',
      );
    }
    if (s.dirty) {
      return const RmBanner(
        kind: RmBannerKind.warn,
        title: '有未保存的时间点修改。',
        body: '保存后 Dashboard 构建包会使用这些时间点。',
      );
    }
    return const RmBanner(
      kind: RmBannerKind.info,
      title: '此曲配置已保存。',
      body: '构建电台包时会通过 timing manifest 注入这些 marker。',
    );
  }

  Widget _collapsedSidePanel(
    BuildContext context,
    ReplaceEditorState s,
    ReplaceEditorNotifier n,
    AudioAnalysisState? analysis, {
    required BoxConstraints viewport,
  }) {
    final drawerWidth = math.min(
      360.0,
      math.max(280.0, viewport.maxWidth - 32),
    );
    final railTop = math.min(112.0, math.max(24.0, viewport.maxHeight - 80));

    return Stack(
      children: [
        if (_sideDrawerOpen)
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => _sideDrawerOpen = false),
              child: const SizedBox.expand(),
            ),
          ),
        Positioned(
          right: 16,
          top: railTop,
          child: _SideRailButton(
            open: _sideDrawerOpen,
            onTap: () => setState(() => _sideDrawerOpen = true),
          ),
        ),
        if (_sideDrawerOpen)
          Positioned(
            top: 24,
            right: 16,
            bottom: 24,
            width: drawerWidth,
            child: _FloatingSideDrawer(
              state: s,
              analysis: analysis,
              onClose: () => setState(() => _sideDrawerOpen = false),
              onAnalyze: () => unawaited(n.analyze(force: true)),
            ),
          ),
      ],
    );
  }

  Widget _manualRefineOverlay(
    BuildContext context,
    ReplaceEditorState s,
    ReplaceEditorNotifier n, {
    required BoxConstraints viewport,
  }) {
    final session = _manualSession;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 220),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, animation) {
        final scale = Tween<double>(begin: 0.982, end: 1).animate(animation);
        return FadeTransition(
          opacity: animation,
          child: ScaleTransition(scale: scale, child: child),
        );
      },
      child: session == null
          ? const SizedBox.shrink(key: ValueKey('manual-refine-empty'))
          : _ManualRefineOverlay(
              key: ValueKey('manual-refine-${session.kind.code}'),
              state: _manualPreviewState(s, session),
              session: session,
              viewport: viewport,
              aiCandidates: _aiCandidatesFor(s, session.kind),
              snapActive: !_altHeld,
              onPlace: (seconds, {required isMove}) =>
                  _placeManualDraft(seconds, isMove: isMove),
              onApplyCandidate: _applyAiCandidateToManual,
              onPickTarget: _setManualFineTarget,
              onNudge: _nudgeManualDraftTarget,
              onAudition: () => _previewManualAudition(n),
              onCancel: _cancelManualRefine,
              onConfirm: () => _confirmManualRefine(n),
              onTogglePlay: () => unawaited(
                _togglePlayback(
                  _manualPreviewState(
                    ref.read(replaceEditorProvider(widget.trackId)),
                    _manualSession!,
                  ),
                  n,
                ),
              ),
              onRewind: () => _placeManualDraft(0, snap: false),
              onSkipFwd: () => _placeManualDraft(s.ai.durationSec, snap: false),
            ),
    );
  }

  ReplaceEditorState _manualPreviewState(
    ReplaceEditorState state,
    _ManualRefineSession session,
  ) {
    final focusPlayhead = session.focusTime
        .clamp(0, state.ai.durationSec)
        .toDouble();
    final playbackActive =
        state.playing || state.playbackMode != PlaybackMode.idle;
    final playhead = (playbackActive ? state.playhead : focusPlayhead)
        .clamp(0, state.ai.durationSec)
        .toDouble();
    if (session.kind.isLoop) {
      final candidate = LoopCandidate(
        start: session.start,
        end: session.end,
        score: 1,
        bars: _barsForManual(session.start, session.end, state.ai.bpm),
        why: '人工选点',
      );
      return switch (session.kind) {
        GroupKind.tl => state.copyWith(
          tlManual: candidate,
          tlIdx: state.ai.tl.length,
          tlConfirmed: false,
          activeGroup: session.kind,
          playhead: playhead,
        ),
        GroupKind.pl => state.copyWith(
          plManual: candidate,
          plIdx: state.ai.pl.length,
          plConfirmed: false,
          activeGroup: session.kind,
          playhead: playhead,
        ),
        GroupKind.td || GroupKind.pd => state,
      };
    }
    final candidate = PointCandidate(
      t: session.pointTime,
      score: 1,
      why: '人工选点',
    );
    return switch (session.kind) {
      GroupKind.td => state.copyWith(
        tdManual: candidate,
        tdIdx: state.ai.td.length,
        tdConfirmed: false,
        activeGroup: session.kind,
        playhead: playhead,
      ),
      GroupKind.pd => state.copyWith(
        pdManual: candidate,
        pdIdx: state.ai.pd.length,
        pdConfirmed: false,
        activeGroup: session.kind,
        playhead: playhead,
      ),
      GroupKind.tl || GroupKind.pl => state,
    };
  }

  List<dynamic> _aiCandidatesFor(ReplaceEditorState state, GroupKind kind) {
    return switch (kind) {
      GroupKind.td => state.ai.td,
      GroupKind.pd => state.ai.pd,
      GroupKind.tl => state.ai.tl,
      GroupKind.pl => state.ai.pl,
    };
  }

  void _openManualRefine(
    ReplaceEditorState state,
    ReplaceEditorNotifier notifier,
    GroupKind kind,
  ) {
    if (state.confirmedOf(kind)) return;
    final session = _ManualRefineSession.fromState(state, kind);
    setState(() {
      _manualSession = session;
      _altHeld = HardwareKeyboard.instance.isAltPressed;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _manualSession != session) return;
      unawaited(
        _seekTo(
          ref.read(replaceEditorProvider(widget.trackId)),
          notifier,
          session.focusTime,
        ),
      );
    });
  }

  void _cancelManualRefine() {
    if (_manualSession == null) return;
    final notifier = ref.read(replaceEditorProvider(widget.trackId).notifier);
    _pauseManualRefinePlayback(notifier);
    setState(() => _manualSession = null);
  }

  void _pauseManualRefinePlayback(ReplaceEditorNotifier notifier) {
    final state = ref.read(replaceEditorProvider(widget.trackId));
    final player = _player;
    if (player?.state.playing == true) {
      _pausedByUser = true;
      unawaited(player!.pause());
    }
    notifier.setPlayback(state.playbackMode, playing: false);
  }

  void _previewManualAudition(ReplaceEditorNotifier notifier) {
    final session = _manualSession;
    if (session == null) return;
    final state = _manualPreviewState(
      ref.read(replaceEditorProvider(widget.trackId)),
      session,
    );
    if (session.kind.isLoop) {
      unawaited(_playLoopPreview(state, notifier, session.start, session.end));
    } else {
      unawaited(_playPointPreview(state, notifier, session.pointTime));
    }
  }

  void _confirmManualRefine(ReplaceEditorNotifier notifier) {
    final session = _manualSession;
    if (session == null) return;
    if (session.kind.isLoop) {
      notifier.applyManualLoop(session.kind, session.start, session.end);
    } else {
      notifier.applyManualPoint(session.kind, session.pointTime);
    }
    _pauseManualRefinePlayback(notifier);
    setState(() => _manualSession = null);
    _scheduleSavePromptIfNeeded(
      ref.read(replaceEditorProvider(widget.trackId)),
    );
  }

  void _placeManualDraft(
    double seconds, {
    bool snap = true,
    bool isMove = false,
  }) {
    final session = _manualSession;
    if (session == null) return;
    final state = ref.read(replaceEditorProvider(widget.trackId));
    // 默认磁吸到最近的拍；按住 Alt 时放弃磁吸，自由放置。
    final bypassSnap = HardwareKeyboard.instance.isAltPressed;
    final target = (snap && !bypassSnap)
        ? _snapToBeat(seconds, state.ai.beats)
        : seconds;
    final next = target.clamp(0, state.ai.durationSec).toDouble();
    // 循环组按下时挑离指针更近的端点（A / B），拖动时沿用当前端点。
    var working = session;
    if (session.kind.isLoop && !isMove) {
      final nearEnd =
          (seconds - session.end).abs() < (seconds - session.start).abs();
      working = session.copyWith(
        activeTarget: nearEnd ? FineTarget.loopEnd : FineTarget.loopStart,
      );
    }
    final updated = working.placeAt(next, duration: state.ai.durationSec);
    setState(() => _manualSession = updated);
    unawaited(
      _seekTo(
        state,
        ref.read(replaceEditorProvider(widget.trackId).notifier),
        updated.focusTime,
      ),
    );
  }

  /// 返回离 [seconds] 最近的拍点；没有拍点数据时原样返回。
  static double _snapToBeat(double seconds, List<double> beats) {
    if (beats.isEmpty) return seconds;
    var best = beats.first;
    var bestDist = (best - seconds).abs();
    for (final beat in beats) {
      final dist = (beat - seconds).abs();
      if (dist < bestDist) {
        best = beat;
        bestDist = dist;
      }
    }
    return best;
  }

  void _applyAiCandidateToManual(dynamic candidate) {
    final session = _manualSession;
    if (session == null) return;
    final state = ref.read(replaceEditorProvider(widget.trackId));
    final notifier = ref.read(replaceEditorProvider(widget.trackId).notifier);
    final updated = session.fromCandidate(
      candidate,
      duration: state.ai.durationSec,
    );
    setState(() => _manualSession = updated);
    if (updated.kind.isLoop) {
      if (widget.enableAudio) {
        unawaited(
          _playLoopPreview(state, notifier, updated.start, updated.end),
        );
      } else {
        final auditionStart = loopPreviewAuditionStartForTesting(
          startSec: updated.start,
          endSec: updated.end,
        );
        notifier.setPlayhead(auditionStart);
        notifier.setPlayback(PlaybackMode.loopPreview, playing: true);
      }
      return;
    }
    if (widget.enableAudio) {
      unawaited(_playPointPreview(state, notifier, updated.pointTime));
    } else {
      final window = pointPreviewWindowForTesting(
        timeSec: updated.pointTime,
        durationSec: _previewDuration(
          state,
          updated.pointTime + pointPreviewDurationSec,
        ),
      );
      notifier.setPlayhead(window.start);
      notifier.setPlayback(PlaybackMode.pointPreview, playing: true);
    }
  }

  void _setManualFineTarget(FineTarget target) {
    final session = _manualSession;
    if (session == null) return;
    setState(() => _manualSession = session.copyWith(activeTarget: target));
  }

  void _nudgeManualDraft(double deltaSec) {
    final session = _manualSession;
    if (session == null) return;
    _nudgeManualDraftTarget(session.activeTarget, deltaSec);
  }

  void _nudgeManualDraftTarget(FineTarget target, double deltaSec) {
    final session = _manualSession;
    if (session == null) return;
    final state = ref.read(replaceEditorProvider(widget.trackId));
    final updated = session.nudge(
      target,
      deltaSec,
      duration: state.ai.durationSec,
    );
    setState(() => _manualSession = updated);
    unawaited(
      _seekTo(
        state,
        ref.read(replaceEditorProvider(widget.trackId).notifier),
        updated.focusTime,
      ),
    );
  }

  Widget _editorBody(
    BuildContext context,
    ReplaceEditorState s,
    ReplaceEditorNotifier n,
    AudioAnalysisState? analysis, {
    required bool reserveSidebar,
    required double sideWidth,
    required double viewportHeight,
  }) {
    final main = _editorMain(context, s, n);
    if (!reserveSidebar) return main;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: main),
            const SizedBox(width: _EditorLayoutMetrics.sideGap),
            _StickySidePanel(
              width: sideWidth,
              contentKey: _scrollContentKey,
              pinGap: _EditorLayoutMetrics.verticalGap,
              bottomGap: 24,
              viewportHeight: viewportHeight,
              scrollController: _pageScrollController,
              onExtraExtentChanged: _setSidePanelExtraScroll,
              child: EditorSidePanel(
                state: s,
                analysis: analysis,
                onAnalyze: () => unawaited(n.analyze(force: true)),
              ),
            ),
          ],
        ),
        if (_sidePanelExtraScroll > 0) SizedBox(height: _sidePanelExtraScroll),
      ],
    );
  }

  void _setSidePanelExtraScroll(double value) {
    final oldValue = _sidePanelExtraScroll;
    if ((oldValue - value).abs() < 0.5) return;
    final controller = _pageScrollController;
    final shouldKeepReleasePosition =
        oldValue > 0 &&
        controller.hasClients &&
        controller.position.extentAfter <= math.max(oldValue, value) + 1;
    setState(() => _sidePanelExtraScroll = value);
    if (!shouldKeepReleasePosition) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !controller.hasClients) return;
      final position = controller.position;
      final next = (position.pixels + value - oldValue)
          .clamp(position.minScrollExtent, position.maxScrollExtent)
          .toDouble();
      if ((next - position.pixels).abs() >= 0.5) {
        controller.jumpTo(next);
      }
    });
  }

  void _setTransportDockMetrics(_TransportDockMetrics? value) {
    final current = _transportDockMetrics;
    if (current == null && value == null) return;
    if (current != null && value != null && current.closeTo(value)) return;
    setState(() => _transportDockMetrics = value);
  }

  Widget _editorMain(
    BuildContext context,
    ReplaceEditorState s,
    ReplaceEditorNotifier n,
  ) {
    final tlLow = s.tl.score < 0.5 || s.ai.tl.every((c) => c.score < 0.5);
    final plLow = s.pl.score < 0.5 || s.ai.pl.every((c) => c.score < 0.5);

    return _StickyTransportLayout(
      scrollController: _pageScrollController,
      viewportKey: _editorViewportKey,
      contentKey: _scrollContentKey,
      onMetricsChanged: _setTransportDockMetrics,
      pinGap: _EditorLayoutMetrics.verticalGap,
      before: WaveformCard(
        state: s,
        aiPending: s.aiPending,
        onSeek: (value) => unawaited(_seekTo(s, n, value)),
        onZoomIn: n.zoomIn,
        onZoomOut: n.zoomOut,
      ),
      transport: _transportBar(s, n, floating: false),
      after: [
        if (s.aiPending)
          const RmBanner(
            kind: RmBannerKind.info,
            title: 'AI 候选生成中。',
            body: '下方候选和结构信息会先保持遮罩；播放、暂停和基础定位仍可使用。',
          )
        else
          RmBanner(
            kind: RmBannerKind.warn,
            title: 'AI 全局置信度 ${(s.ai.confidence * 100).round()}%。',
            body: 'TL 与 PL 部分候选低于 50%，已用黄色标记。请逐个使用"试听拼接"功能确认循环点无缝，再点击确认。',
          ),
        const SizedBox(height: 14),
        _group(s, n, GroupKind.td, s.ai.td, false, pending: s.aiPending),
        const SizedBox(height: 14),
        _group(s, n, GroupKind.tl, s.ai.tl, tlLow, pending: s.aiPending),
        const SizedBox(height: 14),
        _group(s, n, GroupKind.pd, s.ai.pd, false, pending: s.aiPending),
        const SizedBox(height: 14),
        _group(s, n, GroupKind.pl, s.ai.pl, plLow, pending: s.aiPending),
      ],
    );
  }

  Widget _transportBar(
    ReplaceEditorState s,
    ReplaceEditorNotifier n, {
    required bool floating,
  }) {
    return TransportBar(
      key: ValueKey(
        floating
            ? 'editor-transport-bar-floating'
            : 'editor-transport-bar-inline',
      ),
      state: s,
      aiPending: s.aiPending,
      floating: floating,
      onTogglePlay: () => unawaited(_togglePlayback(s, n)),
      onRewind: () => unawaited(_seekTo(s, n, 0)),
      onSkipFwd: () => unawaited(_seekTo(s, n, s.ai.durationSec)),
    );
  }

  Widget _group(
    ReplaceEditorState s,
    ReplaceEditorNotifier n,
    GroupKind kind,
    List<dynamic> candidates,
    bool low, {
    required bool pending,
  }) {
    final card = TimeGroupCard(
      kind: kind,
      candidates: candidates,
      selectedIdx: s.selectedIdxOf(kind),
      confirmed: s.confirmedOf(kind),
      lowConfidence: low,
      onSelect: (i) => n.selectCandidate(kind, i),
      manualCandidate: s.manualCandidateOf(kind),
      manualSelected: s.selectedManualOf(kind),
      onManualRefine: () => _openManualRefine(s, n, kind),
      onConfirm: (i) => _confirmGroup(n, kind, i),
      onCancelConfirm: () => n.setConfirmed(kind, false),
      onPreview: (i) => unawaited(
        _previewCandidate(
          ref.read(replaceEditorProvider(widget.trackId)),
          n,
          kind,
          candidates[i],
        ),
      ),
      onNudge: (target, deltaSec) => n.nudge(kind, target, deltaSec),
      bpm: s.ai.bpm,
    );
    return AiPendingGate(
      pending: pending,
      overlayKey: ValueKey('editor-ai-pending-${kind.code.toLowerCase()}'),
      label: '${kind.name} 候选生成中',
      detail: '等待真实时间点与置信度。',
      blockInput: true,
      child: card,
    );
  }

  void _confirmGroup(ReplaceEditorNotifier n, GroupKind kind, int index) {
    n.selectCandidate(kind, index);
    n.setConfirmed(kind, true);
    _scheduleSavePromptIfNeeded(
      ref.read(replaceEditorProvider(widget.trackId)),
    );
  }

  Future<void> _previewCandidate(
    ReplaceEditorState s,
    ReplaceEditorNotifier n,
    GroupKind kind,
    dynamic candidate,
  ) async {
    if (kind.isLoop) {
      final loop = candidate as LoopCandidate;
      await _playLoopPreview(s, n, loop.start, loop.end);
    } else {
      final point = candidate as PointCandidate;
      await _playPointPreview(s, n, point.t);
    }
  }

  Future<void> _ensureAudioLoaded(
    ReplaceEditorState s,
    ReplaceEditorNotifier n, {
    double? initialStartSec,
    bool forceReload = false,
    bool preservePreviewState = false,
  }) async {
    if (!widget.enableAudio) return;
    final source = s.track.source.trim();
    if (source.isEmpty) return;
    if (!forceReload && source == _loadedSource) return;
    final existingLoad = _loadAudioFuture;
    if (existingLoad != null) {
      await existingLoad;
      if (!forceReload && source == _loadedSource) return;
    }
    final loadToken = ++_loadVersion;
    final load = _loadAudio(
      source,
      n,
      loadToken,
      initialStartSec: initialStartSec,
      preservePreviewState: preservePreviewState,
    );
    _loadAudioFuture = load;
    try {
      await load;
    } finally {
      if (identical(_loadAudioFuture, load)) {
        _loadAudioFuture = null;
      }
    }
  }

  Future<void> _loadAudio(
    String source,
    ReplaceEditorNotifier n,
    int loadToken, {
    double? initialStartSec,
    bool preservePreviewState = false,
  }) async {
    final player = _audioPlayer;
    try {
      _loadedSource = null;
      await player.stop();
      // Let media_kit/mpv apply the preview start during media load so the
      // first decoded audio frame comes from the audition target.
      final media = Media(
        Uri.file(source).toString(),
        start: initialStartSec == null ? null : _duration(initialStartSec),
      );
      await player.open(media, play: false);
      if (loadToken != _loadVersion) return;
      _loadedSource = source;
      _pausedByUser = false;
      _rangeSeeking = false;
      if (!preservePreviewState) {
        _previewRange = null;
      }
      n.setError(null);
    } on Object catch (error) {
      if (loadToken != _loadVersion) return;
      n.setPlayback(PlaybackMode.idle, playing: false);
      n.setError('内置播放器无法打开源音频：$error');
    }
  }

  int _beginPlaybackCommand() => ++_playbackVersion;

  bool _isCurrentPlaybackCommand(int token) {
    return mounted && token == _playbackVersion;
  }

  void _clearLocalPlaybackState() {
    _playbackVersion++;
    _loadVersion++;
    _loadedSource = null;
    _loadAudioFuture = null;
    _pausedByUser = false;
    _rangeSeeking = false;
    _previewRange = null;
    _clearPreviewPositionHold();
  }

  void _startInitialAnalysis() {
    final s = ref.read(replaceEditorProvider(widget.trackId));
    if (!s.track.id.startsWith('real:') || !s.analyzing) return;
    if (_analysisStartedFor == s.track.id) return;
    _analysisStartedFor = s.track.id;
    final n = ref.read(replaceEditorProvider(widget.trackId).notifier);
    unawaited(n.analyze());
  }

  Future<void> _togglePlayback(
    ReplaceEditorState s,
    ReplaceEditorNotifier n,
  ) async {
    if (!widget.enableAudio) return;
    final command = _beginPlaybackCommand();
    await _ensureAudioLoaded(s, n);
    if (!_isCurrentPlaybackCommand(command) || _loadedSource == null) return;
    final player = _audioPlayer;
    final activePlayback = player.state.playing && !player.state.completed;
    if (activePlayback) {
      await player.pause();
      if (!_isCurrentPlaybackCommand(command)) return;
      _pausedByUser = true;
      n.setPlayback(
        s.playbackMode == PlaybackMode.idle
            ? PlaybackMode.full
            : s.playbackMode,
        playing: false,
      );
      return;
    }
    if (_pausedByUser) {
      _pausedByUser = false;
      await player.play();
      if (!_isCurrentPlaybackCommand(command)) return;
      n.setPlayback(
        s.playbackMode == PlaybackMode.idle
            ? PlaybackMode.full
            : s.playbackMode,
        playing: true,
      );
      return;
    }
    _previewRange = null;
    _rangeSeeking = false;
    final restartAtEnd = s.playhead >= s.ai.durationSec - 0.05;
    await player.seek(_duration(restartAtEnd ? 0 : s.playhead));
    if (!_isCurrentPlaybackCommand(command)) return;
    await player.play();
    if (!_isCurrentPlaybackCommand(command)) return;
    n.setPlayback(PlaybackMode.full, playing: true);
  }

  Future<void> _seekTo(
    ReplaceEditorState s,
    ReplaceEditorNotifier n,
    double seconds,
  ) async {
    final command = _beginPlaybackCommand();
    final next = seconds.clamp(0, s.ai.durationSec).toDouble();
    n.setPlayhead(next);
    _previewRange = null;
    _rangeSeeking = false;
    final player = _player;
    final playing = player?.state.playing ?? false;
    n.setPlayback(
      playing ? PlaybackMode.full : PlaybackMode.idle,
      playing: playing,
    );
    if (_loadedSource == null ||
        !_isCurrentPlaybackCommand(command) ||
        player == null) {
      return;
    }
    await player.seek(_duration(next));
  }

  Future<void> _playPointPreview(
    ReplaceEditorState s,
    ReplaceEditorNotifier n,
    double timeSec,
  ) async {
    if (!widget.enableAudio) return;
    final command = _beginPlaybackCommand();
    final window = pointPreviewWindowForTesting(
      timeSec: timeSec,
      durationSec: _previewDuration(s, timeSec + pointPreviewDurationSec),
    );
    final start = window.start;
    final end = window.end;
    _preparePreviewStartup(
      command,
      n,
      range: _PreviewRange(start: start, end: end, loop: false),
      playhead: start,
    );
    await _ensureAudioLoaded(
      s,
      n,
      initialStartSec: start,
      forceReload: true,
      preservePreviewState: true,
    );
    final player = _player;
    if (!_isCurrentPlaybackCommand(command) ||
        _loadedSource == null ||
        player == null) {
      _cancelPreviewStartup(command);
      return;
    }
    if (!await _startPreviewPlayback(
      command,
      player,
      start,
      sourceOpenedAtTarget: true,
    )) {
      return;
    }
    n.setPlayback(PlaybackMode.pointPreview, playing: true);
  }

  Future<void> _playLoopPreview(
    ReplaceEditorState s,
    ReplaceEditorNotifier n,
    double startSec,
    double endSec,
  ) async {
    if (!widget.enableAudio) return;
    final command = _beginPlaybackCommand();
    final duration = _previewDuration(s, math.max(startSec, endSec));
    final start = startSec.clamp(0, duration).toDouble();
    final end = endSec.clamp(start + 0.1, duration).toDouble();
    final auditionStart = loopPreviewAuditionStartForTesting(
      startSec: start,
      endSec: end,
    );
    _preparePreviewStartup(
      command,
      n,
      range: _PreviewRange(start: start, end: end, loop: true),
      playhead: auditionStart,
    );
    await _ensureAudioLoaded(
      s,
      n,
      initialStartSec: auditionStart,
      forceReload: true,
      preservePreviewState: true,
    );
    final player = _player;
    if (!_isCurrentPlaybackCommand(command) ||
        _loadedSource == null ||
        player == null) {
      _cancelPreviewStartup(command);
      return;
    }
    if (!await _startPreviewPlayback(
      command,
      player,
      auditionStart,
      sourceOpenedAtTarget: true,
    )) {
      return;
    }
    n.setPlayback(PlaybackMode.loopPreview, playing: true);
  }

  double _previewDuration(ReplaceEditorState s, double minimum) {
    final trackDuration = s.track.durationSec;
    return math.max(math.max(s.ai.durationSec, trackDuration), minimum);
  }

  Future<bool> _startPreviewPlayback(
    int command,
    Player player,
    double seconds, {
    bool sourceOpenedAtTarget = false,
  }) async {
    final target = _duration(seconds);
    _holdPreviewPosition(command, seconds);
    if (!sourceOpenedAtTarget) {
      await player.pause();
      if (!_isCurrentPlaybackCommand(command)) return false;
      await player.seek(target);
      if (!_isCurrentPlaybackCommand(command)) return false;
      await Future<void>.delayed(Duration.zero);
      if (!_isCurrentPlaybackCommand(command)) return false;
    }
    await player.play();
    if (!_isCurrentPlaybackCommand(command)) return false;
    if (!sourceOpenedAtTarget) {
      await player.seek(target);
    }
    return _isCurrentPlaybackCommand(command);
  }

  void _handlePosition(Duration position) {
    if (!mounted) return;
    final n = ref.read(replaceEditorProvider(widget.trackId).notifier);
    final seconds = position.inMilliseconds / 1000.0;
    if (_ignoreStalePreviewPosition(seconds)) return;
    final range = _previewRange;
    final player = _player;
    if (range != null && player?.state.playing != true) {
      n.setPlayhead(seconds);
      return;
    }
    if (range == null || _rangeSeeking || seconds < range.end) {
      n.setPlayhead(seconds);
      return;
    }

    if (range.loop) {
      _rangeSeeking = true;
      n.setPlayhead(range.start);
      final command = _playbackVersion;
      _holdPreviewPosition(command, range.start);
      final seek = player?.seek(_duration(range.start));
      if (seek == null) {
        _rangeSeeking = false;
      } else {
        unawaited(
          seek.whenComplete(() {
            if (command == _playbackVersion) {
              _rangeSeeking = false;
            }
          }),
        );
      }
      return;
    }

    _previewRange = null;
    _pausedByUser = false;
    n.setPlayhead(range.end);
    n.setPlayback(PlaybackMode.idle, playing: false);
    if (player != null) {
      unawaited(player.pause());
    }
  }

  void _preparePreviewStartup(
    int command,
    ReplaceEditorNotifier n, {
    required _PreviewRange range,
    required double playhead,
  }) {
    _previewRange = range;
    _rangeSeeking = false;
    _pausedByUser = false;
    _holdPreviewPosition(command, playhead);
    n.setPlayhead(playhead);
  }

  void _cancelPreviewStartup(int command) {
    _clearPreviewPositionHold(command);
    if (_playbackVersion != command) return;
    _previewRange = null;
    _rangeSeeking = false;
    _pausedByUser = false;
  }

  void _holdPreviewPosition(int command, double targetSec) {
    _positionHoldTimer?.cancel();
    _positionHoldCommand = command;
    _positionHoldTargetSec = targetSec;
    _positionHoldTimer = Timer(previewSeekPositionHold, () {
      if (!mounted) return;
      _clearPreviewPositionHold(command);
    });
  }

  void _clearPreviewPositionHold([int? command]) {
    if (command != null && _positionHoldCommand != command) return;
    _positionHoldTimer?.cancel();
    _positionHoldTimer = null;
    _positionHoldCommand = null;
    _positionHoldTargetSec = null;
  }

  bool _ignoreStalePreviewPosition(double seconds) {
    final command = _positionHoldCommand;
    final target = _positionHoldTargetSec;
    if (command == null || target == null) return false;
    if (command != _playbackVersion) {
      _clearPreviewPositionHold();
      return false;
    }
    if (!_isStalePreviewStartupPosition(seconds, target)) {
      _clearPreviewPositionHold(command);
      return false;
    }
    return true;
  }

  Duration _duration(double seconds) {
    return Duration(milliseconds: (seconds * 1000).round());
  }

  void _saveConfig(
    BuildContext context,
    ReplaceEditorNotifier n, {
    required String title,
    bool export = false,
  }) {
    n.saveToProject();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(export ? '已导出配置：$title' : '已保存配置：$title')),
    );
  }

  void _scheduleSavePromptIfNeeded(ReplaceEditorState state) {
    if (!state.allConfirmed) return;
    if (_savePromptOpen || _matchesSavedTimingConfig(state)) return;
    _savePromptOpen = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) {
        _savePromptOpen = false;
        return;
      }
      final save = await _showSaveConfigDialog(context, state);
      _savePromptOpen = false;
      if (!mounted || save != true) return;
      final current = ref.read(replaceEditorProvider(widget.trackId));
      if (_matchesSavedTimingConfig(current)) return;
      _saveConfig(
        context,
        ref.read(replaceEditorProvider(widget.trackId).notifier),
        title: current.track.title,
      );
    });
  }

  bool _matchesSavedTimingConfig(ReplaceEditorState state) {
    final saved = ref
        .read(trackTimingProvider.notifier)
        .configForPath(state.track.source);
    if (saved == null || !saved.allConfirmed) return false;
    for (final key in trackMarkerKeys) {
      final current = state.markerSeconds[key];
      final stored = saved.markersSec[key];
      if (current == null || stored == null) return false;
      if ((current - stored).abs() > 0.001) return false;
    }
    for (final key in trackGroupKeys) {
      if (state.confirmedGroups[key] != saved.confirmed[key]) return false;
    }
    return true;
  }

  Future<bool?> _showSaveConfigDialog(
    BuildContext context,
    ReplaceEditorState state,
  ) {
    return showDialog<bool>(
      context: context,
      barrierColor: RmTokens.modalBackdrop,
      builder: (context) {
        final rm = context.rm;
        return Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.all(40),
          child: Container(
            width: 520,
            decoration: BoxDecoration(
              color: rm.panel,
              border: Border.all(color: rm.borderStrong),
              borderRadius: BorderRadius.circular(RmTokens.rXl),
              boxShadow: RmTokens.modal,
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 22, 24, 18),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 34,
                        height: 34,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: rm.accent.bg,
                          border: Border.all(color: rm.accent.ring),
                          borderRadius: BorderRadius.circular(RmTokens.rMd),
                        ),
                        child: RmIcon('check', size: 17, color: rm.accent.base),
                      ),
                      const SizedBox(width: 13),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '时间点已全部确认',
                              style: RmText.microLabel(color: rm.accent.base),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              '保存这首歌的配置？',
                              style: RmText.modalH2(color: rm.fg),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              '${state.track.title} 的 4 组时间点已经确认，当前配置还没有保存到项目，或与已保存配置不同。',
                              style: RmText.sans(
                                13,
                                color: rm.fg3,
                                height: 1.45,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.fromLTRB(24, 14, 24, 22),
                  decoration: BoxDecoration(
                    border: Border(top: BorderSide(color: rm.border)),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      RmButton(
                        onPressed: () => Navigator.of(context).pop(false),
                        label: '暂不保存',
                      ),
                      const SizedBox(width: 10),
                      RmButton(
                        onPressed: () => Navigator.of(context).pop(true),
                        variant: RmButtonVariant.primary,
                        leading: const RmIcon('check', size: 12),
                        label: '保存配置',
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _EditorLayoutMetrics {
  const _EditorLayoutMetrics({
    required this.pageWidth,
    required this.horizontalPadding,
    required this.innerWidth,
    required this.sideWidth,
  });

  static const sideGap = 14.0;
  static const verticalGap = 14.0;

  final double pageWidth;
  final double horizontalPadding;
  final double innerWidth;
  final double sideWidth;
}

class _StickyTransportLayout extends StatefulWidget {
  const _StickyTransportLayout({
    required this.scrollController,
    required this.viewportKey,
    required this.contentKey,
    required this.onMetricsChanged,
    required this.pinGap,
    required this.before,
    required this.transport,
    required this.after,
  });

  final ScrollController scrollController;
  final GlobalKey viewportKey;
  final GlobalKey contentKey;
  final ValueChanged<_TransportDockMetrics?> onMetricsChanged;
  final double pinGap;
  final Widget before;
  final Widget transport;
  final List<Widget> after;

  @override
  State<_StickyTransportLayout> createState() => _StickyTransportLayoutState();
}

class _StickyTransportLayoutState extends State<_StickyTransportLayout> {
  final _anchorKey = GlobalKey();
  double? _anchorContentTop;
  bool _measureScheduled = false;

  @override
  void initState() {
    super.initState();
    _scheduleMeasure();
  }

  @override
  void didUpdateWidget(covariant _StickyTransportLayout oldWidget) {
    super.didUpdateWidget(oldWidget);
    _scheduleMeasure();
  }

  @override
  void dispose() {
    widget.onMetricsChanged(null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _scheduleMeasure();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        widget.before,
        SizedBox(height: widget.pinGap),
        KeyedSubtree(
          key: _anchorKey,
          child: AnimatedBuilder(
            animation: widget.scrollController,
            child: widget.transport,
            builder: (context, child) {
              final pinned = _isPinned();
              return IgnorePointer(
                ignoring: pinned,
                child: Opacity(opacity: pinned ? 0 : 1, child: child),
              );
            },
          ),
        ),
        SizedBox(height: widget.pinGap),
        ...widget.after,
      ],
    );
  }

  bool _isPinned() {
    final anchorTop = _anchorContentTop;
    return anchorTop != null &&
        widget.scrollController.hasClients &&
        widget.scrollController.position.pixels + widget.pinGap >= anchorTop;
  }

  void _scheduleMeasure() {
    if (_measureScheduled) return;
    _measureScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _measureScheduled = false;
      _measureAnchors();
    });
  }

  void _measureAnchors() {
    if (!mounted) return;
    final contentBox =
        widget.contentKey.currentContext?.findRenderObject() as RenderBox?;
    final viewportBox =
        widget.viewportKey.currentContext?.findRenderObject() as RenderBox?;
    final box = _anchorKey.currentContext?.findRenderObject() as RenderBox?;
    if (contentBox == null ||
        viewportBox == null ||
        box == null ||
        !contentBox.attached ||
        !viewportBox.attached ||
        !box.attached ||
        !contentBox.hasSize ||
        !viewportBox.hasSize ||
        !box.hasSize) {
      widget.onMetricsChanged(null);
      return;
    }

    final anchorGlobal = box.localToGlobal(Offset.zero);
    final anchorTop = contentBox.globalToLocal(anchorGlobal).dy;
    final next = _TransportDockMetrics(
      anchorContentTop: anchorTop,
      viewportLeft: viewportBox.globalToLocal(anchorGlobal).dx,
      width: box.size.width,
    );
    if (_anchorContentTop == null ||
        (_anchorContentTop! - anchorTop).abs() >= 0.5) {
      setState(() => _anchorContentTop = anchorTop);
    }
    widget.onMetricsChanged(next);
  }
}

class _TransportFloatingOverlay extends StatelessWidget {
  const _TransportFloatingOverlay({
    required this.scrollController,
    required this.metrics,
    required this.pinGap,
    required this.child,
  });

  final ScrollController scrollController;
  final _TransportDockMetrics? metrics;
  final double pinGap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: scrollController,
      child: child,
      builder: (context, child) {
        final m = metrics;
        final pinned =
            m != null &&
            scrollController.hasClients &&
            scrollController.position.pixels + pinGap >= m.anchorContentTop;
        if (!pinned) return const SizedBox.shrink();
        return Positioned(
          top: pinGap,
          left: m.viewportLeft,
          width: m.width,
          child: child ?? const SizedBox.shrink(),
        );
      },
    );
  }
}

class _TransportDockMetrics {
  const _TransportDockMetrics({
    required this.anchorContentTop,
    required this.viewportLeft,
    required this.width,
  });

  final double anchorContentTop;
  final double viewportLeft;
  final double width;

  bool closeTo(_TransportDockMetrics other) {
    return (anchorContentTop - other.anchorContentTop).abs() < 0.5 &&
        (viewportLeft - other.viewportLeft).abs() < 0.5 &&
        (width - other.width).abs() < 0.5;
  }
}

class _StickySidePanel extends StatefulWidget {
  const _StickySidePanel({
    required this.width,
    required this.contentKey,
    required this.pinGap,
    required this.bottomGap,
    required this.viewportHeight,
    required this.scrollController,
    required this.onExtraExtentChanged,
    required this.child,
  });

  final double width;
  final GlobalKey contentKey;
  final double pinGap;
  final double bottomGap;
  final double viewportHeight;
  final ScrollController scrollController;
  final ValueChanged<double> onExtraExtentChanged;
  final Widget child;

  @override
  State<_StickySidePanel> createState() => _StickySidePanelState();
}

class _StickySidePanelState extends State<_StickySidePanel> {
  final _anchorKey = GlobalKey();
  final _childKey = GlobalKey();
  double _extraExtent = 0;
  double? _anchorContentTop;
  bool _measureScheduled = false;

  @override
  void initState() {
    super.initState();
    _scheduleMeasure();
  }

  @override
  void didUpdateWidget(covariant _StickySidePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    _scheduleMeasure();
  }

  @override
  Widget build(BuildContext context) {
    if (_anchorContentTop == null) {
      _scheduleMeasure();
    }
    return SizedBox(
      key: _anchorKey,
      width: widget.width,
      child: AnimatedBuilder(
        animation: widget.scrollController,
        child: KeyedSubtree(key: _childKey, child: widget.child),
        builder: (context, child) {
          final offset = _stickyOffset();
          return Transform.translate(offset: Offset(0, offset), child: child);
        },
      ),
    );
  }

  void _scheduleMeasure() {
    if (_measureScheduled) return;
    _measureScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _measureScheduled = false;
      _measureLayout();
    });
  }

  void _measureLayout() {
    if (!mounted) return;
    final childBox = _childKey.currentContext?.findRenderObject() as RenderBox?;
    final anchorTop = _topInScrollContent(_anchorKey);
    final availableHeight = math.max(
      0.0,
      widget.viewportHeight - widget.pinGap - widget.bottomGap,
    );
    final nextExtra =
        childBox == null || !childBox.attached || !childBox.hasSize
        ? _extraExtent
        : math.max(0.0, childBox.size.height - availableHeight);
    final extraChanged = (_extraExtent - nextExtra).abs() >= 0.5;
    final anchorChanged =
        anchorTop != null &&
        (_anchorContentTop == null ||
            (_anchorContentTop! - anchorTop).abs() >= 0.5);
    if (!extraChanged && !anchorChanged) return;
    setState(() {
      _extraExtent = nextExtra;
      if (anchorTop != null) _anchorContentTop = anchorTop;
    });
    if (extraChanged) widget.onExtraExtentChanged(nextExtra);
  }

  double _stickyOffset() {
    final anchorTop = _anchorContentTop;
    if (anchorTop == null || !widget.scrollController.hasClients) return 0;
    final pinTop = widget.scrollController.position.pixels + widget.pinGap;
    final release = _releaseDistance();
    return math.max(0.0, pinTop - release - anchorTop);
  }

  double? _topInScrollContent(GlobalKey key) {
    final contentBox =
        widget.contentKey.currentContext?.findRenderObject() as RenderBox?;
    final box = key.currentContext?.findRenderObject() as RenderBox?;
    if (contentBox == null ||
        box == null ||
        !contentBox.attached ||
        !box.attached ||
        !contentBox.hasSize ||
        !box.hasSize) {
      return null;
    }
    return contentBox.globalToLocal(box.localToGlobal(Offset.zero)).dy;
  }

  double _releaseDistance() {
    final controller = widget.scrollController;
    if (!controller.hasClients || _extraExtent <= 0) return 0;
    final extentAfter = controller.position.extentAfter;
    return (_extraExtent - extentAfter).clamp(0.0, _extraExtent).toDouble();
  }
}

class _SideRailButton extends StatelessWidget {
  const _SideRailButton({required this.open, required this.onTap});

  final bool open;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: rm.panel,
            border: Border.all(color: open ? rm.accent.ring : rm.border),
            borderRadius: BorderRadius.circular(999),
            boxShadow: RmTokens.popover,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: rm.accent.base,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                'AI / 快捷键',
                style: RmText.sans(12, weight: FontWeight.w600, color: rm.fg),
              ),
              const SizedBox(width: 6),
              RmIcon('arrow-right', size: 13, color: rm.fg3),
            ],
          ),
        ),
      ),
    );
  }
}

class _FloatingSideDrawer extends StatelessWidget {
  const _FloatingSideDrawer({
    required this.state,
    required this.analysis,
    required this.onClose,
    required this.onAnalyze,
  });

  final ReplaceEditorState state;
  final AudioAnalysisState? analysis;
  final VoidCallback onClose;
  final VoidCallback onAnalyze;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(RmTokens.rLg);
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned.fill(
          child: ClipRRect(
            key: const ValueKey('editor-side-drawer-clip'),
            borderRadius: radius,
            child: SingleChildScrollView(
              child: EditorSidePanel(
                state: state,
                analysis: analysis,
                onAnalyze: onAnalyze,
              ),
            ),
          ),
        ),
        Positioned(
          top: -8,
          right: -8,
          child: RmButton.icon(
            onPressed: onClose,
            icon: const RmIcon('x', size: 12),
            variant: RmButtonVariant.defaultBtn,
            tooltip: '收起',
          ),
        ),
      ],
    );
  }
}

class _ManualRefineWideBody extends StatefulWidget {
  const _ManualRefineWideBody({
    required this.main,
    required this.aiPanelBuilder,
  });

  final Widget main;
  final Widget Function(double height) aiPanelBuilder;

  @override
  State<_ManualRefineWideBody> createState() => _ManualRefineWideBodyState();
}

class _ManualRefineWideBodyState extends State<_ManualRefineWideBody> {
  final _mainKey = GlobalKey();
  double? _mainHeight;

  @override
  void initState() {
    super.initState();
    _measureAfterFrame();
  }

  @override
  void didUpdateWidget(covariant _ManualRefineWideBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    _measureAfterFrame();
  }

  void _measureAfterFrame() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final renderObject = _mainKey.currentContext?.findRenderObject();
      if (renderObject is! RenderBox || !renderObject.hasSize) return;
      final next = renderObject.size.height;
      if ((_mainHeight == null || (next - _mainHeight!).abs() > 0.5) &&
          next > 0) {
        setState(() => _mainHeight = next);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    _measureAfterFrame();
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: KeyedSubtree(key: _mainKey, child: widget.main),
        ),
        const SizedBox(width: 12),
        widget.aiPanelBuilder(_mainHeight ?? 420),
      ],
    );
  }
}

class _ManualRefineOverlay extends StatelessWidget {
  const _ManualRefineOverlay({
    super.key,
    required this.state,
    required this.session,
    required this.viewport,
    required this.aiCandidates,
    required this.snapActive,
    required this.onPlace,
    required this.onApplyCandidate,
    required this.onPickTarget,
    required this.onNudge,
    required this.onAudition,
    required this.onCancel,
    required this.onConfirm,
    required this.onTogglePlay,
    required this.onRewind,
    required this.onSkipFwd,
  });

  final ReplaceEditorState state;
  final _ManualRefineSession session;
  final BoxConstraints viewport;
  final List<dynamic> aiCandidates;

  /// 磁吸到拍是否生效（按住 Alt 时为 false）。
  final bool snapActive;
  final void Function(double seconds, {required bool isMove}) onPlace;
  final ValueChanged<dynamic> onApplyCandidate;
  final ValueChanged<FineTarget> onPickTarget;
  final void Function(FineTarget target, double deltaSec) onNudge;
  final VoidCallback onAudition;
  final VoidCallback onCancel;
  final VoidCallback onConfirm;
  final VoidCallback onTogglePlay;
  final VoidCallback onRewind;
  final VoidCallback onSkipFwd;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    final width = math.min(1080.0, math.max(0.0, viewport.maxWidth - 48));
    final height = math.min(680.0, math.max(0.0, viewport.maxHeight - 48));
    final compact = width < 860;

    return Stack(
      key: const ValueKey('manual-refine-overlay'),
      children: [
        // 背景虚化 + 冷色压暗遮罩：精修台浮到屏幕中央，背后的编辑器被模糊压暗。
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onCancel,
            child: BackdropFilter(
              filter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
              child: const ColoredBox(color: RmTokens.modalBackdrop),
            ),
          ),
        ),
        Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: width, maxHeight: height),
            child: GestureDetector(
              onTap: () {},
              child: Container(
                decoration: BoxDecoration(
                  color: rm.panel,
                  border: Border.all(color: rm.borderStrong),
                  borderRadius: BorderRadius.circular(RmTokens.rXl),
                  boxShadow: RmTokens.modal,
                ),
                clipBehavior: Clip.antiAlias,
                // 高度跟随内容（最高到 maxHeight），不再撑满留出大片空白。
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _header(context),
                    Flexible(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: compact
                            ? _compactBody(context)
                            : _wideBody(context),
                      ),
                    ),
                    _footer(context),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _header(BuildContext context) {
    final rm = context.rm;
    final acc = groupAccent(rm, session.kind);
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 13, 14, 12),
      decoration: BoxDecoration(
        color: rm.panel,
        border: Border(bottom: BorderSide(color: rm.border)),
      ),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: acc.bg,
              border: Border.all(color: acc.ring),
              borderRadius: BorderRadius.circular(RmTokens.rMd),
            ),
            child: Text(
              session.kind.code,
              style: RmText.mono(12, weight: FontWeight.w700, color: acc.base),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${session.kind.name} · 人工精修',
                  style: RmText.sans(17, weight: FontWeight.w700, color: rm.fg),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 3),
                Text(
                  session.kind.isLoop
                      ? '点波形放置 A / B 两个循环端点，确认后锁定当前时间组。'
                      : '点波形放置播放起点，确认后锁定当前时间组。',
                  style: RmText.sans(12.5, color: rm.fg3),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          _statusPill(context),
          const SizedBox(width: 10),
          RmButton.icon(
            onPressed: onCancel,
            icon: const RmIcon('x', size: 13),
            tooltip: '取消人工选点',
          ),
        ],
      ),
    );
  }

  Widget _wideBody(BuildContext context) {
    // 左侧自然高度决定右侧 AI panel 高度：少候选时撑满，多候选时内部滚动。
    return SingleChildScrollView(
      child: _ManualRefineWideBody(
        main: _mainEditor(context, scrollable: false),
        aiPanelBuilder: (height) =>
            SizedBox(width: 300, height: height, child: _aiApplyPanel(context)),
      ),
    );
  }

  Widget _compactBody(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _mainEditor(context, scrollable: false),
          const SizedBox(height: 12),
          SizedBox(height: 260, child: _aiApplyPanel(context)),
        ],
      ),
    );
  }

  Widget _mainEditor(BuildContext context, {bool scrollable = true}) {
    final content = Column(
      key: const ValueKey('manual-refine-main-editor'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _focusWaveform(context),
        const SizedBox(height: 10),
        TransportBar(
          state: state,
          aiPending: false,
          onTogglePlay: onTogglePlay,
          onRewind: onRewind,
          onSkipFwd: onSkipFwd,
          compact: true,
          trailing: _transportTrailing(context),
        ),
        const SizedBox(height: 10),
        _finePanel(context),
      ],
    );
    if (!scrollable) return content;
    return SingleChildScrollView(child: content);
  }

  /// 精修台主波形 —— 直接点 / 拖放置当前时间组的端点。
  Widget _focusWaveform(BuildContext context) {
    final rm = context.rm;
    final acc = groupAccent(rm, session.kind);
    final ai = state.ai;
    final bars = ai.waveformPeaks.isEmpty
        ? WaveformBars.build(segments: ai.segments, duration: ai.durationSec)
        : WaveformBars.fromValues(ai.waveformPeaks);

    final List<FocusHandle> handles;
    if (session.kind.isLoop) {
      final editingEnd = session.activeTarget == FineTarget.loopEnd;
      handles = [
        FocusHandle(
          key: 'a',
          t: session.start,
          label: '${session.kind.code}·A',
          active: !editingEnd,
          dim: editingEnd,
        ),
        FocusHandle(
          key: 'b',
          t: session.end,
          label: '${session.kind.code}·B',
          active: editingEnd,
          dim: !editingEnd,
        ),
      ];
    } else {
      handles = [
        FocusHandle(
          key: 't',
          t: session.pointTime,
          label: session.kind.code,
          active: true,
        ),
      ];
    }

    return Container(
      decoration: BoxDecoration(
        color: rm.panel,
        border: Border.all(color: rm.border),
        borderRadius: BorderRadius.circular(RmTokens.rLg),
      ),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
      child: ManualFocusWaveform(
        bars: bars,
        beats: ai.beats,
        segments: ai.segments,
        duration: ai.durationSec,
        accent: acc.base,
        handles: handles,
        free: !snapActive,
        locked: false,
        playhead: state.playing || state.playbackMode != PlaybackMode.idle
            ? state.playhead
            : null,
        onPlace: onPlace,
      ),
    );
  }

  Widget _transportTrailing(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _manualAuditionButton(context),
        if (session.kind.isLoop) ...[
          const SizedBox(width: 8),
          _endpointToggle(context),
        ],
      ],
    );
  }

  Widget _manualAuditionButton(BuildContext context) {
    final isLoop = session.kind.isLoop;
    final activeMode = isLoop
        ? PlaybackMode.loopPreview
        : PlaybackMode.pointPreview;
    final previewActive = state.playbackMode == activeMode;
    final previewPlaying = previewActive && state.playing;
    return RmButton(
      key: ValueKey(
        isLoop ? 'manual-refine-loop-preview' : 'manual-refine-point-preview',
      ),
      onPressed: previewActive ? onTogglePlay : onAudition,
      size: RmButtonSize.sm,
      leading: RmIcon(
        previewPlaying
            ? 'pause'
            : isLoop
            ? 'loop'
            : 'play',
        size: 12,
      ),
      label: previewPlaying
          ? '暂停试听'
          : previewActive
          ? '继续试听'
          : isLoop
          ? '试听拼接'
          : '试听',
    );
  }

  /// A/B 端点切换，放在传输条行尾，对应当前正在放置的循环端点。
  Widget _endpointToggle(BuildContext context) {
    final rm = context.rm;
    final acc = groupAccent(rm, session.kind);
    Widget seg(String label, FineTarget target) {
      final on = session.activeTarget == target;
      return GestureDetector(
        onTap: () => onPickTarget(target),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
          decoration: BoxDecoration(
            color: on ? acc.base : Colors.transparent,
            borderRadius: BorderRadius.circular(5),
          ),
          child: Text(
            label,
            style: RmText.mono(
              11,
              weight: FontWeight.w700,
              color: on ? Colors.white : rm.fg3,
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: rm.raised,
        border: Border.all(color: rm.border),
        borderRadius: BorderRadius.circular(RmTokens.rSm),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          seg('端点 A', FineTarget.loopStart),
          seg('端点 B', FineTarget.loopEnd),
        ],
      ),
    );
  }

  Widget _finePanel(BuildContext context) {
    final rm = context.rm;
    return Container(
      key: const ValueKey('manual-refine-fine-panel'),
      decoration: BoxDecoration(
        color: rm.panel,
        border: Border.all(color: rm.border),
        borderRadius: BorderRadius.circular(RmTokens.rLg),
      ),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          children: [
            if (session.kind.isLoop) ...[
              _fineRow(
                context,
                label: 'A · start',
                value: session.start,
                target: FineTarget.loopStart,
                active: session.activeTarget == FineTarget.loopStart,
              ),
              const SizedBox(height: 8),
              _fineRow(
                context,
                label: 'B · end',
                value: session.end,
                target: FineTarget.loopEnd,
                active: session.activeTarget == FineTarget.loopEnd,
              ),
            ] else
              _fineRow(
                context,
                label: '播放起点',
                value: session.pointTime,
                target: FineTarget.point,
                active: true,
              ),
            const SizedBox(height: 8),
            _metaRow(context),
          ],
        ),
      ),
    );
  }

  Widget _fineRow(
    BuildContext context, {
    required String label,
    required double value,
    required FineTarget target,
    required bool active,
  }) {
    final rm = context.rm;
    final acc = groupAccent(rm, session.kind);
    final beat = state.ai.bpm <= 0 ? 0.5 : 60 / state.ai.bpm;
    final sampleRate = session.kind.sampleRate;
    return MouseRegion(
      cursor: session.kind.isLoop
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      child: GestureDetector(
        onTap: session.kind.isLoop ? () => onPickTarget(target) : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: active ? acc.bg : rm.raised,
            border: Border.all(color: active ? acc.base : rm.border),
            borderRadius: BorderRadius.circular(RmTokens.rSm),
          ),
          // 单行：标签在左 · 大时间码居中 · 微调按钮成组靠右。
          child: Row(
            children: [
              SizedBox(width: 104, child: _fineLabel(context, label, active)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      formatTimecode(value),
                      style: RmText.mono(
                        22,
                        weight: FontWeight.w700,
                        color: rm.fg,
                      ),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      '= ${formatSamples(value, sampleRate)} samples',
                      style: RmText.mono(11, color: rm.fg4),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              _nudgePair(context, target, beat, '−拍', '+拍', beatUnit: true),
              const SizedBox(width: 8),
              _nudgePair(context, target, 0.010, '−10', '+10', beatUnit: false),
            ],
          ),
        ),
      ),
    );
  }

  /// 一组微调按钮（减 / 加），ms 组在后面补一个单位标签。
  Widget _nudgePair(
    BuildContext context,
    FineTarget target,
    double delta,
    String minus,
    String plus, {
    required bool beatUnit,
  }) {
    final rm = context.rm;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        RmButton(
          onPressed: () => onNudge(target, -delta),
          size: RmButtonSize.sm,
          label: minus,
        ),
        const SizedBox(width: 4),
        RmButton(
          onPressed: () => onNudge(target, delta),
          size: RmButtonSize.sm,
          label: plus,
        ),
        if (!beatUnit) ...[
          const SizedBox(width: 5),
          Text('ms', style: RmText.mono(11, color: rm.fg4)),
        ],
      ],
    );
  }

  Widget _fineLabel(BuildContext context, String label, bool active) {
    final rm = context.rm;
    final acc = groupAccent(rm, session.kind);
    return Row(
      children: [
        Container(
          width: 9,
          height: 9,
          decoration: BoxDecoration(
            color: active ? acc.base : rm.fg4,
            borderRadius: BorderRadius.circular(3),
          ),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            label,
            style: RmText.mono(
              12,
              weight: FontWeight.w700,
              color: active ? rm.fg : rm.fg2,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  /// 元信息（BPM / 1 拍 / 磁吸 / Δ）。试听入口在传输条行尾。
  Widget _metaRow(BuildContext context) {
    final rm = context.rm;
    final beatMs = state.ai.bpm <= 0 ? 0 : 60 / state.ai.bpm * 1000;
    return Row(
      children: [
        Expanded(
          child: Wrap(
            spacing: 14,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _meta(context, 'BPM', state.ai.bpm.toStringAsFixed(1)),
              _meta(context, '1 拍', '${beatMs.round()}ms'),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('磁吸 ', style: RmText.mono(11, color: rm.fg3)),
                  Text(
                    snapActive ? 'downbeat' : 'off',
                    style: RmText.mono(
                      11,
                      color: snapActive
                          ? groupAccent(rm, session.kind).base
                          : rm.fg4,
                    ),
                  ),
                ],
              ),
              if (session.kind.isLoop)
                _meta(
                  context,
                  'Δ',
                  '${(session.end - session.start).toStringAsFixed(2)}s',
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _meta(BuildContext context, String label, String value) {
    final rm = context.rm;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('$label ', style: RmText.mono(11, color: rm.fg3)),
        Text(value, style: RmText.mono(11, color: rm.fg)),
      ],
    );
  }

  Widget _aiApplyPanel(BuildContext context) {
    final rm = context.rm;
    final acc = groupAccent(rm, session.kind);
    return Container(
      key: const ValueKey('manual-refine-ai-panel'),
      decoration: BoxDecoration(
        color: rm.raised,
        border: Border.all(color: rm.border),
        borderRadius: BorderRadius.circular(RmTokens.rLg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 11, 12, 10),
            child: Row(
              children: [
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    color: acc.base,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    '套用 AI 建议',
                    style: RmText.sans(
                      13,
                      weight: FontWeight.w700,
                      color: rm.fg,
                    ),
                  ),
                ),
                Text(
                  '${aiCandidates.length} 个',
                  style: RmText.mono(11, color: rm.fg3),
                ),
              ],
            ),
          ),
          Container(height: 1, color: rm.border),
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.all(10),
              itemCount: aiCandidates.length,
              separatorBuilder: (_, _) => const SizedBox(height: 6),
              itemBuilder: (context, i) {
                return _aiCandidateRow(context, i, aiCandidates[i]);
              },
            ),
          ),
          Container(
            padding: const EdgeInsets.fromLTRB(12, 9, 12, 10),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: rm.border)),
            ),
            child: Text(
              '套用后仍可继续点波形或微调；AI 只是起点。',
              style: RmText.sans(11.5, color: rm.fg3, height: 1.3),
            ),
          ),
        ],
      ),
    );
  }

  Widget _aiCandidateRow(BuildContext context, int index, dynamic candidate) {
    final rm = context.rm;
    final acc = groupAccent(rm, session.kind);
    final selected = session.matches(candidate);
    // 整张卡片即点选区域，去掉单独的「套用」按钮。
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        key: ValueKey('manual-refine-ai-apply-$index'),
        onTap: () => onApplyCandidate(candidate),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: selected ? acc.bg : rm.panel,
            border: Border.all(color: selected ? acc.base : rm.border),
            borderRadius: BorderRadius.circular(RmTokens.rSm),
          ),
          child: Row(
            children: [
              Container(
                width: 20,
                height: 20,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: selected ? acc.base : rm.raised,
                  border: Border.all(
                    color: selected ? acc.base : rm.borderStrong,
                  ),
                  borderRadius: BorderRadius.circular(5),
                ),
                child: Text(
                  '${index + 1}',
                  style: RmText.mono(
                    10.5,
                    color: selected ? Colors.white : rm.fg2,
                  ),
                ),
              ),
              const SizedBox(width: 9),
              Expanded(child: _candidateText(context, candidate)),
              if (selected) ...[
                const SizedBox(width: 8),
                RmIcon('check', size: 12, color: acc.base),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _candidateText(BuildContext context, dynamic candidate) {
    final rm = context.rm;
    if (candidate is LoopCandidate) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${formatTimecode(candidate.start)} → ${formatTimecode(candidate.end)}',
                  style: RmText.mono(13, weight: FontWeight.w700, color: rm.fg),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                '${candidate.bars} 小节',
                style: RmText.mono(9.5, color: rm.fg4),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            candidate.why,
            style: RmText.sans(11, color: rm.fg3),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 4),
          _confidenceBar(context, candidate.score),
        ],
      );
    }
    final point = candidate as PointCandidate;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          formatTimecode(point.t),
          style: RmText.mono(13, weight: FontWeight.w700, color: rm.fg),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 2),
        Text(
          point.why,
          style: RmText.sans(11, color: rm.fg3),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 4),
        _confidenceBar(context, point.score),
      ],
    );
  }

  /// 置信度迷你条 —— 42px 轨道按 score 填充 + 百分比。
  Widget _confidenceBar(BuildContext context, double score) {
    final rm = context.rm;
    final acc = groupAccent(rm, session.kind);
    final pct = score.clamp(0.0, 1.0);
    return Row(
      children: [
        Container(
          width: 42,
          height: 4,
          decoration: BoxDecoration(
            color: rm.border,
            borderRadius: BorderRadius.circular(2),
          ),
          alignment: Alignment.centerLeft,
          child: FractionallySizedBox(
            widthFactor: pct,
            child: Container(
              decoration: BoxDecoration(
                color: acc.base,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        ),
        const SizedBox(width: 7),
        Text(
          '${(pct * 100).round()}%',
          style: RmText.mono(10.5, color: rm.fg3),
        ),
      ],
    );
  }

  Widget _footer(BuildContext context) {
    final rm = context.rm;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Container(
            key: const ValueKey('manual-refine-footer-divider'),
            height: 1,
            color: rm.border,
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 13, 20, 16),
          child: Row(
            children: [
              RmIcon('info', size: 14, color: rm.fg3),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '←/→ 1拍 · Shift+←/→ 10ms · Alt 自由放置 · Enter 确认 · Esc 取消',
                  style: RmText.sans(12.5, color: rm.fg3),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 12),
              RmButton(onPressed: onCancel, label: '取消'),
              const SizedBox(width: 10),
              RmButton(
                onPressed: onConfirm,
                variant: RmButtonVariant.primary,
                leading: const RmIcon('check', size: 12),
                label: '确认选点',
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _statusPill(BuildContext context) {
    final rm = context.rm;
    final dotColor = snapActive ? RmTokens.trafficGreen : rm.warn;
    final label = snapActive ? '磁吸到拍' : '自由放置 · Alt';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
      decoration: BoxDecoration(
        color: snapActive ? rm.raised : rm.warnBg,
        border: Border.all(color: snapActive ? rm.border : rm.warn),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
          ),
          const SizedBox(width: 7),
          Text(
            label,
            style: RmText.sans(12, color: snapActive ? rm.fg3 : rm.warn),
          ),
        ],
      ),
    );
  }
}

class _ManualRefineSession {
  const _ManualRefineSession({
    required this.kind,
    required this.pointTime,
    required this.start,
    required this.end,
    required this.activeTarget,
  });

  factory _ManualRefineSession.fromState(
    ReplaceEditorState state,
    GroupKind kind,
  ) {
    if (kind.isLoop) {
      final current = switch (kind) {
        GroupKind.tl =>
          state.selectedManualOf(kind) ? state.tlManual! : state.tl,
        GroupKind.pl =>
          state.selectedManualOf(kind) ? state.plManual! : state.pl,
        GroupKind.td || GroupKind.pd => state.tl,
      };
      return _ManualRefineSession(
        kind: kind,
        pointTime: current.start,
        start: current.start,
        end: current.end,
        activeTarget: FineTarget.loopStart,
      );
    }
    final current = switch (kind) {
      GroupKind.td => state.selectedManualOf(kind) ? state.tdManual! : state.td,
      GroupKind.pd => state.selectedManualOf(kind) ? state.pdManual! : state.pd,
      GroupKind.tl || GroupKind.pl => state.td,
    };
    return _ManualRefineSession(
      kind: kind,
      pointTime: current.t,
      start: current.t,
      end: current.t,
      activeTarget: FineTarget.point,
    );
  }

  final GroupKind kind;
  final double pointTime;
  final double start;
  final double end;
  final FineTarget activeTarget;

  double get focusTime {
    if (!kind.isLoop) return pointTime;
    return activeTarget == FineTarget.loopEnd ? end : start;
  }

  _ManualRefineSession copyWith({
    double? pointTime,
    double? start,
    double? end,
    FineTarget? activeTarget,
  }) {
    return _ManualRefineSession(
      kind: kind,
      pointTime: pointTime ?? this.pointTime,
      start: start ?? this.start,
      end: end ?? this.end,
      activeTarget: activeTarget ?? this.activeTarget,
    );
  }

  _ManualRefineSession placeAt(double seconds, {required double duration}) {
    if (!kind.isLoop) {
      return copyWith(pointTime: _clampTime(seconds, duration));
    }
    if (activeTarget == FineTarget.loopEnd) {
      return _withLoop(end: seconds, duration: duration);
    }
    return _withLoop(start: seconds, duration: duration);
  }

  _ManualRefineSession nudge(
    FineTarget target,
    double deltaSec, {
    required double duration,
  }) {
    if (!kind.isLoop) {
      return copyWith(
        pointTime: _clampTime(pointTime + deltaSec, duration),
        activeTarget: FineTarget.point,
      );
    }
    if (target == FineTarget.loopEnd) {
      return _withLoop(
        end: end + deltaSec,
        duration: duration,
        activeTarget: target,
      );
    }
    return _withLoop(
      start: start + deltaSec,
      duration: duration,
      activeTarget: FineTarget.loopStart,
    );
  }

  _ManualRefineSession fromCandidate(
    dynamic candidate, {
    required double duration,
  }) {
    if (candidate is LoopCandidate) {
      return _withLoop(
        start: candidate.start,
        end: candidate.end,
        duration: duration,
        activeTarget: FineTarget.loopStart,
      );
    }
    final point = candidate as PointCandidate;
    return copyWith(
      pointTime: _clampTime(point.t, duration),
      start: _clampTime(point.t, duration),
      end: _clampTime(point.t, duration),
      activeTarget: FineTarget.point,
    );
  }

  bool matches(dynamic candidate) {
    const epsilon = 0.001;
    if (candidate is LoopCandidate) {
      return (candidate.start - start).abs() < epsilon &&
          (candidate.end - end).abs() < epsilon;
    }
    final point = candidate as PointCandidate;
    return (point.t - pointTime).abs() < epsilon;
  }

  _ManualRefineSession _withLoop({
    double? start,
    double? end,
    required double duration,
    FineTarget? activeTarget,
  }) {
    const minGap = 0.05;
    final safeDuration = math.max(0.0, duration);
    if (safeDuration <= minGap) {
      return copyWith(
        start: 0,
        end: safeDuration,
        pointTime: 0,
        activeTarget: activeTarget ?? this.activeTarget,
      );
    }
    var nextStart = _clampTime(start ?? this.start, safeDuration);
    var nextEnd = _clampTime(end ?? this.end, safeDuration);
    final target = activeTarget ?? this.activeTarget;
    if (nextEnd - nextStart < minGap) {
      if (target == FineTarget.loopEnd) {
        nextEnd = math.min(safeDuration, nextStart + minGap);
        nextStart = math.min(nextStart, nextEnd - minGap);
      } else {
        nextStart = math.max(0, nextEnd - minGap);
        nextEnd = math.max(nextEnd, nextStart + minGap);
      }
    }
    return copyWith(
      start: nextStart,
      end: nextEnd,
      pointTime: target == FineTarget.loopEnd ? nextEnd : nextStart,
      activeTarget: target,
    );
  }

  static double _clampTime(double seconds, double duration) {
    return seconds.clamp(0, math.max(0.0, duration)).toDouble();
  }
}

int _barsForManual(double start, double end, double bpm) {
  final beat = bpm <= 0 ? 0.5 : 60 / bpm;
  return ((end - start) / beat / 4).round().clamp(1, 128).toInt();
}

class _PreviewRange {
  const _PreviewRange({
    required this.start,
    required this.end,
    required this.loop,
  });

  final double start;
  final double end;
  final bool loop;
}
