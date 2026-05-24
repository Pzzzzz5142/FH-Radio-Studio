import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:path/path.dart' as p;
import 'package:fh_radio_studio/core/siren_audio_cache.dart';
import 'package:fh_radio_studio/core/siren_catalog.dart';
import 'package:fh_radio_studio/screens/siren_library.dart';
import 'package:fh_radio_studio/state/app_state.dart';
import 'package:fh_radio_studio/state/studio_state.dart';
import 'package:fh_radio_studio/theme/accents.dart';
import 'package:fh_radio_studio/theme/app_theme.dart';
import 'package:fh_radio_studio/theme/tokens.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _recentCoverUrl = 'https://web.hycdn.cn/siren/pic/20260516/cover.png';
const _projectDirKey = 'rm.studio.projectDir';

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    GoogleFonts.config.allowRuntimeFetching = false;
    await _loadTestFonts();
  });

  testWidgets('renders MSR archive skeleton while Siren catalog is pending', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1365, 900);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });

    final client = _PendingSirenClient();
    final project = Directory.systemTemp.createTempSync(
      'fh-radio-studio-siren-test-',
    );
    addTearDown(() {
      if (project.existsSync()) project.deleteSync(recursive: true);
    });
    SharedPreferences.setMockInitialValues({_projectDirKey: project.path});
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          sirenCatalogClientProvider.overrideWithValue(client),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildAppTheme(
            brightness: Brightness.light,
            accent: AppAccent.lime,
          ),
          home: const Scaffold(
            body: ColoredBox(
              color: RmTokens.bgLight,
              child: SirenLibraryScreen(),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));

    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('siren-loading')), findsOneWidget);
    expect(find.text('INDEX WARMUP'), findsOneWidget);
    expect(find.text('READING MANIFEST'), findsOneWidget);
    expect(
      find.textContaining('monster-siren.hypergryph.com/music'),
      findsOneWidget,
    );
    expect(find.text('正在同步塞壬唱片索引'), findsNothing);
  });

  testWidgets('renders fetched Siren catalog and prefetches song detail', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1500, 1000);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });

    final client = _FakeSirenClient();
    final project = Directory.systemTemp.createTempSync(
      'fh-radio-studio-siren-test-',
    );
    addTearDown(() {
      if (project.existsSync()) project.deleteSync(recursive: true);
    });
    SharedPreferences.setMockInitialValues({_projectDirKey: project.path});
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          sirenCatalogClientProvider.overrideWithValue(client),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildAppTheme(
            brightness: Brightness.light,
            accent: AppAccent.lime,
          ),
          home: const Scaffold(
            body: ColoredBox(
              color: RmTokens.bgLight,
              child: SirenLibraryScreen(),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));

    expect(tester.takeException(), isNull);
    expect(find.text('MSR · CATALOG ARCHIVE'), findsOneWidget);
    expect(find.bySemanticsLabel('MONSTER SIREN 塞壬唱片'), findsOneWidget);
    expect(find.text('LATEST'), findsOneWidget);
    expect(find.text('曲目'), findsWidgets);
    expect(find.text('待导入清单'), findsWidgets);
    expect(
      find.byKey(const ValueKey('siren-importing-queue-overlay')),
      findsNothing,
    );
    expect(find.text('对峙'), findsWidgets);
    expect(find.textContaining('MSR-232222'), findsNothing);
    expect(find.textContaining('2026-05-16'), findsNothing);
    expect(find.text('Mili'), findsWidgets);
    expect(find.text('塞壬唱片-MSR / Mili'), findsNothing);
    expect(find.text('加入清单'), findsWidgets);
    expect(
      tester
          .getSize(find.byKey(const ValueKey('siren-song-table-body')))
          .height,
      greaterThanOrEqualTo(192),
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('siren-queue-list'))).height,
      224,
    );
    final sameAlbumDefaultTop = tester.getTopLeft(
      find.byKey(const ValueKey('siren-track-row-461111')),
    );
    final nextAlbumDefaultTop = tester.getTopLeft(
      find.byKey(const ValueKey('siren-track-row-232223')),
    );
    expect(sameAlbumDefaultTop.dy, lessThan(nextAlbumDefaultTop.dy));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));

    expect(client.detailRequests, contains('232222'));
    expect(find.text('加载详情', skipOffstage: false), findsNothing);
    expect(find.text('刷新详情', skipOffstage: false), findsNothing);
    expect(find.text('加载专辑信息', skipOffstage: false), findsNothing);
    expect(find.text('刷新专辑信息', skipOffstage: false), findsNothing);
    final songPanel = tester.getRect(
      find.byKey(const ValueKey('siren-song-table-panel')),
    );
    final sidePanel = tester.getRect(
      find.byKey(const ValueKey('siren-import-side-panel')),
    );
    expect((songPanel.bottom - sidePanel.bottom).abs(), lessThan(1));

    await tester.drag(
      find.byKey(const ValueKey('siren-library-scroll')),
      const Offset(0, -360),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));

    expect(
      tester
          .getSize(find.byKey(const ValueKey('siren-track-sort-artist')))
          .height,
      greaterThanOrEqualTo(35),
    );

    await tester.tap(find.text('艺人').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));

    expect(find.text('艺人'), findsWidgets);
    final artistHeaderLeft = tester.getTopLeft(
      find.byKey(const ValueKey('siren-track-artist-header-text')),
    );
    final artistTextLeft = tester.getTopLeft(
      find.byKey(
        const ValueKey('siren-track-artist-text-232223'),
        skipOffstage: false,
      ),
    );
    expect((artistHeaderLeft.dx - artistTextLeft.dx).abs(), lessThan(1));
    final sortedByArtistTop = tester.getTopLeft(
      find.byKey(const ValueKey('siren-track-row-232223'), skipOffstage: false),
    );
    final secondByArtistTop = tester.getTopLeft(
      find.byKey(const ValueKey('siren-track-row-232222'), skipOffstage: false),
    );
    expect(sortedByArtistTop.dy, lessThan(secondByArtistTop.dy));

    await tester.tap(find.text('标题').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));

    expect(
      tester
          .getSize(find.byKey(const ValueKey('siren-track-sort-title')))
          .height,
      greaterThanOrEqualTo(35),
    );
    final titleHeaderLeft = tester.getTopLeft(
      find.byKey(const ValueKey('siren-track-title-header-text')),
    );
    final titleTextLeft = tester.getTopLeft(
      find.byKey(
        const ValueKey('siren-track-title-text-232223'),
        skipOffstage: false,
      ),
    );
    expect((titleHeaderLeft.dx - titleTextLeft.dx).abs(), lessThan(1));
    final actionsHeader = tester.getRect(
      find.byKey(const ValueKey('siren-track-actions-header')),
    );
    final actionsCell = tester.getRect(
      find.byKey(
        const ValueKey('siren-track-actions-232223'),
        skipOffstage: false,
      ),
    );
    expect(
      (actionsHeader.center.dx - actionsCell.center.dx).abs(),
      lessThan(1),
    );

    final sortedByTitleTop = tester.getTopLeft(
      find.byKey(const ValueKey('siren-track-row-232223'), skipOffstage: false),
    );
    final secondByTitleTop = tester.getTopLeft(
      find.byKey(const ValueKey('siren-track-row-232222'), skipOffstage: false),
    );
    expect(sortedByTitleTop.dy, lessThan(secondByTitleTop.dy));

    await tester.tap(find.text('专辑').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));

    final sortedByAlbumTop = tester.getTopLeft(
      find.byKey(const ValueKey('siren-track-row-232223'), skipOffstage: false),
    );
    final secondByAlbumTop = tester.getTopLeft(
      find.byKey(const ValueKey('siren-track-row-232222'), skipOffstage: false),
    );
    expect(sortedByAlbumTop.dy, lessThan(secondByAlbumTop.dy));

    await tester.tap(find.text('加入清单').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));

    expect(find.text('待导入'), findsWidgets);
    expect(find.textContaining('未接入'), findsNothing);

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));

    expect(client.detailRequests, contains('232223'));
    expect(find.textContaining('WAV'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('album rail exposes horizontal drag bar without stealing wheel', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 1000);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });

    final client = _FakeSirenClient.large();
    final project = Directory.systemTemp.createTempSync(
      'fh-radio-studio-siren-test-',
    );
    addTearDown(() {
      if (project.existsSync()) project.deleteSync(recursive: true);
    });
    SharedPreferences.setMockInitialValues({_projectDirKey: project.path});
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          sirenCatalogClientProvider.overrideWithValue(client),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildAppTheme(
            brightness: Brightness.light,
            accent: AppAccent.lime,
          ),
          home: const Scaffold(
            body: ColoredBox(
              color: RmTokens.bgLight,
              child: SirenLibraryScreen(),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));

    final rail = find.byKey(const ValueKey('siren-album-rail'));
    expect(rail, findsOneWidget);
    final allAlbumCard = find.byKey(const ValueKey('siren-album-card-all'));
    expect(allAlbumCard, findsOneWidget);
    expect(tester.getSize(rail).height, 132);
    expect(tester.getSize(allAlbumCard).height, 120);
    expect(
      tester.getBottomLeft(rail).dy - tester.getBottomLeft(allAlbumCard).dy,
      12,
    );
    final scrollable = find.descendant(
      of: rail,
      matching: find.byType(Scrollable),
    );
    final state = tester.state<ScrollableState>(scrollable);
    final pageScrollable = find
        .descendant(
          of: find.byKey(const ValueKey('siren-library-scroll')),
          matching: find.byType(Scrollable),
        )
        .first;
    final pageState = tester.state<ScrollableState>(pageScrollable);
    expect(
      find.descendant(of: rail, matching: find.byType(Scrollbar)),
      findsOneWidget,
    );
    expect(state.position.maxScrollExtent, greaterThan(0));
    expect(state.position.pixels, 0);
    expect(pageState.position.pixels, 0);

    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: tester.getCenter(rail),
        scrollDelta: const Offset(0, 240),
      ),
    );
    await tester.pump();

    expect(state.position.pixels, 0);
    expect(pageState.position.pixels, greaterThan(0));
    await tester.pump(const Duration(milliseconds: 160));

    state.position.jumpTo(240);
    await tester.pump();
    expect(state.position.pixels, greaterThan(0));
    expect(tester.takeException(), isNull);
  });

  testWidgets('keeps queued Siren imports when the screen is remounted', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1500, 1000);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });

    final client = _FakeSirenClient();
    final project = Directory.systemTemp.createTempSync(
      'fh-radio-studio-siren-test-',
    );
    addTearDown(() {
      if (project.existsSync()) project.deleteSync(recursive: true);
    });

    SharedPreferences.setMockInitialValues({_projectDirKey: project.path});
    final prefs = await SharedPreferences.getInstance();
    var showSiren = true;
    StateSetter? hostSetState;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          sirenCatalogClientProvider.overrideWithValue(client),
        ],
        child: StatefulBuilder(
          builder: (context, setState) {
            hostSetState = setState;
            return MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: buildAppTheme(
                brightness: Brightness.light,
                accent: AppAccent.lime,
              ),
              home: Scaffold(
                body: ColoredBox(
                  color: RmTokens.bgLight,
                  child: showSiren
                      ? const SirenLibraryScreen()
                      : const Center(child: Text('其它页面')),
                ),
              ),
            );
          },
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));

    await tester.tap(find.text('加入清单').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));

    expect(find.text('1 项'), findsOneWidget);
    expect(find.text('已在清单'), findsWidgets);

    hostSetState!(() => showSiren = false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));

    expect(find.text('其它页面'), findsOneWidget);

    hostSetState!(() => showSiren = true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));

    expect(find.text('1 项'), findsOneWidget);
    expect(find.text('已在清单'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows batch mask while importing queued Siren tracks', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1500, 1000);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });

    final client = _FakeSirenClient();
    final project = Directory.systemTemp.createTempSync(
      'fh-radio-studio-siren-test-',
    );
    addTearDown(() {
      if (project.existsSync()) project.deleteSync(recursive: true);
    });
    final cachedFile = File(p.join(project.path, 'cached.wav'))
      ..createSync(recursive: true)
      ..writeAsBytesSync([1, 2, 3]);
    final cacheRelease = Completer<void>();

    SharedPreferences.setMockInitialValues({_projectDirKey: project.path});
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          sirenCatalogClientProvider.overrideWithValue(client),
          sirenAudioCacheProvider.overrideWithValue(
            _BlockingSirenAudioCache(
              cachedFile: cachedFile,
              release: cacheRelease,
            ),
          ),
          studioProvider.overrideWith(
            (ref) => _ImportMotionStudioController(prefs),
          ),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildAppTheme(
            brightness: Brightness.light,
            accent: AppAccent.lime,
          ),
          home: const Scaffold(
            body: ColoredBox(
              color: RmTokens.bgLight,
              child: SirenLibraryScreen(),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));

    expect(
      find.byKey(const ValueKey('siren-importing-queue-overlay')),
      findsNothing,
    );

    await tester.tap(find.text('加入清单').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    await tester.tap(find.text('加入清单').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));

    expect(
      find.byKey(const ValueKey('siren-importing-queue-overlay')),
      findsNothing,
    );
    expect(find.text('2 项'), findsOneWidget);

    await tester.tap(find.text('导入全部').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));

    expect(
      find.byKey(const ValueKey('siren-importing-queue-overlay')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('siren-importing-queue-overlay')),
        matching: find.byKey(const ValueKey('pending-overlay-progress-track')),
      ),
      findsOneWidget,
    );
    expect(find.text('正在导入清单'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('siren-importing-queue-item-232222')),
      findsNothing,
    );

    cacheRelease.complete();
    await tester.pump(const Duration(milliseconds: 500));
    expect(
      find.byKey(const ValueKey('siren-importing-queue-overlay')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('latest ticker keeps recent song spacing compact and slower', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1500, 900);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });

    final client = _FakeSirenClient.large();
    final project = Directory.systemTemp.createTempSync(
      'fh-radio-studio-siren-test-',
    );
    addTearDown(() {
      if (project.existsSync()) project.deleteSync(recursive: true);
    });
    SharedPreferences.setMockInitialValues({_projectDirKey: project.path});
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          sirenCatalogClientProvider.overrideWithValue(client),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildAppTheme(
            brightness: Brightness.light,
            accent: AppAccent.lime,
          ),
          home: const Scaffold(
            body: ColoredBox(
              color: RmTokens.bgLight,
              child: SirenLibraryScreen(),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));

    final firstSlot = find.byKey(const ValueKey('siren-latest-slot-0-0'));
    final secondSlot = find.byKey(const ValueKey('siren-latest-slot-0-1'));
    expect(firstSlot, findsOneWidget);
    expect(secondSlot, findsOneWidget);

    final firstLeft = tester.getTopLeft(firstSlot).dx;
    final secondLeft = tester.getTopLeft(secondSlot).dx;
    final slotSpacing = secondLeft - firstLeft;
    expect(slotSpacing, greaterThan(200));
    expect(slotSpacing, lessThan(230));

    await tester.pump(const Duration(seconds: 1));
    final shiftedLeft = tester.getTopLeft(firstSlot).dx;
    final shiftPerSecond = firstLeft - shiftedLeft;
    expect(shiftPerSecond, greaterThan(45));
    expect(shiftPerSecond, lessThan(65));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'capture Siren library route with Flutter render tree',
    (tester) async {
      final outDir = Directory(p.join('build', 'visual_qa'))
        ..createSync(recursive: true);
      final client = _FakeSirenClient.large();

      await _captureSiren(
        tester,
        client: _PendingSirenClient(),
        logicalSize: const Size(1365, 900),
        outputPath: p.join(outDir.path, 'siren_loading_regular.png'),
      );
      await _captureSiren(
        tester,
        client: _PendingSirenClient(),
        logicalSize: const Size(1365, 1500),
        outputPath: p.join(outDir.path, 'siren_loading_full.png'),
      );
      await _captureSiren(
        tester,
        client: client,
        logicalSize: const Size(1365, 900),
        outputPath: p.join(outDir.path, 'siren_regular.png'),
      );
      await _captureSiren(
        tester,
        client: client,
        logicalSize: const Size(1365, 900),
        outputPath: p.join(outDir.path, 'siren_queue_regular.png'),
        queueFirstTrack: true,
      );
      await _captureSiren(
        tester,
        client: client,
        logicalSize: const Size(1365, 900),
        outputPath: p.join(outDir.path, 'siren_importing_regular.png'),
        importingQueueOverlay: true,
      );
      await _captureSiren(
        tester,
        client: client,
        logicalSize: const Size(1365, 900),
        outputPath: p.join(outDir.path, 'siren_tooltip_regular.png'),
        showPlayTooltip: true,
      );
      await _captureSiren(
        tester,
        client: client,
        logicalSize: const Size(860, 900),
        outputPath: p.join(outDir.path, 'siren_narrow_rail_scrolled.png'),
        albumRailScrollOffset: 360,
      );
      await _captureSiren(
        tester,
        client: client,
        logicalSize: const Size(1365, 1500),
        outputPath: p.join(outDir.path, 'siren_full.png'),
      );
      await _captureSiren(
        tester,
        client: client,
        logicalSize: const Size(1365, 1500),
        outputPath: p.join(outDir.path, 'siren_importing_full.png'),
        importingQueueOverlay: true,
      );
      await _captureSiren(
        tester,
        client: client,
        logicalSize: const Size(1365, 1500),
        outputPath: p.join(outDir.path, 'siren_tooltip_full.png'),
        showPlayTooltip: true,
      );
      await _captureSiren(
        tester,
        client: client,
        logicalSize: const Size(860, 1400),
        outputPath: p.join(outDir.path, 'siren_narrow.png'),
      );
    },
    skip: Platform.environment['CAPTURE_SIREN'] != '1',
  );
}

Future<void> _loadTestFonts() async {
  await _loadFontFamily('Noto Sans SC', const [
    r'C:\Windows\Fonts\NotoSansSC-VF.ttf',
    r'C:\Windows\Fonts\msyh.ttc',
  ]);
  await _loadFontFamily('Cascadia Mono', const [
    r'C:\Windows\Fonts\CascadiaMono.ttf',
    r'C:\Windows\Fonts\CascadiaCode.ttf',
  ]);
}

Future<void> _loadFontFamily(String family, List<String> paths) async {
  final loader = FontLoader(family);
  var hasFont = false;
  for (final path in paths) {
    final file = File(path);
    if (!file.existsSync()) continue;
    loader.addFont(_readFontData(file));
    hasFont = true;
  }
  if (hasFont) {
    await loader.load();
  }
}

Future<ByteData> _readFontData(File file) async {
  final bytes = await file.readAsBytes();
  final data = Uint8List.fromList(bytes);
  return ByteData.view(data.buffer);
}

class _BlockingSirenAudioCache extends SirenAudioCache {
  _BlockingSirenAudioCache({required this.cachedFile, required this.release});

  final File cachedFile;
  final Completer<void> release;

  @override
  Future<File> cacheAudio(SirenSongDetail detail, {SirenTrack? track}) async {
    await release.future;
    return cachedFile;
  }

  @override
  Future<File?> cacheCover(SirenTrack track) async => null;
}

class _ImportMotionStudioController extends StudioController {
  _ImportMotionStudioController(super.prefs);

  @override
  Future<void> startupFullCheckOnce() async {}

  @override
  Future<String?> importSirenTrack({
    required SirenTrack track,
    required SirenSongDetail detail,
    required String cachedAudioPath,
    String? coverImagePath,
  }) async {
    return cachedAudioPath;
  }
}

Future<void> _captureSiren(
  WidgetTester tester, {
  required SirenCatalogClient client,
  required Size logicalSize,
  required String outputPath,
  double albumRailScrollOffset = 0,
  bool queueFirstTrack = false,
  bool importingQueueOverlay = false,
  bool showPlayTooltip = false,
}) async {
  final repaintKey = GlobalKey();
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = logicalSize;
  addTearDown(() {
    tester.view.resetDevicePixelRatio();
    tester.view.resetPhysicalSize();
  });
  final project = Directory.systemTemp.createTempSync(
    'fh-radio-studio-siren-test-',
  );
  addTearDown(() {
    if (project.existsSync()) project.deleteSync(recursive: true);
  });
  SharedPreferences.setMockInitialValues({_projectDirKey: project.path});
  final prefs = await SharedPreferences.getInstance();
  final cacheRelease = Completer<void>();
  final cachedFile = File(p.join(project.path, 'cached.wav'));
  if (importingQueueOverlay) {
    cachedFile.createSync(recursive: true);
    cachedFile.writeAsBytesSync([1, 2, 3]);
  }

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        sirenCatalogClientProvider.overrideWithValue(client),
        if (importingQueueOverlay) ...[
          sirenAudioCacheProvider.overrideWithValue(
            _BlockingSirenAudioCache(
              cachedFile: cachedFile,
              release: cacheRelease,
            ),
          ),
          studioProvider.overrideWith(
            (ref) => _ImportMotionStudioController(prefs),
          ),
        ],
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
                child: SirenLibraryScreen(),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 150));
  if (albumRailScrollOffset > 0) {
    final rail = find.byKey(const ValueKey('siren-album-rail'));
    expect(rail, findsOneWidget);
    final scrollable = find.descendant(
      of: rail,
      matching: find.byType(Scrollable),
    );
    final state = tester.state<ScrollableState>(scrollable);
    final position = state.position;
    position.jumpTo(
      albumRailScrollOffset.clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 160));
  }
  if (queueFirstTrack || importingQueueOverlay) {
    await tester.tap(find.text('加入清单').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 160));
  }
  if (importingQueueOverlay) {
    await tester.tap(find.text('导入全部').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 160));
    expect(
      find.byKey(const ValueKey('siren-importing-queue-overlay')),
      findsOneWidget,
    );
  }
  final hoverGesture = showPlayTooltip
      ? await _showSirenPlayTooltip(tester)
      : null;
  expect(tester.takeException(), isNull);

  final boundary = repaintKey.currentContext?.findRenderObject();
  expect(boundary, isA<RenderRepaintBoundary>());
  final renderView = tester.binding.renderViews.single;
  final rootLayer = renderView.debugLayer;
  expect(rootLayer, isA<OffsetLayer>());
  await tester.runAsync(() async {
    final image = await (rootLayer! as OffsetLayer).toImage(
      renderView.paintBounds,
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
  if (hoverGesture != null) {
    await hoverGesture.removePointer();
    await tester.pump();
  }
  if (importingQueueOverlay && !cacheRelease.isCompleted) {
    cacheRelease.complete();
    await tester.pump(const Duration(milliseconds: 500));
  }
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
}

Future<TestGesture> _showSirenPlayTooltip(WidgetTester tester) async {
  final playTooltip = find.byTooltip('在线试听').first;
  expect(playTooltip, findsOneWidget);

  final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await gesture.addPointer(location: const Offset(1, 1));
  await tester.pump();
  await gesture.moveTo(tester.getCenter(playTooltip));
  await tester.pump(const Duration(milliseconds: 520));
  await tester.pump(const Duration(milliseconds: 180));
  expect(find.text('在线试听'), findsOneWidget);
  return gesture;
}

class _FakeSirenClient implements SirenCatalogClient {
  _FakeSirenClient()
    : snapshot = _snapshot(
        albums: const [
          SirenAlbum(
            cid: '0233',
            name: '重启锚点OST',
            coverUrl: _recentCoverUrl,
            artists: ['塞壬唱片-MSR'],
            trackCount: 2,
          ),
          SirenAlbum(
            cid: '6656',
            name: 'Don\'t Miss It',
            coverUrl: _recentCoverUrl,
            artists: ['塞壬唱片-MSR'],
            trackCount: 1,
          ),
        ],
        tracks: const [
          SirenTrack(
            cid: '232222',
            name: '对峙',
            albumCid: '0233',
            albumName: '重启锚点OST',
            coverUrl: _recentCoverUrl,
            artists: ['塞壬唱片-MSR'],
            albumIsOst: true,
          ),
          SirenTrack(
            cid: '461111',
            name: '新生蓝图',
            albumCid: '0233',
            albumName: '重启锚点OST',
            coverUrl: _recentCoverUrl,
            artists: ['塞壬唱片-MSR'],
            albumIsOst: true,
          ),
          SirenTrack(
            cid: '232223',
            name: 'Don\'t Miss It',
            albumCid: '6656',
            albumName: 'Don\'t Miss It',
            coverUrl: _recentCoverUrl,
            artists: ['塞壬唱片-MSR', 'Mili'],
            albumIsOst: false,
          ),
        ],
      );

  _FakeSirenClient.large()
    : snapshot = _snapshot(albums: _largeAlbums, tracks: _largeTracks);

  final SirenCatalogSnapshot snapshot;
  final detailRequests = <String>[];

  @override
  Future<SirenCatalogSnapshot> fetchCatalog() async => snapshot;

  @override
  Future<SirenAlbumDetail> fetchAlbumDetail(String cid) async {
    return SirenAlbumDetail(
      cid: cid,
      name: snapshot.albums.firstWhere((album) => album.cid == cid).name,
      intro: 'fixture',
      belong: 'arknights',
      coverUrl: _recentCoverUrl,
      coverDeUrl: '',
      songs: const [],
    );
  }

  @override
  Future<SirenSongDetail> fetchSongDetail(String cid) async {
    detailRequests.add(cid);
    final track = snapshot.tracks.firstWhere((item) => item.cid == cid);
    return SirenSongDetail(
      cid: track.cid,
      name: track.name,
      albumCid: track.albumCid,
      sourceUrl: 'https://res01.hycdn.cn/siren/audio/20260516/${track.cid}.wav',
      lyricUrl: null,
      mvUrl: null,
      mvCoverUrl: null,
      artists: track.artists,
    );
  }
}

class _PendingSirenClient implements SirenCatalogClient {
  final _catalog = Completer<SirenCatalogSnapshot>();

  @override
  Future<SirenCatalogSnapshot> fetchCatalog() => _catalog.future;

  @override
  Future<SirenAlbumDetail> fetchAlbumDetail(String cid) {
    return Future.error(UnimplementedError('album detail is not used'));
  }

  @override
  Future<SirenSongDetail> fetchSongDetail(String cid) {
    return Future.error(UnimplementedError('song detail is not used'));
  }
}

SirenCatalogSnapshot _snapshot({
  required List<SirenAlbum> albums,
  required List<SirenTrack> tracks,
}) {
  return SirenCatalogSnapshot(
    fetchedAt: DateTime(2026, 5, 23, 10, 30),
    albums: albums,
    tracks: tracks,
  );
}

const _largeAlbums = [
  SirenAlbum(
    cid: '0233',
    name: '重启锚点OST',
    coverUrl: _recentCoverUrl,
    artists: ['塞壬唱片-MSR'],
    trackCount: 4,
  ),
  SirenAlbum(
    cid: '4507',
    name: '相变临界OST',
    coverUrl: _recentCoverUrl,
    artists: ['塞壬唱片-MSR'],
    trackCount: 3,
  ),
  SirenAlbum(
    cid: '6656',
    name: 'Don\'t Miss It',
    coverUrl: _recentCoverUrl,
    artists: ['塞壬唱片-MSR'],
    trackCount: 2,
  ),
  SirenAlbum(
    cid: '0234',
    name: 'All by My Design',
    coverUrl: _recentCoverUrl,
    artists: ['塞壬唱片-MSR'],
    trackCount: 2,
  ),
  SirenAlbum(
    cid: '7762',
    name: 'Innocence',
    coverUrl: _recentCoverUrl,
    artists: ['塞壬唱片-MSR'],
    trackCount: 2,
  ),
];

const _largeTracks = [
  SirenTrack(
    cid: '232222',
    name: '对峙',
    albumCid: '0233',
    albumName: '重启锚点OST',
    coverUrl: _recentCoverUrl,
    artists: ['塞壬唱片-MSR'],
    albumIsOst: true,
  ),
  SirenTrack(
    cid: '461111',
    name: '新生蓝图',
    albumCid: '0233',
    albumName: '重启锚点OST',
    coverUrl: _recentCoverUrl,
    artists: ['塞壬唱片-MSR'],
    albumIsOst: true,
  ),
  SirenTrack(
    cid: '953945',
    name: '繁务间隙',
    albumCid: '0233',
    albumName: '重启锚点OST',
    coverUrl: _recentCoverUrl,
    artists: ['塞壬唱片-MSR'],
    albumIsOst: true,
  ),
  SirenTrack(
    cid: '514503',
    name: '荒原黎明',
    albumCid: '0233',
    albumName: '重启锚点OST',
    coverUrl: _recentCoverUrl,
    artists: ['塞壬唱片-MSR'],
    albumIsOst: true,
  ),
  SirenTrack(
    cid: '697688',
    name: '永恒之春',
    albumCid: '4507',
    albumName: '相变临界OST',
    coverUrl: _recentCoverUrl,
    artists: ['塞壬唱片-MSR'],
    albumIsOst: true,
  ),
  SirenTrack(
    cid: '306877',
    name: '厨房谈话',
    albumCid: '4507',
    albumName: '相变临界OST',
    coverUrl: _recentCoverUrl,
    artists: ['塞壬唱片-MSR'],
    albumIsOst: true,
  ),
  SirenTrack(
    cid: '514504',
    name: '“诺言”',
    albumCid: '4507',
    albumName: '相变临界OST',
    coverUrl: _recentCoverUrl,
    artists: ['塞壬唱片-MSR'],
    albumIsOst: true,
  ),
  SirenTrack(
    cid: '232223',
    name: 'Don\'t Miss It',
    albumCid: '6656',
    albumName: 'Don\'t Miss It',
    coverUrl: _recentCoverUrl,
    artists: ['塞壬唱片-MSR', 'Mili'],
    albumIsOst: false,
  ),
  SirenTrack(
    cid: '880395',
    name: 'Don\'t Miss It (Instrumental)',
    albumCid: '6656',
    albumName: 'Don\'t Miss It',
    coverUrl: _recentCoverUrl,
    artists: ['塞壬唱片-MSR'],
    albumIsOst: false,
  ),
  SirenTrack(
    cid: '306878',
    name: 'All by My Design',
    albumCid: '0234',
    albumName: 'All by My Design',
    coverUrl: _recentCoverUrl,
    artists: ['塞壬唱片-MSR'],
    albumIsOst: false,
  ),
  SirenTrack(
    cid: '880396',
    name: 'All by My Design (Instrumental)',
    albumCid: '0234',
    albumName: 'All by My Design',
    coverUrl: _recentCoverUrl,
    artists: ['塞壬唱片-MSR'],
    albumIsOst: false,
  ),
  SirenTrack(
    cid: '232224',
    name: 'Innocence',
    albumCid: '7762',
    albumName: 'Innocence',
    coverUrl: _recentCoverUrl,
    artists: ['塞壬唱片-MSR'],
    albumIsOst: false,
  ),
  SirenTrack(
    cid: '953947',
    name: 'Innocence (Instrumental)',
    albumCid: '7762',
    albumName: 'Innocence',
    coverUrl: _recentCoverUrl,
    artists: ['塞壬唱片-MSR'],
    albumIsOst: false,
  ),
];
