import 'dart:convert';
import 'dart:io';

import 'package:fh_radio_studio/core/project_refs.dart';
import 'package:fh_radio_studio/core/track_timing_config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('TrackTimingStore writes only timing-owned fields', () {
    final projectDir = Directory.systemTemp.createTempSync(
      'track_timing_slim_',
    );
    addTearDown(() {
      if (projectDir.existsSync()) projectDir.deleteSync(recursive: true);
    });
    final source = File(p.join(projectDir.path, 'sources', 'Artist - Song.wav'))
      ..createSync(recursive: true);

    TrackTimingStore.save(
      projectDir.path,
      TrackTimingConfig(
        source: source.path,
        bpm: 128.5,
        markersSec: const {
          'TrackDrop': 12.0,
          'PostDrop': 42.0,
          'TrackLoopStart': 16.0,
          'TrackLoopEnd': 32.0,
          'PostRaceLoopStart': 44.0,
          'PostRaceLoopEnd': 58.0,
        },
        confirmed: const {'td': true, 'pd': true, 'tl': true, 'pl': true},
        updatedAt: DateTime.utc(2026, 5, 24, 12),
      ),
    );

    final payload =
        jsonDecode(
              File(
                TrackTimingStore.configPath(projectDir.path),
              ).readAsStringSync(encoding: utf8),
            )
            as Map<String, dynamic>;
    final track = (payload['tracks'] as List).single as Map<String, dynamic>;

    expect(payload['schema_version'], 2);
    expect(
      track.keys,
      unorderedEquals([
        'track_key',
        'bpm',
        'markers_sec',
        'confirmed',
        'updated_at',
      ]),
    );
    // track_key is the authoritative identity, derived from the project
    // source_ref; source stays only in memory.
    expect(track['track_key'], isA<String>());
    expect((track['track_key'] as String).startsWith('trkref_'), isTrue);
    expect(track['bpm'], 128.5);
  });

  test('TrackTimingStore rejects project-internal legacy source', () {
    final projectDir = Directory.systemTemp.createTempSync(
      'track_timing_legacy_',
    );
    addTearDown(() {
      if (projectDir.existsSync()) projectDir.deleteSync(recursive: true);
    });
    final source = File(p.join(projectDir.path, 'sources', 'Artist - Song.wav'))
      ..createSync(recursive: true);
    final timingFile = File(TrackTimingStore.configPath(projectDir.path));
    timingFile.parent.createSync(recursive: true);
    timingFile.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        'schema_version': 1,
        'tracks': [
          {
            'source': source.path,
            'title': 'Legacy Title',
            'artist': 'Legacy Artist',
            'duration_sec': 60.0,
            'sample_rate': 44100,
            'bpm': 120.0,
            'markers_sec': {
              'TrackDrop': 12.0,
              'PostDrop': 42.0,
              'TrackLoopStart': 16.0,
              'TrackLoopEnd': 32.0,
              'PostRaceLoopStart': 44.0,
              'PostRaceLoopEnd': 58.0,
            },
            'confirmed': {'td': true, 'pd': true, 'tl': true, 'pl': true},
            'updated_at': '2026-05-24T00:00:00Z',
            'peak_dbfs': -1.0,
            'rms_dbfs': -12.0,
            'ai_note': 'legacy analysis note',
          },
        ],
      }),
      encoding: utf8,
    );

    expect(
      () => TrackTimingStore.readAll(projectDir.path),
      throwsA(isA<ProjectRefException>()),
    );
  });
}
