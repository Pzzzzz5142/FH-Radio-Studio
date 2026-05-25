import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fh_radio_studio/core/siren_audio_cache.dart';
import 'package:fh_radio_studio/core/siren_catalog.dart';

void main() {
  test(
    'Siren audio cache trims least recently used files over max size',
    () async {
      final root = Directory.systemTemp.createTempSync(
        'fh-radio-studio-siren-cache-',
      );
      addTearDown(() {
        if (root.existsSync()) root.deleteSync(recursive: true);
      });
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        final payload = List<int>.filled(80, request.uri.path.hashCode & 0xff);
        request.response.headers.contentType = ContentType.binary;
        request.response.contentLength = payload.length;
        request.response.add(payload);
        await request.response.close();
      });

      final cache = SirenAudioCache(rootPath: root.path, maxBytes: 100);
      final first = _detail('232251', server.port);
      final second = _detail('232252', server.port);

      final firstFile = await cache.cacheAudio(first);
      expect(firstFile.existsSync(), isTrue);
      final secondFile = await cache.cacheAudio(second);

      expect(secondFile.existsSync(), isTrue);
      expect(firstFile.existsSync(), isFalse);
      expect(await cache.cachedAudioFile(first), isNull);
      expect(await cache.cachedAudioFile(second), isNotNull);
    },
  );

  test('Siren audio cache cleans interrupted partial downloads', () async {
    final root = Directory.systemTemp.createTempSync(
      'fh-radio-studio-siren-cache-',
    );
    addTearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });
    final partialDir = Directory('${root.path}${Platform.pathSeparator}partial')
      ..createSync(recursive: true);
    final partial = File(
      '${partialDir.path}${Platform.pathSeparator}232251.part',
    )..writeAsStringSync('partial');
    final keep = File('${partialDir.path}${Platform.pathSeparator}readme.txt')
      ..writeAsStringSync('keep');

    final deleted = await SirenAudioCache(
      rootPath: root.path,
    ).cleanupPartialDownloads();

    expect(deleted, 1);
    expect(partial.existsSync(), isFalse);
    expect(keep.existsSync(), isTrue);
  });

  test(
    'Siren audio cache rejects incomplete content-length downloads',
    () async {
      final root = Directory.systemTemp.createTempSync(
        'fh-radio-studio-siren-cache-',
      );
      addTearDown(() {
        if (root.existsSync()) root.deleteSync(recursive: true);
      });
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close());
      var requests = 0;
      server.listen((socket) {
        requests += 1;
        socket.listen((_) {});
        socket.add(
          ascii.encode(
            'HTTP/1.1 200 OK\r\n'
            'Content-Type: application/octet-stream\r\n'
            'Content-Length: 10\r\n'
            'Connection: close\r\n'
            '\r\n'
            '12345',
          ),
        );
        unawaited(socket.close());
      });

      final cache = SirenAudioCache(rootPath: root.path);
      final detail = _detail('232253', server.port);

      await expectLater(
        cache.cacheAudio(detail),
        throwsA(isA<SirenAudioCacheException>()),
      );
      expect(requests, 3);
      expect(
        File(
          '${root.path}${Platform.pathSeparator}audio'
          '${Platform.pathSeparator}MSR-232253.wav',
        ).existsSync(),
        isFalse,
      );
      expect(
        File(
          '${root.path}${Platform.pathSeparator}partial'
          '${Platform.pathSeparator}MSR-232253.wav.part',
        ).existsSync(),
        isFalse,
      );
    },
  );

  test('Siren audio cache resumes partial audio downloads', () async {
    final root = Directory.systemTemp.createTempSync(
      'fh-radio-studio-siren-cache-',
    );
    addTearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close());
    final ranges = <String?>[];
    var requests = 0;
    server.listen((socket) {
      final requestBytes = <int>[];
      StreamSubscription<List<int>>? subscription;
      subscription = socket.listen((chunk) {
        requestBytes.addAll(chunk);
        final request = ascii.decode(requestBytes, allowInvalid: true);
        if (!request.contains('\r\n\r\n')) return;
        unawaited(subscription?.cancel());
        final range = RegExp(
          r'^Range:\s*([^\r\n]+)$',
          multiLine: true,
          caseSensitive: false,
        ).firstMatch(request)?.group(1);
        ranges.add(range);
        requests += 1;
        if (requests == 1) {
          socket.add(
            ascii.encode(
              'HTTP/1.1 200 OK\r\n'
              'Content-Type: application/octet-stream\r\n'
              'Content-Length: 10\r\n'
              'Connection: close\r\n'
              '\r\n'
              '12345',
            ),
          );
        } else {
          socket.add(
            ascii.encode(
              'HTTP/1.1 206 Partial Content\r\n'
              'Content-Type: application/octet-stream\r\n'
              'Content-Length: 5\r\n'
              'Content-Range: bytes 5-9/10\r\n'
              'Connection: close\r\n'
              '\r\n'
              '67890',
            ),
          );
        }
        unawaited(socket.close());
      });
    });

    final cache = SirenAudioCache(rootPath: root.path);
    final file = await cache.cacheAudio(_detail('232254', server.port));

    expect(await file.readAsString(), '1234567890');
    expect(ranges.length, 2);
    expect(ranges.first, isNull);
    expect(ranges.last, 'bytes=5-');
    expect(
      File(
        '${root.path}${Platform.pathSeparator}partial'
        '${Platform.pathSeparator}MSR-232254.wav.part',
      ).existsSync(),
      isFalse,
    );
  });
}

SirenSongDetail _detail(String cid, int port) {
  return SirenSongDetail(
    cid: cid,
    name: 'Track $cid',
    albumCid: 'album',
    sourceUrl: 'http://127.0.0.1:$port/$cid.wav',
    lyricUrl: null,
    mvUrl: null,
    mvCoverUrl: null,
    artists: const ['塞壬唱片-MSR'],
  );
}
