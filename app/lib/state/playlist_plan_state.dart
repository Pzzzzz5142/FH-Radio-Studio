import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/playlist_plan.dart';
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

  Set<String>? get _validCodes {
    final radios = ref.read(studioProvider).radioOptions;
    if (radios.isEmpty) return null;
    return {for (final r in radios) r.code};
  }

  Map<String, String> get _radioCodeAliases => {
    for (final r in ref.read(studioProvider).radioOptions)
      ?legacyRadioCodeForStation(number: r.number, name: r.name): r.code,
  };

  void _resetDraft() {
    state = const PlaylistPlan.empty();
    PlaylistPlanStore.delete(_projectDir);
  }

  void reload() => _resetDraft();

  void replaceWith(PlaylistPlan plan) {
    if (_editingLocked) return;
    state = plan;
    PlaylistPlanStore.write(
      _projectDir,
      state,
      validCodes: _validCodes,
      radioCodeAliases: _radioCodeAliases,
    );
  }

  void assign({
    required String source,
    required String radioCode,
    required String playlistType,
    required int slot,
  }) {
    if (_editingLocked) return;
    final codes = _validCodes;
    state = _stateSeededFromPackage().assign(
      source: source,
      radioCode: radioCode,
      playlistType: playlistType,
      slot: slot,
    );
    PlaylistPlanStore.write(
      _projectDir,
      state,
      validCodes: codes,
      radioCodeAliases: _radioCodeAliases,
    );
  }

  void unassign(String source, {String? radioCode, String? playlistType}) {
    if (_editingLocked) return;
    final codes = _validCodes;
    state = _stateSeededFromPackage().unassign(
      source,
      radioCode: radioCode,
      playlistType: playlistType,
    );
    PlaylistPlanStore.write(
      _projectDir,
      state,
      validCodes: codes,
      radioCodeAliases: _radioCodeAliases,
    );
  }

  void removeDeletedSource(String source) {
    final codes = _validCodes;
    final aliases = _radioCodeAliases;
    final stored = PlaylistPlanStore.read(
      _projectDir,
      validCodes: codes,
      radioCodeAliases: aliases,
    );
    final base = state.hasDraft
        ? state
        : (stored.hasDraft ? stored : _stateSeededFromPackage());
    state = base.unassign(source);
    PlaylistPlanStore.write(
      _projectDir,
      state,
      validCodes: codes,
      radioCodeAliases: aliases,
    );
  }

  void removeDeletedSources(Iterable<String> sources) {
    final codes = _validCodes;
    final aliases = _radioCodeAliases;
    final stored = PlaylistPlanStore.read(
      _projectDir,
      validCodes: codes,
      radioCodeAliases: aliases,
    );
    final base = state.hasDraft
        ? state
        : (stored.hasDraft ? stored : _stateSeededFromPackage());
    state = base.unassignSources(sources);
    PlaylistPlanStore.write(
      _projectDir,
      state,
      validCodes: codes,
      radioCodeAliases: aliases,
    );
  }

  void restoreBuiltin({
    required String radioCode,
    required String playlistType,
  }) {
    if (_editingLocked) return;
    final codes = _validCodes;
    state = _stateSeededFromPackage().restoreBuiltin(
      radioCode: radioCode,
      playlistType: playlistType,
    );
    PlaylistPlanStore.write(
      _projectDir,
      state,
      validCodes: codes,
      radioCodeAliases: _radioCodeAliases,
    );
  }

  PlaylistPlan _stateSeededFromPackage() {
    if (state.hasDraft) return state;
    final cli = ref.read(studioProvider);
    return playlistPlanFromPackageSummaries(
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
        pending: state.pendingPackageSummary,
        last: state.lastPackageSummary,
      ),
    ),
  );
  return playlistPlanFromPackageSummaries(pending: cli.pending, last: cli.last);
});

PlaylistPlan playlistPlanFromPackageSummaries({
  required PackageArtifactSummary? pending,
  required PackageArtifactSummary? last,
}) {
  final package = pending ?? last;
  if (package == null || package.assignments.isEmpty) {
    return const PlaylistPlan.empty();
  }
  if (package.radio != null && !isUiSupportedRadio(name: package.station)) {
    return const PlaylistPlan.empty();
  }
  final assignments = <String, PlaylistAssignment>{};
  for (final item in package.assignments) {
    if (item.source.trim().isEmpty || item.slot <= 0) continue;
    final playlistTypes = item.normalizedPlaylistTypes;
    for (final playlistType in playlistTypes) {
      final assignment = PlaylistAssignment(
        trackKey: PlaylistAssignment.keyForPath(item.source),
        source: item.source,
        radioCode: canonicalRadioCode(
          item.radioLabel,
          number: package.radio,
          name: package.station,
        ),
        playlistType: playlistType,
        slot: item.slot,
      );
      if (!assignment.isValid || !assignment.isAssigned) continue;
      assignments[assignment.assignmentKey] = assignment;
    }
  }
  return PlaylistPlan(assignments: assignments);
}
