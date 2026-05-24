import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fh_radio_studio/core/siren_catalog.dart';
import 'package:fh_radio_studio/core/siren_imports.dart';
import 'package:fh_radio_studio/state/custom_pool_tracks.dart';

void main() {
  test('Siren artists always put MSR first and preserve other artists', () {
    expect(
      sirenArtistsWithMsrFirst([
        'AIYUE blessed : 理名',
        '塞壬唱片-MSR',
        'AIYUE blessed : 理名',
      ]),
      ['塞壬唱片-MSR', 'AIYUE blessed : 理名'],
    );
    expect(
      sirenArtistDisplayText(['AIYUE blessed : 理名', '塞壬唱片-MSR']),
      '塞壬唱片-MSR / AIYUE blessed : 理名',
    );
    expect(sirenArtistsForDisplay(['塞壬唱片-MSR', 'Mili']), ['Mili']);
    expect(sirenArtistsForDisplay([]), ['塞壬唱片-MSR']);
  });

  test('Siren import registry marks pool tracks as MSR sourced', () {
    final project = Directory.systemTemp.createTempSync(
      'fh-radio-studio-siren-import-',
    );
    addTearDown(() {
      if (project.existsSync()) project.deleteSync(recursive: true);
    });
    final sirenDir = Directory('${project.path}${Platform.pathSeparator}siren')
      ..createSync(recursive: true);
    final audio = File(
      '${sirenDir.path}${Platform.pathSeparator}MSR-232251.wav',
    )..writeAsBytesSync(const [0, 1, 2, 3]);

    final entry = SirenImportEntry(
      cid: '232251',
      title: 'Whistle Stop',
      albumCid: '5106',
      albumName: '巴别塔OST',
      artist: '塞壬唱片-MSR',
      artists: const ['塞壬唱片-MSR'],
      coverUrl: 'https://example.invalid/cover.png',
      lyricUrl: null,
      path: audio.path,
      importedAt: DateTime.utc(2026, 5, 23),
    );
    SirenImportRegistry.upsert(project.path, entry);

    final imports = SirenImportRegistry.readByPath(project.path);
    final tracks = buildRealPoolTracks([sirenDir.path], sirenImports: imports);

    expect(tracks, hasLength(1));
    expect(tracks.single.isSiren, isTrue);
    expect(tracks.single.title, 'Whistle Stop');
    expect(tracks.single.sourceLabel, 'MSR-232251');
    expect(tracks.single.albumName, '巴别塔OST');
  });

  test('Siren imports keep official artist separate from MSR source', () {
    final entry = SirenImportEntry.fromSiren(
      track: const SirenTrack(
        cid: '232223',
        name: 'Iron Lotus',
        albumCid: '6656',
        albumName: 'Iron Lotus',
        coverUrl: '',
        artists: ['塞壬唱片-MSR', 'Mili'],
        albumIsOst: false,
      ),
      detail: const SirenSongDetail(
        cid: '232223',
        name: 'Iron Lotus',
        albumCid: '6656',
        sourceUrl: 'https://example.invalid/IronLotus.wav',
        lyricUrl: null,
        mvUrl: null,
        mvCoverUrl: null,
        artists: ['塞壬唱片-MSR', 'Mili'],
      ),
      path: 'C:/tmp/IronLotus.wav',
    );

    expect(entry.artist, 'Mili');
    expect(entry.artists, ['Mili']);
  });
}
