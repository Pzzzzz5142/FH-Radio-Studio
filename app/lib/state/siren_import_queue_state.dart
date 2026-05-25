import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/siren_audio_cache.dart';
import '../core/siren_catalog.dart';
import 'studio_state.dart';

@immutable
class SirenImportQueueState {
  factory SirenImportQueueState({
    Set<String> queuedCids = const {},
    Set<String> importedPreviewCids = const {},
    Set<String> importingCids = const {},
    Map<String, String> trackErrors = const {},
    Map<String, String> lastBatchErrors = const {},
    int batchTotal = 0,
    int lastBatchTotal = 0,
    bool importing = false,
  }) {
    return SirenImportQueueState._(
      queuedCids: Set.unmodifiable(queuedCids),
      importedPreviewCids: Set.unmodifiable(importedPreviewCids),
      importingCids: Set.unmodifiable(importingCids),
      trackErrors: Map.unmodifiable(trackErrors),
      lastBatchErrors: Map.unmodifiable(lastBatchErrors),
      batchTotal: batchTotal,
      lastBatchTotal: lastBatchTotal,
      importing: importing,
    );
  }

  const SirenImportQueueState._({
    required this.queuedCids,
    required this.importedPreviewCids,
    required this.importingCids,
    required this.trackErrors,
    required this.lastBatchErrors,
    required this.batchTotal,
    required this.lastBatchTotal,
    required this.importing,
  });

  final Set<String> queuedCids;
  final Set<String> importedPreviewCids;
  final Set<String> importingCids;
  final Map<String, String> trackErrors;
  final Map<String, String> lastBatchErrors;
  final int batchTotal;
  final int lastBatchTotal;
  final bool importing;

  static final empty = SirenImportQueueState();
}

class SirenImportQueueController extends StateNotifier<SirenImportQueueState> {
  SirenImportQueueController(this._ref) : super(SirenImportQueueState.empty);

  final Ref _ref;

  void queue(Iterable<String> cids, {Set<String> importedCids = const {}}) {
    final next = {...state.queuedCids};
    final errors = {...state.trackErrors};
    for (final cid in cids) {
      if (cid.isEmpty ||
          importedCids.contains(cid) ||
          state.importedPreviewCids.contains(cid)) {
        continue;
      }
      next.add(cid);
      errors.remove(cid);
    }
    state = SirenImportQueueState(
      queuedCids: next,
      importedPreviewCids: state.importedPreviewCids,
      importingCids: state.importingCids,
      trackErrors: errors,
      lastBatchErrors: state.lastBatchErrors,
      batchTotal: state.batchTotal,
      lastBatchTotal: state.lastBatchTotal,
      importing: state.importing,
    );
  }

  void remove(String cid) {
    if (!state.queuedCids.contains(cid)) return;
    state = SirenImportQueueState(
      queuedCids: {...state.queuedCids}..remove(cid),
      importedPreviewCids: state.importedPreviewCids,
      importingCids: state.importingCids,
      trackErrors: {...state.trackErrors}..remove(cid),
      lastBatchErrors: state.lastBatchErrors,
      batchTotal: state.batchTotal,
      lastBatchTotal: state.lastBatchTotal,
      importing: state.importing,
    );
  }

  void clear() {
    if (state.queuedCids.isEmpty) return;
    state = SirenImportQueueState(
      importedPreviewCids: state.importedPreviewCids,
      importingCids: state.importingCids,
      trackErrors: state.trackErrors,
      lastBatchErrors: state.lastBatchErrors,
      batchTotal: state.batchTotal,
      lastBatchTotal: state.lastBatchTotal,
      importing: state.importing,
    );
  }

  void acknowledgeLastBatchErrors() {
    if (state.lastBatchErrors.isEmpty) return;
    state = SirenImportQueueState(
      queuedCids: state.queuedCids,
      importedPreviewCids: state.importedPreviewCids,
      importingCids: state.importingCids,
      trackErrors: state.trackErrors,
      batchTotal: state.batchTotal,
      lastBatchTotal: 0,
      importing: state.importing,
    );
  }

  void markImported(String cid) {
    if (cid.isEmpty) return;
    state = SirenImportQueueState(
      queuedCids: {...state.queuedCids}..remove(cid),
      importedPreviewCids: {...state.importedPreviewCids, cid},
      importingCids: {...state.importingCids}..remove(cid),
      trackErrors: {...state.trackErrors}..remove(cid),
      lastBatchErrors: state.lastBatchErrors,
      batchTotal: state.batchTotal,
      lastBatchTotal: state.lastBatchTotal,
      importing: state.importing,
    );
  }

  Future<void> importQueuedTracks(List<SirenTrack> tracks) async {
    if (state.importing) return;
    final studio = _ref.read(studioProvider);
    if (studio.busy || !studio.hasProject) return;
    final batch = tracks
        .where(
          (track) =>
              state.queuedCids.contains(track.cid) &&
              !state.importedPreviewCids.contains(track.cid),
        )
        .toList(growable: false);
    if (batch.isEmpty) return;

    state = SirenImportQueueState(
      queuedCids: state.queuedCids,
      importedPreviewCids: state.importedPreviewCids,
      importingCids: {
        ...state.importingCids,
        ...batch.map((track) => track.cid),
      },
      trackErrors: {...state.trackErrors}
        ..removeWhere((cid, _) => batch.any((track) => track.cid == cid)),
      lastBatchErrors: const {},
      batchTotal: batch.length,
      lastBatchTotal: 0,
      importing: true,
    );

    try {
      for (final track in batch) {
        if (!state.queuedCids.contains(track.cid) ||
            state.importedPreviewCids.contains(track.cid)) {
          _markImportComplete(track.cid);
          continue;
        }
        if (_ref.read(studioProvider).busy) {
          _recordTrackError(track.cid, '当前正在导入其它音源，塞壬导入已暂停。');
          break;
        }
        await _importTrack(track);
      }
    } finally {
      final batchCids = batch.map((track) => track.cid).toSet();
      final batchErrors = <String, String>{};
      for (final cid in batchCids) {
        final error = state.trackErrors[cid];
        if (error != null) batchErrors[cid] = error;
      }
      state = SirenImportQueueState(
        queuedCids: state.queuedCids,
        importedPreviewCids: state.importedPreviewCids,
        importingCids: {...state.importingCids}
          ..removeWhere(batchCids.contains),
        trackErrors: state.trackErrors,
        lastBatchErrors: batchErrors,
        batchTotal: 0,
        lastBatchTotal: batch.length,
        importing: false,
      );
    }
  }

  Future<void> _importTrack(SirenTrack track) async {
    try {
      final detail = await _ref
          .read(sirenCatalogClientProvider)
          .fetchSongDetail(track.cid);
      final cache = _ref.read(sirenAudioCacheProvider);
      final cached = await cache.cacheAudio(detail, track: track);
      String? coverImagePath;
      try {
        coverImagePath = (await cache.cacheCover(track))?.path;
      } on Object {
        coverImagePath = null;
      }
      final imported = await _ref
          .read(studioProvider.notifier)
          .importSirenTrack(
            track: track,
            detail: detail,
            cachedAudioPath: cached.path,
            coverImagePath: coverImagePath,
          );
      if (imported != null) {
        markImported(track.cid);
      } else {
        _recordTrackError(track.cid, '塞壬导入没有生成项目音频。');
      }
    } on Object catch (error) {
      _recordTrackError(track.cid, '$error');
    } finally {
      _markImportComplete(track.cid);
    }
  }

  void _markImportComplete(String cid) {
    if (!state.importingCids.contains(cid)) return;
    state = SirenImportQueueState(
      queuedCids: state.queuedCids,
      importedPreviewCids: state.importedPreviewCids,
      importingCids: {...state.importingCids}..remove(cid),
      trackErrors: state.trackErrors,
      lastBatchErrors: state.lastBatchErrors,
      batchTotal: state.batchTotal,
      lastBatchTotal: state.lastBatchTotal,
      importing: state.importing,
    );
  }

  void _recordTrackError(String cid, String error) {
    if (cid.isEmpty) return;
    state = SirenImportQueueState(
      queuedCids: state.queuedCids,
      importedPreviewCids: state.importedPreviewCids,
      importingCids: state.importingCids,
      trackErrors: {...state.trackErrors, cid: error},
      lastBatchErrors: state.lastBatchErrors,
      batchTotal: state.batchTotal,
      lastBatchTotal: state.lastBatchTotal,
      importing: state.importing,
    );
  }
}

final sirenImportQueueProvider =
    StateNotifierProvider<SirenImportQueueController, SirenImportQueueState>(
      (ref) => SirenImportQueueController(ref),
    );
