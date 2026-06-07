// Replacement editor domain models and bundled seed data.

import 'dart:math' as math;

/// 4 个时间组的 kind 枚举。颜色编码必须保持：
/// - td → 主 accent
/// - pd → 紫 (RmTokens.tgPdPurple)
/// - tl → 蓝 (RmTokens.tgTlBlue)
/// - pl → 橙 (RmTokens.tgPlOrange)
enum GroupKind {
  td, // TrackDrop  · 比赛开始的播放起点 · 48000 Hz
  pd, // PostDrop   · 冲线后的播放起点 · 48000 Hz
  tl, // TrackLoop  · 比赛中循环段 (A→B) · 48000 Hz
  pl, // PostLoop   · 冲线循环段 (A→B) · 48000 Hz
}

enum FineTarget { point, loopStart, loopEnd }

extension GroupKindX on GroupKind {
  String get code => switch (this) {
    GroupKind.td => 'TD',
    GroupKind.pd => 'PD',
    GroupKind.tl => 'TL',
    GroupKind.pl => 'PL',
  };
  String get name => switch (this) {
    GroupKind.td => 'TrackDrop',
    GroupKind.pd => 'PostDrop',
    GroupKind.tl => 'TrackLoop',
    GroupKind.pl => 'PostLoop',
  };
  String get description => switch (this) {
    GroupKind.td => '比赛开始时的播放起点（高潮起点）',
    GroupKind.pd => '冲线动画后的播放起点（次高潮）',
    GroupKind.tl => '比赛中无缝循环段的两端（A → B → A）',
    GroupKind.pl => '冲线后无缝循环段的两端',
  };
  int get sampleRate => switch (this) {
    GroupKind.td || GroupKind.pd || GroupKind.tl || GroupKind.pl => 48000,
  };
  bool get isLoop => this == GroupKind.tl || this == GroupKind.pl;
}

class PointCandidate {
  const PointCandidate({
    required this.t,
    required this.score,
    required this.why,
  });
  final double t;
  final double score;
  final String why;

  PointCandidate copyWith({double? t, double? score, String? why}) {
    return PointCandidate(
      t: t ?? this.t,
      score: score ?? this.score,
      why: why ?? this.why,
    );
  }
}

class LoopCandidate {
  const LoopCandidate({
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

  LoopCandidate copyWith({
    double? start,
    double? end,
    double? score,
    int? bars,
    String? why,
  }) {
    return LoopCandidate(
      start: start ?? this.start,
      end: end ?? this.end,
      score: score ?? this.score,
      bars: bars ?? this.bars,
      why: why ?? this.why,
    );
  }
}

class Segment {
  const Segment({required this.start, required this.end, required this.label});
  final double start;
  final double end;

  /// Free-form label emitted by the CLI/provider. The UI must not treat this
  /// as a fixed enum.
  final String label;
}

class AiResult {
  const AiResult({
    required this.durationSec,
    required this.bpm,
    required this.confidence,
    required this.td,
    required this.pd,
    required this.tl,
    required this.pl,
    required this.beats,
    required this.segments,
    this.sourceSampleRate = 48000,
    this.channels = 2,
    this.sourceSamples,
    this.decoder = '',
    this.waveformPeaks = const [],
    this.rmsDbfs,
    this.peakDbfs,
    this.aiNote = '',
  });

  final double durationSec;
  final double bpm;
  final double confidence;
  final List<PointCandidate> td;
  final List<PointCandidate> pd;
  final List<LoopCandidate> tl;
  final List<LoopCandidate> pl;
  final List<double> beats;
  final List<Segment> segments;
  final int sourceSampleRate;
  final int channels;
  final int? sourceSamples;
  final String decoder;
  final List<double> waveformPeaks;
  final double? rmsDbfs;
  final double? peakDbfs;
  final String aiNote;

  AiResult copyWith({
    double? durationSec,
    double? bpm,
    double? confidence,
    List<PointCandidate>? td,
    List<PointCandidate>? pd,
    List<LoopCandidate>? tl,
    List<LoopCandidate>? pl,
    List<double>? beats,
    List<Segment>? segments,
    int? sourceSampleRate,
    int? channels,
    int? sourceSamples,
    String? decoder,
    List<double>? waveformPeaks,
    double? rmsDbfs,
    double? peakDbfs,
    String? aiNote,
  }) {
    return AiResult(
      durationSec: durationSec ?? this.durationSec,
      bpm: bpm ?? this.bpm,
      confidence: confidence ?? this.confidence,
      td: td ?? this.td,
      pd: pd ?? this.pd,
      tl: tl ?? this.tl,
      pl: pl ?? this.pl,
      beats: beats ?? this.beats,
      segments: segments ?? this.segments,
      sourceSampleRate: sourceSampleRate ?? this.sourceSampleRate,
      channels: channels ?? this.channels,
      sourceSamples: sourceSamples ?? this.sourceSamples,
      decoder: decoder ?? this.decoder,
      waveformPeaks: waveformPeaks ?? this.waveformPeaks,
      rmsDbfs: rmsDbfs ?? this.rmsDbfs,
      peakDbfs: peakDbfs ?? this.peakDbfs,
      aiNote: aiNote ?? this.aiNote,
    );
  }
}

class ReplacementEdit {
  const ReplacementEdit({
    required this.radio,
    required this.slot,
    required this.originalTitle,
    required this.originalArtist,
    required this.originalDur,
    required this.incomingFile,
    required this.incomingTitle,
    required this.incomingArtist,
    required this.ai,
  });

  final String radio;
  final int slot;
  final String originalTitle;
  final String originalArtist;
  final double originalDur;
  final String incomingFile;
  final String incomingTitle;
  final String incomingArtist;
  final AiResult ai;
}

/// 在编辑器内进行中的草稿（target picker 用）。
class EditDraft {
  const EditDraft({
    required this.radio,
    required this.slot,
    required this.title,
    required this.artist,
    required this.confirmed,
    required this.total,
    required this.bpm,
    this.broken = false,
  });
  final String radio;
  final int slot;
  final String title;
  final String artist;
  final int confirmed;
  final int total;
  final int bpm;
  final bool broken;
}

const List<EditDraft> kDrafts = [
  EditDraft(
    radio: 'R1',
    slot: 5,
    title: 'Midnight Cascade',
    artist: 'User Import',
    confirmed: 0,
    total: 4,
    bpm: 128,
  ),
  EditDraft(
    radio: 'R3',
    slot: 3,
    title: 'Velvet Avenue',
    artist: 'User Import',
    confirmed: 2,
    total: 4,
    bpm: 96,
  ),
  EditDraft(
    radio: 'R4',
    slot: 2,
    title: 'Iron in the Carburetor',
    artist: 'User Import',
    confirmed: 4,
    total: 4,
    bpm: 142,
    broken: true,
  ),
];

// ============================================================
// 默认编辑器数据
// ============================================================
List<double> _genBeats(double duration, double bpm) {
  final n = (duration * bpm / 60).floor();
  return List<double>.generate(n, (i) => i * 60 / bpm + 0.184);
}

final ReplacementEdit kReplacementEdit = ReplacementEdit(
  radio: 'R1',
  slot: 5,
  originalTitle: 'Daybreak Highway',
  originalArtist: 'Atlas Run',
  originalDur: 204.7,
  incomingFile: '/Users/kira/Music/Sources/midnight-cascade.flac',
  incomingTitle: 'Midnight Cascade',
  incomingArtist: 'User Import',
  ai: AiResult(
    durationSec: 214.309,
    bpm: 128.0,
    confidence: 0.78,
    td: const [
      PointCandidate(t: 68.72, score: 0.92, why: '首个 chorus 入口（drop 后 1 拍）'),
      PointCandidate(t: 90.51, score: 0.61, why: '第二段副歌起始'),
      PointCandidate(t: 152.20, score: 0.44, why: 'Bridge 后回归主题'),
    ],
    pd: const [
      PointCandidate(t: 148.72, score: 0.88, why: '终段 chorus，能量峰值'),
      PointCandidate(t: 170.50, score: 0.54, why: 'Outro 前的最后一次副歌'),
      PointCandidate(t: 90.51, score: 0.41, why: '回退到第二段副歌'),
    ],
    tl: const [
      LoopCandidate(
        start: 23.01,
        end: 118.25,
        score: 0.86,
        bars: 32,
        why: 'Verse → Chorus，32 小节闭环，downbeat 对齐',
      ),
      LoopCandidate(
        start: 55.01,
        end: 118.25,
        score: 0.74,
        bars: 24,
        why: '短版本，更密集',
      ),
      LoopCandidate(
        start: 23.01,
        end: 88.13,
        score: 0.42,
        bars: 16,
        why: '信心不足：循环点频谱不连续',
      ),
    ],
    pl: const [
      LoopCandidate(
        start: 97.27,
        end: 177.27,
        score: 0.83,
        bars: 24,
        why: 'Chorus → Outro 入口，能量回落自然',
      ),
      LoopCandidate(
        start: 120.50,
        end: 177.27,
        score: 0.66,
        bars: 16,
        why: '更短的尾段循环',
      ),
      LoopCandidate(
        start: 145.00,
        end: 200.30,
        score: 0.39,
        bars: 12,
        why: '信心不足：会被淡出截断',
      ),
    ],
    beats: _beats,
    segments: const [
      Segment(start: 0, end: 23.01, label: 'intro'),
      Segment(start: 23.01, end: 55.01, label: 'verse'),
      Segment(start: 55.01, end: 90.51, label: 'chorus'),
      Segment(start: 90.51, end: 118.25, label: 'verse'),
      Segment(start: 118.25, end: 148.72, label: 'bridge'),
      Segment(start: 148.72, end: 177.27, label: 'chorus'),
      Segment(start: 177.27, end: 214.31, label: 'outro'),
    ],
  ),
);

final List<double> _beats = _genBeats(214.309, 128.0);

/// 把秒数格式化为 `m:ss.SS`（mono timecode）。
String formatTimecode(double? t) {
  if (t == null || t.isNaN) return '—';
  final neg = t < 0;
  final abs = t.abs();
  final m = abs ~/ 60;
  final s = abs % 60;
  return '${neg ? "-" : ""}$m:${s.toStringAsFixed(2).padLeft(5, "0")}';
}

/// 把秒 × 采样率换算成采样数，并加千分位。
String formatSamples(double seconds, int sampleRate) {
  final n = (seconds * sampleRate).round();
  // simple thousands separator
  final s = n.toString();
  final buf = StringBuffer();
  for (int i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
    buf.write(s[i]);
  }
  return buf.toString();
}

/// 给一个时间点找到包含它的 segment（fallback 最后一个）。
Segment segmentAt(List<Segment> segments, double t) {
  for (final s in segments) {
    if (t >= s.start && t < s.end) return s;
  }
  return segments.last;
}

/// 用于波形 painter 的"伪噪声" — 与 design/components/waveform.jsx 的 seedNoise + buildWaveform 等效。
class WaveformBars {
  WaveformBars._(this.values);
  final List<double> values;

  factory WaveformBars.build({
    required List<Segment> segments,
    required double duration,
    int barCount = 220,
    int seed = 42,
  }) {
    int s = seed;
    double rand() {
      s = (s * 1664525 + 1013904223) & 0xFFFFFFFF;
      return s / 0xFFFFFFFF;
    }

    final out = List<double>.filled(barCount, 0);
    for (int i = 0; i < barCount; i++) {
      final t = (i / (barCount - 1)) * duration;
      Segment? seg;
      for (final sgm in segments) {
        if (t >= sgm.start && t < sgm.end) {
          seg = sgm;
          break;
        }
      }
      seg ??= segments.last;
      final base = _energyForLabel(seg.label);
      final wobble = 0.5 + math.sin(t * 1.2) * 0.18 + math.cos(t * 0.45) * 0.1;
      final grain = rand() * 0.35 + 0.65;
      out[i] = (base * wobble * grain).clamp(0.05, 1.0);
    }
    return WaveformBars._(out);
  }

  factory WaveformBars.fromValues(List<double> values) {
    if (values.isEmpty) return WaveformBars._(const []);
    final finite = [
      for (final value in values)
        if (value.isFinite) value.clamp(0.0, 1.0).toDouble(),
    ];
    if (finite.isEmpty) return WaveformBars._(const []);
    final sorted = [...finite]..sort();
    final low = _percentile(sorted, 0.08);
    final high = _percentile(sorted, 0.96);
    final maxValue = sorted.last <= 0 ? 1.0 : sorted.last;
    final range = high - low;
    return WaveformBars._([
      for (final value in finite)
        _displayAmplitude(value, low, range, maxValue),
    ]);
  }

  static double _displayAmplitude(
    double value,
    double low,
    double range,
    double maxValue,
  ) {
    if (value <= 0.0001) return 0.05;
    final absolute = (value / maxValue).clamp(0.0, 1.0).toDouble();
    final relative = range < 0.04
        ? absolute
        : ((value - low) / range).clamp(0.0, 1.0).toDouble();
    final shaped = math.pow(relative, 0.72).toDouble();
    return (0.05 + absolute * 0.10 + shaped * 0.72)
        .clamp(0.05, 0.87)
        .toDouble();
  }

  static double _percentile(List<double> sorted, double p) {
    if (sorted.isEmpty) return 0;
    if (sorted.length == 1) return sorted.first;
    final position = p.clamp(0.0, 1.0) * (sorted.length - 1);
    final lower = position.floor();
    final upper = position.ceil();
    if (lower == upper) return sorted[lower];
    final weight = position - lower;
    return sorted[lower] * (1 - weight) + sorted[upper] * weight;
  }

  static double _energyForLabel(String label) {
    final normalized = label.trim().toLowerCase();
    if (normalized.isEmpty) return 0.5;
    var hash = 0;
    for (final code in normalized.codeUnits) {
      hash = ((hash * 31) + code) & 0x7fffffff;
    }
    return 0.32 + (hash % 1000) / 999 * 0.58;
  }
}
