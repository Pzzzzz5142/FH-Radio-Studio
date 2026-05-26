import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fh_radio_studio/core/system_audio_output.dart';

void main() {
  test('debounces default output change refreshes', () async {
    final changes = StreamController<void>();
    var refreshes = 0;
    final follower = SystemAudioOutputFollower(
      changes: changes.stream,
      debounce: const Duration(milliseconds: 10),
      refresh: () async {
        refreshes++;
      },
    );

    changes
      ..add(null)
      ..add(null)
      ..add(null);
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(refreshes, 1);
    follower.dispose();
    await changes.close();
  });

  test('ignores refresh errors and keeps following later changes', () async {
    final changes = StreamController<void>();
    var attempts = 0;
    final follower = SystemAudioOutputFollower(
      changes: changes.stream,
      debounce: Duration.zero,
      refresh: () async {
        attempts++;
        if (attempts == 1) {
          throw StateError('disposed player');
        }
      },
    );

    changes.add(null);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    changes.add(null);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(attempts, 2);
    follower.dispose();
    await changes.close();
  });
}
