import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'path_keys.dart';
import 'project_workspace.dart';
import 'siren_catalog.dart';

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

  String get pathKey => trackKey(path);

  static SirenImportEntry? fromJson(Map json) {
    final cid = _string(json['cid']);
    final title = _string(json['title']);
    final path = _string(json['path']);
    if (cid == null || title == null || path == null) return null;
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
      path: path,
      importedAt:
          DateTime.tryParse(_string(json['imported_at']) ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    );
  }

  Map<String, Object?> toJson() {
    return {
      'cid': cid,
      'title': title,
      'album_cid': albumCid,
      'album_name': albumName,
      'artist': artist,
      'artists': artists,
      'cover_url': coverUrl,
      'lyric_url': lyricUrl,
      'path': path,
      'path_key': pathKey,
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
      final parsed = <SirenImportEntry>[];
      for (final item in tracks) {
        if (item is! Map) continue;
        final entry = SirenImportEntry.fromJson(item);
        if (entry != null) parsed.add(entry);
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
    byKey[entry.pathKey] = entry;
    _write(projectDir, byKey.values.toList(growable: false));
  }

  static void removeByPath(String projectDir, String path) {
    final key = trackKey(path);
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
        'schema_version': 1,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
        'tracks': [for (final entry in sorted) entry.toJson()],
      }),
      encoding: utf8,
    );
  }
}

String trackKey(String path) => canonicalPathKey(path);

String? _string(Object? value) {
  final text = value?.toString().trim();
  return text == null || text.isEmpty ? null : text;
}
