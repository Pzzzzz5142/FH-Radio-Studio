import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:fh_radio_studio/domain/radio_library.dart';
import 'package:fh_radio_studio/screens/playlist.dart';
import 'package:fh_radio_studio/state/app_state.dart';
import 'package:fh_radio_studio/state/custom_pool_tracks.dart';
import 'package:fh_radio_studio/state/playlist_catalog_state.dart';
import 'package:fh_radio_studio/theme/accents.dart';
import 'package:fh_radio_studio/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('package playlist keeps the pool in a right side panel', (
    tester,
  ) async {
    await _pumpPlaylist(tester, const Size(1365, 900));

    final poolPanel = find.byKey(const ValueKey('playlist-pool-side-panel'));
    final firstRadio = find.byKey(const ValueKey('playlist-radio-column-R1'));

    expect(poolPanel, findsOneWidget);
    expect(firstRadio, findsOneWidget);
    expect(
      tester.getTopLeft(poolPanel).dx,
      greaterThan(tester.getTopLeft(firstRadio).dx),
    );
    expect(tester.getTopLeft(poolPanel).dy, tester.getTopLeft(firstRadio).dy);
    expect(
      tester.getSize(poolPanel).height,
      greaterThan(tester.getSize(firstRadio).height),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('narrow package playlist keeps pool visible beside radios', (
    tester,
  ) async {
    await _pumpPlaylist(tester, const Size(720, 900));

    final poolPanel = find.byKey(const ValueKey('playlist-pool-side-panel'));
    final firstRadio = find.byKey(const ValueKey('playlist-radio-column-R1'));
    final secondRadio = find.byKey(const ValueKey('playlist-radio-column-R2'));

    expect(poolPanel, findsOneWidget);
    expect(firstRadio, findsOneWidget);
    expect(secondRadio, findsOneWidget);
    expect(tester.getTopLeft(poolPanel).dy, tester.getTopLeft(firstRadio).dy);
    expect(
      tester.getTopLeft(poolPanel).dx,
      greaterThan(tester.getTopLeft(firstRadio).dx),
    );
    expect(tester.getTopLeft(secondRadio).dy, tester.getTopLeft(firstRadio).dy);
    expect(
      tester.getTopLeft(secondRadio).dx,
      greaterThan(tester.getTopLeft(firstRadio).dx),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('playlist count uses bank-derived slot capacity', (tester) async {
    final temp = Directory.systemTemp.createTempSync(
      'fh-radio-studio-playlist-count-widget-',
    );
    addTearDown(() {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });
    final catalog = _bankSlotCatalog(temp);

    await _pumpPlaylist(tester, const Size(960, 900), catalog: catalog);

    expect(find.text('3 / 3'), findsOneWidget);
    expect(find.text('3 / 4'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'builtin columns only accept inner scroll while control is held',
    (tester) async {
      await _pumpPlaylist(tester, const Size(1365, 900));

      final builtinList = find.descendant(
        of: find.byKey(const ValueKey('playlist-radio-column-R2')),
        matching: find.byType(ListView),
      );

      expect(builtinList, findsOneWidget);
      expect(
        tester.widget<ListView>(builtinList).physics,
        isA<NeverScrollableScrollPhysics>(),
      );

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();

      expect(
        tester.widget<ListView>(builtinList).physics,
        isA<ClampingScrollPhysics>(),
      );

      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );
}

Future<void> _pumpPlaylist(
  WidgetTester tester,
  Size size, {
  PlaylistCatalog? catalog,
}) async {
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;

  final tempRoot = Directory.systemTemp.createTempSync(
    'fh-radio-studio-playlist-layout-',
  );
  addTearDown(() {
    if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
  });
  final projectDir = p.join(tempRoot.path, 'project');
  SharedPreferences.setMockInitialValues({'rm.studio.projectDir': projectDir});
  final prefs = await SharedPreferences.getInstance();

  final effectiveCatalog =
      catalog ??
      const PlaylistCatalog(
        origin: PlaylistCatalogOrigin.package,
        sourcePath: 'test-radio-info.xml',
        radios: kRadios,
        modes: kStationModes,
        freeRoamTracks: kTracks,
        eventTracks: kTracks,
      );

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        realPoolTracksProvider.overrideWithValue(kCustomPool),
        playlistCatalogProvider.overrideWithValue(effectiveCatalog),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildAppTheme(
          brightness: Brightness.light,
          accent: AppAccent.lime,
        ),
        home: const Scaffold(body: PlaylistScreen()),
      ),
    ),
  );
  await tester.pump();
}

PlaylistCatalog _bankSlotCatalog(Directory temp) {
  final gameDir = Directory(p.join(temp.path, 'ForzaHorizon6'));
  final audioDir = Directory(p.join(gameDir.path, 'media', 'audio'))
    ..createSync(recursive: true);
  Directory(p.join(audioDir.path, 'FMODBanks')).createSync();
  _writeFsb5Bank(
    File(p.join(audioDir.path, 'FMODBanks', 'R1_Tracks_CU1.assets.bank')),
    samples: 3,
  );
  File(p.join(audioDir.path, 'RadioInfo_CN.xml')).writeAsStringSync('''
<RadioInfo Language="CN">
  <RadioStations>
    <RadioStation Number="1" Name="Horizon Pulse">
      <Banks>
        <Bank Name="R1_Tracks_CU1" />
      </Banks>
      <SampleList Type="Track">
        <Sample SoundName="HZ6_R1_SLOT_01" SampleLength="48000" SampleRate="48000" DisplayName="One" Artist="Forza" />
        <Sample SoundName="HZ6_R1_SLOT_02" SampleLength="48000" SampleRate="48000" DisplayName="Two" Artist="Forza" />
        <Sample SoundName="HZ6_R1_SLOT_03" SampleLength="48000" SampleRate="48000" DisplayName="Three" Artist="Forza" />
        <Sample SoundName="HZ6_R1_XML_ONLY" SampleLength="48000" SampleRate="48000" DisplayName="XML Only" Artist="Forza" />
      </SampleList>
      <PlayList Type="FreeRoam">
        <Entry Name="HZ6_R1_SLOT_01" />
        <Entry Name="HZ6_R1_SLOT_02" />
        <Entry Name="HZ6_R1_SLOT_03" />
      </PlayList>
      <PlayList Type="Event">
        <Entry Name="HZ6_R1_SLOT_01" />
        <Entry Name="HZ6_R1_SLOT_02" />
        <Entry Name="HZ6_R1_SLOT_03" />
      </PlayList>
    </RadioStation>
  </RadioStations>
</RadioInfo>
''', encoding: utf8);

  return loadPlaylistCatalog(
    packageDir: null,
    gameDir: gameDir.path,
    sourceLang: 'CN',
    targetLang: 'EN',
  );
}

void _writeFsb5Bank(File file, {required int samples}) {
  file.createSync(recursive: true);
  final header = Uint8List(60);
  header.setAll(0, 'FSB5'.codeUnits);
  final view = ByteData.sublistView(header);
  view.setUint32(4, 1, Endian.little);
  view.setUint32(8, samples, Endian.little);
  file.writeAsBytesSync(header);
}
