import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:path/path.dart' as p;
import 'package:fh_radio_studio/core/playlist_plan.dart';
import 'package:fh_radio_studio/domain/radio_library.dart';
import 'package:fh_radio_studio/screens/playlist.dart';
import 'package:fh_radio_studio/state/app_state.dart';
import 'package:fh_radio_studio/state/studio_state.dart';
import 'package:fh_radio_studio/state/custom_pool_tracks.dart';
import 'package:fh_radio_studio/state/playlist_catalog_state.dart';
import 'package:fh_radio_studio/state/playlist_plan_state.dart';
import 'package:fh_radio_studio/theme/accents.dart';
import 'package:fh_radio_studio/theme/app_theme.dart';
import 'package:fh_radio_studio/theme/tokens.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets(
    'capture playlist pool with Flutter render tree',
    (tester) async {
      GoogleFonts.config.allowRuntimeFetching = false;
      SharedPreferences.setMockInitialValues({
        'rm.studio.projectDir': 'capture',
      });
      final prefs = await SharedPreferences.getInstance();
      final outDir = Directory(p.join('build', 'visual_qa'))
        ..createSync(recursive: true);

      await _capturePlaylistPool(
        tester,
        prefs: prefs,
        logicalSize: const Size(1365, 900),
        outputPath: p.join(outDir.path, 'playlist_regular.png'),
      );
      await _capturePlaylistPool(
        tester,
        prefs: prefs,
        logicalSize: const Size(1365, 1800),
        outputPath: p.join(outDir.path, 'playlist_full.png'),
      );
    },
    skip: Platform.environment['CAPTURE_PLAYLIST_POOL'] != '1',
  );
}

Future<void> _capturePlaylistPool(
  WidgetTester tester, {
  required SharedPreferences prefs,
  required Size logicalSize,
  required String outputPath,
}) async {
  final repaintKey = GlobalKey();
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = logicalSize;

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        studioProvider.overrideWith((ref) => _CaptureStudioController(prefs)),
        realPoolTracksProvider.overrideWithValue(_captureTracks),
        playlistCatalogProvider.overrideWithValue(_captureCatalog),
        effectivePlaylistPlanProvider.overrideWithValue(_capturePlan),
      ],
      child: RepaintBoundary(
        key: repaintKey,
        child: SizedBox.fromSize(
          size: logicalSize,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: buildAppTheme(
              brightness: Brightness.light,
              accent: AppAccent.lime,
            ),
            home: const Scaffold(
              body: ColoredBox(
                color: RmTokens.bgLight,
                child: PlaylistScreen(),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));

  expect(tester.takeException(), isNull);
  expect(find.text('全部曲目 · 配置完善靠前'), findsOneWidget);
  final poolPanel = find.byKey(const ValueKey('playlist-pool-side-panel'));
  Finder poolTrack(String title) =>
      find.descendant(of: poolPanel, matching: find.text(title));
  expect(
    tester.getTopLeft(poolTrack('Almost Config')).dy,
    lessThan(tester.getTopLeft(poolTrack('Siren Half')).dy),
  );
  expect(
    tester.getTopLeft(poolTrack('Siren Half')).dy,
    lessThan(tester.getTopLeft(poolTrack('Half Config')).dy),
  );
  expect(
    tester.getTopLeft(poolTrack('Half Config')).dy,
    lessThan(tester.getTopLeft(poolTrack('Zero Config')).dy),
  );
  expect(
    tester.getTopLeft(poolTrack('Zero Config')).dy,
    lessThan(tester.getTopLeft(poolTrack('Done Config')).dy),
  );
  expect(
    find.descendant(of: poolPanel, matching: find.text('MSR')),
    findsOneWidget,
  );

  final boundary = repaintKey.currentContext?.findRenderObject();
  expect(boundary, isA<RenderRepaintBoundary>());
  await tester.runAsync(() async {
    final image = await (boundary! as RenderRepaintBoundary).toImage(
      pixelRatio: 1.5,
    );
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    expect(data, isNotNull);

    final output = File(outputPath);
    await output.parent.create(recursive: true);
    await output.writeAsBytes(data!.buffer.asUint8List(), flush: true);
    // ignore: avoid_print
    print('${p.basenameWithoutExtension(outputPath)}=${output.absolute.path}');
  });
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
}

const _captureCatalog = PlaylistCatalog(
  origin: PlaylistCatalogOrigin.package,
  sourcePath: 'capture-radio-info.xml',
  radios: kRadios,
  modes: kStationModes,
  freeRoamTracks: kTracks,
  eventTracks: kTracks,
);

final _capturePlan = const PlaylistPlan.empty().assign(
  source: r'C:\music\done.wav',
  radioCode: 'HOR',
  playlistType: 'FreeRoam',
  slot: 1,
);

const _captureTracks = [
  PoolTrack(
    id: 'half-config',
    title: 'Half Config',
    artist: 'Local Artist',
    source: r'C:\music\half.wav',
    durationSec: 148,
    bpm: 126,
    key: '待分析',
    configured: false,
    confirmed: 2,
    added: '2026-01-04',
  ),
  PoolTrack(
    id: 'done-config',
    title: 'Done Config',
    artist: 'Local Artist',
    source: r'C:\music\done.wav',
    durationSec: 121,
    bpm: 128,
    key: '待分析',
    configured: true,
    confirmed: 4,
    added: '2026-01-05',
  ),
  PoolTrack(
    id: 'siren-half',
    title: 'Siren Half',
    artist: '塞壬唱片-MSR',
    source: r'C:\project\siren\MSR-232251.wav',
    durationSec: 193,
    bpm: 124,
    key: '待分析',
    configured: false,
    confirmed: 2,
    sourceKind: 'siren',
    sourceLabel: 'MSR-232251',
    sirenCid: '232251',
    albumName: '巴别塔OST',
    added: '2026-05-23',
  ),
  PoolTrack(
    id: 'zero-config',
    title: 'Zero Config',
    artist: 'Local Artist',
    source: r'C:\music\zero.wav',
    durationSec: 156,
    bpm: 118,
    key: '待分析',
    configured: false,
    confirmed: 0,
    added: '2026-01-02',
  ),
  PoolTrack(
    id: 'almost-config',
    title: 'Almost Config',
    artist: 'Local Artist',
    source: r'C:\music\almost.wav',
    durationSec: 176,
    bpm: 120,
    key: '待分析',
    configured: false,
    confirmed: 3,
    added: '2026-01-03',
  ),
];

class _CaptureStudioController extends StudioController {
  _CaptureStudioController(super.prefs) {
    state = state.copyWith(log: const ['视觉检查 fixture 已加载']);
  }

  @override
  Future<void> refreshStatus({bool verifyFiles = false}) async {}
}
