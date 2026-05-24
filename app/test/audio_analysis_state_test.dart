import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fh_radio_studio/core/project_workspace.dart';
import 'package:fh_radio_studio/core/fh_radio_studio_cli.dart';
import 'package:fh_radio_studio/state/app_state.dart';
import 'package:fh_radio_studio/state/audio_analysis_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('AudioAnalysisResult parses schema v2 candidates and grid', () {
    final result = AudioAnalysisResult.fromJson({
      'schema_version': 2,
      'source': 'C:/Music/song.wav',
      'title': 'song',
      'duration_sec': 120.0,
      'sample_rate': 44100,
      'channels': 2,
      'samples': 5292000,
      'peak_dbfs': -1.2,
      'rms_dbfs': -12.3,
      'bpm': 128.0,
      'decoder': 'soundfile',
      'grid': {
        'beats': [0.0, 0.46875],
        'downbeats': [0.0],
      },
      'segments': [
        {
          'start': 8.0,
          'end': 32.0,
          'label': 'drop_2 / final hook',
          'confidence': 0.8,
          'provider': 'songformer',
        },
      ],
      'candidates': {
        'td': [
          {'t': 32.0, 'score': 0.9, 'why': 'drop'},
        ],
        'pd': [
          {'t': 88.0, 'score': 0.8, 'why': 'final chorus'},
        ],
        'tl': [
          {
            'start': 32.0,
            'end': 64.0,
            'score': 0.7,
            'bars': 16,
            'why': 'main loop',
          },
        ],
        'pl': [
          {
            'start': 88.0,
            'end': 112.0,
            'score': 0.6,
            'bars': 8,
            'why': 'post loop',
          },
        ],
      },
      'warnings': ['deep provider missing'],
    });

    expect(result.markers['TrackDrop'], 32.0);
    expect(result.markers['PostRaceLoopEnd'], 112.0);
    expect(result.beats, [0.0, 0.46875]);
    expect(result.pointCandidates['td']!.single.why, 'drop');
    expect(result.loopCandidates['tl']!.single.bars, 16);
    expect(result.segments.single.label, 'drop_2 / final hook');
    expect(result.warnings, ['deep provider missing']);
  });

  test('AudioAnalysisController cancels an in-flight CLI analysis', () async {
    final tempRoot = Directory.systemTemp.createTempSync(
      'audio_analysis_cancel_test_',
    );
    addTearDown(() {
      if (tempRoot.existsSync()) {
        tempRoot.deleteSync(recursive: true);
      }
    });

    SharedPreferences.setMockInitialValues({
      'rm.studio.projectDir': tempRoot.path,
      'rm.studio.repoRoot': tempRoot.path,
    });
    final prefs = await SharedPreferences.getInstance();
    final completer = Completer<CliRunResult>();
    CliCancellationToken? token;
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
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

    final controller = container.read(audioAnalysisProvider.notifier);
    final future = controller.analyze('song.wav');
    await Future<void>.delayed(Duration.zero);

    expect(container.read(audioAnalysisProvider).busy, isTrue);
    expect(token, isNotNull);

    await controller.cancel();
    expect(token!.isCancelled, isTrue);
    expect(container.read(audioAnalysisProvider).busy, isFalse);

    completer.complete(
      const CliRunResult(
        exitCode: -1,
        stdout: '',
        stderr: 'Cancelled',
        commandLine: 'fake',
        cancelled: true,
      ),
    );
    expect(await future, isNull);
  });

  test('AudioAnalysisController tracks structured CLI progress', () async {
    final tempRoot = Directory.systemTemp.createTempSync(
      'audio_analysis_progress_test_',
    );
    addTearDown(() {
      if (tempRoot.existsSync()) {
        tempRoot.deleteSync(recursive: true);
      }
    });

    SharedPreferences.setMockInitialValues({
      'rm.studio.projectDir': tempRoot.path,
      'rm.studio.repoRoot': tempRoot.path,
    });
    final prefs = await SharedPreferences.getInstance();
    final completer = Completer<CliRunResult>();
    CliLineHandler? stderrHandler;
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        audioAnalysisCliRunnerProvider.overrideWithValue((
          repoRoot,
          args, {
          cancellationToken,
          onStdout,
          onStderr,
        }) {
          expect(args, contains('--progress-jsonl'));
          stderrHandler = onStderr;
          onStderr?.call(
            'FH_RADIO_STUDIO_PROGRESS ${jsonEncode({
              'event': 'plan',
              'steps': [
                {'id': 'setup', 'label': '启动', 'detail': '准备', 'weight': 1},
                {'id': 'baseline_mir.analyze', 'label': '波形', 'detail': '分析', 'weight': 2},
              ],
            })}',
          );
          onStderr?.call(
            'FH_RADIO_STUDIO_PROGRESS ${jsonEncode({'event': 'step_started', 'step_id': 'setup'})}',
          );
          onStderr?.call(
            'FH_RADIO_STUDIO_PROGRESS ${jsonEncode({'event': 'step_completed', 'step_id': 'setup', 'status': 'done', 'runtime_ms': 12})}',
          );
          onStderr?.call(
            'FH_RADIO_STUDIO_PROGRESS ${jsonEncode({'event': 'step_started', 'step_id': 'baseline_mir.analyze'})}',
          );
          return completer.future;
        }),
      ],
    );
    addTearDown(container.dispose);

    final future = container
        .read(audioAnalysisProvider.notifier)
        .analyze('song.wav');
    await Future<void>.delayed(Duration.zero);

    final inFlight = container.read(audioAnalysisProvider);
    expect(inFlight.progressSteps.map((step) => step.id), [
      'setup',
      'baseline_mir.analyze',
    ]);
    expect(inFlight.progressSteps[0].status, 'done');
    expect(inFlight.progressSteps[1].status, 'running');
    expect(inFlight.progressPercent, 33);

    stderrHandler?.call(
      'FH_RADIO_STUDIO_PROGRESS ${jsonEncode({'event': 'step_completed', 'step_id': 'baseline_mir.analyze', 'status': 'done', 'runtime_ms': 34})}',
    );
    completer.complete(
      CliRunResult(
        exitCode: 0,
        stdout: jsonEncode({
          'schema_version': 2,
          'source': 'song.wav',
          'title': 'song',
          'duration_sec': 8.0,
          'sample_rate': 48000,
          'channels': 2,
          'samples': 384000,
          'peak_dbfs': -1.0,
          'rms_dbfs': -12.0,
          'bpm': 120.0,
          'decoder': 'test',
          'grid': {
            'beats': [0.0, 0.5],
            'downbeats': [0.0],
          },
          'candidates': {
            'td': [
              {'t': 1.0, 'score': 0.8, 'why': 'drop'},
            ],
            'pd': [
              {'t': 4.0, 'score': 0.7, 'why': 'post'},
            ],
            'tl': [
              {
                'start': 1.0,
                'end': 3.0,
                'score': 0.6,
                'bars': 4,
                'why': 'loop',
              },
            ],
            'pl': [
              {
                'start': 4.0,
                'end': 7.0,
                'score': 0.6,
                'bars': 4,
                'why': 'post loop',
              },
            ],
          },
        }),
        stderr: '',
        commandLine: 'fake',
      ),
    );

    expect(await future, isNotNull);
    expect(container.read(audioAnalysisProvider).progressPercent, 100);
  });

  test(
    'AudioAnalysisController uses the configured AI pipeline profile',
    () async {
      final tempRoot = Directory.systemTemp.createTempSync(
        'audio_analysis_profile_test_',
      );
      addTearDown(() {
        if (tempRoot.existsSync()) {
          tempRoot.deleteSync(recursive: true);
        }
      });

      FhRadioStudioProject.ensure(tempRoot.path);
      FhRadioStudioProject.writeSettings(
        tempRoot.path,
        aiProfile: 'local-deep',
      );
      SharedPreferences.setMockInitialValues({
        'rm.studio.projectDir': tempRoot.path,
        'rm.studio.repoRoot': tempRoot.path,
      });
      final prefs = await SharedPreferences.getInstance();
      List<String>? capturedArgs;
      final container = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          audioAnalysisCliRunnerProvider.overrideWithValue((
            repoRoot,
            args, {
            cancellationToken,
            onStdout,
            onStderr,
          }) async {
            capturedArgs = args;
            return CliRunResult(
              exitCode: 0,
              stdout: jsonEncode({
                'schema_version': 2,
                'source': 'song.wav',
                'title': 'song',
                'duration_sec': 8.0,
                'sample_rate': 48000,
                'channels': 2,
                'samples': 384000,
                'peak_dbfs': -1.0,
                'rms_dbfs': -12.0,
                'bpm': 120.0,
                'decoder': 'test',
                'grid': {
                  'beats': [0.0, 0.5],
                },
                'candidates': const {},
              }),
              stderr: '',
              commandLine: 'fake',
            );
          }),
        ],
      );
      addTearDown(container.dispose);

      expect(
        await container
            .read(audioAnalysisProvider.notifier)
            .analyze('song.wav'),
        isNotNull,
      );
      final profileIndex = capturedArgs!.indexOf('--profile');
      expect(profileIndex, greaterThanOrEqualTo(0));
      expect(capturedArgs![profileIndex + 1], 'local-deep');
    },
  );
}
