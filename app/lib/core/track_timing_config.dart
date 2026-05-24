import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'path_keys.dart';
import 'project_workspace.dart';

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
  });

  final String source;
  final double bpm;
  final Map<String, double> markersSec;
  final Map<String, bool> confirmed;
  final DateTime updatedAt;

  String get key => keyForPath(source);

  bool get allConfirmed =>
      trackGroupKeys.every((key) => confirmed[key] == true);

  int get confirmedGroupCount =>
      trackGroupKeys.where((key) => confirmed[key] == true).length;

  Map<String, dynamic> toJson() {
    return {
      'source': source,
      'path_key': key,
      'bpm': bpm,
      'markers_sec': markersSec,
      'confirmed': confirmed,
      'updated_at': updatedAt.toUtc().toIso8601String(),
    };
  }

  factory TrackTimingConfig.fromJson(Map<String, dynamic> json) {
    return TrackTimingConfig(
      source: _asString(json['source']),
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
      final out = <String, TrackTimingConfig>{};
      for (final item in tracks) {
        if (item is! Map) continue;
        final config = TrackTimingConfig.fromJson(
          item.map((key, value) => MapEntry('$key', value)),
        );
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
        'tracks': [for (final config in ordered) config.toJson()],
      }),
      encoding: utf8,
    );
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
      tracks.add(config.toJson());
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
