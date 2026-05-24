import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../core/fh_radio_studio_cli.dart';
import 'studio_state.dart';

typedef AudioAnalysisCliRunner =
    Future<CliRunResult> Function(
      String repoRoot,
      List<String> args, {
      CliCancellationToken? cancellationToken,
      CliLineHandler? onStdout,
      CliLineHandler? onStderr,
    });

final audioAnalysisCliRunnerProvider = Provider<AudioAnalysisCliRunner>((ref) {
  return (repoRoot, args, {cancellationToken, onStdout, onStderr}) {
    return FhRadioStudioCli(repoRoot: repoRoot).run(
      args,
      cancellationToken: cancellationToken,
      onStdout: onStdout,
      onStderr: onStderr,
    );
  };
});

const _progressPrefix = 'FH_RADIO_STUDIO_PROGRESS ';
const _startupStepId = 'app.start_cli';

@immutable
class AudioWaveformBin {
  const AudioWaveformBin({required this.peak, required this.rms});

  final double peak;
  final double rms;
}

@immutable
class AudioAnalysisResult {
  const AudioAnalysisResult({
    required this.path,
    required this.title,
    required this.durationSec,
    required this.sampleRate,
    required this.channels,
    required this.samples,
    required this.peakDbfs,
    required this.rmsDbfs,
    required this.bpm,
    required this.waveform,
    required this.markers,
    required this.beats,
    required this.segments,
    required this.pointCandidates,
    required this.loopCandidates,
    required this.warnings,
    required this.aiNote,
    required this.decoder,
  });

  final String path;
  final String title;
  final double durationSec;
  final int sampleRate;
  final int channels;
  final int samples;
  final double peakDbfs;
  final double rmsDbfs;
  final double bpm;
  final List<AudioWaveformBin> waveform;
  final Map<String, double> markers;
  final List<double> beats;
  final List<AudioAnalysisSegment> segments;
  final Map<String, List<AudioPointCandidate>> pointCandidates;
  final Map<String, List<AudioLoopCandidate>> loopCandidates;
  final List<String> warnings;
  final String aiNote;
  final String decoder;

  factory AudioAnalysisResult.fromJson(Map<String, dynamic> json) {
    final analysisJson = _asMap(json['analysis']);
    final gridJson = _asMap(json['grid']);
    final waveformJson = _asMap(json['waveform']);
    final bins = _asList(waveformJson?['bins']);
    final candidatesJson = _asMap(json['candidates']) ?? const {};
    final pointCandidates = _parsePointCandidates(candidatesJson);
    final loopCandidates = _parseLoopCandidates(candidatesJson);
    final markerJson =
        _asMap(json['markers']) ??
        _markersFromCandidates(pointCandidates, loopCandidates);
    final beatsJson = _asList(json['beats']).isNotEmpty
        ? _asList(json['beats'])
        : _asList(gridJson?['beats']);
    final segmentsJson = _asList(json['segments']);
    final warnings = _stringList(_asList(json['warnings']));
    return AudioAnalysisResult(
      path: '${json['source'] ?? ''}',
      title: '${json['title'] ?? 'Audio'}',
      durationSec: _asDouble(json['duration_sec']) ?? 0,
      sampleRate:
          _asInt(json['sample_rate']) ??
          _asInt(analysisJson?['source_sample_rate']) ??
          _asInt(analysisJson?['write_sample_rate']) ??
          0,
      channels: _asInt(json['channels']) ?? 0,
      samples: _asInt(json['samples']) ?? 0,
      peakDbfs: _asDouble(json['peak_dbfs']) ?? 0,
      rmsDbfs: _asDouble(json['rms_dbfs']) ?? 0,
      bpm: _asDouble(json['bpm']) ?? _asDouble(analysisJson?['bpm']) ?? 120,
      waveform: [
        for (final item in bins)
          if (_asMap(item) case final map?)
            AudioWaveformBin(
              peak: _asDouble(map['norm_peak']) ?? 0,
              rms: _asDouble(map['norm_rms']) ?? 0,
            ),
      ],
      markers: {
        for (final entry in markerJson.entries)
          entry.key: _asDouble(entry.value) ?? 0,
      },
      beats: _doubleList(beatsJson),
      segments: [
        for (final item in segmentsJson)
          if (_asMap(item) case final map?)
            AudioAnalysisSegment(
              start: _asDouble(map['start']) ?? 0,
              end: _asDouble(map['end']) ?? 0,
              label: '${map['label'] ?? 'segment'}',
            ),
      ],
      pointCandidates: pointCandidates,
      loopCandidates: loopCandidates,
      warnings: warnings,
      aiNote: '${json['ai_note'] ?? warnings.join('\n')}',
      decoder: '${json['decoder'] ?? analysisJson?['decoder'] ?? ''}',
    );
  }
}

@immutable
class AudioPointCandidate {
  const AudioPointCandidate({
    required this.t,
    required this.score,
    required this.why,
  });

  final double t;
  final double score;
  final String why;
}

@immutable
class AudioLoopCandidate {
  const AudioLoopCandidate({
    required this.start,
    required this.end,
    required this.score,
    required this.bars,
    required this.why,
  });

  final double start;
  final double end;
  final double score;
  final int bars;
  final String why;
}

@immutable
class AudioAnalysisSegment {
  const AudioAnalysisSegment({
    required this.start,
    required this.end,
    required this.label,
  });

  final double start;
  final double end;
  final String label;
}

@immutable
class AudioAnalysisProgressStep {
  const AudioAnalysisProgressStep({
    required this.id,
    required this.label,
    required this.detail,
    required this.status,
    required this.weight,
    this.provider,
    this.optional = false,
    this.enabled = true,
    this.summary = '',
    this.runtimeMs,
    this.warnings = const [],
  });

  final String id;
  final String label;
  final String detail;
  final String status;
  final int weight;
  final String? provider;
  final bool optional;
  final bool enabled;
  final String summary;
  final int? runtimeMs;
  final List<String> warnings;

  bool get terminal =>
      status == 'done' ||
      status == 'skipped' ||
      status == 'warning' ||
      status == 'error';

  AudioAnalysisProgressStep copyWith({
    String? status,
    String? summary,
    int? runtimeMs,
    List<String>? warnings,
  }) {
    return AudioAnalysisProgressStep(
      id: id,
      label: label,
      detail: detail,
      status: status ?? this.status,
      weight: weight,
      provider: provider,
      optional: optional,
      enabled: enabled,
      summary: summary ?? this.summary,
      runtimeMs: runtimeMs ?? this.runtimeMs,
      warnings: warnings ?? this.warnings,
    );
  }

  factory AudioAnalysisProgressStep.fromJson(Map<String, dynamic> json) {
    return AudioAnalysisProgressStep(
      id: '${json['id'] ?? ''}',
      label: '${json['label'] ?? json['id'] ?? '步骤'}',
      detail: '${json['detail'] ?? ''}',
      status: 'pending',
      weight: _asInt(json['weight']) ?? 1,
      provider: json['provider'] == null ? null : '${json['provider']}',
      optional: json['optional'] == true,
      enabled: json['enabled'] != false,
    );
  }
}

@immutable
class AudioAnalysisState {
  const AudioAnalysisState({
    required this.busy,
    this.path,
    this.result,
    this.error,
    this.progressSteps = const [],
  });

  const AudioAnalysisState.initial() : this(busy: false);

  final bool busy;
  final String? path;
  final AudioAnalysisResult? result;
  final String? error;
  final List<AudioAnalysisProgressStep> progressSteps;

  bool get hasProgress => progressSteps.isNotEmpty;

  AudioAnalysisProgressStep? get activeProgressStep {
    for (final step in progressSteps) {
      if (step.status == 'running') return step;
    }
    return null;
  }

  int get progressPercent {
    if (progressSteps.isEmpty) return busy ? 0 : 100;
    final total = progressSteps.fold<int>(
      0,
      (sum, step) => sum + (step.weight <= 0 ? 1 : step.weight),
    );
    if (total <= 0) return 0;
    final completed = progressSteps.fold<int>(0, (sum, step) {
      if (!step.terminal) return sum;
      return sum + (step.weight <= 0 ? 1 : step.weight);
    });
    return ((completed / total) * 100).clamp(0, 100).round();
  }
}

class AudioAnalysisController extends StateNotifier<AudioAnalysisState> {
  AudioAnalysisController(this.ref) : super(const AudioAnalysisState.initial());

  final Ref ref;
  CliCancellationToken? _activeToken;
  int _runId = 0;

  Future<AudioAnalysisResult?> analyze(String path) async {
    final studio = ref.read(studioProvider);
    final repoRoot = studio.repoRoot;
    final profile = studio.aiProfile;
    await cancel();
    final runId = ++_runId;
    final token = CliCancellationToken();
    _activeToken = token;
    state = AudioAnalysisState(
      busy: true,
      path: path,
      result: state.result,
      progressSteps: _startupProgressSteps(),
    );
    final ffmpeg = _vendoredFfmpeg(repoRoot);
    final runner = ref.read(audioAnalysisCliRunnerProvider);
    final result = await runner(
      repoRoot,
      [
        'analyze-audio',
        path,
        '--profile',
        profile,
        '--bins',
        '320',
        if (ffmpeg != null) ...['--ffmpeg', ffmpeg],
        '--json',
        '--progress-jsonl',
      ],
      cancellationToken: token,
      onStderr: (line) {
        _handleProgressLine(runId, token, line);
      },
    );
    if (!mounted || runId != _runId || token.isCancelled || result.cancelled) {
      if (mounted && _activeToken == token) {
        _activeToken = null;
        state = AudioAnalysisState(
          busy: false,
          path: path,
          result: state.result,
          progressSteps: state.progressSteps,
        );
      }
      return null;
    }
    _activeToken = null;
    if (!result.ok) {
      final stderr = _stripProgressLines(result.stderr).trim();
      final stdout = _stripProgressLines(result.stdout).trim();
      state = AudioAnalysisState(
        busy: false,
        path: path,
        error: stderr.isEmpty ? stdout : stderr,
        progressSteps: state.progressSteps,
      );
      return null;
    }
    try {
      final decoded = jsonDecode(result.stdout);
      final map = _asMap(decoded);
      if (map == null) {
        throw const FormatException('JSON root is not an object');
      }
      final parsed = AudioAnalysisResult.fromJson(map);
      state = AudioAnalysisState(
        busy: false,
        path: path,
        result: parsed,
        progressSteps: state.progressSteps,
      );
      return parsed;
    } on FormatException catch (error) {
      state = AudioAnalysisState(
        busy: false,
        path: path,
        error: '分析结果解析失败：${error.message}',
        progressSteps: state.progressSteps,
      );
      return null;
    }
  }

  Future<void> cancel() async {
    final token = _activeToken;
    _activeToken = null;
    _runId++;
    if (token != null) {
      await token.cancel();
    }
    if (mounted && state.busy) {
      state = AudioAnalysisState(
        busy: false,
        path: state.path,
        result: state.result,
        progressSteps: state.progressSteps,
      );
    }
  }

  @override
  void dispose() {
    unawaited(cancel());
    super.dispose();
  }

  String? _vendoredFfmpeg(String repoRoot) {
    final runtime = UvRuntime.resolve(repoRoot);
    final exe = p.join(
      runtime.audioToolsDir,
      'ffmpeg',
      Platform.isWindows ? 'ffmpeg.exe' : 'ffmpeg',
    );
    return File(exe).existsSync() ? exe : null;
  }

  void _handleProgressLine(int runId, CliCancellationToken token, String line) {
    if (!line.startsWith(_progressPrefix)) return;
    if (!mounted || runId != _runId || token.isCancelled) return;
    try {
      final decoded = jsonDecode(line.substring(_progressPrefix.length));
      final event = _asMap(decoded);
      if (event == null) return;
      state = _stateWithProgressEvent(state, event);
    } on FormatException {
      return;
    }
  }
}

final audioAnalysisProvider =
    StateNotifierProvider<AudioAnalysisController, AudioAnalysisState>((ref) {
      return AudioAnalysisController(ref);
    });

List<AudioAnalysisProgressStep> _startupProgressSteps() {
  return const [
    AudioAnalysisProgressStep(
      id: _startupStepId,
      label: '启动 Python 环境',
      detail: '准备 uv runtime 并启动分析 CLI。',
      status: 'running',
      weight: 4,
    ),
  ];
}

AudioAnalysisState _stateWithProgressEvent(
  AudioAnalysisState current,
  Map<String, dynamic> event,
) {
  final type = '${event['event'] ?? ''}';
  if (type == 'plan') {
    final steps = [
      for (final item in _asList(event['steps']))
        if (_asMap(item) case final map?)
          AudioAnalysisProgressStep.fromJson(map),
    ];
    if (steps.isEmpty) return current;
    return AudioAnalysisState(
      busy: current.busy,
      path: current.path,
      result: current.result,
      error: current.error,
      progressSteps: steps,
    );
  }

  final stepId = '${event['step_id'] ?? ''}';
  if (stepId.isEmpty) return current;
  if (type == 'step_started') {
    return _updateProgressStep(current, stepId, (step) {
      return step.copyWith(status: 'running');
    });
  }
  if (type == 'step_completed') {
    final status = '${event['status'] ?? 'done'}';
    return _updateProgressStep(current, stepId, (step) {
      return step.copyWith(
        status: status,
        summary: '${event['summary'] ?? step.summary}',
        runtimeMs: _asInt(event['runtime_ms']),
        warnings: _stringList(_asList(event['warnings'])),
      );
    });
  }
  if (type == 'step_failed') {
    return _updateProgressStep(current, stepId, (step) {
      return step.copyWith(
        status: 'error',
        summary: '${event['summary'] ?? '执行失败'}',
        runtimeMs: _asInt(event['runtime_ms']),
      );
    });
  }
  return current;
}

AudioAnalysisState _updateProgressStep(
  AudioAnalysisState current,
  String stepId,
  AudioAnalysisProgressStep Function(AudioAnalysisProgressStep step) update,
) {
  final steps = [...current.progressSteps];
  final index = steps.indexWhere((step) => step.id == stepId);
  final fallback = AudioAnalysisProgressStep(
    id: stepId,
    label: stepId,
    detail: '',
    status: 'pending',
    weight: 1,
  );
  if (index < 0) {
    steps.add(update(fallback));
  } else {
    steps[index] = update(steps[index]);
  }
  return AudioAnalysisState(
    busy: current.busy,
    path: current.path,
    result: current.result,
    error: current.error,
    progressSteps: steps,
  );
}

String _stripProgressLines(String value) {
  return value
      .split('\n')
      .where((line) => !line.startsWith(_progressPrefix))
      .join('\n');
}

Map<String, dynamic>? _asMap(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return value.map((key, item) => MapEntry('$key', item));
  return null;
}

double? _asDouble(Object? value) {
  if (value is double) return value;
  if (value is int) return value.toDouble();
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value);
  return null;
}

int? _asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.round();
  if (value is String) return int.tryParse(value);
  return null;
}

List<double> _doubleList(List<Object?> values) {
  return [
    for (final value in values)
      if (_asDouble(value) != null) _asDouble(value)!,
  ];
}

List<String> _stringList(List<Object?> values) {
  return [
    for (final value in values)
      if (value != null) '$value',
  ];
}

List<Object?> _asList(Object? value) {
  return value is List ? value : const [];
}

Map<String, List<AudioPointCandidate>> _parsePointCandidates(
  Map<String, dynamic> candidatesJson,
) {
  return {
    for (final key in const ['td', 'pd'])
      key: [
        for (final item in _asList(candidatesJson[key]))
          if (_asMap(item) case final map?)
            AudioPointCandidate(
              t: _asDouble(map['t']) ?? 0,
              score: _asDouble(map['score']) ?? 0,
              why: '${map['why'] ?? ''}',
            ),
      ],
  };
}

Map<String, List<AudioLoopCandidate>> _parseLoopCandidates(
  Map<String, dynamic> candidatesJson,
) {
  return {
    for (final key in const ['tl', 'pl'])
      key: [
        for (final item in _asList(candidatesJson[key]))
          if (_asMap(item) case final map?)
            AudioLoopCandidate(
              start: _asDouble(map['start']) ?? 0,
              end: _asDouble(map['end']) ?? 0,
              score: _asDouble(map['score']) ?? 0,
              bars: _asInt(map['bars']) ?? 0,
              why: '${map['why'] ?? ''}',
            ),
      ],
  };
}

Map<String, dynamic> _markersFromCandidates(
  Map<String, List<AudioPointCandidate>> pointCandidates,
  Map<String, List<AudioLoopCandidate>> loopCandidates,
) {
  return {
    if ((pointCandidates['td'] ?? const []).isNotEmpty)
      'TrackDrop': pointCandidates['td']!.first.t,
    if ((pointCandidates['pd'] ?? const []).isNotEmpty)
      'PostDrop': pointCandidates['pd']!.first.t,
    if ((loopCandidates['tl'] ?? const []).isNotEmpty) ...{
      'TrackLoopStart': loopCandidates['tl']!.first.start,
      'TrackLoopEnd': loopCandidates['tl']!.first.end,
    },
    if ((loopCandidates['pl'] ?? const []).isNotEmpty) ...{
      'PostRaceLoopStart': loopCandidates['pl']!.first.start,
      'PostRaceLoopEnd': loopCandidates['pl']!.first.end,
    },
  };
}
