import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:fh_radio_studio/core/playlist_plan.dart';
import 'package:fh_radio_studio/core/project_workspace.dart';
import 'package:fh_radio_studio/core/track_metadata_cache.dart';
import 'package:fh_radio_studio/domain/radio_library.dart';
import 'package:fh_radio_studio/state/app_state.dart';
import 'package:fh_radio_studio/state/studio_state.dart';
import 'package:fh_radio_studio/state/custom_pool_tracks.dart';
import 'package:fh_radio_studio/state/playlist_catalog_state.dart';
import 'package:fh_radio_studio/state/playlist_plan_state.dart';
import 'package:fh_radio_studio/screens/playlist/playlist_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('loads playlist catalog from latest package before game files', () {
    final repoRoot = p.dirname(p.current);
    final catalog = loadPlaylistCatalog(
      packageDir: p.join(
        repoRoot,
        'test',
        'project',
        'cli-full-flow',
        'packages',
        'r4-full-flow',
      ),
      gameDir: p.join(
        repoRoot,
        'test',
        'fixtures',
        'mock-game',
        'fh6-steam-b99000001',
        'steamapps',
        'common',
        'ForzaHorizon6',
      ),
      sourceLang: 'CN',
      targetLang: 'EN',
    );

    expect(catalog.origin, PlaylistCatalogOrigin.package);
    expect(catalog.sourcePath, contains('RadioInfo_CN.xml'));
    expect(catalog.modeOf('R4'), StationMode.custom);
    expect(
      catalog.tracksOfRadio('R4', 'FreeRoam').map((track) => track.title),
      contains('Full Flow Test'),
    );
  });

  test('game view reads installed game files even when a package exists', () {
    final repoRoot = p.dirname(p.current);
    final packageDir = p.join(
      repoRoot,
      'test',
      'project',
      'cli-full-flow',
      'packages',
      'r4-full-flow',
    );
    final catalog = loadPlaylistCatalog(
      view: PlaylistCatalogView.game,
      packageDir: packageDir,
      gameDir: p.join(
        repoRoot,
        'test',
        'fixtures',
        'mock-game',
        'fh6-steam-b99000001',
        'steamapps',
        'common',
        'ForzaHorizon6',
      ),
      sourceLang: 'CN',
      targetLang: 'EN',
      detectionPackageDirs: [packageDir],
    );

    expect(catalog.origin, PlaylistCatalogOrigin.game);
    expect(catalog.modeOfList('R1', 'FreeRoam'), StationMode.builtin);
    expect(
      catalog.tracksOfRadio('R4', 'FreeRoam').map((track) => track.title),
      isNot(contains('Full Flow Test')),
    );
  });

  test('loads playlist catalog from game files when no package exists', () {
    final repoRoot = p.dirname(p.current);
    final catalog = loadPlaylistCatalog(
      packageDir: null,
      gameDir: p.join(
        repoRoot,
        'test',
        'fixtures',
        'mock-game',
        'fh6-steam-b99000001',
        'steamapps',
        'common',
        'ForzaHorizon6',
      ),
      sourceLang: 'EN',
      targetLang: 'CHS',
    );

    expect(catalog.origin, PlaylistCatalogOrigin.game);
    expect(catalog.modeOf('R1'), StationMode.builtin);
    expect(
      catalog.tracksOfRadio('R1', 'FreeRoam').map((track) => track.title),
      contains('Mock R1 Reference'),
    );
  });

  test('playlist custom mode compares current RadioInfo with baseline', () {
    final temp = Directory.systemTemp.createTempSync(
      'fh-radio-studio-playlist-baseline-compare-',
    );
    addTearDown(() {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });
    final baselineDir = Directory(p.join(temp.path, 'baseline'));
    final gameDir = Directory(p.join(temp.path, 'ForzaHorizon6'));
    final baselineAudio = Directory(p.join(baselineDir.path, 'media', 'audio'))
      ..createSync(recursive: true);
    final gameAudio = Directory(p.join(gameDir.path, 'media', 'audio'))
      ..createSync(recursive: true);
    File(p.join(baselineAudio.path, 'RadioInfo_CN.xml')).writeAsStringSync(
      _singleTrackRadioInfoXml(title: 'Original Pulse', artist: 'Forza'),
      encoding: utf8,
    );
    File(p.join(gameAudio.path, 'RadioInfo_CN.xml')).writeAsStringSync(
      _singleTrackRadioInfoXml(title: 'Custom Pulse', artist: 'Local Artist'),
      encoding: utf8,
    );

    final catalog = loadPlaylistCatalog(
      packageDir: null,
      gameDir: gameDir.path,
      sourceLang: 'CN',
      targetLang: 'EN',
      baselineGameDir: baselineDir.path,
    );

    expect(catalog.origin, PlaylistCatalogOrigin.game);
    expect(catalog.modeOfList('R1', 'FreeRoam'), StationMode.custom);
    expect(catalog.modeOfList('R1', 'Event'), StationMode.custom);
    expect(catalog.tracksOfRadio('R1', 'FreeRoam').single.modded, isTrue);
  });

  test('playlist catalog hides Streamer Mode from the UI', () {
    final repoRoot = p.dirname(p.current);
    final catalog = loadPlaylistCatalog(
      packageDir: null,
      gameDir: p.join(
        repoRoot,
        'test',
        'fixtures',
        'mock-game',
        'fh6-steam-b99000001',
        'steamapps',
        'common',
        'ForzaHorizon6',
      ),
      sourceLang: 'CN',
      targetLang: 'EN',
    );

    expect(catalog.radios.map((radio) => radio.code), isNot(contains('R10')));
    expect(
      catalog.radios.map((radio) => radio.name.toLowerCase()),
      isNot(contains('streamer mode')),
    );
  });

  test('uses bank slots instead of extra XML track samples', () {
    final temp = Directory.systemTemp.createTempSync(
      'fh-radio-studio-playlist-bank-slots-',
    );
    addTearDown(() {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });
    final gameDir = Directory(p.join(temp.path, 'ForzaHorizon6'));
    final audioDir = Directory(p.join(gameDir.path, 'media', 'audio'))
      ..createSync(recursive: true);
    Directory(p.join(audioDir.path, 'FMODBanks')).createSync();
    _writeFsb5Bank(
      File(p.join(audioDir.path, 'FMODBanks', 'R1_Tracks_CU1.assets.bank')),
      samples: 3,
    );
    File(
      p.join(audioDir.path, 'RadioInfo_CN.xml'),
    ).writeAsStringSync(_bankSlotRadioInfoXml(), encoding: utf8);

    final catalog = loadPlaylistCatalog(
      packageDir: null,
      gameDir: gameDir.path,
      sourceLang: 'CN',
      targetLang: 'EN',
    );

    expect(catalog.radios.single.slot, 3);
    expect(catalog.tracksOfRadio('R1', 'FreeRoam'), hasLength(3));
  });

  test('package catalog falls back to game bank slots', () {
    final temp = Directory.systemTemp.createTempSync(
      'fh-radio-studio-playlist-package-bank-slots-',
    );
    addTearDown(() {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });
    final gameDir = Directory(p.join(temp.path, 'ForzaHorizon6'));
    final gameAudio = Directory(p.join(gameDir.path, 'media', 'audio'))
      ..createSync(recursive: true);
    Directory(p.join(gameAudio.path, 'FMODBanks')).createSync();
    _writeFsb5Bank(
      File(p.join(gameAudio.path, 'FMODBanks', 'R1_Tracks_CU1.assets.bank')),
      samples: 3,
    );
    File(
      p.join(gameAudio.path, 'RadioInfo_CN.xml'),
    ).writeAsStringSync(_bankSlotRadioInfoXml(), encoding: utf8);

    final packageDir = Directory(p.join(temp.path, 'package-root'));
    final packageAudio = Directory(
      p.join(packageDir.path, 'package', 'media', 'audio'),
    )..createSync(recursive: true);
    File(
      p.join(packageAudio.path, 'RadioInfo_CN.xml'),
    ).writeAsStringSync(_bankSlotRadioInfoXml(), encoding: utf8);

    final catalog = loadPlaylistCatalog(
      packageDir: packageDir.path,
      gameDir: gameDir.path,
      sourceLang: 'CN',
      targetLang: 'EN',
    );

    expect(catalog.origin, PlaylistCatalogOrigin.package);
    expect(catalog.radios.single.slot, 3);
  });

  test(
    'playlist catalog prefers baseline bank slots over current status slots',
    () async {
      final temp = Directory.systemTemp.createTempSync(
        'fh-radio-studio-playlist-baseline-slots-',
      );
      addTearDown(() {
        if (temp.existsSync()) temp.deleteSync(recursive: true);
      });
      final projectDir = p.join(temp.path, 'project');
      final gameDir = p.join(temp.path, 'ForzaHorizon6');
      final gameAudio = Directory(p.join(gameDir, 'media', 'audio'))
        ..createSync(recursive: true);
      final baselineAudio = Directory(
        p.join(projectDir, 'backups', 'baseline-current', 'media', 'audio'),
      )..createSync(recursive: true);
      Directory(p.join(gameAudio.path, 'FMODBanks')).createSync();
      Directory(p.join(baselineAudio.path, 'FMODBanks')).createSync();
      _writeFsb5Bank(
        File(p.join(gameAudio.path, 'FMODBanks', 'R1_Tracks_CU1.assets.bank')),
        samples: 5,
      );
      _writeFsb5Bank(
        File(
          p.join(baselineAudio.path, 'FMODBanks', 'R1_Tracks_CU1.assets.bank'),
        ),
        samples: 3,
      );
      File(
        p.join(gameAudio.path, 'RadioInfo_CN.xml'),
      ).writeAsStringSync(_bankSlotRadioInfoXml(), encoding: utf8);
      File(
        p.join(baselineAudio.path, 'RadioInfo_CN.xml'),
      ).writeAsStringSync(_bankSlotRadioInfoXml(), encoding: utf8);

      SharedPreferences.setMockInitialValues({
        'rm.studio.projectDir': projectDir,
      });
      final prefs = await SharedPreferences.getInstance();
      final controller = _EditableStudioController(prefs);
      controller.state = controller.state.copyWith(
        projectDir: projectDir,
        gameDir: gameDir,
        sourceLang: 'CN',
        targetLang: 'EN',
        radioOptions: const [
          RadioStatusOption(
            number: 1,
            name: 'Horizon Pulse',
            code: 'R1',
            tracks: 4,
            bankSlots: 5,
            freeRoam: 3,
            event: 3,
          ),
        ],
      );
      final container = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          studioProvider.overrideWith((ref) => controller),
        ],
      );
      addTearDown(container.dispose);

      expect(container.read(baselineBankSlotOverridesProvider)['R1'], 3);
      final catalog = container.read(
        playlistCatalogForViewProvider(PlaylistCatalogView.game),
      );

      expect(catalog.radios.single.slot, 3);
    },
  );

  test('game view marks deployed custom lists and seeds a draft plan', () {
    final repoRoot = p.dirname(p.current);
    final packageDir = p.join(
      repoRoot,
      'test',
      'project',
      'cli-full-flow',
      'packages',
      'r4-full-flow',
    );
    final temp = Directory.systemTemp.createTempSync(
      'fh-radio-studio-game-playlist-',
    );
    addTearDown(() {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });
    final gameDir = Directory(p.join(temp.path, 'ForzaHorizon6'));
    final audioDir = Directory(p.join(gameDir.path, 'media', 'audio'))
      ..createSync(recursive: true);
    File(
      p.join(packageDir, 'package', 'media', 'audio', 'RadioInfo_CN.xml'),
    ).copySync(p.join(audioDir.path, 'RadioInfo_CN.xml'));

    final catalog = loadPlaylistCatalog(
      view: PlaylistCatalogView.game,
      packageDir: packageDir,
      gameDir: gameDir.path,
      sourceLang: 'CN',
      targetLang: 'EN',
      detectionPackageDirs: [packageDir],
    );
    final track = catalog
        .tracksOfRadio('R4', 'FreeRoam')
        .firstWhere((track) => track.modded);
    final plan = playlistPlanFromCatalog(catalog, const []);

    expect(catalog.origin, PlaylistCatalogOrigin.game);
    expect(catalog.modeOfList('R4', 'FreeRoam'), StationMode.custom);
    expect(catalog.sourceForTrack(track), endsWith('Full Flow Test.wav'));
    expect(plan.assignmentsForRadio('R4', 'FreeRoam'), hasLength(1));
    expect(plan.assignmentsForRadio('R4', 'Event'), hasLength(1));
    expect(plan.hasBuiltinOverride('R1', 'FreeRoam'), isTrue);
  });

  test(
    'reports a failed catalog when package and game files are unavailable',
    () {
      final catalog = loadPlaylistCatalog(
        packageDir: p.join(
          Directory.systemTemp.path,
          'missing-fh-radio-studio-package',
        ),
        gameDir: p.join(Directory.systemTemp.path, 'missing-fh6-game'),
        sourceLang: 'EN',
        targetLang: 'CHS',
      );

      expect(catalog.origin, PlaylistCatalogOrigin.failed);
      expect(catalog.failed, isTrue);
      expect(catalog.radios, isEmpty);
      expect(catalog.badgeLabel, '读取失败');
      expect(catalog.error, contains('RadioInfo_*.xml'));
    },
  );

  test('seeds the draft plan from package assignments', () {
    final source = p.join(Directory.current.path, 'test-fixtures', 'song.wav');
    final plan = playlistPlanFromPackageSummaries(
      pending: PackageArtifactSummary(
        radio: 4,
        station: 'Horizon XS',
        bankName: 'R4_Tracks_CU1.assets.bank',
        musicCount: 1,
        bankSlots: 3,
        playlistMode: 'only',
        skipBank: true,
        runtimeVerified: false,
        sourceLang: 'CN',
        targetLang: 'EN',
        previewTracks: const ['FH Radio Studio Dev - Full Flow Test'],
        assignments: [
          PackageTrackAssignment(source: source, radioLabel: 'R4', slot: 1),
        ],
      ),
      last: null,
    );

    final assignment = plan.assignmentForPath(source);
    expect(assignment, isNotNull);
    expect(assignment!.radioCode, 'R4');
    expect(assignment.slot, 1);
  });

  test('seeding a draft plan skips Streamer Mode package assignments', () {
    final source = p.join(Directory.current.path, 'test-fixtures', 'song.wav');
    final plan = playlistPlanFromPackageSummaries(
      pending: PackageArtifactSummary(
        radio: 10,
        station: 'Streamer Mode',
        bankName: 'R10_Tracks_Disk.assets.bank',
        musicCount: 1,
        bankSlots: 1,
        playlistMode: 'only',
        skipBank: true,
        runtimeVerified: false,
        sourceLang: 'CN',
        targetLang: 'EN',
        previewTracks: const ['Streamer Track'],
        assignments: [
          PackageTrackAssignment(source: source, radioLabel: 'R10', slot: 1),
        ],
      ),
      last: null,
    );

    expect(plan.assignments, isEmpty);
  });

  test(
    'playlist plan allows multi-list assignment and deduplicates a list',
    () {
      final source = p.join(Directory.current.path, 'song.wav');
      final plan = const PlaylistPlan.empty()
          .assign(
            source: source,
            radioCode: 'R4',
            playlistType: 'FreeRoam',
            slot: 1,
          )
          .assign(
            source: source,
            radioCode: 'R4',
            playlistType: 'FreeRoam',
            slot: 9,
          )
          .assign(
            source: source,
            radioCode: 'R2',
            playlistType: 'Event',
            slot: 1,
          );

      expect(plan.assignmentsForPath(source), hasLength(2));
      expect(plan.assignmentsForRadio('R4', 'FreeRoam'), hasLength(1));
      expect(plan.assignmentsForRadio('R4', 'FreeRoam').single.slot, 1);
      expect(plan.sourcesForRadio('R4'), [source]);
    },
  );

  test(
    'playlist plan can explicitly restore a package-seeded list to builtin',
    () {
      final source = p.join(Directory.current.path, 'song.wav');
      final plan = const PlaylistPlan.empty()
          .assign(
            source: source,
            radioCode: 'R4',
            playlistType: 'FreeRoam',
            slot: 1,
          )
          .restoreBuiltin(radioCode: 'R4', playlistType: 'FreeRoam');

      expect(plan.hasDraft, isTrue);
      expect(plan.hasBuiltinOverride('R4', 'FreeRoam'), isTrue);
      expect(plan.assignmentsForRadio('R4', 'FreeRoam'), isEmpty);
    },
  );

  test('playlist plan persists builtin restore targets', () {
    final project = Directory.systemTemp.createTempSync(
      'fh-radio-studio-playlist-builtin-',
    );
    addTearDown(() {
      if (project.existsSync()) project.deleteSync(recursive: true);
    });

    final plan = const PlaylistPlan.empty().restoreBuiltin(
      radioCode: 'R4',
      playlistType: 'Event',
    );

    PlaylistPlanStore.write(project.path, plan);
    final restored = PlaylistPlanStore.read(project.path);

    expect(
      File(
        p.join(project.path, '.fh-radio-studio', 'playlist_plan.json'),
      ).existsSync(),
      isTrue,
    );
    expect(
      File(p.join(project.path, 'analysis', 'playlist_plan.json')).existsSync(),
      isFalse,
    );
    expect(restored.hasDraft, isTrue);
    expect(restored.hasBuiltinOverride('R4', 'Event'), isTrue);
    expect(restored.assignments, isEmpty);
  });

  test('playlist plan ignores the old analysis draft path', () {
    final project = Directory.systemTemp.createTempSync(
      'fh-radio-studio-playlist-migrate-',
    );
    addTearDown(() {
      if (project.existsSync()) project.deleteSync(recursive: true);
    });
    final legacy = File(p.join(project.path, 'analysis', 'playlist_plan.json'))
      ..createSync(recursive: true);
    final source = p.join(project.path, 'sources', 'song.wav');
    legacy.writeAsStringSync('''
{
  "schema_version": 2,
  "assignments": [
    {
      "source": ${jsonEncode(source)},
      "radio_code": "R4",
      "playlist_type": "FreeRoam",
      "slot": 1
    }
  ],
  "builtin_targets": []
}
''', encoding: utf8);

    final restored = PlaylistPlanStore.read(project.path);

    expect(restored.hasDraft, isFalse);
    expect(
      File(PlaylistPlanStore.configPath(project.path)).existsSync(),
      isFalse,
    );
    expect(legacy.existsSync(), isTrue);
  });

  test(
    'real pool keeps all songs, deduplicates paths, and sorts assigned last',
    () {
      final dir = Directory.systemTemp.createTempSync(
        'fh-radio-studio-pool-dedupe-',
      );
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
      final first = File(p.join(dir.path, '01 - Artist - First.wav'))
        ..writeAsBytesSync(const []);
      final second = File(p.join(dir.path, '02 - Artist - Second.wav'))
        ..writeAsBytesSync(const []);
      final third = File(p.join(dir.path, '03 - Artist - Third.wav'))
        ..writeAsBytesSync(const []);
      final plan = const PlaylistPlan.empty().assign(
        source: first.path,
        radioCode: 'R4',
        playlistType: 'FreeRoam',
        slot: 1,
      );

      final pool = buildRealPoolTracks(
        [dir.path, first.path],
        assignments: plan.assignments,
        configs: {
          realTrackKeyForPath(first.path): {
            'confirmedGroupCount': 4,
            'allConfirmed': true,
          },
          realTrackKeyForPath(second.path): {
            'confirmedGroupCount': 1,
            'allConfirmed': false,
          },
          realTrackKeyForPath(third.path): {
            'confirmedGroupCount': 3,
            'allConfirmed': false,
          },
        },
      );
      final state = PlaylistState(
        pool: pool,
        mode: PlaylistMode.freeroam,
        search: '',
        splitPlaylistTypes: false,
      );

      expect(pool.map((track) => track.source).toSet(), {
        first.path,
        second.path,
        third.path,
      });
      expect(state.poolForDisplay(plan).map((track) => track.source), [
        third.path,
        second.path,
        first.path,
      ]);
      expect(
        state.tracksOfRadio('R4', 'FreeRoam', plan).single.source,
        first.path,
      );
    },
  );

  test(
    'playlist pool display keeps existing order rules and puts MSR first on ties',
    () {
      const local = PoolTrack(
        id: 'local-tie',
        title: 'Local Tie',
        artist: 'Local Artist',
        source: r'C:\music\local-tie.wav',
        durationSec: 120,
        bpm: 0,
        key: '待分析',
        configured: false,
        confirmed: 2,
        added: 'now',
      );
      const siren = PoolTrack(
        id: 'siren-tie',
        title: 'Siren Tie',
        artist: '塞壬唱片-MSR',
        source: r'C:\project\siren\MSR-232251.wav',
        durationSec: 120,
        bpm: 0,
        key: '待分析',
        configured: false,
        confirmed: 2,
        sourceKind: 'siren',
        sourceLabel: 'MSR-232251',
        sirenCid: '232251',
        added: 'now',
      );
      const state = PlaylistState(
        pool: [local, siren],
        mode: PlaylistMode.freeroam,
        search: '',
        splitPlaylistTypes: false,
      );

      expect(
        state
            .poolForDisplay(const PlaylistPlan.empty())
            .map((track) => track.title),
        ['Siren Tie', 'Local Tie'],
      );
    },
  );

  test('real pool uses CLI metadata cache before filename fallback', () {
    final dir = Directory.systemTemp.createTempSync(
      'fh-radio-studio-pool-metadata-',
    );
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final track = File(p.join(dir.path, '01 - Wrong Artist - Wrong Title.wav'))
      ..writeAsBytesSync(const []);

    final pool = buildRealPoolTracks(
      [track.path],
      metadata: {
        realTrackKeyForPath(track.path): const TrackMetadata(
          artist: 'Collage',
          title: 'Nine Sols',
          fromTags: true,
          coverArtPath: r'C:\project\.fh-radio-studio\artwork\nine-sols.png',
        ),
      },
    );

    expect(pool.single.artist, 'Collage');
    expect(pool.single.title, 'Nine Sols');
    expect(
      pool.single.coverArtPath,
      r'C:\project\.fh-radio-studio\artwork\nine-sols.png',
    );
  });

  test('playlist plan can collapse split FreeRoam and Event lists', () {
    final free = p.join(Directory.current.path, 'free.wav');
    final event = p.join(Directory.current.path, 'event.wav');
    final split = const PlaylistPlan.empty()
        .assign(
          source: free,
          radioCode: 'R4',
          playlistType: 'FreeRoam',
          slot: 1,
        )
        .assign(source: event, radioCode: 'R4', playlistType: 'Event', slot: 1);

    expect(split.hasSplitPlaylistDifferences, isTrue);

    final synced = split.syncPlaylistTypesFrom('Event');

    expect(synced.hasSplitPlaylistDifferences, isFalse);
    expect(synced.assignmentsForRadio('R4', 'FreeRoam').single.source, event);
    expect(synced.assignmentsForRadio('R4', 'Event').single.source, event);
  });

  test(
    'playlist notifier refuses assignments beyond the radio slot limit',
    () async {
      final projectDir = _tempProjectDir();
      SharedPreferences.setMockInitialValues({
        'rm.studio.projectDir': projectDir,
      });
      final prefs = await SharedPreferences.getInstance();
      final tracks = [
        _testTrack('one', 'One', projectDir),
        _testTrack('two', 'Two', projectDir),
      ];
      final container = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          studioProvider.overrideWith(
            (ref) => _EditableStudioController(prefs),
          ),
          realPoolTracksProvider.overrideWithValue(tracks),
        ],
      );
      addTearDown(container.dispose);

      final notifier = container.read(playlistProvider.notifier);
      expect(
        notifier.assignToRadio('one', 'R4', 'FreeRoam', maxSlots: 1),
        isTrue,
      );
      expect(
        notifier.assignToRadio('two', 'R4', 'FreeRoam', maxSlots: 1),
        isFalse,
      );

      final plan = container.read(playlistPlanProvider);
      expect(plan.assignmentsForRadio('R4', 'FreeRoam'), hasLength(1));
      expect(plan.assignmentsForRadio('R4', 'Event'), hasLength(1));
    },
  );

  test('playlist notifier moves list drags instead of copying them', () async {
    final projectDir = _tempProjectDir();
    SharedPreferences.setMockInitialValues({
      'rm.studio.projectDir': projectDir,
    });
    final prefs = await SharedPreferences.getInstance();
    final track = _testTrack('one', 'One', projectDir);
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        studioProvider.overrideWith((ref) => _EditableStudioController(prefs)),
        realPoolTracksProvider.overrideWithValue([track]),
      ],
    );
    addTearDown(container.dispose);

    final notifier = container.read(playlistProvider.notifier);
    expect(
      notifier.assignToRadio('one', 'R4', 'FreeRoam', maxSlots: 3),
      isTrue,
    );
    expect(
      notifier.assignToRadio(
        'one',
        'R2',
        'FreeRoam',
        maxSlots: 3,
        originRadioCode: 'R4',
        originPlaylistType: 'FreeRoam',
      ),
      isTrue,
    );

    final plan = container.read(playlistPlanProvider);
    expect(plan.assignmentsForRadio('R4', 'FreeRoam'), isEmpty);
    expect(plan.assignmentsForRadio('R4', 'Event'), isEmpty);
    expect(plan.assignmentsForRadio('R2', 'FreeRoam'), hasLength(1));
    expect(plan.assignmentsForRadio('R2', 'Event'), hasLength(1));
  });

  test(
    'playlist notifier keeps origin when a list move target is full',
    () async {
      final projectDir = _tempProjectDir();
      SharedPreferences.setMockInitialValues({
        'rm.studio.projectDir': projectDir,
      });
      final prefs = await SharedPreferences.getInstance();
      final tracks = [
        _testTrack('one', 'One', projectDir),
        _testTrack('two', 'Two', projectDir),
      ];
      final container = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          studioProvider.overrideWith(
            (ref) => _EditableStudioController(prefs),
          ),
          realPoolTracksProvider.overrideWithValue(tracks),
        ],
      );
      addTearDown(container.dispose);

      final notifier = container.read(playlistProvider.notifier);
      expect(
        notifier.assignToRadio('one', 'R4', 'FreeRoam', maxSlots: 1),
        isTrue,
      );
      expect(
        notifier.assignToRadio('two', 'R2', 'FreeRoam', maxSlots: 1),
        isTrue,
      );
      expect(
        notifier.assignToRadio(
          'one',
          'R2',
          'FreeRoam',
          maxSlots: 1,
          originRadioCode: 'R4',
          originPlaylistType: 'FreeRoam',
        ),
        isFalse,
      );

      final plan = container.read(playlistPlanProvider);
      expect(plan.assignmentsForRadio('R4', 'FreeRoam'), hasLength(1));
      expect(plan.assignmentsForRadio('R2', 'FreeRoam'), hasLength(1));
      expect(
        plan.assignmentsForRadio('R2', 'FreeRoam').single.source,
        tracks[1].source,
      );
    },
  );

  test('playlist notifier ignores edits while file scan is running', () async {
    final projectDir = _tempProjectDir();
    SharedPreferences.setMockInitialValues({
      'rm.studio.projectDir': projectDir,
    });
    final prefs = await SharedPreferences.getInstance();
    final track = _testTrack('one', 'One', projectDir);
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        studioProvider.overrideWith((ref) => _ScanningStudioController(prefs)),
        realPoolTracksProvider.overrideWithValue([track]),
      ],
    );
    addTearDown(container.dispose);

    final notifier = container.read(playlistProvider.notifier);

    expect(
      notifier.assignToRadio('one', 'R4', 'FreeRoam', maxSlots: 3),
      isFalse,
    );
    expect(container.read(playlistPlanProvider).assignments, isEmpty);
  });

  test('ignores persisted playlist draft on startup', () async {
    final project = Directory.systemTemp.createTempSync(
      'fh-radio-studio-playlist-plan-',
    );
    addTearDown(() {
      if (project.existsSync()) project.deleteSync(recursive: true);
    });

    final source = p.join(project.path, 'sources', 'old-song.wav');
    PlaylistPlanStore.write(
      project.path,
      PlaylistPlan.empty().assign(
        source: source,
        radioCode: 'R4',
        playlistType: 'FreeRoam',
        slot: 2,
      ),
    );

    SharedPreferences.setMockInitialValues({
      'rm.studio.projectDir': project.path,
    });
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
    );
    addTearDown(container.dispose);

    expect(container.read(playlistPlanProvider).assignments, isEmpty);
    expect(container.read(effectivePlaylistPlanProvider).assignments, isEmpty);
  });

  test('playlist plan store keeps project sources and siren assignments', () {
    final projectDir = _tempProjectDir();
    final sourceTrack = _testTrack('inside', 'Inside', projectDir);
    final sirenTrack = File(
      p.join(FhRadioStudioProject.sirenDir(projectDir), 'MSR-232251.wav'),
    )..createSync(recursive: true);
    final outside = p.join(Directory.current.path, 'outside.wav');

    PlaylistPlanStore.write(
      projectDir,
      PlaylistPlan.empty()
          .assign(
            source: outside,
            radioCode: 'R2',
            playlistType: 'FreeRoam',
            slot: 1,
          )
          .assign(
            source: sourceTrack.source,
            radioCode: 'R4',
            playlistType: 'FreeRoam',
            slot: 1,
          )
          .assign(
            source: sirenTrack.path,
            radioCode: 'R5',
            playlistType: 'Event',
            slot: 3,
          ),
    );

    final restored = PlaylistPlanStore.read(projectDir);

    expect(restored.assignmentsForPath(outside), isEmpty);
    expect(restored.assignmentsForPath(sourceTrack.source), hasLength(1));
    expect(restored.assignmentsForPath(sirenTrack.path), hasLength(1));
  });
}

String _tempProjectDir() {
  final project = Directory.systemTemp.createTempSync(
    'fh-radio-studio-playlist-plan-',
  );
  FhRadioStudioProject.ensure(project.path);
  addTearDown(() {
    if (project.existsSync()) project.deleteSync(recursive: true);
  });
  return project.path;
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

String _bankSlotRadioInfoXml() {
  return '''
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
''';
}

String _singleTrackRadioInfoXml({
  required String title,
  required String artist,
}) {
  return '''
<RadioInfo Language="CN">
  <RadioStations>
    <RadioStation Number="1" Name="Horizon Pulse">
      <SampleList Type="Track">
        <Sample SoundName="HZ6_R1_SLOT_01" SampleLength="48000" SampleRate="48000" DisplayName="$title" Artist="$artist" />
      </SampleList>
      <PlayList Type="FreeRoam">
        <Entry Name="HZ6_R1_SLOT_01" />
      </PlayList>
      <PlayList Type="Event">
        <Entry Name="HZ6_R1_SLOT_01" />
      </PlayList>
    </RadioStation>
  </RadioStations>
</RadioInfo>
''';
}

PoolTrack _testTrack(String id, String title, String projectDir) {
  final file =
      File(p.join(FhRadioStudioProject.sourcesDir(projectDir), '$id.wav'))
        ..createSync(recursive: true)
        ..writeAsBytesSync([0, 1, 2, 3]);
  return PoolTrack(
    id: id,
    title: title,
    artist: 'Artist',
    source: file.path,
    durationSec: 1,
    bpm: 0,
    key: '',
    configured: false,
    confirmed: 0,
    added: 'now',
  );
}

class _EditableStudioController extends StudioController {
  _EditableStudioController(super.prefs) {
    state = state.copyWith(
      fileIntegrity: GameFileIntegritySummary.deferred(
        baselineManifestPath: 'baseline.json',
        pendingBaselineManifestPath: null,
        packageManifestPath: null,
        lastAppliedPackageManifestPath: null,
      ),
    );
  }
}

class _ScanningStudioController extends _EditableStudioController {
  _ScanningStudioController(super.prefs) {
    state = state.copyWith(busy: true, busyLabel: '完整校验当前环境');
  }
}
