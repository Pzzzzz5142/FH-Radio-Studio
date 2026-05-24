import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/track_timing_config.dart';
import '../../domain/radio_library.dart';
import '../../domain/replacement_models.dart';
import '../../state/audio_analysis_state.dart';
import '../../state/custom_pool_tracks.dart';
import '../../state/track_timing_state.dart';

enum PlaybackMode { idle, full, pointPreview, loopPreview }

@immutable
class ReplaceEditorState {
  const ReplaceEditorState({
    required this.trackId,
    required this.track,
    required this.ai,
    required this.tdIdx,
    required this.pdIdx,
    required this.tlIdx,
    required this.plIdx,
    required this.tdConfirmed,
    required this.pdConfirmed,
    required this.tlConfirmed,
    required this.plConfirmed,
    required this.playing,
    required this.playhead,
    required this.zoomStart,
    required this.zoomEnd,
    required this.activeGroup,
    required this.playbackMode,
    required this.analyzing,
    required this.dirty,
    required this.saved,
    this.error,
  });

  factory ReplaceEditorState.initial({
    required String trackId,
    required PoolTrack track,
    required AiResult ai,
    TrackTimingConfig? config,
  }) {
    final initialAi = config == null ? ai : _applyConfig(ai, config);
    return ReplaceEditorState(
      trackId: trackId,
      track: track,
      ai: initialAi,
      tdIdx: 0,
      pdIdx: 0,
      tlIdx: 0,
      plIdx: 0,
      tdConfirmed: config?.confirmed['td'] ?? track.confirmed >= 1,
      pdConfirmed: config?.confirmed['pd'] ?? track.confirmed >= 2,
      tlConfirmed: config?.confirmed['tl'] ?? track.confirmed >= 3,
      plConfirmed: config?.confirmed['pl'] ?? track.confirmed >= 4,
      playing: false,
      playhead: 0,
      zoomStart: 0,
      zoomEnd: initialAi.durationSec,
      activeGroup: GroupKind.td,
      playbackMode: PlaybackMode.idle,
      analyzing: track.id.startsWith('real:') && config == null,
      dirty: false,
      saved: config != null,
    );
  }

  final String trackId;
  final PoolTrack track;
  final AiResult ai;
  final int tdIdx;
  final int pdIdx;
  final int tlIdx;
  final int plIdx;
  final bool tdConfirmed;
  final bool pdConfirmed;
  final bool tlConfirmed;
  final bool plConfirmed;
  final bool playing;
  final double playhead;
  final double zoomStart;
  final double zoomEnd;
  final GroupKind activeGroup;
  final PlaybackMode playbackMode;
  final bool analyzing;
  final bool dirty;
  final bool saved;
  final String? error;

  PointCandidate get td => ai.td[_idx(tdIdx, ai.td.length)];
  PointCandidate get pd => ai.pd[_idx(pdIdx, ai.pd.length)];
  LoopCandidate get tl => ai.tl[_idx(tlIdx, ai.tl.length)];
  LoopCandidate get pl => ai.pl[_idx(plIdx, ai.pl.length)];

  bool get allConfirmed =>
      tdConfirmed && pdConfirmed && tlConfirmed && plConfirmed;

  bool get aiPending => analyzing && error == null;

  int get doneCount =>
      (tdConfirmed ? 1 : 0) +
      (pdConfirmed ? 1 : 0) +
      (tlConfirmed ? 1 : 0) +
      (plConfirmed ? 1 : 0);

  bool confirmedOf(GroupKind k) => switch (k) {
    GroupKind.td => tdConfirmed,
    GroupKind.pd => pdConfirmed,
    GroupKind.tl => tlConfirmed,
    GroupKind.pl => plConfirmed,
  };

  int selectedIdxOf(GroupKind k) => switch (k) {
    GroupKind.td => tdIdx,
    GroupKind.pd => pdIdx,
    GroupKind.tl => tlIdx,
    GroupKind.pl => plIdx,
  };

  Map<String, double> get markerSeconds => {
    'TrackDrop': td.t,
    'PostDrop': pd.t,
    'TrackLoopStart': tl.start,
    'TrackLoopEnd': tl.end,
    'PostRaceLoopStart': pl.start,
    'PostRaceLoopEnd': pl.end,
  };

  Map<String, bool> get confirmedGroups => {
    'td': tdConfirmed,
    'pd': pdConfirmed,
    'tl': tlConfirmed,
    'pl': plConfirmed,
  };

  ReplaceEditorState copyWith({
    PoolTrack? track,
    AiResult? ai,
    int? tdIdx,
    int? pdIdx,
    int? tlIdx,
    int? plIdx,
    bool? tdConfirmed,
    bool? pdConfirmed,
    bool? tlConfirmed,
    bool? plConfirmed,
    bool? playing,
    double? playhead,
    double? zoomStart,
    double? zoomEnd,
    GroupKind? activeGroup,
    PlaybackMode? playbackMode,
    bool? analyzing,
    bool? dirty,
    bool? saved,
    Object? error = _sentinel,
  }) {
    final nextAi = ai ?? this.ai;
    return ReplaceEditorState(
      trackId: trackId,
      track: track ?? this.track,
      ai: nextAi,
      tdIdx: _idx(tdIdx ?? this.tdIdx, nextAi.td.length),
      pdIdx: _idx(pdIdx ?? this.pdIdx, nextAi.pd.length),
      tlIdx: _idx(tlIdx ?? this.tlIdx, nextAi.tl.length),
      plIdx: _idx(plIdx ?? this.plIdx, nextAi.pl.length),
      tdConfirmed: tdConfirmed ?? this.tdConfirmed,
      pdConfirmed: pdConfirmed ?? this.pdConfirmed,
      tlConfirmed: tlConfirmed ?? this.tlConfirmed,
      plConfirmed: plConfirmed ?? this.plConfirmed,
      playing: playing ?? this.playing,
      playhead: (playhead ?? this.playhead).clamp(0, nextAi.durationSec),
      zoomStart: (zoomStart ?? this.zoomStart).clamp(0, nextAi.durationSec),
      zoomEnd: (zoomEnd ?? this.zoomEnd).clamp(0, nextAi.durationSec),
      activeGroup: activeGroup ?? this.activeGroup,
      playbackMode: playbackMode ?? this.playbackMode,
      analyzing: analyzing ?? this.analyzing,
      dirty: dirty ?? this.dirty,
      saved: saved ?? this.saved,
      error: identical(error, _sentinel) ? this.error : error as String?,
    );
  }
}

class ReplaceEditorNotifier extends StateNotifier<ReplaceEditorState> {
  ReplaceEditorNotifier(
    this.ref,
    super.state,
    this._initialConfig,
    this._analysisController,
  );

  final Ref ref;
  final TrackTimingConfig? _initialConfig;
  final AudioAnalysisController _analysisController;
  final List<ReplaceEditorState> _history = [];

  Future<void> analyze({bool force = false}) async {
    final path = pathFromRealTrackId(state.trackId) ?? state.track.source;
    if (path.trim().isEmpty) return;
    state = state.copyWith(analyzing: true, error: null);
    final result = await ref.read(audioAnalysisProvider.notifier).analyze(path);
    if (!mounted) return;
    final analysis = ref.read(audioAnalysisProvider);
    if (analysis.error != null) {
      state = state.copyWith(analyzing: false, error: analysis.error);
      return;
    }
    if (result == null) {
      state = state.copyWith(analyzing: false);
      return;
    }

    var nextAi = _aiFromAnalysis(result);
    if (!force && _initialConfig != null) {
      nextAi = _applyConfig(nextAi, _initialConfig);
    } else if (state.dirty || state.saved) {
      nextAi = _applyCurrentMarkers(nextAi, state);
    }
    state = state.copyWith(
      ai: nextAi,
      analyzing: false,
      dirty: force ? true : state.dirty,
      saved: force ? false : state.saved,
      error: null,
      zoomStart: 0,
      zoomEnd: nextAi.durationSec,
    );
  }

  @override
  void dispose() {
    unawaited(_analysisController.cancel());
    super.dispose();
  }

  void selectCandidate(GroupKind kind, int idx) {
    if (state.confirmedOf(kind)) return;
    _remember();
    state = switch (kind) {
      GroupKind.td => state.copyWith(
        tdIdx: idx,
        activeGroup: kind,
        dirty: true,
        saved: false,
      ),
      GroupKind.pd => state.copyWith(
        pdIdx: idx,
        activeGroup: kind,
        dirty: true,
        saved: false,
      ),
      GroupKind.tl => state.copyWith(
        tlIdx: idx,
        activeGroup: kind,
        dirty: true,
        saved: false,
      ),
      GroupKind.pl => state.copyWith(
        plIdx: idx,
        activeGroup: kind,
        dirty: true,
        saved: false,
      ),
    };
  }

  void setConfirmed(GroupKind kind, bool value) {
    _remember();
    state = switch (kind) {
      GroupKind.td => state.copyWith(
        tdConfirmed: value,
        activeGroup: kind,
        dirty: true,
        saved: false,
      ),
      GroupKind.pd => state.copyWith(
        pdConfirmed: value,
        activeGroup: kind,
        dirty: true,
        saved: false,
      ),
      GroupKind.tl => state.copyWith(
        tlConfirmed: value,
        activeGroup: kind,
        dirty: true,
        saved: false,
      ),
      GroupKind.pl => state.copyWith(
        plConfirmed: value,
        activeGroup: kind,
        dirty: true,
        saved: false,
      ),
    };
  }

  void confirmActive() {
    setConfirmed(state.activeGroup, true);
  }

  void setPlayhead(double t) {
    state = state.copyWith(playhead: t);
  }

  void togglePlay() {
    state = state.copyWith(playing: !state.playing);
  }

  void setPlaying(bool value) {
    state = state.copyWith(playing: value);
  }

  void setPlayback(PlaybackMode mode, {bool? playing}) {
    state = state.copyWith(playbackMode: mode, playing: playing);
  }

  void setError(String? message) {
    state = state.copyWith(error: message);
  }

  void seekRelative(double deltaSec) {
    setPlayhead(state.playhead + deltaSec);
  }

  void jumpToSegment(int index) {
    if (index < 0 || index >= state.ai.segments.length) return;
    setPlayhead(state.ai.segments[index].start);
  }

  void nudge(GroupKind kind, FineTarget target, double deltaSec) {
    if (state.confirmedOf(kind)) return;
    _remember();
    final duration = state.ai.durationSec;
    double bound(double value) => value.clamp(0, duration).toDouble();

    switch (kind) {
      case GroupKind.td:
        final list = [...state.ai.td];
        list[state.tdIdx] = list[state.tdIdx].copyWith(
          t: bound(list[state.tdIdx].t + deltaSec),
          why: '手动微调',
        );
        state = state.copyWith(
          ai: state.ai.copyWith(td: list),
          activeGroup: kind,
          dirty: true,
          saved: false,
        );
      case GroupKind.pd:
        final list = [...state.ai.pd];
        list[state.pdIdx] = list[state.pdIdx].copyWith(
          t: bound(list[state.pdIdx].t + deltaSec),
          why: '手动微调',
        );
        state = state.copyWith(
          ai: state.ai.copyWith(pd: list),
          activeGroup: kind,
          dirty: true,
          saved: false,
        );
      case GroupKind.tl:
        final list = [...state.ai.tl];
        final current = list[state.tlIdx];
        final start = target == FineTarget.loopEnd
            ? current.start
            : bound(current.start + deltaSec);
        final end = target == FineTarget.loopStart
            ? current.end
            : bound(current.end + deltaSec);
        list[state.tlIdx] = current.copyWith(
          start: start.clamp(0, end - 0.05).toDouble(),
          end: end.clamp(start + 0.05, duration).toDouble(),
          why: '手动微调',
        );
        state = state.copyWith(
          ai: state.ai.copyWith(tl: list),
          activeGroup: kind,
          dirty: true,
          saved: false,
        );
      case GroupKind.pl:
        final list = [...state.ai.pl];
        final current = list[state.plIdx];
        final start = target == FineTarget.loopEnd
            ? current.start
            : bound(current.start + deltaSec);
        final end = target == FineTarget.loopStart
            ? current.end
            : bound(current.end + deltaSec);
        list[state.plIdx] = current.copyWith(
          start: start.clamp(0, end - 0.05).toDouble(),
          end: end.clamp(start + 0.05, duration).toDouble(),
          why: '手动微调',
        );
        state = state.copyWith(
          ai: state.ai.copyWith(pl: list),
          activeGroup: kind,
          dirty: true,
          saved: false,
        );
    }
  }

  void zoomIn() {
    final width = (state.zoomEnd - state.zoomStart)
        .clamp(8, state.ai.durationSec)
        .toDouble();
    final nextWidth = (width * 0.65).clamp(8, state.ai.durationSec).toDouble();
    _setZoomWidth(nextWidth);
  }

  void zoomOut() {
    final width = (state.zoomEnd - state.zoomStart)
        .clamp(8, state.ai.durationSec)
        .toDouble();
    final nextWidth = (width * 1.55).clamp(8, state.ai.durationSec).toDouble();
    _setZoomWidth(nextWidth);
  }

  void _setZoomWidth(double width) {
    final center = state.playhead.clamp(0, state.ai.durationSec);
    var start = center - width / 2;
    var end = center + width / 2;
    if (start < 0) {
      end -= start;
      start = 0;
    }
    if (end > state.ai.durationSec) {
      start -= end - state.ai.durationSec;
      end = state.ai.durationSec;
    }
    state = state.copyWith(zoomStart: start, zoomEnd: end);
  }

  void undo() {
    if (_history.isEmpty) return;
    state = _history.removeLast();
  }

  TrackTimingConfig saveToProject() {
    final config = TrackTimingConfig(
      source: state.track.source,
      bpm: state.ai.bpm,
      markersSec: state.markerSeconds,
      confirmed: state.confirmedGroups,
      updatedAt: DateTime.now().toUtc(),
    );
    ref.read(trackTimingProvider.notifier).save(config);
    state = state.copyWith(dirty: false, saved: true);
    return config;
  }

  void _remember() {
    _history.add(state);
    if (_history.length > 40) _history.removeAt(0);
  }
}

final replaceEditorProvider = StateNotifierProvider.autoDispose
    .family<ReplaceEditorNotifier, ReplaceEditorState, String>((ref, trackId) {
      final realTracks = ref.watch(realPoolTracksProvider);
      final track =
          _resolveTrack(trackId, realTracks) ??
          _fallbackTrackForRouteId(trackId);
      final config = track.id.startsWith('real:')
          ? ref.read(trackTimingProvider.notifier).configForPath(track.source)
          : null;
      final notifier = ReplaceEditorNotifier(
        ref,
        ReplaceEditorState.initial(
          trackId: track.id,
          track: track,
          ai: _seedAiFromTrackMetadata(kReplacementEdit.ai, track),
          config: config,
        ),
        config,
        ref.read(audioAnalysisProvider.notifier),
      );
      return notifier;
    });

const Object _sentinel = Object();

AiResult _seedAiFromTrackMetadata(AiResult ai, PoolTrack track) {
  final duration = track.durationSec > 0 ? track.durationSec : ai.durationSec;
  final bpm = track.bpm > 0 ? track.bpm.toDouble() : ai.bpm;
  final hasAudioMetadata =
      track.sampleRate != null ||
      track.channels != null ||
      track.samples != null;
  if (duration == ai.durationSec && bpm == ai.bpm && !hasAudioMetadata) {
    return ai;
  }
  final scale = ai.durationSec > 0 ? duration / ai.durationSec : 1.0;
  double t(double value) => (value * scale).clamp(0, duration).toDouble();
  final sampleRate =
      track.sampleRate ??
      (ai.sourceSampleRate <= 0 ? 48000 : ai.sourceSampleRate);
  final channels = track.channels ?? (ai.channels <= 0 ? 2 : ai.channels);
  final samples =
      track.samples ?? (duration > 0 ? (duration * sampleRate).round() : null);
  return ai.copyWith(
    durationSec: duration,
    bpm: bpm,
    td: [for (final item in ai.td) item.copyWith(t: t(item.t))],
    pd: [for (final item in ai.pd) item.copyWith(t: t(item.t))],
    tl: [
      for (final item in ai.tl)
        item.copyWith(start: t(item.start), end: t(item.end)),
    ],
    pl: [
      for (final item in ai.pl)
        item.copyWith(start: t(item.start), end: t(item.end)),
    ],
    beats: _seedBeats(duration, bpm),
    segments: [
      for (final item in ai.segments)
        Segment(start: t(item.start), end: t(item.end), label: item.label),
    ],
    sourceSampleRate: sampleRate,
    channels: channels,
    sourceSamples: samples,
  );
}

PoolTrack? _resolveTrack(String routeTrackId, List<PoolTrack> realTracks) {
  final candidates = <String>{routeTrackId};
  if (routeTrackId.startsWith('real:')) {
    final source = pathFromRealTrackId(routeTrackId);
    if (source != null && source.isNotEmpty) {
      candidates.add(realTrackIdForPath(source));
    }
  }
  for (final track in [...realTracks, ...kCustomPool]) {
    if (candidates.contains(track.id)) return track;
  }
  return null;
}

PoolTrack _fallbackTrackForRouteId(String routeTrackId) {
  final source = routeTrackId.startsWith('real:')
      ? pathFromRealTrackId(routeTrackId)
      : null;
  if (source != null && source.isNotEmpty) {
    final file = File(source);
    final (artist, title) = guessTrackMetadata(file);
    return PoolTrack(
      id: realTrackIdForPath(source),
      title: title,
      artist: artist,
      source: source,
      durationSec: 0,
      bpm: 0,
      key: '待分析',
      configured: false,
      confirmed: 0,
      added: '未知',
    );
  }
  return PoolTrack(
    id: routeTrackId,
    title: '找不到曲目',
    artist: 'Unknown Artist',
    source: '',
    durationSec: 0,
    bpm: 0,
    key: '待分析',
    configured: false,
    confirmed: 0,
    added: '未知',
  );
}

List<double> _seedBeats(double duration, double bpm) {
  if (duration <= 0 || bpm <= 0) return const [];
  final step = 60 / bpm;
  return [
    for (var t = 0.0; t <= duration; t += step)
      double.parse(t.toStringAsFixed(3)),
  ];
}

AiResult _aiFromAnalysis(AudioAnalysisResult result) {
  final duration = result.durationSec <= 0 ? 1.0 : result.durationSec;
  final bpm = result.bpm <= 0 ? 120.0 : result.bpm;
  final beat = 60 / bpm;
  double m(String key, double fallback) {
    final value = result.markers[key];
    if (value == null || value.isNaN) return fallback.clamp(0, duration);
    return value.clamp(0, duration).toDouble();
  }

  List<PointCandidate> point(
    String key,
    String group,
    String label,
    double fallback,
  ) {
    final v2 = result.pointCandidates[group] ?? const [];
    if (v2.isNotEmpty) {
      return [
        for (final item in v2)
          PointCandidate(
            t: item.t.clamp(0, duration).toDouble(),
            score: item.score,
            why: item.why.isEmpty ? '$label · AI v2 建议' : item.why,
          ),
      ];
    }
    final base = m(key, fallback);
    return [
      PointCandidate(t: base, score: 0.82, why: '$label · 本地分析建议'),
      PointCandidate(
        t: (base - beat).clamp(0, duration).toDouble(),
        score: 0.62,
        why: '提前 1 拍',
      ),
      PointCandidate(
        t: (base + beat).clamp(0, duration).toDouble(),
        score: 0.58,
        why: '推后 1 拍',
      ),
    ];
  }

  List<LoopCandidate> loop(
    String startKey,
    String endKey,
    String group,
    double startFallback,
    double endFallback,
    String label,
  ) {
    final v2 = result.loopCandidates[group] ?? const [];
    if (v2.isNotEmpty) {
      return [
        for (final item in v2)
          LoopCandidate(
            start: item.start.clamp(0, duration).toDouble(),
            end: item.end.clamp(item.start + 0.5, duration).toDouble(),
            score: item.score,
            bars: item.bars <= 0 ? 1 : item.bars,
            why: item.why.isEmpty ? '$label · AI v2 建议' : item.why,
          ),
      ];
    }
    final start = m(startKey, startFallback);
    final end = m(endKey, endFallback).clamp(start + 0.5, duration).toDouble();
    final bars = ((end - start) / beat / 4).round().clamp(1, 128);
    return [
      LoopCandidate(
        start: start,
        end: end,
        score: 0.78,
        bars: bars,
        why: '$label · 能量窗口启发式',
      ),
      LoopCandidate(
        start: (start + beat * 4).clamp(0, duration - 0.5).toDouble(),
        end: end,
        score: 0.61,
        bars: bars,
        why: '短一点的循环入口',
      ),
      LoopCandidate(
        start: start,
        end: (end - beat * 4).clamp(start + 0.5, duration).toDouble(),
        score: 0.52,
        bars: (bars - 1).clamp(1, 128),
        why: '短一点的循环出口',
      ),
    ];
  }

  final segments = result.segments
      .where((segment) => segment.end > segment.start)
      .map(
        (segment) => Segment(
          start: segment.start.clamp(0, duration).toDouble(),
          end: segment.end.clamp(0, duration).toDouble(),
          label: segment.label,
        ),
      )
      .toList(growable: false);

  return AiResult(
    durationSec: duration,
    bpm: bpm,
    confidence: 0.72,
    td: point('TrackDrop', 'td', 'TrackDrop', duration * 0.25),
    pd: point('PostDrop', 'pd', 'PostDrop', duration * 0.68),
    tl: loop(
      'TrackLoopStart',
      'TrackLoopEnd',
      'tl',
      duration * 0.12,
      duration * 0.55,
      'TrackLoop',
    ),
    pl: loop(
      'PostRaceLoopStart',
      'PostRaceLoopEnd',
      'pl',
      duration * 0.55,
      duration * 0.86,
      'PostLoop',
    ),
    beats: result.beats.isEmpty ? _genBeats(duration, bpm) : result.beats,
    segments: segments.isEmpty
        ? [Segment(start: 0, end: duration, label: 'chorus')]
        : segments,
    waveformPeaks: _waveformDisplayValues(result.waveform),
    sourceSampleRate: result.sampleRate <= 0 ? 48000 : result.sampleRate,
    channels: result.channels <= 0 ? 2 : result.channels,
    sourceSamples: result.samples <= 0 ? null : result.samples,
    decoder: result.decoder,
    rmsDbfs: result.rmsDbfs,
    peakDbfs: result.peakDbfs,
    aiNote: result.aiNote,
  );
}

AiResult _applyConfig(AiResult ai, TrackTimingConfig config) {
  return _applyMarkers(
    ai,
    config.markersSec,
    bpm: config.bpm > 0 ? config.bpm : ai.bpm,
  );
}

AiResult _applyCurrentMarkers(AiResult ai, ReplaceEditorState state) {
  return _applyMarkers(ai, state.markerSeconds, bpm: state.ai.bpm);
}

AiResult _applyMarkers(
  AiResult ai,
  Map<String, double> markers, {
  required double bpm,
}) {
  PointCandidate firstPoint(
    List<PointCandidate> list,
    String marker,
    String why,
  ) {
    final fallback = list.isEmpty ? 0.0 : list.first.t;
    return PointCandidate(
      t: (markers[marker] ?? fallback).clamp(0, ai.durationSec).toDouble(),
      score: list.isEmpty ? 1 : list.first.score,
      why: why,
    );
  }

  LoopCandidate firstLoop(
    List<LoopCandidate> list,
    String startMarker,
    String endMarker,
    String why,
  ) {
    final fallback = list.isEmpty
        ? LoopCandidate(
            start: 0,
            end: ai.durationSec,
            score: 1,
            bars: 1,
            why: why,
          )
        : list.first;
    final start = (markers[startMarker] ?? fallback.start)
        .clamp(0, ai.durationSec)
        .toDouble();
    final end = (markers[endMarker] ?? fallback.end)
        .clamp(start + 0.05, ai.durationSec)
        .toDouble();
    return fallback.copyWith(start: start, end: end, why: why);
  }

  return ai.copyWith(
    bpm: bpm,
    td: [firstPoint(ai.td, 'TrackDrop', '已保存配置'), ...ai.td.skip(1)],
    pd: [firstPoint(ai.pd, 'PostDrop', '已保存配置'), ...ai.pd.skip(1)],
    tl: [
      firstLoop(ai.tl, 'TrackLoopStart', 'TrackLoopEnd', '已保存配置'),
      ...ai.tl.skip(1),
    ],
    pl: [
      firstLoop(ai.pl, 'PostRaceLoopStart', 'PostRaceLoopEnd', '已保存配置'),
      ...ai.pl.skip(1),
    ],
  );
}

List<double> _genBeats(double duration, double bpm) {
  final step = bpm <= 0 ? 0.5 : 60 / bpm;
  return [
    for (double t = 0; t <= duration; t += step)
      double.parse(t.toStringAsFixed(3)),
  ];
}

List<double> _waveformDisplayValues(List<AudioWaveformBin> bins) {
  return [
    for (final bin in bins)
      (bin.rms.clamp(0, 1) * 0.88 + bin.peak.clamp(0, 1) * 0.12)
          .clamp(0, 1)
          .toDouble(),
  ];
}

int _idx(int value, int length) {
  if (length <= 1) return 0;
  return value.clamp(0, length - 1).toInt();
}
