import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/playlist_plan.dart';
import '../../domain/radio_library.dart';
import '../../state/studio_state.dart';
import '../../state/custom_pool_tracks.dart';
import '../../state/playlist_catalog_state.dart';
import '../../state/playlist_plan_state.dart';

enum PlaylistMode { freeroam, event }

@immutable
class PlaylistState {
  const PlaylistState({
    required this.pool,
    required this.mode,
    required this.search,
    required this.splitPlaylistTypes,
  });

  final List<PoolTrack> pool;
  final PlaylistMode mode;
  final String search;
  final bool splitPlaylistTypes;

  List<PoolTrack> tracksOfRadio(
    String radioCode,
    String playlistType,
    PlaylistPlan plan,
  ) {
    final bySource = {
      for (final track in pool)
        PlaylistAssignment.keyForPath(track.source): track,
    };
    final out = <PoolTrack>[];
    for (final assignment in plan.assignmentsForRadio(
      radioCode,
      playlistType,
    )) {
      final track = bySource[assignment.trackKey];
      if (track == null) continue;
      out.add(
        track.copyWith(assignedTo: assignment.radioCode, slot: assignment.slot),
      );
    }
    return out;
  }

  List<PoolTrack> poolForDisplay(PlaylistPlan plan) {
    final indexed = <({int index, PoolTrack track})>[
      for (var index = 0; index < pool.length; index += 1)
        (index: index, track: pool[index]),
    ];
    indexed.sort((a, b) {
      final aAssigned = plan.assignmentsForPath(a.track.source).isNotEmpty;
      final bAssigned = plan.assignmentsForPath(b.track.source).isNotEmpty;
      if (aAssigned != bAssigned) return aAssigned ? 1 : -1;
      final byCompleteness = _configurationCompleteness(
        b.track,
      ).compareTo(_configurationCompleteness(a.track));
      if (byCompleteness != 0) return byCompleteness;
      if (a.track.configured != b.track.configured) {
        return a.track.configured ? -1 : 1;
      }
      if (a.track.isSiren != b.track.isSiren) {
        return a.track.isSiren ? -1 : 1;
      }
      return a.index.compareTo(b.index);
    });
    return [for (final item in indexed) item.track];
  }

  PlaylistState copyWith({
    List<PoolTrack>? pool,
    PlaylistMode? mode,
    String? search,
    bool? splitPlaylistTypes,
  }) {
    return PlaylistState(
      pool: pool ?? this.pool,
      mode: mode ?? this.mode,
      search: search ?? this.search,
      splitPlaylistTypes: splitPlaylistTypes ?? this.splitPlaylistTypes,
    );
  }
}

class PlaylistNotifier extends StateNotifier<PlaylistState> {
  PlaylistNotifier(this.ref, List<PoolTrack> pool)
    : super(
        PlaylistState(
          pool: List<PoolTrack>.from(pool),
          mode: PlaylistMode.freeroam,
          search: '',
          splitPlaylistTypes: false,
        ),
      );

  final Ref ref;

  void setMode(PlaylistMode m) => state = state.copyWith(mode: m);
  void setSearch(String s) => state = state.copyWith(search: s);
  void setSplitPlaylistTypes(bool value) {
    if (_editingLocked) return;
    state = state.copyWith(splitPlaylistTypes: value);
  }

  void setPool(List<PoolTrack> pool) {
    state = state.copyWith(pool: List<PoolTrack>.from(pool));
  }

  /// 把曲目分配到电台。slot 自动 = 该电台当前已分配数 + 1。
  bool assignToRadio(
    String trackId,
    String radioCode,
    String playlistType, {
    int? maxSlots,
    String? originRadioCode,
    String? originPlaylistType,
  }) {
    if (_editingLocked) return false;
    final track = _trackById(trackId);
    if (track == null) return false;
    final targetRadio = radioCode.trim().toUpperCase();
    final targetType = PlaylistAssignment.normalizePlaylistType(playlistType);
    var plan = _ensureEditablePlanSeeded();
    if (!state.splitPlaylistTypes) {
      _syncPlanFrom(targetType);
      plan = ref.read(effectivePlaylistPlanProvider);
    }
    final existing =
        plan.assignmentFor(
          source: track.source,
          radioCode: targetRadio,
          playlistType: targetType,
        ) ??
        (!state.splitPlaylistTypes
            ? plan.assignmentFor(
                source: track.source,
                radioCode: targetRadio,
                playlistType: _otherPlaylistType(targetType),
              )
            : null);
    if (existing == null &&
        maxSlots != null &&
        plan.assignmentsForRadio(targetRadio, targetType).length >= maxSlots) {
      return false;
    }
    final nextSlot =
        existing?.slot ??
        plan.assignmentsForRadio(targetRadio, targetType).length + 1;
    var nextPlan = plan.assign(
      source: track.source,
      radioCode: targetRadio,
      playlistType: targetType,
      slot: nextSlot,
    );
    if (!state.splitPlaylistTypes) {
      nextPlan = nextPlan.assign(
        source: track.source,
        radioCode: targetRadio,
        playlistType: _otherPlaylistType(targetType),
        slot: nextSlot,
      );
    }
    nextPlan = _removeMoveOrigin(
      plan: nextPlan,
      source: track.source,
      targetRadioCode: targetRadio,
      targetPlaylistType: targetType,
      originRadioCode: originRadioCode,
      originPlaylistType: originPlaylistType,
    );
    ref.read(playlistPlanProvider.notifier).replaceWith(nextPlan);
    state = state.copyWith(
      pool: [
        for (final t in state.pool)
          if (t.id == trackId)
            t.copyWith(assignedTo: targetRadio, slot: nextSlot)
          else
            t,
      ],
    );
    return true;
  }

  PlaylistPlan _removeMoveOrigin({
    required PlaylistPlan plan,
    required String source,
    required String targetRadioCode,
    required String targetPlaylistType,
    required String? originRadioCode,
    required String? originPlaylistType,
  }) {
    final originRadio = originRadioCode?.trim().toUpperCase();
    if (originRadio == null || originRadio.isEmpty) return plan;
    final originType = originPlaylistType == null
        ? null
        : PlaylistAssignment.normalizePlaylistType(originPlaylistType);
    if (state.splitPlaylistTypes) {
      if (originType == null) return plan;
      if (originRadio == targetRadioCode && originType == targetPlaylistType) {
        return plan;
      }
      return plan.unassign(
        source,
        radioCode: originRadio,
        playlistType: originType,
      );
    }
    if (originRadio == targetRadioCode) return plan;
    return plan.unassign(source, radioCode: originRadio);
  }

  /// 把曲目移回池子（取消分配）。
  void unassign(String trackId, {String? radioCode, String? playlistType}) {
    if (_editingLocked) return;
    final track = _trackById(trackId);
    if (track == null) return;
    if (!state.splitPlaylistTypes && playlistType != null) {
      _syncPlanFrom(playlistType);
    } else {
      _ensureEditablePlanSeeded();
    }
    ref
        .read(playlistPlanProvider.notifier)
        .unassign(
          track.source,
          radioCode: radioCode,
          playlistType: state.splitPlaylistTypes ? playlistType : null,
        );
    state = state.copyWith(
      pool: [
        for (final t in state.pool)
          if (t.id == trackId) t.copyWith(clearAssigned: true) else t,
      ],
    );
  }

  void restoreBuiltin(String radioCode, String playlistType) {
    if (_editingLocked) return;
    final controller = ref.read(playlistPlanProvider.notifier);
    _ensureEditablePlanSeeded();
    if (!state.splitPlaylistTypes) {
      _syncPlanFrom(playlistType);
    }
    controller.restoreBuiltin(radioCode: radioCode, playlistType: playlistType);
    if (!state.splitPlaylistTypes) {
      controller.restoreBuiltin(
        radioCode: radioCode,
        playlistType: _otherPlaylistType(playlistType),
      );
    }
    state = state.copyWith(
      pool: [for (final t in state.pool) t.copyWith(clearAssigned: true)],
    );
  }

  int copyGameLayout(PlaylistCatalog catalog) {
    if (_editingLocked) return 0;
    final plan = playlistPlanFromCatalog(catalog, state.pool);
    ref.read(playlistPlanProvider.notifier).replaceWith(plan);
    return plan.assignments.length;
  }

  bool get _editingLocked => ref.read(studioProvider).projectEditingLocked;

  PoolTrack? _trackById(String trackId) {
    for (final track in state.pool) {
      if (track.id == trackId) return track;
    }
    return null;
  }

  void _syncPlanFrom(String playlistType) {
    final plan = _ensureEditablePlanSeeded();
    if (!plan.hasDraft && !plan.hasSplitPlaylistDifferences) return;
    ref
        .read(playlistPlanProvider.notifier)
        .replaceWith(plan.syncPlaylistTypesFrom(playlistType));
  }

  PlaylistPlan _ensureEditablePlanSeeded() {
    final currentDraft = ref.read(playlistPlanProvider);
    if (currentDraft.hasDraft) return currentDraft;
    final effective = ref.read(effectivePlaylistPlanProvider);
    if (effective.hasDraft) return effective;
    final catalog = ref.read(playlistCatalogProvider);
    if (catalog.failed) return effective;
    final detected = playlistPlanFromCatalog(
      catalog,
      state.pool,
      includeBuiltinTargets: false,
    );
    if (detected.assignments.isEmpty) return effective;
    ref.read(playlistPlanProvider.notifier).replaceWith(detected);
    return ref.read(effectivePlaylistPlanProvider);
  }

  String _otherPlaylistType(String playlistType) {
    return PlaylistAssignment.normalizePlaylistType(playlistType) == 'Event'
        ? 'FreeRoam'
        : 'Event';
  }
}

PlaylistPlan playlistPlanFromCatalog(
  PlaylistCatalog catalog,
  List<PoolTrack> pool, {
  bool includeBuiltinTargets = true,
}) {
  final poolByMeta = <String, String>{};
  for (final track in pool) {
    poolByMeta.putIfAbsent(_metaKey(track.title, track.artist), () {
      return track.source;
    });
  }

  var plan = const PlaylistPlan.empty();
  for (final radio in catalog.radios) {
    for (final playlistType in const ['FreeRoam', 'Event']) {
      if (catalog.modeOfList(radio.code, playlistType) != StationMode.custom) {
        if (includeBuiltinTargets) {
          plan = plan.restoreBuiltin(
            radioCode: radio.code,
            playlistType: playlistType,
          );
        }
        continue;
      }

      var slot = 1;
      for (final track in catalog.tracksOfRadio(radio.code, playlistType)) {
        // 包 manifest 的 sound_name→source 是权威映射（构建时写入），优先采用；
        // 只有没有该映射时才退回按 title/artist 在 pool 里匹配。
        final source =
            catalog.sourceForTrack(track) ??
            poolByMeta[_metaKey(track.title, track.artist)];
        if (source == null || source.trim().isEmpty) continue;
        plan = plan.assign(
          source: source,
          radioCode: radio.code,
          playlistType: playlistType,
          slot: slot,
        );
        slot += 1;
      }
    }
  }
  return plan;
}

String _metaKey(String title, String artist) {
  return '${artist.trim().toLowerCase()}|${title.trim().toLowerCase()}';
}

final playlistProvider = StateNotifierProvider<PlaylistNotifier, PlaylistState>(
  (ref) {
    final notifier = PlaylistNotifier(ref, ref.read(realPoolTracksProvider));
    ref.listen<List<PoolTrack>>(
      realPoolTracksProvider,
      (_, next) => notifier.setPool(next),
    );
    return notifier;
  },
);

int _configurationCompleteness(PoolTrack track) {
  if (track.configured) return 4;
  return track.confirmed.clamp(0, 4).toInt();
}
