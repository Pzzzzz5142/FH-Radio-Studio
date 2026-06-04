import 'dart:convert';
import 'dart:io';

import 'package:fh_radio_studio/core/path_keys.dart';
import 'package:fh_radio_studio/core/project_refs.dart';
import 'package:fh_radio_studio/core/project_workspace.dart';
import 'package:fh_radio_studio/core/track_metadata_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('project refs round-trip project-owned paths', () {
    final projectDir = Directory.systemTemp.createTempSync('project_refs_');
    addTearDown(() {
      if (projectDir.existsSync()) projectDir.deleteSync(recursive: true);
    });
    final track = File(
      p.join(projectDir.path, 'sources', 'Folder A', '100% ready #1.wav'),
    )..createSync(recursive: true);

    final sourceRef = projectRefForPath(projectDir.path, track.path);

    expect(
      sourceRef,
      'fh-project:/sources/Folder%20A/100%25%20ready%20%231.wav',
    );
    expect(resolveProjectRef(projectDir.path, sourceRef!), track.absolute.path);
  });

  test('project refs reject escapes and non-project roots', () {
    final invalid = [
      'fh-project:/sources/../song.wav',
      'fh-project://sources/song.wav',
      'fh-project:/tmp/song.wav',
      'fh-project:/sources/C:/song.wav',
      'fh-project:/sources/foo%2Fbar.wav',
      'fh-project:/sources/bad%zz.wav',
      'fh-project:/sources/bad%00name.wav',
    ];

    for (final sourceRef in invalid) {
      expect(
        () => normalizeProjectRef(sourceRef),
        throwsA(isA<ProjectRefException>()),
      );
    }
  });

  test('track key is derived from canonical source ref', () {
    final left = trackKeyForSourceRef('fh-project:/sources/./Song.wav');
    final right = trackKeyForSourceRef('fh-project:/sources/Song.wav');

    expect(left, right);
    expect(left, startsWith('trkref_'));
    expect(left.length, 'trkref_'.length + 32);
  });

  test('TrackMetadataCache reads source refs and resolves project artwork', () {
    final projectDir = Directory.systemTemp.createTempSync('metadata_refs_');
    addTearDown(() {
      if (projectDir.existsSync()) projectDir.deleteSync(recursive: true);
    });
    final cachePath = File(TrackMetadataCache.configPath(projectDir.path));
    cachePath.parent.createSync(recursive: true);
    final sourceRef = 'fh-project:/sources/Artist%20-%20Song.wav';
    final coverRef = 'fh-project:/.fh-radio-studio/artwork/cover.png';
    final trackKey = trackKeyForSourceRef(sourceRef);
    cachePath.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        'schema_version': 2,
        'tracks': [
          {
            'track_key': trackKey,
            'source_ref': sourceRef,
            'artist': 'Artist',
            'title': 'Song',
            'from_tags': true,
            'cover_art_path': coverRef,
          },
        ],
      }),
      encoding: utf8,
    );

    final metadata = TrackMetadataCache.read(projectDir.path);

    // The in-memory map is keyed by the resolved file's canonical path so
    // callers can join it to live files; the durable track_key identity is
    // exposed through the asset index instead.
    final resolvedSource = resolveProjectRef(projectDir.path, sourceRef);
    final runtimeKey = canonicalPathKey(resolvedSource);
    expect(metadata.keys, [runtimeKey]);
    expect(metadata[runtimeKey]!.artist, 'Artist');
    expect(
      metadata[runtimeKey]!.coverArtPath,
      p.join(projectDir.path, '.fh-radio-studio', 'artwork', 'cover.png'),
    );

    // The asset index maps the durable track_key back to its source_ref.
    expect(TrackMetadataCache.assetIndex(projectDir.path), {
      trackKey: sourceRef,
    });
    expect(
      TrackMetadataCache.resolveTrackKey(projectDir.path, trackKey),
      resolvedSource,
    );
  });

  test('project migration detection catches path_schema 2 legacy metadata', () {
    final projectDir = Directory.systemTemp.createTempSync('metadata_legacy_');
    addTearDown(() {
      if (projectDir.existsSync()) projectDir.deleteSync(recursive: true);
    });
    FhRadioStudioProject.ensure(projectDir.path);
    final track = File(p.join(projectDir.path, 'siren', 'MSR-306877.wav'))
      ..createSync(recursive: true);
    final cachePath = File(TrackMetadataCache.configPath(projectDir.path));
    cachePath.parent.createSync(recursive: true);
    cachePath.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        'schema_version': 1,
        'tracks': [
          {
            'source': track.path,
            'path_key': 'legacy',
            'artist': 'Siren',
            'title': 'MSR',
          },
        ],
      }),
      encoding: utf8,
    );

    expect(FhRadioStudioProject.needsPathMigration(projectDir.path), isTrue);
  });

  test('writeSettings does not stamp legacy projects as migrated', () {
    final projectDir = Directory.systemTemp.createTempSync('settings_legacy_');
    addTearDown(() {
      if (projectDir.existsSync()) projectDir.deleteSync(recursive: true);
    });
    final manifest = File(FhRadioStudioProject.manifestPath(projectDir.path));
    manifest.parent.createSync(recursive: true);
    manifest.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        'schema': 1,
        'app': 'FH Radio Studio',
        'settings': {'radio': 4},
      }),
      encoding: utf8,
    );

    FhRadioStudioProject.writeSettings(projectDir.path, radio: 5);
    final decoded =
        jsonDecode(manifest.readAsStringSync(encoding: utf8)) as Map;

    expect(decoded['schema'], 2);
    expect(decoded.containsKey('path_schema'), isFalse);
    expect(FhRadioStudioProject.needsPathMigration(projectDir.path), isTrue);
  });
}
