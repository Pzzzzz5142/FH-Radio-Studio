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
        request.response.headers.contentType = ContentType.binary;
        request.response.add(
          List<int>.filled(80, request.uri.path.hashCode & 0xff),
        );
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
