import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/track_timing_config.dart';
import 'studio_state.dart';

class TrackTimingController
    extends StateNotifier<Map<String, TrackTimingConfig>> {
  TrackTimingController(this.ref) : super(const {}) {
    _projectDir = ref.read(studioProvider).projectDir;
    _load();
    ref.listen<String>(studioProvider.select((state) => state.projectDir), (
      _,
      next,
    ) {
      _projectDir = next;
      _load();
    });
  }

  final Ref ref;
  late String _projectDir;

  void _load() {
    state = TrackTimingStore.readAll(_projectDir);
  }

  void reload() => _load();

  TrackTimingConfig? configForPath(String path) {
    return state[TrackTimingConfig.keyForPath(path)];
  }

  void save(TrackTimingConfig config) {
    TrackTimingStore.save(_projectDir, config);
    _load();
  }

  void remove(String source) {
    TrackTimingStore.remove(_projectDir, source);
    _load();
  }
}

final trackTimingProvider =
    StateNotifierProvider<
      TrackTimingController,
      Map<String, TrackTimingConfig>
    >((ref) => TrackTimingController(ref));
