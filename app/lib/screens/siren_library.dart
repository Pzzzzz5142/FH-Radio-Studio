import 'dart:async';
import 'dart:math' as math;

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';

import '../core/system_audio_output.dart';
import '../core/siren_audio_cache.dart';
import '../core/siren_catalog.dart';
import '../core/siren_imports.dart';
import '../state/siren_import_queue_state.dart';
import '../state/studio_state.dart';
import '../theme/app_theme.dart';
import '../theme/text_styles.dart';
import '../theme/tokens.dart';
import '../widgets/pending_gate.dart';
import '../widgets/rm_button.dart';
import '../widgets/rm_banner.dart';
import '../widgets/rm_chip.dart';
import '../widgets/rm_icon.dart';
import '../widgets/rm_panel.dart';
import '../widgets/rm_segmented.dart';

enum _SirenFilter { all, unimported, queued, imported, failed }

enum _SirenSort { catalog, title, artist, album }

const _latestTickerCycleDuration = Duration(seconds: 38);
const _latestTickerDesktopItemWidth = 224.0;
const _latestTickerNarrowItemWidth = 204.0;
const _latestTickerSeparatorPadding = 8.0;
const _sirenPageMaxWidth = RmTokens.pageWide;
const _sirenPageWidePadding = 40.0;
const _sirenPageNarrowPadding = 24.0;
const _sirenPinnedTopPadding = 18.0;
const _sirenPinnedBottomPadding = 24.0;
const _sirenAlbumCardHeight = 120.0;
const _sirenAlbumScrollbarGap = 12.0;
const _sirenAlbumRailHeight = _sirenAlbumCardHeight + _sirenAlbumScrollbarGap;
const _trackHeaderHeight = 36.0;
const _trackRowHeight = 52.0;
const _songTablePanelChromeHeight = 51.0;

class SirenLibraryScreen extends ConsumerStatefulWidget {
  const SirenLibraryScreen({super.key});

  @override
  ConsumerState<SirenLibraryScreen> createState() => _SirenLibraryScreenState();
}

class _SirenLibraryScreenState extends ConsumerState<SirenLibraryScreen> {
  final _searchController = TextEditingController();
  final _songDetails = <String, AsyncValue<SirenSongDetail>>{};
  final _albumDetails = <String, AsyncValue<SirenAlbumDetail>>{};
  final _playingBusyCids = <String>{};
  final _trackErrors = <String, String>{};
  final _autoFetchingSongCids = <String>{};
  final _autoFetchingAlbumCids = <String>{};

  Player? _player;
  SystemAudioOutputFollower? _audioOutputFollower;
  StreamSubscription<bool>? _playingSub;

  var _query = '';
  var _filter = _SirenFilter.all;
  var _sort = _SirenSort.catalog;
  String? _activeAlbumCid;
  String? _activeTrackCid;
  String? _playingCid;
  bool _playing = false;
  double _importSidePanelHeight = 0;
  bool _failureDialogScheduled = false;

  @override
  void dispose() {
    _searchController.dispose();
    _playingSub?.cancel();
    _audioOutputFollower?.dispose();
    _player?.dispose();
    super.dispose();
  }

  Player get _audioPlayer {
    final existing = _player;
    final player = existing ?? Player();
    if (existing == null) {
      _player = player;
      _audioOutputFollower = followSystemAudioOutput(player);
    }
    _playingSub ??= player.stream.playing.listen((playing) {
      if (!mounted) return;
      setState(() => _playing = playing);
    });
    return player;
  }

  @override
  Widget build(BuildContext context) {
    final catalog = ref.watch(sirenCatalogProvider);
    return SizedBox.expand(
      child: ColoredBox(
        color: context.rm.bg,
        child: catalog.when(
          loading: () => const _SirenLoading(),
          error: (error, _) => _SirenLoadError(
            error: error,
            onRetry: () => ref.invalidate(sirenCatalogProvider),
          ),
          data: _buildCatalog,
        ),
      ),
    );
  }

  Widget _buildCatalog(SirenCatalogSnapshot snapshot) {
    final cli = ref.watch(studioProvider);
    final importQueue = ref.watch(sirenImportQueueProvider);
    final queuedCids = importQueue.queuedCids;
    final importedPreviewCids = importQueue.importedPreviewCids;
    final queueImporting = importQueue.importing;
    final importingCids = importQueue.importingCids;
    final trackErrors = {...importQueue.trackErrors, ..._trackErrors};
    _scheduleBatchFailureDialog(
      importQueue.lastBatchErrors,
      importQueue.lastBatchTotal,
      snapshot.tracks,
    );
    final sourceImportBlocked = cli.busy && !queueImporting;
    final importedCids = <String>{
      if (cli.hasProject) ...SirenImportRegistry.importedCids(cli.projectDir),
      ...importedPreviewCids,
    };
    final albumByCid = snapshot.albumByCid;
    final albumOrder = _albumOrder(snapshot.albums);
    final trackOrder = _trackOrder(snapshot.tracks);
    final latestTracks = snapshot.recentInferredTracks();
    final visibleTracks = _visibleTracks(
      snapshot.tracks,
      importedCids,
      queuedCids: queuedCids,
      trackErrors: trackErrors,
      albumOrder: albumOrder,
      trackOrder: trackOrder,
    );
    final queuedTracks = snapshot.tracks
        .where(
          (track) =>
              queuedCids.contains(track.cid) &&
              !importedCids.contains(track.cid),
        )
        .toList(growable: false);
    final selectedTrack =
        visibleTracks.firstWhereOrNull(
          (track) => track.cid == _activeTrackCid,
        ) ??
        queuedTracks.firstOrNull ??
        visibleTracks.firstOrNull;
    final selectedAlbum = selectedTrack == null
        ? (_activeAlbumCid == null ? null : albumByCid[_activeAlbumCid])
        : albumByCid[selectedTrack.albumCid];
    _scheduleAutoDetailFetches(selectedTrack, selectedAlbum);
    return LayoutBuilder(
      builder: (context, viewport) {
        final edgePadding = viewport.maxWidth < 900
            ? _sirenPageNarrowPadding
            : _sirenPageWidePadding;
        final contentWidth = math.min(
          _sirenPageMaxWidth,
          math.max(0.0, viewport.maxWidth - edgePadding * 2),
        );
        final horizontalInset = math.max(
          edgePadding,
          (viewport.maxWidth - contentWidth) / 2,
        );
        final workspaceBodyHeight = math.max(
          460.0,
          viewport.maxHeight -
              _sirenPinnedTopPadding -
              _sirenPinnedBottomPadding,
        );

        return CustomScrollView(
          key: const ValueKey('siren-library-scroll'),
          slivers: [
            SliverPadding(
              padding: EdgeInsets.fromLTRB(
                horizontalInset,
                32,
                horizontalInset,
                16,
              ),
              sliver: SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _ImportBridgeHero(
                      fetchedAt: snapshot.fetchedAt,
                      albumCount: snapshot.albums.length,
                      trackCount: snapshot.tracks.length,
                      visibleCount: visibleTracks.length,
                      queuedCount: queuedTracks.length,
                      importedCount: importedCids.length,
                      latestTracks: latestTracks,
                      onSelectLatest: (track) => setState(() {
                        _activeTrackCid = track.cid;
                        _activeAlbumCid = track.albumCid;
                      }),
                      onRefresh: () => ref.invalidate(sirenCatalogProvider),
                    ),
                    const SizedBox(height: 16),
                    _CatalogToolbar(
                      controller: _searchController,
                      query: _query,
                      filter: _filter,
                      totalCount: snapshot.tracks.length,
                      visibleCount: visibleTracks.length,
                      onQueryChanged: (value) => setState(() => _query = value),
                      onClear: () {
                        _searchController.clear();
                        setState(() => _query = '');
                      },
                      onFilterChanged: (value) =>
                          setState(() => _filter = value),
                    ),
                    const SizedBox(height: 14),
                    _AlbumRail(
                      albums: snapshot.albums,
                      tracks: snapshot.tracks,
                      activeAlbumCid: _activeAlbumCid,
                      queuedCids: queuedCids,
                      importedCids: importedCids,
                      onSelectAll: () => setState(() => _activeAlbumCid = null),
                      onSelectAlbum: (album) =>
                          setState(() => _activeAlbumCid = album.cid),
                    ),
                  ],
                ),
              ),
            ),
            SliverPadding(
              padding: EdgeInsets.fromLTRB(
                horizontalInset,
                _sirenPinnedTopPadding,
                horizontalInset,
                _sirenPinnedBottomPadding,
              ),
              sliver: SliverToBoxAdapter(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final compact = constraints.maxWidth < 920;
                    final maxTableBodyHeight = compact
                        ? math.max(420.0, workspaceBodyHeight * 0.58)
                        : math.max(360.0, workspaceBodyHeight - 54);
                    final table = _SongTable(
                      bodyHeight: _songTableBodyHeight(
                        visibleTracks.length,
                        maxTableBodyHeight,
                        alignToPanelHeight: compact
                            ? 0
                            : _importSidePanelHeight,
                      ),
                      tracks: visibleTracks,
                      sort: _sort,
                      queuedCids: queuedCids,
                      importedCids: importedCids,
                      activeTrackCid: selectedTrack?.cid,
                      playingCid: _playingCid,
                      playing: _playing,
                      playingBusyCids: _playingBusyCids,
                      onSortChanged: (value) => setState(() => _sort = value),
                      onSelectTrack: (track) =>
                          setState(() => _activeTrackCid = track.cid),
                      onPlay: _togglePlayback,
                      onQueue: (track) => _queueTracks([track]),
                    );
                    final side = _ImportSidePanel(
                      key: const ValueKey('siren-import-side-panel'),
                      queuedTracks: queuedTracks,
                      queueImporting: queueImporting,
                      batchTotal: importQueue.batchTotal,
                      importingCount: importingCids.length,
                      failedCount: importQueue.trackErrors.length,
                      selectedTrack: selectedTrack,
                      selectedAlbum: selectedAlbum,
                      selectedAlbumDetail: selectedAlbum == null
                          ? null
                          : _albumDetails[selectedAlbum.cid],
                      selectedTrackDetail: selectedTrack == null
                          ? null
                          : _songDetails[selectedTrack.cid],
                      queuedCids: queuedCids,
                      importedCids: importedCids,
                      importingCids: importingCids,
                      trackErrors: trackErrors,
                      onRemoveQueued: _removeQueued,
                      onClearQueue: queuedCids.isEmpty
                          ? null
                          : ref.read(sirenImportQueueProvider.notifier).clear,
                      importQueuedTooltip: sourceImportBlocked
                          ? '自建歌曲正在导入，完成后可导入塞壬唱片'
                          : null,
                      onImportQueued:
                          queuedTracks.isEmpty || sourceImportBlocked
                          ? null
                          : () => ref
                                .read(sirenImportQueueProvider.notifier)
                                .importQueuedTracks(queuedTracks),
                      onPlayTrack: selectedTrack == null
                          ? null
                          : () => _togglePlayback(selectedTrack),
                      onQueueTrack: selectedTrack == null
                          ? null
                          : () => _queueTracks([selectedTrack]),
                    );
                    if (compact) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [table, const SizedBox(height: 16), side],
                      );
                    }
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: table),
                        const SizedBox(width: 16),
                        SizedBox(
                          width: 330,
                          child: _MeasureSize(
                            onChanged: _setImportSidePanelHeight,
                            child: side,
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  double _songTableBodyHeight(
    int trackCount,
    double maxBodyHeight, {
    double alignToPanelHeight = 0,
  }) {
    final minBodyHeight = _trackHeaderHeight + _trackRowHeight;
    final alignedBodyHeight = alignToPanelHeight <= 0
        ? 0.0
        : math.max(
            minBodyHeight,
            alignToPanelHeight - _songTablePanelChromeHeight,
          );
    if (trackCount <= 0) {
      return math.max(math.min(maxBodyHeight, 360.0), alignedBodyHeight);
    }
    final contentHeight = _trackHeaderHeight + trackCount * _trackRowHeight;
    final naturalHeight = math
        .min(maxBodyHeight, contentHeight)
        .clamp(minBodyHeight, maxBodyHeight)
        .toDouble();
    return math.max(naturalHeight, alignedBodyHeight);
  }

  void _setImportSidePanelHeight(Size size) {
    final height = size.height;
    if ((_importSidePanelHeight - height).abs() < 0.5) return;
    setState(() => _importSidePanelHeight = height);
  }

  void _scheduleAutoDetailFetches(SirenTrack? track, SirenAlbum? album) {
    if (track != null &&
        _songDetails[track.cid] == null &&
        !_autoFetchingSongCids.contains(track.cid)) {
      _autoFetchingSongCids.add(track.cid);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        unawaited(_autoFetchSongDetail(track));
      });
    }
    if (album != null &&
        _albumDetails[album.cid] == null &&
        !_autoFetchingAlbumCids.contains(album.cid)) {
      _autoFetchingAlbumCids.add(album.cid);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        unawaited(_autoFetchAlbumDetail(album));
      });
    }
  }

  Future<void> _autoFetchSongDetail(SirenTrack track) async {
    try {
      await _ensureSongDetail(track);
    } on Object {
      // The inspector displays the stored AsyncError; automatic loading should
      // not surface as an unhandled frame exception.
    } finally {
      _autoFetchingSongCids.remove(track.cid);
    }
  }

  Future<void> _autoFetchAlbumDetail(SirenAlbum album) async {
    try {
      await _fetchAlbumDetail(album);
    } finally {
      _autoFetchingAlbumCids.remove(album.cid);
    }
  }

  List<SirenTrack> _visibleTracks(
    List<SirenTrack> tracks,
    Set<String> importedCids, {
    required Set<String> queuedCids,
    required Map<String, String> trackErrors,
    required Map<String, int> albumOrder,
    required Map<String, int> trackOrder,
  }) {
    final query = _query.trim();
    final result = tracks
        .where((track) {
          if (_activeAlbumCid != null && track.albumCid != _activeAlbumCid) {
            return false;
          }
          if (query.isNotEmpty && !track.matches(query)) return false;
          return switch (_filter) {
            _SirenFilter.all => true,
            _SirenFilter.unimported =>
              !queuedCids.contains(track.cid) &&
                  !importedCids.contains(track.cid),
            _SirenFilter.queued =>
              queuedCids.contains(track.cid) &&
                  !importedCids.contains(track.cid),
            _SirenFilter.imported => importedCids.contains(track.cid),
            _SirenFilter.failed =>
              _songDetails[track.cid]?.hasError == true ||
                  trackErrors.containsKey(track.cid),
          };
        })
        .toList(growable: false);

    result.sort((a, b) {
      return switch (_sort) {
        _SirenSort.catalog => _compareAlbumRailThenSource(
          a,
          b,
          albumOrder,
          trackOrder,
        ),
        _SirenSort.title => a.name.compareTo(b.name),
        _SirenSort.artist => _compareArtistThenTitle(a, b),
        _SirenSort.album => _compareAlbumThenTrack(a, b),
      };
    });
    return result;
  }

  Map<String, int> _albumOrder(List<SirenAlbum> albums) {
    return {for (final (index, album) in albums.indexed) album.cid: index};
  }

  Map<String, int> _trackOrder(List<SirenTrack> tracks) {
    return {for (final (index, track) in tracks.indexed) track.cid: index};
  }

  int _compareCatalogId(String a, String b) {
    final ai = int.tryParse(a);
    final bi = int.tryParse(b);
    if (ai != null && bi != null) return ai.compareTo(bi);
    return a.compareTo(b);
  }

  int _compareAlbumThenTrack(SirenTrack a, SirenTrack b) {
    final album = a.albumName.compareTo(b.albumName);
    if (album != 0) return album;
    return _compareCatalogId(a.cid, b.cid);
  }

  int _compareAlbumRailThenSource(
    SirenTrack a,
    SirenTrack b,
    Map<String, int> albumOrder,
    Map<String, int> trackOrder,
  ) {
    final album = (albumOrder[a.albumCid] ?? 1 << 30).compareTo(
      albumOrder[b.albumCid] ?? 1 << 30,
    );
    if (album != 0) return album;
    final source = (trackOrder[a.cid] ?? 1 << 30).compareTo(
      trackOrder[b.cid] ?? 1 << 30,
    );
    if (source != 0) return source;
    return _compareCatalogId(a.cid, b.cid);
  }

  int _compareArtistThenTitle(SirenTrack a, SirenTrack b) {
    final artist = a.artistDisplayText.compareTo(b.artistDisplayText);
    if (artist != 0) return artist;
    final title = a.name.compareTo(b.name);
    if (title != 0) return title;
    return _compareCatalogId(a.cid, b.cid);
  }

  void _queueTracks(List<SirenTrack> tracks) {
    final cli = ref.read(studioProvider);
    final importedCids = <String>{
      if (cli.hasProject) ...SirenImportRegistry.importedCids(cli.projectDir),
      ...ref.read(sirenImportQueueProvider).importedPreviewCids,
    };
    ref
        .read(sirenImportQueueProvider.notifier)
        .queue(tracks.map((track) => track.cid), importedCids: importedCids);
    setState(() {
      _activeTrackCid = tracks.firstOrNull?.cid ?? _activeTrackCid;
    });
  }

  void _removeQueued(String cid) {
    ref.read(sirenImportQueueProvider.notifier).remove(cid);
  }

  Future<void> _fetchAlbumDetail(SirenAlbum album) async {
    final current = _albumDetails[album.cid];
    if (current is AsyncLoading) return;
    setState(() => _albumDetails[album.cid] = const AsyncLoading());
    try {
      final detail = await ref
          .read(sirenCatalogClientProvider)
          .fetchAlbumDetail(album.cid);
      if (!mounted) return;
      setState(() => _albumDetails[album.cid] = AsyncData(detail));
    } catch (error, stackTrace) {
      if (!mounted) return;
      setState(() => _albumDetails[album.cid] = AsyncError(error, stackTrace));
    }
  }

  Future<SirenSongDetail> _ensureSongDetail(
    SirenTrack track, {
    bool forceRefresh = false,
  }) async {
    final current = _songDetails[track.cid];
    if (!forceRefresh && current?.hasValue == true) {
      return current!.requireValue;
    }
    if (current is AsyncLoading) {
      final detail = await ref
          .read(sirenCatalogClientProvider)
          .fetchSongDetail(track.cid);
      return detail;
    }
    setState(() {
      _activeTrackCid = track.cid;
      _songDetails[track.cid] = const AsyncLoading();
      _trackErrors.remove(track.cid);
    });
    try {
      final detail = await ref
          .read(sirenCatalogClientProvider)
          .fetchSongDetail(track.cid);
      if (mounted) {
        setState(() => _songDetails[track.cid] = AsyncData(detail));
      }
      return detail;
    } catch (error, stackTrace) {
      if (mounted) {
        setState(() {
          _songDetails[track.cid] = AsyncError(error, stackTrace);
          _trackErrors[track.cid] = '$error';
        });
      }
      rethrow;
    }
  }

  Future<void> _togglePlayback(SirenTrack track) async {
    if (_playingCid == track.cid && _playing) {
      await _audioPlayer.pause();
      if (!mounted) return;
      setState(() => _playing = false);
      return;
    }

    setState(() {
      _activeTrackCid = track.cid;
      _playingBusyCids.add(track.cid);
      _trackErrors.remove(track.cid);
    });
    try {
      final detail = await _ensureSongDetail(track);
      final cache = ref.read(sirenAudioCacheProvider);
      final cached = await cache.cachedAudioFile(detail);
      final mediaUri = cached == null
          ? detail.sourceUrl
          : Uri.file(cached.path).toString();
      await _audioPlayer.open(Media(mediaUri), play: true);
      if (cached == null) {
        unawaited(_cacheInBackground(cache, detail, track));
      }
      if (!mounted) return;
      setState(() {
        _playingCid = track.cid;
        _playing = true;
      });
    } on Object catch (error) {
      _recordTrackError(track.cid, error);
    } finally {
      if (mounted) {
        setState(() => _playingBusyCids.remove(track.cid));
      }
    }
  }

  Future<void> _cacheInBackground(
    SirenAudioCache cache,
    SirenSongDetail detail,
    SirenTrack track,
  ) async {
    try {
      await cache.cacheAudio(detail, track: track);
    } on Object catch (error) {
      _recordTrackError(track.cid, error);
    }
  }

  void _recordTrackError(String cid, Object error) {
    if (!mounted) return;
    setState(() => _trackErrors[cid] = '$error');
  }

  void _scheduleBatchFailureDialog(
    Map<String, String> failures,
    int batchTotal,
    List<SirenTrack> tracks,
  ) {
    if (failures.isEmpty || _failureDialogScheduled) return;
    _failureDialogScheduled = true;
    final byCid = {for (final track in tracks) track.cid: track};
    final items = [
      for (final entry in failures.entries)
        _SirenImportFailure(
          cid: entry.key,
          track: byCid[entry.key],
          error: entry.value,
        ),
    ];
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => _SirenImportFailureDialog(
          items: items,
          allFailed: batchTotal > 0 && failures.length >= batchTotal,
        ),
      );
      if (!mounted) return;
      ref.read(sirenImportQueueProvider.notifier).acknowledgeLastBatchErrors();
      _failureDialogScheduled = false;
    });
  }
}

class _MeasureSize extends StatefulWidget {
  const _MeasureSize({required this.onChanged, required this.child});

  final ValueChanged<Size> onChanged;
  final Widget child;

  @override
  State<_MeasureSize> createState() => _MeasureSizeState();
}

class _MeasureSizeState extends State<_MeasureSize> {
  Size? _lastSize;
  bool _scheduled = false;

  @override
  void initState() {
    super.initState();
    _scheduleMeasure();
  }

  @override
  void didUpdateWidget(covariant _MeasureSize oldWidget) {
    super.didUpdateWidget(oldWidget);
    _scheduleMeasure();
  }

  @override
  Widget build(BuildContext context) {
    _scheduleMeasure();
    return widget.child;
  }

  void _scheduleMeasure() {
    if (_scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!mounted) return;
      final size = context.size;
      if (size == null) return;
      final last = _lastSize;
      if (last != null &&
          (last.width - size.width).abs() < 0.5 &&
          (last.height - size.height).abs() < 0.5) {
        return;
      }
      _lastSize = size;
      widget.onChanged(size);
    });
  }
}

class _SirenImportFailure {
  const _SirenImportFailure({
    required this.cid,
    required this.track,
    required this.error,
  });

  final String cid;
  final SirenTrack? track;
  final String error;

  String get title => track?.name ?? cid;

  String get subtitle {
    final value = track;
    if (value == null) return 'CID $cid';
    return '${value.albumName} · ${value.artistDisplayText}';
  }
}

class _SirenImportFailureDialog extends StatelessWidget {
  const _SirenImportFailureDialog({
    required this.items,
    required this.allFailed,
  });

  final List<_SirenImportFailure> items;
  final bool allFailed;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    final tone = allFailed ? rm.danger : rm.warn;
    final toneBg = allFailed ? rm.dangerBg : rm.warnBg;
    final toneIcon = allFailed ? 'danger' : 'warn';
    final bannerKind = allFailed ? RmBannerKind.danger : RmBannerKind.warn;
    return Dialog(
      key: const ValueKey('siren-import-failure-dialog'),
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 36),
      child: Container(
        width: 600,
        constraints: const BoxConstraints(maxHeight: 720),
        decoration: BoxDecoration(
          color: rm.panel,
          border: Border.all(color: rm.borderStrong),
          borderRadius: BorderRadius.circular(RmTokens.rXl),
          boxShadow: RmTokens.modal,
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 22, 24, 16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    key: ValueKey(
                      allFailed
                          ? 'siren-import-failure-tone-danger'
                          : 'siren-import-failure-tone-warn',
                    ),
                    width: 34,
                    height: 34,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: toneBg,
                      border: Border.all(color: tone.withAlpha(77)),
                      borderRadius: BorderRadius.circular(RmTokens.rMd),
                    ),
                    child: RmIcon(toneIcon, size: 17, color: tone),
                  ),
                  const SizedBox(width: 13),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'SIREN IMPORT',
                          style: RmText.mono(
                            11,
                            color: tone,
                            letterSpacing: 0.12 * 11,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          allFailed ? '塞壬曲目导入失败' : '部分塞壬曲目导入失败',
                          style: RmText.modalH2(color: rm.fg),
                        ),
                      ],
                    ),
                  ),
                  RmButton.icon(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const RmIcon('x', size: 13),
                    variant: RmButtonVariant.ghost,
                    tooltip: '关闭',
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: rm.border),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 18, 24, 18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    RmBanner(
                      kind: bannerKind,
                      title: '已继续处理队列：',
                      body: allFailed
                          ? '下面这些曲目重试后仍失败，仍留在待导入清单里，稍后可以再次导入。'
                          : '成功导入的曲目已经保留；下面这些曲目重试后仍失败，仍留在待导入清单里，稍后可以再次导入。',
                    ),
                    const SizedBox(height: 14),
                    for (final item in items) ...[
                      _SirenImportFailureRow(item: item, allFailed: allFailed),
                      if (item != items.last) const SizedBox(height: 8),
                    ],
                  ],
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.fromLTRB(24, 14, 24, 22),
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: rm.border)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  RmButton(
                    onPressed: () => Navigator.of(context).pop(),
                    variant: allFailed
                        ? RmButtonVariant.dangerPrimary
                        : RmButtonVariant.primary,
                    label: '知道了',
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SirenImportFailureRow extends StatelessWidget {
  const _SirenImportFailureRow({required this.item, required this.allFailed});

  final _SirenImportFailure item;
  final bool allFailed;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    final tone = allFailed ? rm.danger : rm.warn;
    final toneIcon = allFailed ? 'danger' : 'warn';
    return Container(
      key: ValueKey('siren-import-failure-${item.cid}'),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: rm.raised,
        border: Border.all(color: rm.border),
        borderRadius: BorderRadius.circular(RmTokens.rMd),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: RmIcon(toneIcon, size: 14, color: tone),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: RmText.sans(13, weight: FontWeight.w700, color: rm.fg),
                ),
                const SizedBox(height: 4),
                Text(
                  item.subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: RmText.mono(11, color: rm.fg3),
                ),
                const SizedBox(height: 6),
                Text(
                  item.error,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: RmText.sans(12, color: tone, height: 1.35),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ImportBridgeHero extends StatelessWidget {
  const _ImportBridgeHero({
    required this.fetchedAt,
    required this.albumCount,
    required this.trackCount,
    required this.visibleCount,
    required this.queuedCount,
    required this.importedCount,
    required this.latestTracks,
    required this.onSelectLatest,
    required this.onRefresh,
  });

  final DateTime fetchedAt;
  final int albumCount;
  final int trackCount;
  final int visibleCount;
  final int queuedCount;
  final int importedCount;
  final List<SirenTrack> latestTracks;
  final ValueChanged<SirenTrack> onSelectLatest;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 252),
      decoration: BoxDecoration(
        color: const Color(0xFF0B0C0E),
        borderRadius: BorderRadius.circular(RmTokens.rLg),
        border: Border.all(color: const Color(0xFF272A30)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(20),
            blurRadius: 30,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(RmTokens.rLg),
        child: Stack(
          children: [
            Positioned.fill(
              child: CustomPaint(
                painter: _SirenStripePainter(
                  color: Colors.white,
                  opacity: 0.035,
                  step: 16,
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 43,
              height: 1,
              child: ColoredBox(color: Colors.white.withAlpha(28)),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: _LatestStrip(
                tracks: latestTracks,
                onSelect: onSelectLatest,
                embedded: true,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(28, 24, 28, 68),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final compact = constraints.maxWidth < 680;
                  final title = _BridgeTitle(trackCount: trackCount);
                  final status = _BridgeStatusCard(
                    fetchedAt: fetchedAt,
                    albumCount: albumCount,
                    trackCount: trackCount,
                    visibleCount: visibleCount,
                    queuedCount: queuedCount,
                    importedCount: importedCount,
                    onRefresh: onRefresh,
                  );
                  if (compact) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [title, const SizedBox(height: 18), status],
                    );
                  }
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: title),
                      const SizedBox(width: 24),
                      SizedBox(width: 290, child: status),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BridgeTitle extends StatelessWidget {
  const _BridgeTitle({required this.trackCount});

  final int trackCount;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            const _DarkTag('MSR · CATALOG ARCHIVE'),
            Text(
              'RADIOMOD · IMPORT BRIDGE',
              style: RmText.mono(
                11,
                color: const Color(0xFF6F737C),
                letterSpacing: 0.18 * 11,
              ),
            ),
          ],
        ),
        const SizedBox(height: 18),
        Semantics(
          label: 'MONSTER SIREN 塞壬唱片',
          child: ExcludeSemantics(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                const _MonsterSirenMark(size: 60),
                const SizedBox(width: 18),
                Flexible(
                  child: RichText(
                    text: TextSpan(
                      children: [
                        TextSpan(
                          text: '塞壬',
                          style: RmText.sans(
                            42,
                            color: Colors.white,
                            weight: FontWeight.w800,
                            height: 1,
                          ),
                        ),
                        TextSpan(
                          text: '唱片',
                          style: RmText.sans(
                            42,
                            color: const Color(0xFF24B347),
                            weight: FontWeight.w800,
                            height: 1,
                          ),
                        ),
                      ],
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 14,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Container(width: 34, height: 2, color: const Color(0xFF24B347)),
            Text(
              'CATALOG · ARCHIVE · IMPORT',
              style: RmText.mono(
                13,
                color: const Color(0xFFE8E8EA),
                weight: FontWeight.w700,
                letterSpacing: 0.18 * 13,
              ),
            ),
            Text(
              '$trackCount TRACKS INDEXED',
              style: RmText.mono(11, color: const Color(0xFF7B808A)),
            ),
          ],
        ),
      ],
    );
  }
}

class _BridgeStatusCard extends StatelessWidget {
  const _BridgeStatusCard({
    required this.fetchedAt,
    required this.albumCount,
    required this.trackCount,
    required this.visibleCount,
    required this.queuedCount,
    required this.importedCount,
    required this.onRefresh,
  });

  final DateTime fetchedAt;
  final int albumCount;
  final int trackCount;
  final int visibleCount;
  final int queuedCount;
  final int importedCount;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.black.withAlpha(52),
        border: Border.all(color: const Color(0xFF2E333A)),
        borderRadius: BorderRadius.circular(RmTokens.rMd),
      ),
      child: Column(
        children: [
          _StatusLine(label: 'SOURCE', value: 'CDN · LIVE', live: true),
          _StatusLine(label: 'SYNC', value: _formatDateTime(fetchedAt)),
          _StatusLine(label: 'ALBUMS', value: '$albumCount'),
          _StatusLine(label: 'VISIBLE', value: '$visibleCount / $trackCount'),
          _StatusLine(label: 'QUEUE', value: '$queuedCount 待接入'),
          _StatusLine(label: 'POOL', value: '$importedCount 已加入'),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: RmButton(
                  onPressed: onRefresh,
                  size: RmButtonSize.sm,
                  leading: const RmIcon('refresh', size: 12),
                  label: '刷新索引',
                ),
              ),
              const SizedBox(width: 8),
              const RmChip(
                label: 'MSR 来源',
                variant: RmChipVariant.accent,
                showDot: true,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _LatestStrip extends StatefulWidget {
  const _LatestStrip({
    required this.tracks,
    required this.onSelect,
    this.embedded = false,
  });

  final List<SirenTrack> tracks;
  final ValueChanged<SirenTrack> onSelect;
  final bool embedded;

  @override
  State<_LatestStrip> createState() => _LatestStripState();
}

class _LatestStripState extends State<_LatestStrip>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: _latestTickerCycleDuration,
    );
    if (widget.tracks.isNotEmpty) {
      _controller.repeat();
    }
  }

  @override
  void didUpdateWidget(covariant _LatestStrip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.tracks.isEmpty) {
      _controller.stop();
      _controller.value = 0;
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tracks = widget.tracks.take(24).toList(growable: false);
    return Container(
      height: widget.embedded ? 43 : 44,
      decoration: BoxDecoration(
        color: const Color(0xFF0B0C0E),
        borderRadius: widget.embedded
            ? BorderRadius.zero
            : BorderRadius.circular(RmTokens.rMd),
        border: widget.embedded
            ? null
            : Border.all(color: const Color(0xFF272A30)),
      ),
      child: ClipRRect(
        borderRadius: widget.embedded
            ? BorderRadius.zero
            : BorderRadius.circular(RmTokens.rMd),
        child: Stack(
          children: [
            Positioned.fill(
              child: CustomPaint(
                painter: _SirenStripePainter(
                  color: Colors.white,
                  opacity: 0.025,
                  step: 14,
                ),
              ),
            ),
            Row(
              children: [
                Container(
                  width: 124,
                  height: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  decoration: BoxDecoration(
                    border: Border(
                      right: BorderSide(color: Colors.white.withAlpha(22)),
                    ),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          border: Border.all(color: const Color(0xFF24B347)),
                        ),
                        child: Center(
                          child: Container(
                            width: 3,
                            height: 3,
                            color: const Color(0xFF24B347),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        'LATEST',
                        style: RmText.mono(
                          11,
                          color: const Color(0xFF24B347),
                          weight: FontWeight.w800,
                          letterSpacing: 0.22 * 11,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: _LatestTickerBody(
                    tracks: tracks,
                    controller: _controller,
                    onSelect: widget.onSelect,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _LatestTickerBody extends StatelessWidget {
  const _LatestTickerBody({
    required this.tracks,
    required this.controller,
    required this.onSelect,
  });

  final List<SirenTrack> tracks;
  final AnimationController controller;
  final ValueChanged<SirenTrack> onSelect;

  @override
  Widget build(BuildContext context) {
    if (tracks.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            'NO LATEST ENTRIES IN CURRENT INDEX',
            style: RmText.mono(11, color: const Color(0xFF7B808A)),
          ),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final itemWidth = constraints.maxWidth < 620
            ? _latestTickerNarrowItemWidth
            : _latestTickerDesktopItemWidth;
        final cycleWidth = math.max(itemWidth, tracks.length * itemWidth);
        return ClipRect(
          child: AnimatedBuilder(
            animation: controller,
            builder: (context, child) {
              return Transform.translate(
                offset: Offset(-controller.value * cycleWidth, 0),
                child: child,
              );
            },
            child: OverflowBox(
              alignment: Alignment.centerLeft,
              minWidth: cycleWidth * 2,
              maxWidth: cycleWidth * 2,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _LatestEntries(
                    repeatIndex: 0,
                    width: cycleWidth,
                    itemWidth: itemWidth,
                    tracks: tracks,
                    onSelect: onSelect,
                  ),
                  _LatestEntries(
                    repeatIndex: 1,
                    width: cycleWidth,
                    itemWidth: itemWidth,
                    tracks: tracks,
                    onSelect: onSelect,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _LatestEntries extends StatelessWidget {
  const _LatestEntries({
    required this.repeatIndex,
    required this.width,
    required this.itemWidth,
    required this.tracks,
    required this.onSelect,
  });

  final int repeatIndex;
  final double width;
  final double itemWidth;
  final List<SirenTrack> tracks;
  final ValueChanged<SirenTrack> onSelect;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: Row(
        children: [
          for (var index = 0; index < tracks.length; index++)
            SizedBox(
              key: ValueKey('siren-latest-slot-$repeatIndex-$index'),
              width: itemWidth,
              child: Row(
                children: [
                  Expanded(
                    child: _LatestEntry(
                      track: tracks[index],
                      onTap: () => onSelect(tracks[index]),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: _latestTickerSeparatorPadding,
                    ),
                    child: Text(
                      '/',
                      style: RmText.mono(13, color: const Color(0xFF575C66)),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _LatestEntry extends StatelessWidget {
  const _LatestEntry({required this.track, required this.onTap});

  final SirenTrack track;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              flex: 3,
              child: Text(
                track.name,
                style: RmText.sans(
                  12.5,
                  color: const Color(0xFF24B347),
                  weight: FontWeight.w700,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 6),
            Flexible(
              flex: 2,
              child: Text(
                '· ${track.primaryArtist}',
                style: RmText.mono(11, color: const Color(0xFF7B808A)),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusLine extends StatelessWidget {
  const _StatusLine({
    required this.label,
    required this.value,
    this.live = false,
  });

  final String label;
  final String value;
  final bool live;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          if (live) ...[
            Container(
              width: 7,
              height: 7,
              decoration: const BoxDecoration(
                color: Color(0xFF24B347),
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 7),
          ],
          Expanded(
            child: Text(
              label,
              style: RmText.mono(
                11,
                color: const Color(0xFF747985),
                letterSpacing: 0.16 * 11,
              ),
            ),
          ),
          Text(
            value,
            style: RmText.mono(
              12,
              color: live ? Colors.white : const Color(0xFFE7E8EA),
              weight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _CatalogToolbar extends StatelessWidget {
  const _CatalogToolbar({
    required this.controller,
    required this.query,
    required this.filter,
    required this.totalCount,
    required this.visibleCount,
    required this.onQueryChanged,
    required this.onClear,
    required this.onFilterChanged,
  });

  final TextEditingController controller;
  final String query;
  final _SirenFilter filter;
  final int totalCount;
  final int visibleCount;
  final ValueChanged<String> onQueryChanged;
  final VoidCallback onClear;
  final ValueChanged<_SirenFilter> onFilterChanged;

  @override
  Widget build(BuildContext context) {
    return RmPanel(
      noPad: true,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxWidth < 820;
            final search = _SearchBox(
              controller: controller,
              query: query,
              onChanged: onQueryChanged,
              onClear: onClear,
            );
            final filters = Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                RmSegmented<_SirenFilter>(
                  value: filter,
                  onChanged: onFilterChanged,
                  options: [
                    RmSegmentedOption(value: _SirenFilter.all, label: '全部'),
                    RmSegmentedOption(
                      value: _SirenFilter.unimported,
                      label: '未加入',
                    ),
                    RmSegmentedOption(value: _SirenFilter.queued, label: '待导入'),
                    RmSegmentedOption(
                      value: _SirenFilter.imported,
                      label: '已加入',
                    ),
                    RmSegmentedOption(value: _SirenFilter.failed, label: '失败'),
                  ],
                ),
                RmChip(
                  label: '$visibleCount / $totalCount',
                  variant: RmChipVariant.muted,
                ),
              ],
            );
            if (compact) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [search, const SizedBox(height: 10), filters],
              );
            }
            return Row(
              children: [
                SizedBox(width: 360, child: search),
                const SizedBox(width: 12),
                Expanded(child: filters),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _SearchBox extends StatelessWidget {
  const _SearchBox({
    required this.controller,
    required this.query,
    required this.onChanged,
    required this.onClear,
  });

  final TextEditingController controller;
  final String query;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    return Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: rm.raised,
        border: Border.all(color: rm.border),
        borderRadius: BorderRadius.circular(RmTokens.rSm),
      ),
      child: Row(
        children: [
          RmIcon('search', size: 15, color: rm.fg3),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: controller,
              onChanged: onChanged,
              style: RmText.body(color: rm.fg),
              cursorColor: rm.accent.base,
              decoration: InputDecoration(
                border: InputBorder.none,
                isDense: true,
                hintText: '搜索 标题 / 艺人 / 专辑',
                hintStyle: RmText.body(color: rm.fg3),
              ),
            ),
          ),
          if (query.isNotEmpty)
            RmButton.icon(
              onPressed: onClear,
              icon: const RmIcon('x', size: 12),
              variant: RmButtonVariant.ghost,
              tooltip: '清空搜索',
            ),
        ],
      ),
    );
  }
}

class _AlbumRail extends StatefulWidget {
  const _AlbumRail({
    required this.albums,
    required this.tracks,
    required this.activeAlbumCid,
    required this.queuedCids,
    required this.importedCids,
    required this.onSelectAll,
    required this.onSelectAlbum,
  });

  final List<SirenAlbum> albums;
  final List<SirenTrack> tracks;
  final String? activeAlbumCid;
  final Set<String> queuedCids;
  final Set<String> importedCids;
  final VoidCallback onSelectAll;
  final ValueChanged<SirenAlbum> onSelectAlbum;

  @override
  State<_AlbumRail> createState() => _AlbumRailState();
}

class _AlbumRailState extends State<_AlbumRail> {
  final _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    final cards = [
      _AllAlbumCard(
        active: widget.activeAlbumCid == null,
        trackCount: widget.tracks.length,
        queuedCount: widget.tracks
            .where((track) => widget.queuedCids.contains(track.cid))
            .length,
        onTap: widget.onSelectAll,
      ),
      for (final album in widget.albums.take(48))
        _AlbumFilterCard(
          album: album,
          active: widget.activeAlbumCid == album.cid,
          queuedCount: widget.tracks
              .where(
                (track) =>
                    track.albumCid == album.cid &&
                    widget.queuedCids.contains(track.cid),
              )
              .length,
          importedCount: widget.tracks
              .where(
                (track) =>
                    track.albumCid == album.cid &&
                    widget.importedCids.contains(track.cid),
              )
              .length,
          onTap: () => widget.onSelectAlbum(album),
        ),
    ];
    return SizedBox(
      key: const ValueKey('siren-album-rail'),
      height: _sirenAlbumRailHeight,
      child: ScrollbarTheme(
        data: ScrollbarTheme.of(context).copyWith(
          thumbVisibility: WidgetStateProperty.all(true),
          trackVisibility: WidgetStateProperty.all(true),
          interactive: true,
          radius: const Radius.circular(999),
          thickness: WidgetStateProperty.all(6),
          thumbColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.dragged)) {
              return rm.accent.base;
            }
            if (states.contains(WidgetState.hovered)) {
              return rm.accent.base.withAlpha(184);
            }
            return rm.accent.base.withAlpha(112);
          }),
          trackColor: WidgetStateProperty.all(rm.raised),
          trackBorderColor: WidgetStateProperty.all(rm.border),
        ),
        child: Scrollbar(
          controller: _scrollController,
          thumbVisibility: true,
          trackVisibility: true,
          interactive: true,
          scrollbarOrientation: ScrollbarOrientation.bottom,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: ListView.separated(
              controller: _scrollController,
              scrollDirection: Axis.horizontal,
              itemCount: cards.length,
              separatorBuilder: (_, _) => const SizedBox(width: 10),
              itemBuilder: (_, index) => cards[index],
            ),
          ),
        ),
      ),
    );
  }
}

class _AllAlbumCard extends StatelessWidget {
  const _AllAlbumCard({
    required this.active,
    required this.trackCount,
    required this.queuedCount,
    required this.onTap,
  });

  final bool active;
  final int trackCount;
  final int queuedCount;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    return _AlbumShell(
      id: 'all',
      active: active,
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 56,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: active ? rm.fg : rm.raised,
              borderRadius: BorderRadius.circular(RmTokens.rSm),
            ),
            child: Stack(
              children: [
                Align(
                  alignment: Alignment.bottomRight,
                  child: Text(
                    'ALL',
                    style: RmText.mono(
                      22,
                      color: active ? rm.panel : rm.fg,
                      weight: FontWeight.w800,
                    ),
                  ),
                ),
                Align(
                  alignment: Alignment.topLeft,
                  child: Text(
                    '完整曲库',
                    style: RmText.mono(
                      11,
                      color: active ? rm.panel : rm.fg2,
                      letterSpacing: 0.16 * 11,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 7),
          Text(
            '全部专辑',
            style: RmText.body(weight: FontWeight.w600, color: rm.fg),
          ),
          const SizedBox(height: 2),
          Text(
            '$trackCount 首 · 待导入 $queuedCount',
            style: RmText.mono(11, color: rm.fg3),
          ),
        ],
      ),
    );
  }
}

class _AlbumFilterCard extends StatelessWidget {
  const _AlbumFilterCard({
    required this.album,
    required this.active,
    required this.queuedCount,
    required this.importedCount,
    required this.onTap,
  });

  final SirenAlbum album;
  final bool active;
  final int queuedCount;
  final int importedCount;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    return _AlbumShell(
      id: album.cid,
      active: active,
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 56,
            child: _SirenCover(
              url: album.coverUrl,
              label: album.isOst ? 'OST' : 'MSR',
              title: album.name,
              compact: true,
            ),
          ),
          const SizedBox(height: 7),
          Text(
            album.name,
            style: RmText.body(weight: FontWeight.w600, color: rm.fg),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 2),
          Text(
            '${album.trackCount} 首 · 待导入 $queuedCount · 已导入 $importedCount',
            style: RmText.mono(11, color: rm.fg3),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

class _AlbumShell extends StatefulWidget {
  const _AlbumShell({
    required this.id,
    required this.active,
    required this.onTap,
    required this.child,
  });

  final String id;
  final bool active;
  final VoidCallback onTap;
  final Widget child;

  @override
  State<_AlbumShell> createState() => _AlbumShellState();
}

class _AlbumShellState extends State<_AlbumShell> {
  var _hover = false;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          key: ValueKey('siren-album-card-${widget.id}'),
          duration: const Duration(milliseconds: 120),
          width: 150,
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: widget.active ? rm.panel : rm.raised,
            borderRadius: BorderRadius.circular(RmTokens.rMd),
            border: Border.all(
              color: widget.active
                  ? rm.fg
                  : (_hover ? rm.borderStrong : rm.border),
              width: widget.active ? 2 : 1,
            ),
          ),
          child: widget.child,
        ),
      ),
    );
  }
}

class _SongTable extends StatelessWidget {
  const _SongTable({
    required this.bodyHeight,
    required this.tracks,
    required this.sort,
    required this.queuedCids,
    required this.importedCids,
    required this.activeTrackCid,
    required this.playingCid,
    required this.playing,
    required this.playingBusyCids,
    required this.onSortChanged,
    required this.onSelectTrack,
    required this.onPlay,
    required this.onQueue,
  });

  final double bodyHeight;
  final List<SirenTrack> tracks;
  final _SirenSort sort;
  final Set<String> queuedCids;
  final Set<String> importedCids;
  final String? activeTrackCid;
  final String? playingCid;
  final bool playing;
  final Set<String> playingBusyCids;
  final ValueChanged<_SirenSort> onSortChanged;
  final ValueChanged<SirenTrack> onSelectTrack;
  final ValueChanged<SirenTrack> onPlay;
  final ValueChanged<SirenTrack> onQueue;

  @override
  Widget build(BuildContext context) {
    return RmPanel(
      key: const ValueKey('siren-song-table-panel'),
      title: '曲目',
      subtitle: tracks.isEmpty ? '没有匹配曲目' : '${tracks.length} 首可见',
      titleTrailing: const RmChip(
        label: 'MSR 来源预览',
        variant: RmChipVariant.accent,
        showDot: true,
      ),
      noPad: true,
      child: SizedBox(
        key: const ValueKey('siren-song-table-body'),
        height: bodyHeight,
        child: Column(
          children: [
            _TrackHeader(sort: sort, onSortChanged: onSortChanged),
            Expanded(
              child: tracks.isEmpty
                  ? const _EmptyTable()
                  : ListView.builder(
                      padding: EdgeInsets.zero,
                      itemCount: tracks.length,
                      itemBuilder: (context, index) {
                        final track = tracks[index];
                        return _TrackRow(
                          key: ValueKey('siren-track-row-${track.cid}'),
                          track: track,
                          active: activeTrackCid == track.cid,
                          queued: queuedCids.contains(track.cid),
                          imported: importedCids.contains(track.cid),
                          playing: playingCid == track.cid && playing,
                          playBusy: playingBusyCids.contains(track.cid),
                          onSelect: () => onSelectTrack(track),
                          onPlay: () => onPlay(track),
                          onQueue: () => onQueue(track),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

const double _trackTableGap = 10;
const double _trackActionsWidth = 164;
const double _trackPlayButtonWidth = 38;
const double _trackQueueButtonWidth = 116;
const double _trackActionGap = 10;
const double _trackTitleTextInset = 38.5;

class _TrackHeader extends StatelessWidget {
  const _TrackHeader({required this.sort, required this.onSortChanged});

  final _SirenSort sort;
  final ValueChanged<_SirenSort> onSortChanged;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    Text header(String label) => Text(
      label,
      style: RmText.mono(10.5, color: rm.fg3, letterSpacing: 0.12 * 10.5),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
    return Container(
      height: _trackHeaderHeight,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: rm.border)),
      ),
      child: Row(
        children: [
          Expanded(
            flex: 7,
            child: _TrackHeaderSortButton(
              key: const ValueKey('siren-track-sort-title'),
              label: '标题',
              leftPadding: _trackTitleTextInset,
              textKey: const ValueKey('siren-track-title-header-text'),
              active: sort == _SirenSort.title,
              onTap: () => onSortChanged(_SirenSort.title),
            ),
          ),
          const SizedBox(width: _trackTableGap),
          Expanded(
            flex: 5,
            child: _TrackHeaderSortButton(
              key: const ValueKey('siren-track-sort-artist'),
              label: '艺人',
              textKey: const ValueKey('siren-track-artist-header-text'),
              active: sort == _SirenSort.artist,
              onTap: () => onSortChanged(_SirenSort.artist),
            ),
          ),
          const SizedBox(width: _trackTableGap),
          Expanded(
            flex: 8,
            child: _TrackHeaderSortButton(
              key: const ValueKey('siren-track-sort-album'),
              label: '专辑',
              active: sort == _SirenSort.album,
              onTap: () => onSortChanged(_SirenSort.album),
            ),
          ),
          const SizedBox(width: _trackTableGap),
          SizedBox(
            key: const ValueKey('siren-track-actions-header'),
            width: _trackActionsWidth,
            child: Center(child: header('操作')),
          ),
        ],
      ),
    );
  }
}

class _TrackHeaderSortButton extends StatefulWidget {
  const _TrackHeaderSortButton({
    super.key,
    required this.label,
    required this.active,
    required this.onTap,
    this.leftPadding = 0,
    this.textKey,
  });

  final String label;
  final bool active;
  final VoidCallback onTap;
  final double leftPadding;
  final Key? textKey;

  @override
  State<_TrackHeaderSortButton> createState() => _TrackHeaderSortButtonState();
}

class _TrackHeaderSortButtonState extends State<_TrackHeaderSortButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    final color = widget.active ? rm.accent.base : (_hover ? rm.fg2 : rm.fg3);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: SizedBox.expand(
          child: Padding(
            padding: EdgeInsets.only(left: widget.leftPadding),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      key: widget.textKey,
                      widget.label,
                      style: RmText.mono(
                        10.5,
                        color: color,
                        weight: widget.active
                            ? FontWeight.w700
                            : FontWeight.w500,
                        letterSpacing: 0.12 * 10.5,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (widget.active) ...[
                    const SizedBox(width: 6),
                    Container(
                      width: 4,
                      height: 4,
                      decoration: BoxDecoration(
                        color: rm.accent.base,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TrackRow extends StatefulWidget {
  const _TrackRow({
    super.key,
    required this.track,
    required this.active,
    required this.queued,
    required this.imported,
    required this.playing,
    required this.playBusy,
    required this.onSelect,
    required this.onPlay,
    required this.onQueue,
  });

  final SirenTrack track;
  final bool active;
  final bool queued;
  final bool imported;
  final bool playing;
  final bool playBusy;
  final VoidCallback onSelect;
  final VoidCallback onPlay;
  final VoidCallback onQueue;

  @override
  State<_TrackRow> createState() => _TrackRowState();
}

class _TrackRowState extends State<_TrackRow> {
  var _hover = false;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    final rowBg = widget.active
        ? rm.accent.bg
        : (_hover ? rm.raised : Colors.transparent);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onSelect,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          constraints: const BoxConstraints(minHeight: _trackRowHeight),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: rowBg,
            border: Border(bottom: BorderSide(color: rm.border)),
          ),
          child: Row(
            children: [
              Expanded(flex: 7, child: _TrackTitleBlock(track: widget.track)),
              const SizedBox(width: _trackTableGap),
              Expanded(flex: 5, child: _TrackArtistCell(track: widget.track)),
              const SizedBox(width: _trackTableGap),
              Expanded(
                flex: 8,
                child: Text(
                  widget.track.albumName,
                  style: RmText.body(color: rm.fg2),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: _trackTableGap),
              SizedBox(
                key: ValueKey('siren-track-actions-${widget.track.cid}'),
                width: _trackActionsWidth,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    SizedBox(
                      width: _trackPlayButtonWidth,
                      child: RmButton.icon(
                        onPressed: widget.playBusy ? null : widget.onPlay,
                        icon: RmIcon(
                          widget.playing ? 'pause' : 'play',
                          size: 12,
                        ),
                        variant: widget.playing
                            ? RmButtonVariant.primary
                            : RmButtonVariant.defaultBtn,
                        tooltip: widget.playBusy
                            ? '正在打开音频'
                            : (widget.playing ? '暂停试听' : '在线试听'),
                      ),
                    ),
                    const SizedBox(width: _trackActionGap),
                    SizedBox(
                      width: _trackQueueButtonWidth,
                      child: RmButton(
                        onPressed: widget.imported ? null : widget.onQueue,
                        size: RmButtonSize.sm,
                        variant: widget.imported || widget.queued
                            ? RmButtonVariant.defaultBtn
                            : RmButtonVariant.primary,
                        label: widget.imported
                            ? '已导入'
                            : widget.queued
                            ? '待导入'
                            : '加入清单',
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TrackTitleBlock extends StatelessWidget {
  const _TrackTitleBlock({required this.track});

  final SirenTrack track;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            const _SourceBadge(),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                key: ValueKey('siren-track-title-text-${track.cid}'),
                track.name,
                style: RmText.rowTitle(color: rm.fg),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _TrackArtistCell extends StatelessWidget {
  const _TrackArtistCell({required this.track});

  final SirenTrack track;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    return Text(
      key: ValueKey('siren-track-artist-text-${track.cid}'),
      track.artistDisplayText,
      style: RmText.body(color: rm.fg2),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}

class _ImportSidePanel extends StatelessWidget {
  const _ImportSidePanel({
    super.key,
    required this.queuedTracks,
    required this.queueImporting,
    required this.batchTotal,
    required this.importingCount,
    required this.failedCount,
    required this.selectedTrack,
    required this.selectedAlbum,
    required this.selectedAlbumDetail,
    required this.selectedTrackDetail,
    required this.queuedCids,
    required this.importedCids,
    required this.importingCids,
    required this.trackErrors,
    required this.onRemoveQueued,
    required this.onClearQueue,
    required this.importQueuedTooltip,
    required this.onImportQueued,
    required this.onPlayTrack,
    required this.onQueueTrack,
  });

  final List<SirenTrack> queuedTracks;
  final bool queueImporting;
  final int batchTotal;
  final int importingCount;
  final int failedCount;
  final SirenTrack? selectedTrack;
  final SirenAlbum? selectedAlbum;
  final AsyncValue<SirenAlbumDetail>? selectedAlbumDetail;
  final AsyncValue<SirenSongDetail>? selectedTrackDetail;
  final Set<String> queuedCids;
  final Set<String> importedCids;
  final Set<String> importingCids;
  final Map<String, String> trackErrors;
  final ValueChanged<String> onRemoveQueued;
  final VoidCallback? onClearQueue;
  final String? importQueuedTooltip;
  final VoidCallback? onImportQueued;
  final VoidCallback? onPlayTrack;
  final VoidCallback? onQueueTrack;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _QueuePanel(
          queuedTracks: queuedTracks,
          importing: queueImporting,
          batchTotal: batchTotal,
          importingCount: importingCount,
          failedCount: failedCount,
          onRemoveQueued: onRemoveQueued,
          onClearQueue: onClearQueue,
          importTooltip: importQueuedTooltip,
          onImportQueued: onImportQueued,
        ),
        const SizedBox(height: 16),
        _TrackInspector(
          track: selectedTrack,
          album: selectedAlbum,
          albumDetail: selectedAlbumDetail,
          trackDetail: selectedTrackDetail,
          queued: selectedTrack == null
              ? false
              : queuedCids.contains(selectedTrack!.cid),
          imported: selectedTrack == null
              ? false
              : importedCids.contains(selectedTrack!.cid),
          importing: selectedTrack == null
              ? false
              : queueImporting && importingCids.contains(selectedTrack!.cid),
          error: selectedTrack == null ? null : trackErrors[selectedTrack!.cid],
          onPlayTrack: onPlayTrack,
          onQueueTrack: onQueueTrack,
        ),
      ],
    );
  }
}

class _QueuePanel extends StatelessWidget {
  const _QueuePanel({
    required this.queuedTracks,
    required this.importing,
    required this.batchTotal,
    required this.importingCount,
    required this.failedCount,
    required this.onRemoveQueued,
    required this.onClearQueue,
    required this.importTooltip,
    required this.onImportQueued,
  });

  final List<SirenTrack> queuedTracks;
  final bool importing;
  final int batchTotal;
  final int importingCount;
  final int failedCount;
  final ValueChanged<String> onRemoveQueued;
  final VoidCallback? onClearQueue;
  final String? importTooltip;
  final VoidCallback? onImportQueued;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    return RmPanel(
      noPad: true,
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: rm.border)),
            ),
            child: Row(
              children: [
                Text(
                  '待导入清单',
                  style: RmText.body(weight: FontWeight.w600, color: rm.fg),
                ),
                const SizedBox(width: 12),
                Text(
                  '${queuedTracks.length} 项',
                  style: RmText.sans(12, color: rm.fg3),
                ),
                const Spacer(),
                RmButton(
                  onPressed: importing ? null : onImportQueued,
                  size: RmButtonSize.sm,
                  variant: RmButtonVariant.primary,
                  leading: const RmIcon('import', size: 12),
                  label: importing ? '导入中' : '导入全部',
                  tooltip: importTooltip,
                ),
                const SizedBox(width: 8),
                RmButton(
                  onPressed: importing ? null : onClearQueue,
                  size: RmButtonSize.sm,
                  variant: RmButtonVariant.ghost,
                  label: '清空',
                ),
              ],
            ),
          ),
          PendingGate(
            pending: importing,
            overlayKey: const ValueKey('siren-importing-queue-overlay'),
            label: '正在导入清单',
            detailWidget: _QueueProgressDetail(
              batchTotal: batchTotal,
              importingCount: importingCount,
              failedCount: failedCount,
            ),
            compact: true,
            borderRadius: BorderRadius.zero,
            childOpacity: 0.46,
            child: SizedBox(
              key: const ValueKey('siren-queue-list'),
              height: _queuePanelListHeight,
              child: queuedTracks.isEmpty
                  ? const _EmptyQueue()
                  : ListView.separated(
                      padding: const EdgeInsets.all(12),
                      itemCount: queuedTracks.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (context, index) {
                        final track = queuedTracks[index];
                        return _QueueItem(
                          track: track,
                          onRemove: importing
                              ? null
                              : () => onRemoveQueued(track.cid),
                        );
                      },
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

const double _queuePanelListHeight = 224;

String _queueProgressText({
  required int batchTotal,
  required int importingCount,
  required int failedCount,
}) {
  final total = math.max(1, batchTotal);
  final completed = (batchTotal - importingCount).clamp(0, total);
  final failed = failedCount.clamp(0, total);
  final succeeded = math.max(0, completed - failed);
  if (failed <= 0) return '成功 $succeeded/$total';
  return '成功 $succeeded/$total · 失败 $failed';
}

class _QueueProgressDetail extends StatelessWidget {
  const _QueueProgressDetail({
    required this.batchTotal,
    required this.importingCount,
    required this.failedCount,
  });

  final int batchTotal;
  final int importingCount;
  final int failedCount;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    final total = math.max(1, batchTotal);
    final completed = (batchTotal - importingCount).clamp(0, total);
    final failed = failedCount.clamp(0, total);
    final succeeded = math.max(0, completed - failed);
    final label = _queueProgressText(
      batchTotal: batchTotal,
      importingCount: importingCount,
      failedCount: failedCount,
    );
    final baseStyle = RmText.sans(11, color: rm.fg3, weight: FontWeight.w600);
    final successStyle = RmText.sans(
      11,
      color: rm.accent.base,
      weight: FontWeight.w700,
    );
    final failureStyle = RmText.sans(
      11,
      color: rm.warn,
      weight: FontWeight.w700,
    );
    return Semantics(
      key: const ValueKey('siren-import-queue-progress'),
      label: label,
      child: ExcludeSemantics(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('成功 ', style: baseStyle),
            Text('$succeeded', style: successStyle),
            Text('/$total', style: baseStyle),
            if (failed > 0) ...[
              Text(' · 失败 ', style: baseStyle),
              Text('$failed', style: failureStyle),
            ],
          ],
        ),
      ),
    );
  }
}

class _QueueItem extends StatelessWidget {
  const _QueueItem({required this.track, required this.onRemove});

  final SirenTrack track;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
      decoration: BoxDecoration(
        color: rm.accent.bg,
        border: Border.all(color: rm.accent.ring),
        borderRadius: BorderRadius.circular(RmTokens.rSm),
      ),
      child: Row(
        children: [
          RmIcon('drag', size: 12, color: rm.fg4),
          const SizedBox(width: 8),
          const _SourceBadge(),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  track.name,
                  style: RmText.sans(
                    12.5,
                    weight: FontWeight.w500,
                    color: rm.accent.base,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  '${track.albumName} · ${track.artistDisplayText}',
                  style: RmText.sans(11, color: rm.fg3),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          RmButton.icon(
            onPressed: onRemove,
            icon: const RmIcon('x', size: 12),
            variant: RmButtonVariant.ghost,
            tooltip: onRemove == null ? '正在导入' : '移出清单',
          ),
        ],
      ),
    );
  }
}

class _TrackInspector extends StatelessWidget {
  const _TrackInspector({
    required this.track,
    required this.album,
    required this.albumDetail,
    required this.trackDetail,
    required this.queued,
    required this.imported,
    required this.importing,
    required this.error,
    required this.onPlayTrack,
    required this.onQueueTrack,
  });

  final SirenTrack? track;
  final SirenAlbum? album;
  final AsyncValue<SirenAlbumDetail>? albumDetail;
  final AsyncValue<SirenSongDetail>? trackDetail;
  final bool queued;
  final bool imported;
  final bool importing;
  final String? error;
  final VoidCallback? onPlayTrack;
  final VoidCallback? onQueueTrack;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    final track = this.track;
    final album = this.album;
    return RmPanel(
      title: '选中曲目',
      subtitle: track == null ? '未选择' : track.albumName,
      child: track == null
          ? const _EmptyInspector()
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 74,
                      height: 74,
                      child: _SirenCover(
                        url: track.coverUrl,
                        label: track.albumIsOst ? 'OST' : 'MSR',
                        title: track.albumName,
                        compact: true,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            track.name,
                            style: RmText.panelTitle(color: context.rm.fg),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            track.primaryArtist,
                            style: RmText.body(color: context.rm.fg2),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              const RmChip(
                                label: 'MSR 来源预览',
                                variant: RmChipVariant.accent,
                                showDot: true,
                              ),
                              RmChip(
                                label: imported
                                    ? '已导入'
                                    : queued
                                    ? '待导入'
                                    : '未加入',
                                variant: imported
                                    ? RmChipVariant.accent
                                    : queued
                                    ? RmChipVariant.info
                                    : RmChipVariant.muted,
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                _InspectorKv(label: '专辑', value: track.albumName),
                const _InspectorKv(label: '来源标识', value: 'Monster Siren'),
                _TrackDetailBlock(detail: trackDetail),
                if (error != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    error!,
                    style: RmText.sans(12, color: rm.warn, height: 1.35),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    RmButton(
                      onPressed: onPlayTrack,
                      size: RmButtonSize.sm,
                      leading: const RmIcon('play', size: 12),
                      label: '试听',
                    ),
                    RmButton(
                      onPressed: imported || importing ? null : onQueueTrack,
                      size: RmButtonSize.sm,
                      variant: RmButtonVariant.primary,
                      label: imported
                          ? '已导入'
                          : importing
                          ? '导入中'
                          : queued
                          ? '已在清单'
                          : '加入清单',
                    ),
                  ],
                ),
                if (album != null || albumDetail != null) ...[
                  const SizedBox(height: 12),
                  _AlbumDetailPreview(album: album, detail: albumDetail),
                ],
              ],
            ),
    );
  }
}

class _TrackDetailBlock extends StatelessWidget {
  const _TrackDetailBlock({required this.detail});

  final AsyncValue<SirenSongDetail>? detail;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    final value = detail;
    if (value == null) {
      return _InspectorKv(label: '音源详情', value: '尚未加载');
    }
    return value.when(
      loading: () => _InspectorKv(label: '音源详情', value: '加载中'),
      error: (error, _) => Text(
        '详情失败：$error',
        style: RmText.sans(13, color: rm.warn, height: 1.35),
      ),
      data: (data) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _InspectorKv(
            label: '音源',
            value: '${data.sourceExtension} · ${data.sourceHost}',
          ),
          _InspectorKv(
            label: '歌词 / MV',
            value:
                '${data.hasLyric ? '有歌词' : '无歌词'} · ${data.hasMv ? '有 MV' : '无 MV'}',
          ),
        ],
      ),
    );
  }
}

class _AlbumDetailPreview extends StatelessWidget {
  const _AlbumDetailPreview({required this.album, required this.detail});

  final SirenAlbum? album;
  final AsyncValue<SirenAlbumDetail>? detail;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    final value = detail;
    if (value == null) {
      return Text(
        album == null ? '' : '${album!.name} · 专辑信息尚未加载',
        style: RmText.mono(11, color: rm.fg3),
      );
    }
    return value.when(
      loading: () => Text('专辑信息加载中', style: RmText.mono(11, color: rm.info)),
      error: (error, _) => Text(
        '专辑详情失败：$error',
        style: RmText.sans(13, color: rm.warn, height: 1.35),
      ),
      data: (data) => Text(
        data.intro.isEmpty
            ? '${data.name} · ${data.songs.length} 首曲目'
            : data.intro,
        style: RmText.sans(13, color: rm.fg2, height: 1.4),
        maxLines: 4,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

class _InspectorKv extends StatelessWidget {
  const _InspectorKv({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 86,
            child: Text(label, style: RmText.mono(10.5, color: rm.fg3)),
          ),
          Expanded(
            child: Text(
              value,
              style: RmText.mono(11, color: rm.fg2),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyTable extends StatelessWidget {
  const _EmptyTable();

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          RmIcon('search', size: 24, color: rm.fg3),
          const SizedBox(height: 10),
          Text('没有匹配曲目', style: RmText.emptyTitle(color: rm.fg)),
          const SizedBox(height: 4),
          Text('调整搜索、状态或专辑筛选', style: RmText.body(color: rm.fg3)),
        ],
      ),
    );
  }
}

class _EmptyQueue extends StatelessWidget {
  const _EmptyQueue();

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            RmIcon('import', size: 24, color: rm.fg3),
            const SizedBox(height: 10),
            Text('清单为空', style: RmText.emptyTitle(color: rm.fg)),
            const SizedBox(height: 4),
            Text(
              '从曲目列表加入后，可在这里确认并导入。',
              textAlign: TextAlign.center,
              style: RmText.body(color: rm.fg3),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyInspector extends StatelessWidget {
  const _EmptyInspector();

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 34),
      child: Column(
        children: [
          RmIcon('music', size: 22, color: rm.fg3),
          const SizedBox(height: 10),
          Text('选择一首歌查看详情', style: RmText.body(color: rm.fg3)),
        ],
      ),
    );
  }
}

class _SirenCover extends StatelessWidget {
  const _SirenCover({
    required this.url,
    required this.label,
    required this.title,
    this.compact = false,
  });

  final String url;
  final String label;
  final String title;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final color = _colorFromText(label);
    final showSourceMark = !compact;
    final showCornerLabel = label.isNotEmpty && (!compact || label == 'OST');
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(RmTokens.rSm),
        border: Border.all(color: Colors.black.withAlpha(28)),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(RmTokens.rSm),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (url.isNotEmpty)
              Image.network(
                url,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => const SizedBox.shrink(),
              ),
            CustomPaint(
              painter: _SirenStripePainter(
                color: Colors.white,
                opacity: url.isEmpty ? 0.10 : 0.05,
                step: 12,
              ),
            ),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Colors.black.withAlpha(url.isEmpty ? 0 : 35),
                    Colors.black.withAlpha(url.isEmpty ? 28 : 90),
                  ],
                ),
              ),
            ),
            if (showSourceMark)
              Positioned(
                left: 10,
                top: 9,
                child: Text(
                  'MSR',
                  style: RmText.mono(
                    compact ? 10 : 12,
                    color: Colors.white,
                    weight: FontWeight.w800,
                  ),
                ),
              ),
            if (showCornerLabel)
              Positioned(
                right: 10,
                bottom: 8,
                child: Text(
                  label,
                  style: RmText.mono(
                    compact ? 10.5 : 12,
                    color: Colors.white,
                    weight: FontWeight.w800,
                  ),
                ),
              ),
            if (!compact)
              Positioned(
                left: 10,
                right: 10,
                bottom: 28,
                child: Text(
                  title,
                  style: RmText.sans(
                    13,
                    color: Colors.white,
                    weight: FontWeight.w700,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _SourceBadge extends StatelessWidget {
  const _SourceBadge();

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: rm.accent.bg,
        border: Border.all(color: rm.accent.ring),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        'MSR',
        style: RmText.mono(9.5, color: rm.accent.base, weight: FontWeight.w800),
      ),
    );
  }
}

class _DarkTag extends StatelessWidget {
  const _DarkTag(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withAlpha(70),
        border: Border.all(color: const Color(0xFF3A3F47)),
      ),
      child: Text(
        label,
        style: RmText.mono(
          11,
          color: Colors.white,
          weight: FontWeight.w700,
          letterSpacing: 0.16 * 11,
        ),
      ),
    );
  }
}

class _MonsterSirenMark extends StatelessWidget {
  const _MonsterSirenMark({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: Colors.black,
        border: Border.all(color: Colors.white, width: 1.5),
      ),
      child: ClipRect(
        child: Stack(
          fit: StackFit.expand,
          children: [
            Padding(
              padding: const EdgeInsets.all(4),
              child: Image.asset(
                'assets/images/monster_siren_share_logo.png',
                fit: BoxFit.contain,
                filterQuality: FilterQuality.medium,
              ),
            ),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withAlpha(0),
                    Colors.black.withAlpha(18),
                  ],
                ),
              ),
            ),
            CustomPaint(
              painter: const _MonsterSirenFramePainter(
                accent: Color(0xFF24B347),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MonsterSirenFramePainter extends CustomPainter {
  const _MonsterSirenFramePainter({required this.accent});

  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    final accentPaint = Paint()
      ..color = accent
      ..strokeWidth = 1.8
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.square;
    final ghostPaint = Paint()
      ..color = Colors.white.withAlpha(34)
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;

    final inset = size.width * 0.18;
    final span = size.width * 0.22;
    final path = Path()
      ..moveTo(inset, inset + span)
      ..lineTo(inset, inset)
      ..lineTo(inset + span, inset);
    canvas.drawPath(path, accentPaint);

    final opposite = Path()
      ..moveTo(size.width - inset - span, size.height - inset)
      ..lineTo(size.width - inset, size.height - inset)
      ..lineTo(size.width - inset, size.height - inset - span);
    canvas.drawPath(opposite, accentPaint);

    canvas.drawLine(
      Offset(inset + span + 3, inset),
      Offset(inset + span + 10, inset + 8),
      ghostPaint,
    );
    canvas.drawLine(
      Offset(size.width - inset - span - 3, size.height - inset),
      Offset(size.width - inset - span - 10, size.height - inset - 8),
      ghostPaint,
    );
  }

  @override
  bool shouldRepaint(covariant _MonsterSirenFramePainter oldDelegate) {
    return oldDelegate.accent != accent;
  }
}

class _SirenStripePainter extends CustomPainter {
  const _SirenStripePainter({
    required this.color,
    required this.opacity,
    required this.step,
  });

  final Color color;
  final double opacity;
  final double step;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color.withAlpha((opacity * 255).round())
      ..strokeWidth = 1;
    final limit = size.width + size.height;
    for (double offset = -size.height; offset < limit; offset += step) {
      canvas.drawLine(
        Offset(offset, size.height),
        Offset(offset + size.height, 0),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _SirenStripePainter oldDelegate) {
    return oldDelegate.color != color ||
        oldDelegate.opacity != opacity ||
        oldDelegate.step != step;
  }
}

class _SirenLoading extends StatelessWidget {
  const _SirenLoading();

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, viewport) {
        final edgePadding = viewport.maxWidth < 900
            ? _sirenPageNarrowPadding
            : _sirenPageWidePadding;
        final contentWidth = math.min(
          _sirenPageMaxWidth,
          math.max(0.0, viewport.maxWidth - edgePadding * 2),
        );
        final horizontalInset = math.max(
          edgePadding,
          (viewport.maxWidth - contentWidth) / 2,
        );

        return CustomScrollView(
          key: const ValueKey('siren-loading'),
          slivers: [
            SliverPadding(
              padding: EdgeInsets.fromLTRB(
                horizontalInset,
                32,
                horizontalInset,
                64,
              ),
              sliver: SliverToBoxAdapter(
                child: Semantics(
                  label: '塞壬唱片索引初始化中',
                  child: const Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _SirenLoadingHero(),
                      SizedBox(height: 16),
                      _SirenLoadingToolbar(),
                      SizedBox(height: 14),
                      _SirenLoadingAlbumRail(),
                      SizedBox(height: 28),
                      _SirenLoadingWorkspace(),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _SirenLoadingHero extends StatelessWidget {
  const _SirenLoadingHero();

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 252),
      decoration: BoxDecoration(
        color: const Color(0xFF0B0C0E),
        borderRadius: BorderRadius.circular(RmTokens.rLg),
        border: Border.all(color: const Color(0xFF272A30)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(20),
            blurRadius: 30,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(RmTokens.rLg),
        child: Stack(
          children: [
            Positioned.fill(
              child: CustomPaint(
                painter: _SirenStripePainter(
                  color: Colors.white,
                  opacity: 0.035,
                  step: 16,
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 43,
              height: 1,
              child: ColoredBox(color: Colors.white.withAlpha(28)),
            ),
            const Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: _SirenLoadingTicker(),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(28, 24, 28, 68),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final compact = constraints.maxWidth < 680;
                  const title = _SirenLoadingTitle();
                  const status = _SirenLoadingStatusCard();
                  if (compact) {
                    return const Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [title, SizedBox(height: 18), status],
                    );
                  }
                  return const Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: title),
                      SizedBox(width: 24),
                      SizedBox(width: 290, child: status),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SirenLoadingTitle extends StatelessWidget {
  const _SirenLoadingTitle();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            const _DarkTag('MSR · CATALOG ARCHIVE'),
            Text(
              'RADIOMOD · IMPORT BRIDGE',
              style: RmText.mono(
                11,
                color: const Color(0xFF6F737C),
                letterSpacing: 0.18 * 11,
              ),
            ),
          ],
        ),
        const SizedBox(height: 18),
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            const _SirenLoadingMark(size: 60),
            const SizedBox(width: 18),
            Flexible(
              child: RichText(
                text: TextSpan(
                  children: [
                    TextSpan(
                      text: '塞壬',
                      style: RmText.sans(
                        42,
                        color: Colors.white,
                        weight: FontWeight.w800,
                        height: 1,
                      ),
                    ),
                    TextSpan(
                      text: '唱片',
                      style: RmText.sans(
                        42,
                        color: const Color(0xFF24B347),
                        weight: FontWeight.w800,
                        height: 1,
                      ),
                    ),
                  ],
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 14,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Container(width: 34, height: 2, color: const Color(0xFF24B347)),
            Text(
              'CATALOG · ARCHIVE · IMPORT',
              style: RmText.mono(
                13,
                color: const Color(0xFFE8E8EA),
                weight: FontWeight.w700,
                letterSpacing: 0.18 * 13,
              ),
            ),
            Text(
              'INDEX WARMUP',
              style: RmText.mono(11, color: const Color(0xFF7B808A)),
            ),
          ],
        ),
      ],
    );
  }
}

class _SirenLoadingStatusCard extends StatelessWidget {
  const _SirenLoadingStatusCard();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.black.withAlpha(52),
        border: Border.all(color: const Color(0xFF2E333A)),
        borderRadius: BorderRadius.circular(RmTokens.rMd),
      ),
      child: Column(
        children: const [
          _StatusLine(label: 'SOURCE', value: 'CDN · LIVE', live: true),
          _StatusLine(label: 'SCAN', value: 'INIT'),
          _StatusLine(label: 'ALBUMS', value: '--'),
          _StatusLine(label: 'VISIBLE', value: '-- / --'),
          _StatusLine(label: 'QUEUE', value: 'STANDBY'),
          SizedBox(height: 12),
          _SirenLoadingMeter(),
        ],
      ),
    );
  }
}

class _SirenLoadingMark extends StatelessWidget {
  const _SirenLoadingMark({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: Colors.black,
        border: Border.all(color: Colors.white, width: 1.5),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          CustomPaint(
            painter: _SirenStripePainter(
              color: Colors.white,
              opacity: 0.045,
              step: 10,
            ),
          ),
          Center(
            child: Text(
              'MSR',
              style: RmText.mono(
                13,
                color: Colors.white,
                weight: FontWeight.w800,
                letterSpacing: 0.08 * 13,
              ),
            ),
          ),
          Positioned.fill(
            child: CustomPaint(
              painter: const _MonsterSirenFramePainter(
                accent: Color(0xFF24B347),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SirenLoadingMeter extends StatelessWidget {
  const _SirenLoadingMeter();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(999),
          child: Stack(
            children: [
              Container(height: 4, color: Colors.white.withAlpha(26)),
              FractionallySizedBox(
                widthFactor: 0.42,
                child: Container(height: 4, color: const Color(0xFF24B347)),
              ),
            ],
          ),
        ),
        const SizedBox(height: 9),
        Text(
          'READING MANIFEST',
          textAlign: TextAlign.right,
          style: RmText.mono(
            10.5,
            color: const Color(0xFF747985),
            letterSpacing: 0.16 * 10.5,
          ),
        ),
      ],
    );
  }
}

class _SirenLoadingTicker extends StatelessWidget {
  const _SirenLoadingTicker();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 43,
      color: const Color(0xFF0B0C0E),
      child: Stack(
        children: [
          Positioned.fill(
            child: CustomPaint(
              painter: _SirenStripePainter(
                color: Colors.white,
                opacity: 0.025,
                step: 14,
              ),
            ),
          ),
          Row(
            children: [
              Container(
                width: 124,
                height: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                decoration: BoxDecoration(
                  border: Border(
                    right: BorderSide(color: Colors.white.withAlpha(22)),
                  ),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        border: Border.all(color: const Color(0xFF24B347)),
                      ),
                      child: Center(
                        child: Container(
                          width: 3,
                          height: 3,
                          color: const Color(0xFF24B347),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      'LATEST',
                      style: RmText.mono(
                        11,
                        color: const Color(0xFF24B347),
                        weight: FontWeight.w800,
                        letterSpacing: 0.22 * 11,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                  child: Text(
                    'monster-siren.hypergryph.com/music · albums / songs · waiting for manifest',
                    style: RmText.mono(11, color: const Color(0xFF7B808A)),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SirenLoadingToolbar extends StatelessWidget {
  const _SirenLoadingToolbar();

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: rm.panel,
        border: Border.all(color: rm.border),
        borderRadius: BorderRadius.circular(RmTokens.rLg),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 720;
          final search = _SirenLoadingBlock(
            height: 36,
            width: compact ? double.infinity : 360,
          );
          final filters = Row(
            children: [
              for (final width in const [54.0, 62.0, 62.0, 62.0])
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: _SirenLoadingBlock(height: 28, width: width),
                ),
              const _SirenLoadingBlock(height: 24, width: 56, rounded: true),
            ],
          );
          if (compact) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [search, const SizedBox(height: 10), filters],
            );
          }
          return Row(
            children: [
              search,
              const SizedBox(width: 12),
              Expanded(child: filters),
            ],
          );
        },
      ),
    );
  }
}

class _SirenLoadingAlbumRail extends StatelessWidget {
  const _SirenLoadingAlbumRail();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: _sirenAlbumCardHeight,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: 6,
        separatorBuilder: (_, _) => const SizedBox(width: 10),
        itemBuilder: (context, index) =>
            _SirenLoadingAlbumCard(active: index == 0),
      ),
    );
  }
}

class _SirenLoadingAlbumCard extends StatelessWidget {
  const _SirenLoadingAlbumCard({required this.active});

  final bool active;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    return Container(
      width: 150,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: rm.panel,
        borderRadius: BorderRadius.circular(RmTokens.rMd),
        border: Border.all(
          color: active ? rm.fg : rm.border,
          width: active ? 2 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SirenLoadingBlock(height: 56, width: double.infinity),
          const SizedBox(height: 10),
          _SirenLoadingBlock(height: 13, width: active ? 86 : 112, dark: true),
          const SizedBox(height: 8),
          const _SirenLoadingBlock(height: 11, width: 92),
        ],
      ),
    );
  }
}

class _SirenLoadingWorkspace extends StatelessWidget {
  const _SirenLoadingWorkspace();

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 920;
        final table = _SirenLoadingPanel(
          flexLines: compact ? 7 : 8,
          titleWidth: 86,
          trailingWidth: 120,
        );
        final side = _SirenLoadingPanel(
          flexLines: compact ? 4 : 6,
          titleWidth: 92,
          trailingWidth: 72,
        );
        if (compact) {
          return Column(children: [table, const SizedBox(height: 16), side]);
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: table),
            const SizedBox(width: 16),
            SizedBox(width: 330, child: side),
          ],
        );
      },
    );
  }
}

class _SirenLoadingPanel extends StatelessWidget {
  const _SirenLoadingPanel({
    required this.flexLines,
    required this.titleWidth,
    required this.trailingWidth,
  });

  final int flexLines;
  final double titleWidth;
  final double trailingWidth;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    return Container(
      decoration: BoxDecoration(
        color: rm.panel,
        border: Border.all(color: rm.border),
        borderRadius: BorderRadius.circular(RmTokens.rLg),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
            child: Row(
              children: [
                _SirenLoadingBlock(height: 16, width: titleWidth, dark: true),
                const SizedBox(width: 14),
                const _SirenLoadingBlock(height: 24, width: 88, rounded: true),
                const Spacer(),
                _SirenLoadingBlock(height: 28, width: trailingWidth),
              ],
            ),
          ),
          Divider(height: 1, color: rm.border),
          Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              children: [
                for (var index = 0; index < flexLines; index++) ...[
                  _SirenLoadingRow(index: index),
                  if (index != flexLines - 1) const SizedBox(height: 12),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SirenLoadingRow extends StatelessWidget {
  const _SirenLoadingRow({required this.index});

  final int index;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const _SirenLoadingBlock(height: 24, width: 42, rounded: true),
        const SizedBox(width: 12),
        Expanded(
          flex: 5,
          child: _SirenLoadingBlock(
            height: 14,
            width: double.infinity,
            dark: index.isEven,
          ),
        ),
        const SizedBox(width: 18),
        Expanded(
          flex: 4,
          child: _SirenLoadingBlock(
            height: 14,
            width: double.infinity,
            dark: index % 3 == 0,
          ),
        ),
        const SizedBox(width: 18),
        const _SirenLoadingBlock(height: 30, width: 96),
      ],
    );
  }
}

class _SirenLoadingBlock extends StatelessWidget {
  const _SirenLoadingBlock({
    required this.height,
    required this.width,
    this.rounded = false,
    this.dark = false,
  });

  final double height;
  final double width;
  final bool rounded;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: dark ? rm.fg.withAlpha(20) : rm.raised,
        border: Border.all(
          color: dark ? rm.borderStrong.withAlpha(120) : rm.border,
        ),
        borderRadius: BorderRadius.circular(rounded ? 999 : RmTokens.rSm),
      ),
      child: dark
          ? ClipRRect(
              borderRadius: BorderRadius.circular(rounded ? 999 : RmTokens.rSm),
              child: CustomPaint(
                painter: _SirenStripePainter(
                  color: rm.fg,
                  opacity: 0.025,
                  step: 10,
                ),
              ),
            )
          : null,
    );
  }
}

class _SirenLoadError extends StatelessWidget {
  const _SirenLoadError({required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final rm = context.rm;
    return Center(
      child: SizedBox(
        width: 520,
        child: RmPanel(
          title: '塞壬唱片暂时不可用',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '$error',
                style: RmText.sans(13, color: rm.warn, height: 1.4),
              ),
              const SizedBox(height: 14),
              RmButton(
                onPressed: onRetry,
                variant: RmButtonVariant.primary,
                leading: const RmIcon('refresh', size: 12),
                label: '重新请求',
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Color _colorFromText(String text) {
  var hash = 0;
  for (final unit in text.codeUnits) {
    hash = 0x1fffffff & (hash + unit);
    hash = 0x1fffffff & (hash + ((0x0007ffff & hash) << 10));
    hash ^= hash >> 6;
  }
  final hue = (hash % 360).toDouble();
  return HSLColor.fromAHSL(1, hue, 0.36, 0.36).toColor();
}

String _formatDateTime(DateTime value) {
  String two(int item) => item.toString().padLeft(2, '0');
  return '${value.year}-${two(value.month)}-${two(value.day)} '
      '${two(value.hour)}:${two(value.minute)}';
}
