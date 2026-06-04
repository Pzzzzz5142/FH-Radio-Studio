import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'path_keys.dart';
import 'project_refs.dart';
import 'project_workspace.dart';

class TrackMetadata {
  const TrackMetadata({
    required this.artist,
    required this.title,
    required this.fromTags,
    this.durationSec,
    this.sampleRate,
    this.channels,
    this.samples,
    this.integratedLufs,
    this.coverArtPath,
  });

  final String artist;
  final String title;
  final bool fromTags;
  final double? durationSec;
  final int? sampleRate;
  final int? channels;
  final int? samples;
  final double? integratedLufs;
  final String? coverArtPath;
}

class TrackMetadataCache {
  const TrackMetadataCache._();

  static String configPath(String projectDir) {
    return p.join(
      FhRadioStudioProject.metadataDir(projectDir),
      'track_metadata.json',
    );
  }

  static Map<String, TrackMetadata> read(String projectDir) {
    final file = File(configPath(projectDir));
    if (!file.existsSync()) return const {};
    try {
      final decoded = jsonDecode(file.readAsStringSync(encoding: utf8));
      if (decoded is! Map) return const {};
      final tracks = decoded['tracks'];
      if (tracks is! List) return const {};
      final out = <String, TrackMetadata>{};
      for (final item in tracks) {
        if (item is! Map) continue;
        final sourceRef = _readString(item, 'source_ref');
        // `source_ref` is authoritative: resolve it against the currently open
        // project. A project-internal legacy `source` without `source_ref` is a
        // migration/schema error.
        final source = sourceRef == null
            ? _readString(item, 'source')
            : _resolveProjectRefOrNull(projectDir, sourceRef);
        if (sourceRef == null && _isProjectInternalPath(projectDir, source)) {
          throw ProjectRefException(
            'Legacy project metadata source requires migration: $source',
          );
        }
        final title = _readString(item, 'title');
        final artist = _readString(item, 'artist');
        if (source == null || title == null || artist == null) continue;
        final loudness = item['loudness_analysis'] is Map
            ? item['loudness_analysis'] as Map
            : null;
        // The returned map is a runtime convenience keyed by the resolved file's
        // canonical path, matching how callers join it to live files
        // (`metadata[canonicalPathKey(path)]`). The durable `track_key` identity
        // lives in the asset index (`assetIndex` / `resolveTrackKey`), not here.
        out[_trackKey(source)] = TrackMetadata(
          artist: artist,
          title: title,
          fromTags: item['from_tags'] == true,
          durationSec: _readDouble(item, 'duration_sec'),
          sampleRate: _readInt(item, 'sample_rate'),
          channels: _readInt(item, 'channels'),
          samples: _readInt(item, 'samples'),
          integratedLufs: loudness?['status'] == 'ok'
              ? _readDouble(loudness!, 'integrated_lufs')
              : null,
          coverArtPath: _resolveProjectPathOrNull(
            projectDir,
            _readString(item, 'cover_art_path'),
          ),
        );
      }
      return out;
    } on FormatException {
      return const {};
    } on FileSystemException {
      return const {};
    }
  }

  /// The authoritative `track_key -> source_ref` map for the project.
  ///
  /// `track_metadata.json` doubles as the project track asset index: every
  /// project-owned audio file scanned by `scan-metadata` carries a canonical
  /// `source_ref` and the `track_key` derived from it. Business records
  /// (timing, siren, playlist) persist only `track_key` and resolve back to a
  /// runtime path through this index.
  static Map<String, String> assetIndex(String projectDir) {
    final file = File(configPath(projectDir));
    if (!file.existsSync()) return const {};
    try {
      final decoded = jsonDecode(file.readAsStringSync(encoding: utf8));
      if (decoded is! Map) return const {};
      final tracks = decoded['tracks'];
      if (tracks is! List) return const {};
      final out = <String, String>{};
      for (final item in tracks) {
        if (item is! Map) continue;
        final trackKey = _readString(item, 'track_key');
        final sourceRef = _readString(item, 'source_ref');
        if (trackKey == null || sourceRef == null) continue;
        try {
          out[trackKey] = normalizeProjectRef(sourceRef);
        } on ProjectRefException {
          continue;
        }
      }
      return out;
    } on FormatException {
      return const {};
    } on FileSystemException {
      return const {};
    }
  }

  /// Resolve a `track_key` to a runtime absolute path via the asset index.
  static String? resolveTrackKey(String projectDir, String trackKey) {
    final sourceRef = assetIndex(projectDir)[trackKey];
    if (sourceRef == null) return null;
    return _resolveProjectRefOrNull(projectDir, sourceRef);
  }

  static void remove(String projectDir, String source) {
    final file = File(configPath(projectDir));
    if (!file.existsSync()) return;
    try {
      final decoded = jsonDecode(file.readAsStringSync(encoding: utf8));
      if (decoded is! Map) return;
      final tracks = decoded['tracks'];
      if (tracks is! List) return;
      final projectTrackKey = _trackKeyForProjectPathOrNull(projectDir, source);
      final sourceKeys = {?projectTrackKey, _trackKey(source)};
      final kept = <Object?>[];
      var changed = false;
      for (final item in tracks) {
        if (item is! Map) {
          kept.add(item);
          continue;
        }
        final trackKey = _readString(item, 'track_key');
        final sourceRef = _readString(item, 'source_ref');
        final pathKey = _readString(item, 'path_key');
        final itemSource = _readString(item, 'source');
        final itemKey =
            trackKey ??
            (sourceRef == null
                ? null
                : _trackKeyForSourceRefOrNull(sourceRef)) ??
            pathKey ??
            (itemSource == null ? null : _trackKey(itemSource));
        if (itemKey != null && sourceKeys.contains(itemKey)) {
          changed = true;
          continue;
        }
        kept.add(item);
      }
      if (!changed) return;
      final data = decoded.map((key, value) => MapEntry('$key', value));
      data['tracks'] = kept;
      data['updated_at'] = DateTime.now().toUtc().toIso8601String();
      file.writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(data),
        encoding: utf8,
      );
    } on FormatException {
      return;
    } on FileSystemException {
      return;
    }
  }
}

String? _readString(Map object, String name) {
  final value = object[name];
  if (value == null) return null;
  final text = '$value'.trim();
  return text.isEmpty ? null : text;
}

double? _readDouble(Map object, String name) {
  final value = object[name];
  if (value is double) return value;
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value);
  return null;
}

int? _readInt(Map object, String name) {
  final value = object[name];
  if (value is int) return value;
  if (value is num) return value.round();
  if (value is String) return int.tryParse(value);
  return null;
}

String _trackKey(String path) => canonicalPathKey(path);

String? _trackKeyForProjectPathOrNull(String projectDir, String path) {
  try {
    return trackKeyForProjectPath(projectDir, path);
  } on ProjectRefException {
    return null;
  } on ArgumentError {
    return null;
  }
}

String? _trackKeyForSourceRefOrNull(String sourceRef) {
  try {
    return trackKeyForSourceRef(sourceRef);
  } on ProjectRefException {
    return null;
  }
}

String? _resolveProjectRefOrNull(String projectDir, String sourceRef) {
  try {
    return resolveProjectRef(projectDir, sourceRef);
  } on ProjectRefException {
    return null;
  }
}

String? _resolveProjectPathOrNull(String projectDir, String? value) {
  if (value == null) return null;
  if (!isProjectRef(value)) return value;
  return _resolveProjectRefOrNull(projectDir, value);
}

bool _isProjectInternalPath(String projectDir, String? path) {
  if (path == null || path.trim().isEmpty) return false;
  try {
    return trackKeyForProjectPath(projectDir, path) != null;
  } on ProjectRefException {
    return false;
  } on ArgumentError {
    return false;
  }
}
