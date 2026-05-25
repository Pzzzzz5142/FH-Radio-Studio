import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import 'app_info.dart';
import 'siren_catalog.dart';

const defaultSirenAudioCacheMaxBytes = 2 * 1024 * 1024 * 1024;
const _sirenAudioDownloadMaxAttempts = 3;
const _fakeSirenContentLengthFailure = bool.fromEnvironment(
  'FH_RADIO_STUDIO_FAKE_SIREN_CONTENT_LENGTH_FAILURE',
);

final sirenAudioCacheProvider = Provider<SirenAudioCache>((ref) {
  return SirenAudioCache();
});

class SirenAudioCache {
  SirenAudioCache({
    String? rootPath,
    this.maxBytes = defaultSirenAudioCacheMaxBytes,
  }) : rootPath = rootPath ?? defaultRootPath();

  final String rootPath;
  final int maxBytes;
  final _activeDownloads = <String, Future<File>>{};

  static String defaultRootPath() {
    final env = Platform.environment;
    if (Platform.isWindows) {
      final localAppData = env['LOCALAPPDATA']?.trim();
      if (localAppData != null && localAppData.isNotEmpty) {
        return p.join(localAppData, 'FH Radio Studio', 'siren-cache');
      }
    }
    if (Platform.isMacOS) {
      final home = env['HOME']?.trim();
      if (home != null && home.isNotEmpty) {
        return p.join(
          home,
          'Library',
          'Application Support',
          'FH Radio Studio',
          'siren-cache',
        );
      }
    }
    final xdg = env['XDG_CACHE_HOME']?.trim();
    if (xdg != null && xdg.isNotEmpty) {
      return p.join(xdg, 'FH Radio Studio', 'siren-cache');
    }
    final home = env['HOME']?.trim();
    if (home != null && home.isNotEmpty) {
      return p.join(home, '.cache', 'FH Radio Studio', 'siren-cache');
    }
    return p.join(
      Directory.current.absolute.path,
      '.fh-radio-studio-siren-cache',
    );
  }

  Future<File?> cachedAudioFile(SirenSongDetail detail) async {
    final manifest = await _readManifest();
    final entry = manifest.entries[detail.cid];
    if (entry == null) return null;
    final file = File(entry.path);
    if (!await file.exists()) {
      manifest.entries.remove(detail.cid);
      await _writeManifest(manifest);
      return null;
    }
    final stat = await file.stat();
    manifest.entries[detail.cid] = entry.copyWith(
      size: stat.size,
      lastAccessedMs: DateTime.now().millisecondsSinceEpoch,
    );
    await _writeManifest(manifest);
    return file;
  }

  Future<File> cacheAudio(SirenSongDetail detail, {SirenTrack? track}) {
    final existing = _activeDownloads[detail.cid];
    if (existing != null) return existing;
    final pending = _cacheAudio(detail, track: track);
    _activeDownloads[detail.cid] = pending;
    pending.then<void>(
      (_) {
        _activeDownloads.remove(detail.cid);
      },
      onError: (_, _) {
        _activeDownloads.remove(detail.cid);
      },
    );
    return pending;
  }

  Future<int> cleanupPartialDownloads() async {
    final partialDir = Directory(p.join(rootPath, 'partial'));
    if (!await partialDir.exists()) return 0;
    var deleted = 0;
    await for (final entity in partialDir.list(followLinks: false)) {
      if (entity is! File || !entity.path.endsWith('.part')) continue;
      try {
        await entity.delete();
        deleted += 1;
      } on FileSystemException {
        // The next startup can retry this stale partial download.
      }
    }
    return deleted;
  }

  Future<File?> cacheCover(SirenTrack track) async {
    final coverUrl = track.coverUrl.trim();
    if (coverUrl.isEmpty) return null;

    final root = Directory(rootPath);
    final coverDir = Directory(p.join(root.path, 'covers'));
    final partialDir = Directory(p.join(root.path, 'partial'));
    await coverDir.create(recursive: true);
    await partialDir.create(recursive: true);

    final basename = _coverCacheBasename(track);
    final destination = File(p.join(coverDir.path, basename));
    if (await destination.exists()) {
      final stat = await destination.stat();
      if (stat.size > 0) return destination;
    }

    final partial = File(p.join(partialDir.path, '$basename.part'));
    if (await partial.exists()) await partial.delete();

    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse(coverUrl));
      request.headers.set(HttpHeaders.acceptHeader, 'image/*,*/*');
      request.headers.set(
        HttpHeaders.userAgentHeader,
        fhRadioStudioUserAgent(),
      );
      request.headers.set(
        HttpHeaders.refererHeader,
        '$monsterSirenOrigin/album/${track.albumCid}',
      );
      final response = await request.close();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw SirenAudioCacheException('封面缓存失败：HTTP ${response.statusCode}');
      }
      final expectedLength = response.contentLength;
      final sink = partial.openWrite();
      await response.pipe(sink);
      await _verifyPartialLength(
        partial,
        expectedLength: expectedLength,
        label: '封面缓存',
      );
      if (await destination.exists()) await destination.delete();
      await partial.rename(destination.path);
      return destination;
    } on SocketException catch (error) {
      throw SirenAudioCacheException('封面缓存失败：${error.message}', cause: error);
    } on HttpException catch (error) {
      throw SirenAudioCacheException('封面缓存失败：${error.message}', cause: error);
    } finally {
      client.close(force: true);
      if (await partial.exists()) {
        try {
          await partial.delete();
        } on FileSystemException {
          // A later cache attempt can replace this stale partial file.
        }
      }
    }
  }

  Future<File> _cacheAudio(SirenSongDetail detail, {SirenTrack? track}) async {
    final cached = await cachedAudioFile(detail);
    if (cached != null) return cached;

    final root = Directory(rootPath);
    final audioDir = Directory(p.join(root.path, 'audio'));
    final partialDir = Directory(p.join(root.path, 'partial'));
    await audioDir.create(recursive: true);
    await partialDir.create(recursive: true);

    final basename = _cacheBasename(detail);
    final destination = File(p.join(audioDir.path, basename));
    final partial = File(p.join(partialDir.path, '$basename.part'));

    await _downloadAudioWithRetry(
      detail,
      destination: destination,
      partial: partial,
    );

    final stat = await destination.stat();
    final manifest = await _readManifest();
    manifest.entries[detail.cid] = _SirenCacheEntry(
      cid: detail.cid,
      title: detail.name,
      albumCid: detail.albumCid,
      albumName: track?.albumName,
      artists: detail.artists,
      sourceUrl: detail.sourceUrl,
      path: destination.path,
      size: stat.size,
      cachedAtMs: DateTime.now().millisecondsSinceEpoch,
      lastAccessedMs: DateTime.now().millisecondsSinceEpoch,
    );
    await _writeManifest(manifest);
    await trimToSize(protectedCids: {detail.cid});
    return destination;
  }

  Future<void> _downloadAudioWithRetry(
    SirenSongDetail detail, {
    required File destination,
    required File partial,
  }) async {
    SirenAudioCacheException? lastError;
    for (
      var attempt = 1;
      attempt <= _sirenAudioDownloadMaxAttempts;
      attempt += 1
    ) {
      try {
        await _downloadAudioAttempt(
          detail,
          destination: destination,
          partial: partial,
        );
        return;
      } on _RestartSirenDownloadException catch (error) {
        lastError = SirenAudioCacheException(error.message, cause: error);
        await _deleteIfExists(partial);
      } on SirenAudioCacheException catch (error) {
        lastError = error;
      }
    }
    await _deleteIfExists(partial);
    final detailMessage = _withoutCacheFailurePrefix(
      lastError?.message ?? '未知错误',
    );
    throw SirenAudioCacheException(
      '音频缓存失败：已重试 $_sirenAudioDownloadMaxAttempts 次，$detailMessage',
      cause: lastError,
    );
  }

  Future<void> _downloadAudioAttempt(
    SirenSongDetail detail, {
    required File destination,
    required File partial,
  }) async {
    final resumeFrom = await partial.exists() ? await partial.length() : 0;
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse(detail.sourceUrl));
      request.headers.set(HttpHeaders.acceptHeader, '*/*');
      request.headers.set(
        HttpHeaders.userAgentHeader,
        fhRadioStudioUserAgent(),
      );
      request.headers.set(
        HttpHeaders.refererHeader,
        '$monsterSirenOrigin/music/${detail.cid}',
      );
      if (resumeFrom > 0) {
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=$resumeFrom-');
      }
      final response = await request.close();
      if (response.statusCode == HttpStatus.requestedRangeNotSatisfiable &&
          resumeFrom > 0) {
        throw const _RestartSirenDownloadException('服务器拒绝续传位置，已改为重新下载。');
      }
      if (response.statusCode != HttpStatus.ok &&
          response.statusCode != HttpStatus.partialContent) {
        throw SirenAudioCacheException('音频缓存失败：HTTP ${response.statusCode}');
      }

      final append = response.statusCode == HttpStatus.partialContent;
      var expectedLength = response.contentLength;
      if (append) {
        final range = _parseContentRange(
          response.headers.value(HttpHeaders.contentRangeHeader),
        );
        if (resumeFrom <= 0 || range == null || range.start != resumeFrom) {
          throw const _RestartSirenDownloadException('服务器返回的续传范围不匹配，已改为重新下载。');
        }
        expectedLength =
            range.total ??
            (expectedLength < 0 ? -1 : resumeFrom + expectedLength);
      } else if (resumeFrom > 0) {
        await _deleteIfExists(partial);
      }

      final sink = partial.openWrite(
        mode: append ? FileMode.append : FileMode.write,
      );
      await response.pipe(sink);
      await _verifyPartialLength(
        partial,
        expectedLength: expectedLength,
        label: '音频缓存',
      );
      if (await destination.exists()) await destination.delete();
      await partial.rename(destination.path);
    } on _RestartSirenDownloadException {
      rethrow;
    } on SocketException catch (error) {
      throw SirenAudioCacheException('音频缓存失败：${error.message}', cause: error);
    } on HttpException catch (error) {
      throw SirenAudioCacheException('音频缓存失败：${error.message}', cause: error);
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _deleteIfExists(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // A later attempt or startup cleanup can replace this stale partial file.
    }
  }

  Future<void> _verifyPartialLength(
    File partial, {
    required int expectedLength,
    required String label,
  }) async {
    if (expectedLength < 0) return;
    final actualLength = await partial.length();
    if (_fakeSirenContentLengthFailure) {
      throw SirenAudioCacheException(
        '$label失败：下载大小不完整（$actualLength / $expectedLength 字节）',
      );
    }
    if (actualLength == expectedLength) return;
    throw SirenAudioCacheException(
      '$label失败：下载大小不完整（$actualLength / $expectedLength 字节）',
    );
  }

  Future<void> trimToSize({Set<String> protectedCids = const {}}) async {
    final manifest = await _readManifest();
    var entries = manifest.entries.values.toList(growable: false);
    var total = 0;
    for (final entry in entries) {
      final file = File(entry.path);
      if (!await file.exists()) {
        manifest.entries.remove(entry.cid);
        continue;
      }
      final stat = await file.stat();
      total += stat.size;
      manifest.entries[entry.cid] = entry.copyWith(size: stat.size);
    }
    if (total <= maxBytes) {
      await _writeManifest(manifest);
      return;
    }

    entries = manifest.entries.values.toList(growable: false)
      ..sort((a, b) => a.lastAccessedMs.compareTo(b.lastAccessedMs));
    for (final entry in entries) {
      if (total <= maxBytes) break;
      if (protectedCids.contains(entry.cid)) continue;
      final file = File(entry.path);
      if (await file.exists()) {
        final stat = await file.stat();
        try {
          await file.delete();
          total -= stat.size;
        } on FileSystemException {
          continue;
        }
      }
      manifest.entries.remove(entry.cid);
    }
    await _writeManifest(manifest);
  }

  Future<_SirenCacheManifest> _readManifest() async {
    final file = File(_manifestPath);
    if (!await file.exists()) {
      return _SirenCacheManifest(entries: {});
    }
    try {
      final decoded = jsonDecode(await file.readAsString(encoding: utf8));
      if (decoded is! Map) return _SirenCacheManifest(entries: {});
      final entries = decoded['entries'];
      if (entries is! List) return _SirenCacheManifest(entries: {});
      final parsed = <String, _SirenCacheEntry>{};
      for (final item in entries) {
        if (item is! Map) continue;
        final entry = _SirenCacheEntry.fromJson(item);
        if (entry != null) parsed[entry.cid] = entry;
      }
      return _SirenCacheManifest(entries: parsed);
    } on FileSystemException {
      return _SirenCacheManifest(entries: {});
    } on FormatException {
      return _SirenCacheManifest(entries: {});
    }
  }

  Future<void> _writeManifest(_SirenCacheManifest manifest) async {
    final file = File(_manifestPath);
    await file.parent.create(recursive: true);
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'schema_version': 1,
        'max_bytes': maxBytes,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
        'entries': [for (final entry in manifest.entries.values) entry.toJson()]
          ..sort((a, b) => '${a['cid']}'.compareTo('${b['cid']}')),
      }),
      encoding: utf8,
    );
  }

  String get _manifestPath => p.join(rootPath, 'manifest.json');
}

String _withoutCacheFailurePrefix(String message) {
  const prefix = '音频缓存失败：';
  return message.startsWith(prefix)
      ? message.substring(prefix.length)
      : message;
}

class SirenAudioCacheException implements Exception {
  const SirenAudioCacheException(this.message, {this.cause});

  final String message;
  final Object? cause;

  @override
  String toString() => message;
}

class _RestartSirenDownloadException implements Exception {
  const _RestartSirenDownloadException(this.message);

  final String message;
}

class _SirenContentRange {
  const _SirenContentRange({required this.start, required this.total});

  final int start;
  final int? total;
}

_SirenContentRange? _parseContentRange(String? value) {
  if (value == null) return null;
  final match = RegExp(
    r'^bytes\s+(\d+)-(\d+)/(\d+|\*)$',
    caseSensitive: false,
  ).firstMatch(value.trim());
  if (match == null) return null;
  final start = int.tryParse(match.group(1)!);
  if (start == null) return null;
  final totalText = match.group(3)!;
  return _SirenContentRange(
    start: start,
    total: totalText == '*' ? null : int.tryParse(totalText),
  );
}

class _SirenCacheManifest {
  _SirenCacheManifest({required this.entries});

  final Map<String, _SirenCacheEntry> entries;
}

class _SirenCacheEntry {
  const _SirenCacheEntry({
    required this.cid,
    required this.title,
    required this.albumCid,
    required this.albumName,
    required this.artists,
    required this.sourceUrl,
    required this.path,
    required this.size,
    required this.cachedAtMs,
    required this.lastAccessedMs,
  });

  final String cid;
  final String title;
  final String albumCid;
  final String? albumName;
  final List<String> artists;
  final String sourceUrl;
  final String path;
  final int size;
  final int cachedAtMs;
  final int lastAccessedMs;

  static _SirenCacheEntry? fromJson(Map json) {
    final cid = _string(json['cid']);
    final path = _string(json['path']);
    if (cid == null || path == null) return null;
    return _SirenCacheEntry(
      cid: cid,
      title: _string(json['title']) ?? 'Untitled Track',
      albumCid: _string(json['album_cid']) ?? '',
      albumName: _string(json['album_name']),
      artists: (json['artists'] is List ? json['artists'] as List : const [])
          .map(_string)
          .nonNulls
          .toList(growable: false),
      sourceUrl: _string(json['source_url']) ?? '',
      path: path,
      size: _int(json['size']) ?? 0,
      cachedAtMs: _int(json['cached_at_ms']) ?? 0,
      lastAccessedMs: _int(json['last_accessed_ms']) ?? 0,
    );
  }

  _SirenCacheEntry copyWith({int? size, int? lastAccessedMs}) {
    return _SirenCacheEntry(
      cid: cid,
      title: title,
      albumCid: albumCid,
      albumName: albumName,
      artists: artists,
      sourceUrl: sourceUrl,
      path: path,
      size: size ?? this.size,
      cachedAtMs: cachedAtMs,
      lastAccessedMs: lastAccessedMs ?? this.lastAccessedMs,
    );
  }

  Map<String, Object?> toJson() {
    return {
      'cid': cid,
      'title': title,
      'album_cid': albumCid,
      'album_name': albumName,
      'artists': artists,
      'source_url': sourceUrl,
      'path': path,
      'size': size,
      'cached_at_ms': cachedAtMs,
      'last_accessed_ms': lastAccessedMs,
    };
  }
}

String _cacheBasename(SirenSongDetail detail) {
  final extension = _sourceExtension(detail.sourceUrl);
  return 'MSR-${_safeSegment(detail.cid)}.$extension';
}

String _coverCacheBasename(SirenTrack track) {
  final id = track.albumCid.isNotEmpty ? track.albumCid : track.cid;
  final extension = _coverExtension(track.coverUrl);
  return 'MSR-cover-${_safeSegment(id)}.$extension';
}

String _coverExtension(String coverUrl) {
  final extension = _sourceExtension(coverUrl).toLowerCase();
  if (extension == 'jpeg') return 'jpg';
  if (const {'jpg', 'png', 'webp'}.contains(extension)) return extension;
  return 'jpg';
}

String _sourceExtension(String sourceUrl) {
  final path = Uri.tryParse(sourceUrl)?.path ?? sourceUrl;
  final extension = p.extension(path).replaceFirst('.', '').toLowerCase();
  if (extension.isEmpty || extension.length > 8) return 'wav';
  return extension;
}

String _safeSegment(String value) {
  return value.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_');
}

String? _string(Object? value) {
  final text = value?.toString().trim();
  return text == null || text.isEmpty ? null : text;
}

int? _int(Object? value) {
  if (value is int) return value;
  if (value is num) return value.round();
  if (value is String) return int.tryParse(value);
  return null;
}
