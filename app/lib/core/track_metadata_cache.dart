import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'path_keys.dart';
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
        final source = _readString(item, 'source');
        final title = _readString(item, 'title');
        final artist = _readString(item, 'artist');
        if (source == null || title == null || artist == null) continue;
        final loudness = item['loudness_analysis'] is Map
            ? item['loudness_analysis'] as Map
            : null;
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
          coverArtPath: _readString(item, 'cover_art_path'),
        );
      }
      return out;
    } on FormatException {
      return const {};
    } on FileSystemException {
      return const {};
    }
  }

  static void remove(String projectDir, String source) {
    final file = File(configPath(projectDir));
    if (!file.existsSync()) return;
    try {
      final decoded = jsonDecode(file.readAsStringSync(encoding: utf8));
      if (decoded is! Map) return;
      final tracks = decoded['tracks'];
      if (tracks is! List) return;
      final sourceKey = _trackKey(source);
      final kept = <Object?>[];
      var changed = false;
      for (final item in tracks) {
        if (item is! Map) {
          kept.add(item);
          continue;
        }
        final pathKey = _readString(item, 'path_key');
        final itemSource = _readString(item, 'source');
        final itemKey =
            pathKey ?? (itemSource == null ? null : _trackKey(itemSource));
        if (itemKey == sourceKey) {
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
