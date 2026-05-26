import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';

@visibleForTesting
const systemAudioOutputRefreshDebounce = Duration(milliseconds: 250);

typedef AudioOutputRefresh = Future<void> Function();

class SystemAudioOutputMonitor {
  SystemAudioOutputMonitor({
    MethodChannel channel = const MethodChannel('fh_radio_studio/audio_output'),
  }) : _channel = channel;

  final MethodChannel _channel;
  final _changes = StreamController<void>.broadcast();
  var _initialized = false;

  Stream<void> get changes {
    _ensureInitialized();
    return _changes.stream;
  }

  void _ensureInitialized() {
    if (_initialized) return;
    _initialized = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'defaultOutputChanged') {
        _changes.add(null);
      }
    });
  }

  @visibleForTesting
  void notifyDefaultOutputChanged() {
    _changes.add(null);
  }
}

final systemAudioOutputMonitor = SystemAudioOutputMonitor();

SystemAudioOutputFollower followSystemAudioOutput(Player player) {
  if (!Platform.isWindows) return SystemAudioOutputFollower.disabled();
  return SystemAudioOutputFollower(
    changes: systemAudioOutputMonitor.changes,
    refresh: () => player.setAudioDevice(AudioDevice.auto()),
  );
}

class SystemAudioOutputFollower {
  SystemAudioOutputFollower({
    required Stream<void> changes,
    required AudioOutputRefresh refresh,
    Duration debounce = systemAudioOutputRefreshDebounce,
  }) : _refresh = refresh,
       _debounce = debounce {
    _subscription = changes.listen((_) => _scheduleRefresh());
  }

  SystemAudioOutputFollower.disabled()
    : _refresh = null,
      _debounce = Duration.zero;

  final AudioOutputRefresh? _refresh;
  final Duration _debounce;
  StreamSubscription<void>? _subscription;
  Timer? _timer;
  Future<void> _pending = Future.value();
  var _disposed = false;

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    final subscription = _subscription;
    if (subscription != null) {
      unawaited(subscription.cancel());
      _subscription = null;
    }
  }

  void _scheduleRefresh() {
    final refresh = _refresh;
    if (_disposed || refresh == null) return;
    _timer?.cancel();
    _timer = Timer(_debounce, () {
      _timer = null;
      _pending = _pending.then((_) async {
        if (_disposed) return;
        try {
          await refresh();
        } on Object {
          // The player may have been disposed while a queued refresh is in flight.
        }
      });
    });
  }
}
