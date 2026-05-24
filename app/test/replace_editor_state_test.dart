import 'dart:io';
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:fh_radio_studio/core/fh_radio_studio_cli.dart';
import 'package:fh_radio_studio/screens/replace_editor/replace_state.dart';
import 'package:fh_radio_studio/state/app_state.dart';
import 'package:fh_radio_studio/state/audio_analysis_state.dart';
import 'package:fh_radio_studio/state/custom_pool_tracks.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('creating a real-track editor does not start audio analysis', () async {
    final tempRoot = Directory.systemTemp.createTempSync(
      'replace_editor_state_test_',
    );
    addTearDown(() {
      if (tempRoot.existsSync()) {
        tempRoot.deleteSync(recursive: true);
      }
    });

    SharedPreferences.setMockInitialValues({
      'rm.studio.projectDir': tempRoot.path,
      'rm.studio.repoRoot': p.dirname(p.current),
    });
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        realPoolTracksProvider.overrideWithValue(const []),
      ],
    );
    addTearDown(container.dispose);

    var analysisUpdates = 0;
    container.listen(audioAnalysisProvider, (_, _) {
      analysisUpdates++;
    });

    final source = p.join(tempRoot.path, '01 - JANE DOE.flac');
    final state = container.read(
      replaceEditorProvider(realTrackIdForPath(source)),
    );

    expect(state.analyzing, isTrue);
    expect(container.read(audioAnalysisProvider).busy, isFalse);
    expect(analysisUpdates, 0);
  });

  test('disposing a real-track editor cancels active audio analysis', () async {
    final tempRoot = Directory.systemTemp.createTempSync(
      'replace_editor_cancel_test_',
    );
    addTearDown(() {
      if (tempRoot.existsSync()) {
        tempRoot.deleteSync(recursive: true);
      }
    });

    SharedPreferences.setMockInitialValues({
      'rm.studio.projectDir': tempRoot.path,
      'rm.studio.repoRoot': p.dirname(p.current),
    });
    final prefs = await SharedPreferences.getInstance();
    final completer = Completer<CliRunResult>();
    CliCancellationToken? token;
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        realPoolTracksProvider.overrideWithValue(const []),
        audioAnalysisCliRunnerProvider.overrideWithValue((
          repoRoot,
          args, {
          cancellationToken,
          onStdout,
          onStderr,
        }) {
          token = cancellationToken;
          return completer.future;
        }),
      ],
    );
    addTearDown(container.dispose);

    final source = p.join(tempRoot.path, '02 - ANALYZE ME.flac');
    final provider = replaceEditorProvider(realTrackIdForPath(source));
    final subscription = container.listen(provider, (_, _) {});
    final future = container.read(provider.notifier).analyze();
    await Future<void>.delayed(Duration.zero);

    expect(token, isNotNull);
    expect(container.read(audioAnalysisProvider).busy, isTrue);

    subscription.close();
    await Future<void>.delayed(Duration.zero);

    expect(token!.isCancelled, isTrue);
    completer.complete(
      const CliRunResult(
        exitCode: -1,
        stdout: '',
        stderr: 'Cancelled',
        commandLine: 'fake',
        cancelled: true,
      ),
    );
    await future;
  });
}
