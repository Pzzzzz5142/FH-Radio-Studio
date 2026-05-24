import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_info.dart';

const monsterSirenOrigin = 'https://monster-siren.hypergryph.com';
const monsterSirenArtistName = '塞壬唱片-MSR';
const sirenArtistDisplaySeparator = ' / ';

final sirenCatalogClientProvider = Provider<SirenCatalogClient>((ref) {
  return MonsterSirenCatalogClient();
});

final sirenCatalogProvider = FutureProvider<SirenCatalogSnapshot>((ref) {
  return ref.watch(sirenCatalogClientProvider).fetchCatalog();
});

abstract class SirenCatalogClient {
  Future<SirenCatalogSnapshot> fetchCatalog();

  Future<SirenSongDetail> fetchSongDetail(String cid);

  Future<SirenAlbumDetail> fetchAlbumDetail(String cid);
}

class MonsterSirenCatalogClient implements SirenCatalogClient {
  MonsterSirenCatalogClient({this.timeout = const Duration(seconds: 18)});

  final Duration timeout;

  @override
  Future<SirenCatalogSnapshot> fetchCatalog() async {
    final responses = await Future.wait([
      _getJson('/api/albums'),
      _getJson('/api/songs'),
    ]);
    final albumsJson = responses[0]['data'];
    final songsJson = _asMap(responses[1]['data'])['list'];

    final albums = [
      for (final item in _asList(albumsJson)) SirenAlbum.fromJson(_asMap(item)),
    ];
    final albumByCid = {for (final album in albums) album.cid: album};
    final tracks = [
      for (final item in _asList(songsJson))
        SirenTrack.fromJson(_asMap(item), albumByCid: albumByCid),
    ];
    final trackCounts = <String, int>{};
    for (final track in tracks) {
      trackCounts.update(
        track.albumCid,
        (value) => value + 1,
        ifAbsent: () => 1,
      );
    }

    return SirenCatalogSnapshot(
      fetchedAt: DateTime.now(),
      albums: [
        for (final album in albums)
          album.copyWith(trackCount: trackCounts[album.cid] ?? 0),
      ],
      tracks: tracks,
    );
  }

  @override
  Future<SirenAlbumDetail> fetchAlbumDetail(String cid) async {
    final json = await _getJson('/api/album/$cid/detail');
    return SirenAlbumDetail.fromJson(_asMap(json['data']));
  }

  @override
  Future<SirenSongDetail> fetchSongDetail(String cid) async {
    final json = await _getJson('/api/song/$cid');
    return SirenSongDetail.fromJson(_asMap(json['data']));
  }

  Future<Map<String, dynamic>> _getJson(String path) async {
    final client = HttpClient();
    try {
      final uri = Uri.parse('$monsterSirenOrigin$path');
      final request = await client.getUrl(uri).timeout(timeout);
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      request.headers.set(
        HttpHeaders.userAgentHeader,
        fhRadioStudioUserAgent('SirenLibrary'),
      );
      final response = await request.close().timeout(timeout);
      final body = await response
          .transform(utf8.decoder)
          .join()
          .timeout(timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw SirenCatalogException('请求失败：HTTP ${response.statusCode} $path');
      }
      final decoded = jsonDecode(body);
      if (decoded is! Map) {
        throw SirenCatalogException('响应不是 JSON object：$path');
      }
      final code = decoded['code'];
      if (code is num && code != 0) {
        throw SirenCatalogException('${decoded['msg'] ?? '接口返回错误'}');
      }
      return decoded.map((key, value) => MapEntry('$key', value));
    } on TimeoutException catch (error) {
      throw SirenCatalogException('请求超时：$path', cause: error);
    } on SocketException catch (error) {
      throw SirenCatalogException('网络不可用：${error.message}', cause: error);
    } on FormatException catch (error) {
      throw SirenCatalogException('JSON 解析失败：$path', cause: error);
    } finally {
      client.close(force: true);
    }
  }
}

class SirenCatalogException implements Exception {
  const SirenCatalogException(this.message, {this.cause});

  final String message;
  final Object? cause;

  @override
  String toString() => message;
}

@immutable
class SirenCatalogSnapshot {
  const SirenCatalogSnapshot({
    required this.fetchedAt,
    required this.albums,
    required this.tracks,
  });

  final DateTime fetchedAt;
  final List<SirenAlbum> albums;
  final List<SirenTrack> tracks;

  Map<String, SirenAlbum> get albumByCid => {
    for (final album in albums) album.cid: album,
  };

  List<SirenTrack> recentInferredTracks({
    Duration window = const Duration(days: 14),
  }) {
    final today = DateTime(fetchedAt.year, fetchedAt.month, fetchedAt.day);
    final cutoff = today.subtract(window);
    final recent = [
      for (final track in tracks)
        if (track.effectiveInferredResourceDate case final date?)
          if (!track.isInstrumental &&
              !date.isBefore(cutoff) &&
              !date.isAfter(today))
            track,
    ];
    recent.sort((a, b) {
      final aDate = a.effectiveInferredResourceDate;
      final bDate = b.effectiveInferredResourceDate;
      final date = bDate!.compareTo(aDate!);
      if (date != 0) return date;
      final name = a.name.compareTo(b.name);
      if (name != 0) return name;
      return a.albumName.compareTo(b.albumName);
    });
    return recent;
  }
}

@immutable
class SirenAlbum {
  const SirenAlbum({
    required this.cid,
    required this.name,
    required this.coverUrl,
    required this.artists,
    this.trackCount = 0,
    this.inferredResourceDate,
  });

  factory SirenAlbum.fromJson(Map<String, dynamic> json) {
    final coverUrl = _readString(json['coverUrl']);
    return SirenAlbum(
      cid: _readString(json['cid']),
      name: _readString(json['name'], fallback: 'Untitled Album'),
      coverUrl: coverUrl,
      artists: _readSirenArtists(json['artistes'] ?? json['artists']),
      inferredResourceDate: _dateFromSirenResourceUrl(coverUrl),
    );
  }

  final String cid;
  final String name;
  final String coverUrl;
  final List<String> artists;
  final int trackCount;
  final DateTime? inferredResourceDate;

  SirenAlbum copyWith({int? trackCount}) {
    return SirenAlbum(
      cid: cid,
      name: name,
      coverUrl: coverUrl,
      artists: artists,
      trackCount: trackCount ?? this.trackCount,
      inferredResourceDate: inferredResourceDate,
    );
  }

  bool get isOst => name.toUpperCase().contains('OST');
}

@immutable
class SirenTrack {
  const SirenTrack({
    required this.cid,
    required this.name,
    required this.albumCid,
    required this.albumName,
    required this.coverUrl,
    required this.artists,
    required this.albumIsOst,
    this.inferredResourceDate,
  });

  factory SirenTrack.fromJson(
    Map<String, dynamic> json, {
    required Map<String, SirenAlbum> albumByCid,
  }) {
    final albumCid = _readString(json['albumCid']);
    final album = albumByCid[albumCid];
    return SirenTrack(
      cid: _readString(json['cid']),
      name: _readString(json['name'], fallback: 'Untitled Track'),
      albumCid: albumCid,
      albumName: album?.name ?? '未知专辑',
      coverUrl: album?.coverUrl ?? '',
      artists: _readSirenArtists(json['artists'] ?? json['artistes']),
      albumIsOst: album?.isOst ?? false,
      inferredResourceDate: album?.inferredResourceDate,
    );
  }

  final String cid;
  final String name;
  final String albumCid;
  final String albumName;
  final String coverUrl;
  final List<String> artists;
  final bool albumIsOst;
  final DateTime? inferredResourceDate;

  String get catalogId => 'MSR-$cid';

  List<String> get displayArtists => sirenArtistsForDisplay(artists);

  String get primaryArtist => displayArtists.first;

  String get artistDisplayText =>
      displayArtists.join(sirenArtistDisplaySeparator);

  String get featuredArtists {
    final display = displayArtists;
    if (display.length <= 1) return '';
    return display.skip(1).join(sirenArtistDisplaySeparator);
  }

  bool get isInstrumental => name.toLowerCase().contains('instrument');

  DateTime? get effectiveInferredResourceDate =>
      inferredResourceDate ?? _dateFromSirenResourceUrl(coverUrl);

  bool matches(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;
    final haystack = [name, albumName, ...artists].join('\n').toLowerCase();
    return haystack.contains(q);
  }
}

@immutable
class SirenSongDetail {
  const SirenSongDetail({
    required this.cid,
    required this.name,
    required this.albumCid,
    required this.sourceUrl,
    required this.lyricUrl,
    required this.mvUrl,
    required this.mvCoverUrl,
    required this.artists,
  });

  factory SirenSongDetail.fromJson(Map<String, dynamic> json) {
    return SirenSongDetail(
      cid: _readString(json['cid']),
      name: _readString(json['name'], fallback: 'Untitled Track'),
      albumCid: _readString(json['albumCid']),
      sourceUrl: _readString(json['sourceUrl']),
      lyricUrl: _nullableString(json['lyricUrl']),
      mvUrl: _nullableString(json['mvUrl']),
      mvCoverUrl: _nullableString(json['mvCoverUrl']),
      artists: _readSirenArtists(json['artists'] ?? json['artistes']),
    );
  }

  final String cid;
  final String name;
  final String albumCid;
  final String sourceUrl;
  final String? lyricUrl;
  final String? mvUrl;
  final String? mvCoverUrl;
  final List<String> artists;

  String get sourceExtension {
    final path = Uri.tryParse(sourceUrl)?.path ?? sourceUrl;
    final index = path.lastIndexOf('.');
    if (index < 0 || index == path.length - 1) return 'unknown';
    return path.substring(index + 1).toUpperCase();
  }

  String get sourceHost {
    final uri = Uri.tryParse(sourceUrl);
    return uri == null || uri.host.isEmpty ? 'unknown' : uri.host;
  }

  bool get hasLyric => lyricUrl != null && lyricUrl!.isNotEmpty;

  bool get hasMv => mvUrl != null && mvUrl!.isNotEmpty;
}

@immutable
class SirenAlbumDetail {
  const SirenAlbumDetail({
    required this.cid,
    required this.name,
    required this.intro,
    required this.belong,
    required this.coverUrl,
    required this.coverDeUrl,
    required this.songs,
  });

  factory SirenAlbumDetail.fromJson(Map<String, dynamic> json) {
    return SirenAlbumDetail(
      cid: _readString(json['cid']),
      name: _readString(json['name'], fallback: 'Untitled Album'),
      intro: _readString(json['intro']),
      belong: _readString(json['belong']),
      coverUrl: _readString(json['coverUrl']),
      coverDeUrl: _readString(json['coverDeUrl']),
      songs: [
        for (final item in _asList(json['songs']))
          SirenAlbumSong.fromJson(_asMap(item)),
      ],
    );
  }

  final String cid;
  final String name;
  final String intro;
  final String belong;
  final String coverUrl;
  final String coverDeUrl;
  final List<SirenAlbumSong> songs;
}

@immutable
class SirenAlbumSong {
  const SirenAlbumSong({
    required this.cid,
    required this.name,
    required this.artists,
  });

  factory SirenAlbumSong.fromJson(Map<String, dynamic> json) {
    return SirenAlbumSong(
      cid: _readString(json['cid']),
      name: _readString(json['name'], fallback: 'Untitled Track'),
      artists: _readSirenArtists(json['artistes'] ?? json['artists']),
    );
  }

  final String cid;
  final String name;
  final List<String> artists;
}

List<Object?> _asList(Object? value) {
  return value is List ? value : const [];
}

Map<String, dynamic> _asMap(Object? value) {
  if (value is Map) {
    return value.map((key, item) => MapEntry('$key', item));
  }
  return const {};
}

String _readString(Object? value, {String fallback = ''}) {
  final text = value?.toString().trim();
  return text == null || text.isEmpty ? fallback : text;
}

String? _nullableString(Object? value) {
  final text = value?.toString().trim();
  return text == null || text.isEmpty ? null : text;
}

List<String> _readStrings(Object? value) {
  return [
    for (final item in _asList(value))
      if (_readString(item).isNotEmpty) _readString(item),
  ];
}

List<String> sirenArtistsWithMsrFirst(Iterable<String> values) {
  final result = <String>[monsterSirenArtistName];
  final seen = {monsterSirenArtistName.toLowerCase()};
  for (final value in values) {
    final artist = value.trim();
    if (artist.isEmpty) continue;
    final key = artist.toLowerCase();
    if (key == monsterSirenArtistName.toLowerCase()) continue;
    if (seen.add(key)) result.add(artist);
  }
  return result;
}

List<String> sirenArtistsForDisplay(Iterable<String> values) {
  final result = <String>[];
  final seen = <String>{};
  for (final value in values) {
    final artist = value.trim();
    if (artist.isEmpty) continue;
    final key = artist.toLowerCase();
    if (key == monsterSirenArtistName.toLowerCase()) continue;
    if (seen.add(key)) result.add(artist);
  }
  return result.isEmpty ? const [monsterSirenArtistName] : result;
}

String sirenArtistDisplayText(Iterable<String> values) {
  return sirenArtistsWithMsrFirst(values).join(sirenArtistDisplaySeparator);
}

List<String> _readSirenArtists(Object? value) {
  return sirenArtistsWithMsrFirst(_readStrings(value));
}

DateTime? _dateFromSirenResourceUrl(String url) {
  final match = RegExp(r'/(?:pic|audio)/(\d{8})/').firstMatch(url);
  if (match == null) return null;
  final raw = match.group(1)!;
  final year = int.tryParse(raw.substring(0, 4));
  final month = int.tryParse(raw.substring(4, 6));
  final day = int.tryParse(raw.substring(6, 8));
  if (year == null || month == null || day == null) return null;
  return DateTime(year, month, day);
}
