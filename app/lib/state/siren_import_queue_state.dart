import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

@immutable
class SirenImportQueueState {
  factory SirenImportQueueState({
    Set<String> queuedCids = const {},
    Set<String> importedPreviewCids = const {},
  }) {
    return SirenImportQueueState._(
      queuedCids: Set.unmodifiable(queuedCids),
      importedPreviewCids: Set.unmodifiable(importedPreviewCids),
    );
  }

  const SirenImportQueueState._({
    required this.queuedCids,
    required this.importedPreviewCids,
  });

  final Set<String> queuedCids;
  final Set<String> importedPreviewCids;

  static final empty = SirenImportQueueState();
}

class SirenImportQueueController extends StateNotifier<SirenImportQueueState> {
  SirenImportQueueController() : super(SirenImportQueueState.empty);

  void queue(Iterable<String> cids, {Set<String> importedCids = const {}}) {
    final next = {...state.queuedCids};
    for (final cid in cids) {
      if (cid.isEmpty ||
          importedCids.contains(cid) ||
          state.importedPreviewCids.contains(cid)) {
        continue;
      }
      next.add(cid);
    }
    state = SirenImportQueueState(
      queuedCids: next,
      importedPreviewCids: state.importedPreviewCids,
    );
  }

  void remove(String cid) {
    if (!state.queuedCids.contains(cid)) return;
    state = SirenImportQueueState(
      queuedCids: {...state.queuedCids}..remove(cid),
      importedPreviewCids: state.importedPreviewCids,
    );
  }

  void clear() {
    if (state.queuedCids.isEmpty) return;
    state = SirenImportQueueState(
      importedPreviewCids: state.importedPreviewCids,
    );
  }

  void markImported(String cid) {
    if (cid.isEmpty) return;
    state = SirenImportQueueState(
      queuedCids: {...state.queuedCids}..remove(cid),
      importedPreviewCids: {...state.importedPreviewCids, cid},
    );
  }
}

final sirenImportQueueProvider =
    StateNotifierProvider<SirenImportQueueController, SirenImportQueueState>(
      (ref) => SirenImportQueueController(),
    );
