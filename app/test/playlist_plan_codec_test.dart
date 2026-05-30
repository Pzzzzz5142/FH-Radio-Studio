import 'package:flutter_test/flutter_test.dart';
import 'package:fh_radio_studio/core/playlist_plan.dart';

void main() {
  group('PlaylistPlan stdin/stdout codec', () {
    test('encodeForCli round-trips through decodeJson', () {
      final plan = const PlaylistPlan.empty()
          .assign(
            source: r'C:\proj\sources\a.wav',
            radioCode: 'XS',
            playlistType: 'FreeRoam',
            slot: 1,
          )
          .assign(
            source: r'C:\proj\sources\b.wav',
            radioCode: 'R5',
            playlistType: 'Event',
            slot: 1,
          )
          .restoreBuiltin(radioCode: 'R6', playlistType: 'FreeRoam');

      final decoded = PlaylistPlanCodec.decodeJson(plan.encodeForCli());

      expect(
        decoded.assignments.values.map((a) => a.assignmentKey).toSet(),
        plan.assignments.values.map((a) => a.assignmentKey).toSet(),
      );
      expect(decoded.builtinTargets, plan.builtinTargets);
      expect(decoded.hasBuiltinOverride('R6', 'FreeRoam'), isTrue);
    });

    test('decodeJson tolerates empty and malformed input', () {
      expect(PlaylistPlanCodec.decodeJson('').hasDraft, isFalse);
      expect(PlaylistPlanCodec.decodeJson('   ').hasDraft, isFalse);
      expect(PlaylistPlanCodec.decodeJson('not json {').hasDraft, isFalse);
      expect(
        PlaylistPlanCodec.decodeJson('{"assignments": "nope"}').hasDraft,
        isFalse,
      );
    });

    test('encodeForCli emits a single compact line for a pipe write', () {
      final encoded = const PlaylistPlan.empty()
          .assign(
            source: r'C:\proj\sources\a.wav',
            radioCode: 'XS',
            playlistType: 'FreeRoam',
            slot: 1,
          )
          .encodeForCli();

      expect(encoded.contains('\n'), isFalse);
      expect(encoded, contains('"schema_version":2'));
    });
  });
}
