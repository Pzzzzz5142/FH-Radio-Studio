import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/project_workspace.dart';
import '../core/track_timing_config.dart';
import 'studio_state.dart';

class TrackTimingController
    extends StateNotifier<Map<String, TrackTimingConfig>> {
  TrackTimingController(this.ref) : super(const {}) {
    final studio = ref.read(studioProvider);
    _projectDir = studio.projectDir;
    _load(studio);
    ref.listen<
      ({
        String projectDir,
        bool migrationRequired,
        bool migrationRunning,
        int migrationRevision,
      })
    >(
      studioProvider.select(
        (state) => (
          projectDir: state.projectDir,
          migrationRequired: state.projectPathMigrationRequired,
          migrationRunning: state.projectPathMigrationRunning,
          migrationRevision: state.projectPathMigrationRevision,
        ),
      ),
      (_, next) {
        _projectDir = next.projectDir;
        final studio = ref.read(studioProvider);
        _load(studio);
      },
    );
  }

  final Ref ref;
  late String _projectDir;

  void _load(StudioState studio) {
    if (_projectReadsBlocked(studio)) {
      state = const {};
      return;
    }
    state = TrackTimingStore.readAll(_projectDir);
  }

  void reload() => _load(ref.read(studioProvider));

  TrackTimingConfig? configForPath(String path) {
    return state[TrackTimingConfig.keyForPath(path)];
  }

  void save(TrackTimingConfig config) {
    TrackTimingStore.save(_projectDir, config);
    _load(ref.read(studioProvider));
  }

  void remove(String source) {
    TrackTimingStore.remove(_projectDir, source);
    _load(ref.read(studioProvider));
  }
}

bool _projectReadsBlocked(StudioState studio) {
  if (!studio.hasProject) return false;
  if (studio.projectPathMigrationActive) return true;
  return FhRadioStudioProject.needsPathMigration(studio.projectDir);
}

final trackTimingProvider =
    StateNotifierProvider<
      TrackTimingController,
      Map<String, TrackTimingConfig>
    >((ref) => TrackTimingController(ref));
