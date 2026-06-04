import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'path_keys.dart';
import 'project_refs.dart';
import 'project_workspace.dart';
import 'track_metadata_cache.dart';

const trackMarkerKeys = <String>[
  'TrackDrop',
  'PostDrop',
  'TrackLoopStart',
  'TrackLoopEnd',
  'PostRaceLoopStart',
  'PostRaceLoopEnd',
];

const trackGroupKeys = <String>['td', 'pd', 'tl', 'pl'];

class TrackTimingConfig {
  const TrackTimingConfig({
    required this.source,
    required this.bpm,
    required this.markersSec,
    required this.confirmed,
    required this.updatedAt,
    this.trackKey,
  });

  final String source;
  final double bpm;
  final Map<String, double> markersSec;
  final Map<String, bool> confirmed;
  final DateTime updatedAt;

  /// Durable project identity for this track, derived from its canonical
  /// `source_ref`. Persisted in `track_timing.json`; `source` stays a runtime
  /// value resolved from the asset index when the config is read back.
  final String? trackKey;

  TrackTimingConfig copyWith({String? source, String? trackKey}) {
    return TrackTimingConfig(
      source: source ?? this.source,
      bpm: bpm,
      markersSec: markersSec,
      confirmed: confirmed,
      updatedAt: updatedAt,
      trackKey: trackKey ?? this.trackKey,
    );
  }

  String get key => keyForPath(source);

  bool get allConfirmed =>
      trackGroupKeys.every((key) => confirmed[key] == true);

  int get confirmedGroupCount =>
      trackGroupKeys.where((key) => confirmed[key] == true).length;

  /// Durable form for `track_timing.json`.
  ///
  /// `track_key` is the authoritative identity. `source` is a runtime value and
  /// must not be persisted for project-owned tracks.
  Map<String, dynamic> toJson() {
    return {
      if (trackKey != null) 'track_key': trackKey,
      'bpm': bpm,
      'markers_sec': markersSec,
      'confirmed': confirmed,
      'updated_at': updatedAt.toUtc().toIso8601String(),
    };
  }

  factory TrackTimingConfig.fromJson(Map<String, dynamic> json) {
    final rawTrackKey = _asString(json['track_key']);
    return TrackTimingConfig(
      source: _asString(json['source']),
      trackKey: rawTrackKey.isEmpty ? null : rawTrackKey,
      bpm: _asDouble(json['bpm']),
      markersSec: _doubleMap(json['markers_sec']),
      confirmed: _boolMap(json['confirmed']),
      updatedAt:
          DateTime.tryParse(_asString(json['updated_at'])) ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    );
  }

  static String keyForPath(String path) {
    return canonicalPathKey(path);
  }
}

class TrackTimingStore {
  const TrackTimingStore._();

  static String configPath(String projectDir) {
    return p.join(
      FhRadioStudioProject.analysisDir(projectDir),
      'track_timing.json',
    );
  }

  static String buildManifestPath(String projectDir) {
    return p.join(
      FhRadioStudioProject.analysisDir(projectDir),
      'build_timing_manifest.json',
    );
  }

  static Map<String, TrackTimingConfig> readAll(String projectDir) {
    final file = File(configPath(projectDir));
    if (!file.existsSync()) return const {};
    try {
      final decoded = jsonDecode(file.readAsStringSync(encoding: utf8));
      final tracks = decoded is Map ? decoded['tracks'] : null;
      if (tracks is! List) return const {};
      final index = TrackMetadataCache.assetIndex(projectDir);
      final out = <String, TrackTimingConfig>{};
      for (final item in tracks) {
        if (item is! Map) continue;
        var config = TrackTimingConfig.fromJson(
          item.map((key, value) => MapEntry('$key', value)),
        );
        // `track_key` is authoritative: resolve it to the live file through the
        // asset index so a moved project still matches. A project-internal
        // legacy `source` without `track_key` is a migration/schema error.
        final sourceRef = config.trackKey == null
            ? null
            : index[config.trackKey];
        final resolved = sourceRef == null
            ? null
            : _resolveProjectRefOrNull(projectDir, sourceRef);
        if (resolved != null) {
          config = config.copyWith(source: resolved);
        } else if (config.trackKey == null &&
            _isProjectInternalSource(projectDir, config.source)) {
          throw ProjectRefException(
            'Legacy project timing source requires migration: ${config.source}',
          );
        }
        if (config.source.trim().isEmpty) continue;
        out[config.key] = config;
      }
      return out;
    } on FormatException {
      return const {};
    } on FileSystemException {
      return const {};
    }
  }

  static void writeAll(
    String projectDir,
    Map<String, TrackTimingConfig> configs,
  ) {
    FhRadioStudioProject.ensure(projectDir);
    final file = File(configPath(projectDir));
    file.parent.createSync(recursive: true);
    final ordered = configs.values.toList()
      ..sort(
        (a, b) => a.source.toLowerCase().compareTo(b.source.toLowerCase()),
      );
    file.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        'schema_version': 2,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
        'tracks': [
          for (final config in ordered)
            _withTrackKey(projectDir, config).toJson(),
        ],
      }),
      encoding: utf8,
    );
  }

  /// Ensure a config carries its durable `track_key` before it is written.
  /// Derived directly from the project source_ref, so it never needs the asset
  /// index to be populated first.
  static TrackTimingConfig _withTrackKey(
    String projectDir,
    TrackTimingConfig config,
  ) {
    if (config.trackKey != null) return config;
    String? trackKey;
    try {
      trackKey = trackKeyForProjectPath(projectDir, config.source);
    } on ProjectRefException {
      trackKey = null;
    } on ArgumentError {
      trackKey = null;
    }
    if (trackKey == null) {
      throw ProjectRefException(
        'Track timing source is not a project-owned audio file: ${config.source}',
      );
    }
    return config.copyWith(trackKey: trackKey);
  }

  static void save(String projectDir, TrackTimingConfig config) {
    final all = Map<String, TrackTimingConfig>.from(readAll(projectDir));
    all[config.key] = config;
    writeAll(projectDir, all);
  }

  static void remove(String projectDir, String source) {
    final all = Map<String, TrackTimingConfig>.from(readAll(projectDir));
    all.remove(TrackTimingConfig.keyForPath(source));
    writeAll(projectDir, all);
  }

  static String? writeBuildManifest({
    required String projectDir,
    required List<String> musicInputs,
  }) {
    final configs = readAll(projectDir);
    final files = FhRadioStudioProject.collectAudioFiles(musicInputs);
    final tracks = <Map<String, dynamic>>[];
    for (final file in files) {
      final config = configs[TrackTimingConfig.keyForPath(file.path)];
      if (config == null || !config.allConfirmed) continue;
      if (!trackMarkerKeys.every(config.markersSec.containsKey)) continue;
      tracks.add(_withTrackKey(projectDir, config).toJson());
    }
    if (tracks.isEmpty) return null;
    final path = buildManifestPath(projectDir);
    final file = File(path);
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        'schema_version': 2,
        'created_at': DateTime.now().toUtc().toIso8601String(),
        'tracks': tracks,
      }),
      encoding: utf8,
    );
    return path;
  }
}

String? _resolveProjectRefOrNull(String projectDir, String sourceRef) {
  try {
    return resolveProjectRef(projectDir, sourceRef);
  } on ProjectRefException {
    return null;
  }
}

bool _isProjectInternalSource(String projectDir, String source) {
  if (source.trim().isEmpty) return false;
  try {
    return trackKeyForProjectPath(projectDir, source) != null;
  } on ProjectRefException {
    return false;
  } on ArgumentError {
    return false;
  }
}

String _asString(Object? value) => value == null ? '' : '$value';

double _asDouble(Object? value) => _nullableDouble(value) ?? 0;

double? _nullableDouble(Object? value) {
  if (value is double) return value;
  if (value is int) return value.toDouble();
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value);
  return null;
}

Map<String, double> _doubleMap(Object? value) {
  if (value is! Map) return const {};
  return {
    for (final entry in value.entries)
      if (_nullableDouble(entry.value) != null)
        '${entry.key}': _nullableDouble(entry.value)!,
  };
}

Map<String, bool> _boolMap(Object? value) {
  if (value is! Map) return const {};
  return {
    for (final entry in value.entries) '${entry.key}': entry.value == true,
  };
}
