import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/playlist_plan.dart';
import '../core/project_refs.dart';
import '../domain/radio_library.dart';
import 'studio_state.dart';

class PlaylistPlanController extends StateNotifier<PlaylistPlan> {
  PlaylistPlanController(this.ref) : super(const PlaylistPlan.empty()) {
    _projectDir = ref.read(studioProvider).projectDir;
    _resetDraft();
    ref.listen<String>(studioProvider.select((state) => state.projectDir), (
      _,
      next,
    ) {
      _projectDir = next;
      _resetDraft();
    });
  }

  final Ref ref;
  late String _projectDir;

  void _resetDraft() {
    state = const PlaylistPlan.empty();
    PlaylistPlanStore.delete(_projectDir);
  }

  void reload() => _resetDraft();

  // 草稿是纯内存权威（不再每次写盘）；build 时由 buildPackage 经 stdin 喂给 CLI。
  void replaceWith(PlaylistPlan plan) {
    if (_editingLocked) return;
    state = plan;
  }

  void assign({
    required String source,
    required String radioCode,
    required String playlistType,
    required int slot,
  }) {
    if (_editingLocked) return;
    state = _stateSeededFromPackage().assign(
      source: source,
      radioCode: radioCode,
      playlistType: playlistType,
      slot: slot,
      projectDir: _projectDir,
    );
  }

  void unassign(String source, {String? radioCode, String? playlistType}) {
    if (_editingLocked) return;
    state = _stateSeededFromPackage().unassign(
      source,
      radioCode: radioCode,
      playlistType: playlistType,
      projectDir: _projectDir,
    );
  }

  void removeDeletedSource(String source) {
    final base = state.hasDraft ? state : _stateSeededFromPackage();
    state = base.unassign(source, projectDir: _projectDir);
  }

  void removeDeletedSources(Iterable<String> sources) {
    final base = state.hasDraft ? state : _stateSeededFromPackage();
    state = base.unassignSources(sources, projectDir: _projectDir);
  }

  void restoreBuiltin({
    required String radioCode,
    required String playlistType,
  }) {
    if (_editingLocked) return;
    state = _stateSeededFromPackage().restoreBuiltin(
      radioCode: radioCode,
      playlistType: playlistType,
    );
  }

  PlaylistPlan _stateSeededFromPackage() {
    if (state.hasDraft) return state;
    final cli = ref.read(studioProvider);
    return playlistPlanFromPackageSummaries(
      projectDir: cli.projectDir,
      pending: cli.pendingPackageSummary,
      last: cli.lastPackageSummary,
    );
  }

  bool get _editingLocked => ref.read(studioProvider).projectEditingLocked;
}

final playlistPlanProvider =
    StateNotifierProvider<PlaylistPlanController, PlaylistPlan>(
      (ref) => PlaylistPlanController(ref),
    );

final effectivePlaylistPlanProvider = Provider<PlaylistPlan>((ref) {
  final plan = ref.watch(playlistPlanProvider);
  if (plan.hasDraft) return plan;
  final cli = ref.watch(
    studioProvider.select(
      (state) => (
        projectDir: state.projectDir,
        pending: state.pendingPackageSummary,
        last: state.lastPackageSummary,
      ),
    ),
  );
  return playlistPlanFromPackageSummaries(
    projectDir: cli.projectDir,
    pending: cli.pending,
    last: cli.last,
  );
});

PlaylistPlan playlistPlanFromPackageSummaries({
  required String projectDir,
  required PackageArtifactSummary? pending,
  required PackageArtifactSummary? last,
}) {
  final package = pending ?? last;
  if (package == null || package.assignments.isEmpty) {
    return const PlaylistPlan.empty();
  }
  if (!isUiSupportedRadio(name: package.station)) {
    return const PlaylistPlan.empty();
  }
  final assignments = <String, PlaylistAssignment>{};
  for (final item in package.assignments) {
    if (item.source.trim().isEmpty || item.slot <= 0) continue;
    final radioCode = canonicalRadioCode(item.radioLabel);
    final playlistTypes = item.normalizedPlaylistTypes;
    for (final playlistType in playlistTypes) {
      final assignment = PlaylistAssignment(
        trackKey: _playlistTrackKey(projectDir, item.source),
        source: item.source,
        radioCode: radioCode,
        playlistType: playlistType,
        slot: item.slot,
      );
      if (!assignment.isValid || !assignment.isAssigned) continue;
      assignments[assignment.assignmentKey] = assignment;
    }
  }
  return PlaylistPlan(assignments: assignments);
}

String _playlistTrackKey(String projectDir, String source) {
  try {
    return trackKeyForProjectPath(projectDir, source) ??
        PlaylistAssignment.keyForPath(source);
  } on Object {
    return PlaylistAssignment.keyForPath(source);
  }
}
