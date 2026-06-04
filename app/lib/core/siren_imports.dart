import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'path_keys.dart';
import 'project_refs.dart';
import 'project_workspace.dart';
import 'siren_catalog.dart';
import 'track_metadata_cache.dart';

class SirenImportEntry {
  const SirenImportEntry({
    required this.cid,
    required this.title,
    required this.albumCid,
    required this.albumName,
    required this.artist,
    required this.artists,
    required this.coverUrl,
    required this.lyricUrl,
    required this.path,
    required this.importedAt,
    this.trackKey,
  });

  factory SirenImportEntry.fromSiren({
    required SirenTrack track,
    required SirenSongDetail detail,
    required String path,
  }) {
    final artists = sirenArtistsForDisplay(
      detail.artists.isEmpty ? track.artists : detail.artists,
    );
    return SirenImportEntry(
      cid: detail.cid,
      title: detail.name.isEmpty ? track.name : detail.name,
      albumCid: detail.albumCid.isEmpty ? track.albumCid : detail.albumCid,
      albumName: track.albumName,
      artist: artists.first,
      artists: artists,
      coverUrl: track.coverUrl,
      lyricUrl: detail.lyricUrl,
      path: File(path).absolute.path,
      importedAt: DateTime.now().toUtc(),
    );
  }

  final String cid;
  final String title;
  final String albumCid;
  final String albumName;
  final String artist;
  final List<String> artists;
  final String coverUrl;
  final String? lyricUrl;
  final String path;
  final DateTime importedAt;

  /// Durable project identity for the imported siren wav, derived from its
  /// canonical `source_ref` (`fh-project:/siren/<name>.wav`). Persisted in
  /// `siren_imports.json`; `path` is a runtime value resolved from the asset
  /// index when the record is read back.
  final String? trackKey;

  String get pathKey => sirenPathKey(path);

  SirenImportEntry copyWith({String? path, String? trackKey}) {
    return SirenImportEntry(
      cid: cid,
      title: title,
      albumCid: albumCid,
      albumName: albumName,
      artist: artist,
      artists: artists,
      coverUrl: coverUrl,
      lyricUrl: lyricUrl,
      path: path ?? this.path,
      importedAt: importedAt,
      trackKey: trackKey ?? this.trackKey,
    );
  }

  static SirenImportEntry? fromJson(Map json) {
    final cid = _string(json['cid']);
    final title = _string(json['title']);
    final path = _string(json['path']);
    final rawTrackKey = _string(json['track_key']);
    if (cid == null || title == null) return null;
    if ((path == null || path.isEmpty) && rawTrackKey == null) return null;
    final artists =
        (json['artists'] is List ? json['artists'] as List : const [])
            .map(_string)
            .nonNulls
            .toList(growable: false);
    final artist = _string(json['artist']);
    return SirenImportEntry(
      cid: cid,
      title: title,
      albumCid: _string(json['album_cid']) ?? '',
      albumName: _string(json['album_name']) ?? '未知专辑',
      artist: artist == null || artist == monsterSirenArtistName
          ? sirenArtistsForDisplay(artists).first
          : artist,
      artists: artists,
      coverUrl: _string(json['cover_url']) ?? '',
      lyricUrl: _string(json['lyric_url']),
      path: path ?? '',
      trackKey: rawTrackKey,
      importedAt:
          DateTime.tryParse(_string(json['imported_at']) ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    );
  }

  /// Durable form for `siren_imports.json`.
  ///
  /// `track_key` is the authoritative identity. `path` is a runtime value and
  /// must not be persisted for project-owned imports.
  Map<String, Object?> toJson() {
    return {
      if (trackKey != null) 'track_key': trackKey,
      'cid': cid,
      'title': title,
      'album_cid': albumCid,
      'album_name': albumName,
      'artist': artist,
      'artists': artists,
      'cover_url': coverUrl,
      'lyric_url': lyricUrl,
      'imported_at': importedAt.toIso8601String(),
    };
  }
}

class SirenImportRegistry {
  const SirenImportRegistry._();

  static String configPath(String projectDir) {
    return p.join(
      FhRadioStudioProject.sirenDir(projectDir),
      'siren_imports.json',
    );
  }

  static List<SirenImportEntry> read(String projectDir) {
    final file = File(configPath(projectDir));
    if (!file.existsSync()) return const [];
    try {
      final decoded = jsonDecode(file.readAsStringSync(encoding: utf8));
      if (decoded is! Map) return const [];
      final tracks = decoded['tracks'];
      if (tracks is! List) return const [];
      final index = TrackMetadataCache.assetIndex(projectDir);
      final parsed = <SirenImportEntry>[];
      for (final item in tracks) {
        if (item is! Map) continue;
        var entry = SirenImportEntry.fromJson(item);
        if (entry == null) continue;
        // `track_key` is authoritative: resolve it to the live siren wav through
        // the asset index. A project-internal legacy `path` without `track_key`
        // is a migration/schema error.
        final sourceRef = entry.trackKey == null ? null : index[entry.trackKey];
        final resolved = sourceRef == null
            ? null
            : _resolveProjectRefOrNull(projectDir, sourceRef);
        if (resolved != null) entry = entry.copyWith(path: resolved);
        if (entry.trackKey == null &&
            _isProjectInternalPath(projectDir, entry.path)) {
          throw ProjectRefException(
            'Legacy project siren import path requires migration: ${entry.path}',
          );
        }
        if (entry.path.trim().isEmpty) continue;
        parsed.add(entry);
      }
      return parsed;
    } on FileSystemException {
      return const [];
    } on FormatException {
      return const [];
    }
  }

  static Map<String, SirenImportEntry> readByPath(String projectDir) {
    return {for (final entry in read(projectDir)) entry.pathKey: entry};
  }

  static Set<String> importedCids(String projectDir) {
    return {for (final entry in read(projectDir)) entry.cid};
  }

  static void upsert(String projectDir, SirenImportEntry entry) {
    final entries = read(projectDir);
    final byKey = {for (final item in entries) item.pathKey: item};
    byKey[entry.pathKey] = _withTrackKey(projectDir, entry);
    _write(projectDir, byKey.values.toList(growable: false));
  }

  static void removeByPath(String projectDir, String path) {
    final key = sirenPathKey(path);
    final kept = [
      for (final entry in read(projectDir))
        if (entry.pathKey != key) entry,
    ];
    _write(projectDir, kept);
  }

  static void _write(String projectDir, List<SirenImportEntry> entries) {
    final file = File(configPath(projectDir));
    file.parent.createSync(recursive: true);
    final sorted = entries.toList(growable: false)
      ..sort((a, b) {
        final byAlbum = a.albumName.compareTo(b.albumName);
        if (byAlbum != 0) return byAlbum;
        return a.title.compareTo(b.title);
      });
    file.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        'schema_version': 2,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
        'tracks': [
          for (final entry in sorted) _withTrackKey(projectDir, entry).toJson(),
        ],
      }),
      encoding: utf8,
    );
  }

  /// Ensure a record carries its durable `track_key` before it is written.
  /// Derived directly from the project source_ref of the siren wav.
  static SirenImportEntry _withTrackKey(
    String projectDir,
    SirenImportEntry entry,
  ) {
    if (entry.trackKey != null) return entry;
    String? trackKey;
    try {
      trackKey = trackKeyForProjectPath(projectDir, entry.path);
    } on ProjectRefException {
      trackKey = null;
    } on ArgumentError {
      trackKey = null;
    }
    if (trackKey == null) {
      throw ProjectRefException(
        'Siren import path is not a project-owned audio file: ${entry.path}',
      );
    }
    return entry.copyWith(trackKey: trackKey);
  }
}

String sirenPathKey(String path) => canonicalPathKey(path);

String? _resolveProjectRefOrNull(String projectDir, String sourceRef) {
  try {
    return resolveProjectRef(projectDir, sourceRef);
  } on ProjectRefException {
    return null;
  }
}

bool _isProjectInternalPath(String projectDir, String path) {
  if (path.trim().isEmpty) return false;
  try {
    return trackKeyForProjectPath(projectDir, path) != null;
  } on ProjectRefException {
    return false;
  } on ArgumentError {
    return false;
  }
}

String? _string(Object? value) {
  final text = value?.toString().trim();
  return text == null || text.isEmpty ? null : text;
}
