import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../core/path_keys.dart';
import '../core/playlist_plan.dart';
import '../core/project_workspace.dart';
import '../core/siren_imports.dart';
import '../core/track_metadata_cache.dart';
import '../domain/radio_library.dart';
import 'studio_state.dart';
import 'playlist_plan_state.dart';
import 'track_timing_state.dart';

final realPoolTracksProvider = Provider<List<PoolTrack>>((ref) {
  final studio = ref.watch(
    studioProvider.select(
      (state) => (
        projectDir: state.projectDir,
        musicPaths: state.musicPaths,
        migrationRequired: state.projectPathMigrationRequired,
        migrationRunning: state.projectPathMigrationRunning,
        migrationRevision: state.projectPathMigrationRevision,
      ),
    ),
  );
  if (studio.migrationRequired ||
      studio.migrationRunning ||
      FhRadioStudioProject.needsPathMigration(studio.projectDir)) {
    return const [];
  }
  final configs = ref.watch(trackTimingProvider);
  final playlist = ref.watch(effectivePlaylistPlanProvider);
  final metadata = TrackMetadataCache.read(studio.projectDir);
  final sirenImports = SirenImportRegistry.readByPath(studio.projectDir);
  return buildRealPoolTracks(
    studio.musicPaths,
    configs: configs,
    assignments: playlist.assignments,
    metadata: metadata,
    sirenImports: sirenImports,
  );
});

const _audioSuffixes = {
  '.wav',
  '.flac',
  '.ogg',
  '.aiff',
  '.aif',
  '.mp3',
  '.m4a',
  '.aac',
};

List<PoolTrack> buildRealPoolTracks(
  List<String> inputs, {
  Map<String, dynamic> configs = const {},
  Map<String, PlaylistAssignment> assignments = const {},
  Map<String, TrackMetadata> metadata = const {},
  Map<String, SirenImportEntry> sirenImports = const {},
}) {
  final files = <File>[];
  final seen = <String>{};
  for (final raw in inputs) {
    final path = raw.trim();
    if (path.isEmpty) continue;
    final file = File(path);
    if (file.existsSync()) {
      if (_isAudioPath(file.path) && seen.add(realTrackKeyForPath(file.path))) {
        files.add(file);
      }
      continue;
    }
    final dir = Directory(path);
    if (!dir.existsSync()) continue;
    final children =
        dir
            .listSync(followLinks: false)
            .whereType<File>()
            .where((item) => _isAudioPath(item.path))
            .toList()
          ..sort(
            (a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()),
          );
    for (final child in children) {
      if (seen.add(realTrackKeyForPath(child.path))) files.add(child);
    }
  }
  return [
    for (final file in files)
      poolTrackFromFile(
        file,
        config: configs[realTrackKeyForPath(file.path)],
        assignment: firstAssignmentForPath(assignments, file.path),
        metadata: metadata[realTrackKeyForPath(file.path)],
        sirenImport: sirenImports[realTrackKeyForPath(file.path)],
      ),
  ];
}

PlaylistAssignment? firstAssignmentForPath(
  Map<String, PlaylistAssignment> assignments,
  String path,
) {
  final key = realTrackKeyForPath(path);
  final items =
      assignments.values
          .where(
            (assignment) =>
                assignment.isAssigned &&
                (assignment.trackKey == key ||
                    PlaylistAssignment.keyForPath(assignment.source) == key),
          )
          .toList()
        ..sort((a, b) {
          final byRadio = a.radioCode.compareTo(b.radioCode);
          if (byRadio != 0) return byRadio;
          final byType = _playlistSortKey(
            a.playlistType,
          ).compareTo(_playlistSortKey(b.playlistType));
          if (byType != 0) return byType;
          return a.slot.compareTo(b.slot);
        });
  return items.isEmpty ? null : items.first;
}

int _playlistSortKey(String value) {
  return PlaylistAssignment.normalizePlaylistType(value) == 'FreeRoam' ? 0 : 1;
}

PoolTrack poolTrackFromFile(
  File file, {
  dynamic config,
  dynamic assignment,
  TrackMetadata? metadata,
  SirenImportEntry? sirenImport,
}) {
  final (fallbackArtist, fallbackTitle) = guessTrackMetadata(file);
  final metadataTitle = _meaningfulText(metadata?.title);
  final metadataArtist = _meaningfulArtist(metadata?.artist);
  final title = sirenImport?.title ?? metadataTitle ?? fallbackTitle;
  final artist = sirenImport?.artist ?? metadataArtist ?? fallbackArtist;
  final duration = metadata?.durationSec ?? 0;
  final bpm = (_readDouble(config, 'bpm') ?? 0).round();
  final confirmed =
      _readInt(config, 'confirmedGroupCount') ??
      _readInt(config, 'confirmed_group_count') ??
      0;
  final configured =
      _readBool(config, 'allConfirmed') ??
      _readBool(config, 'all_confirmed') ??
      false;
  final assignedTo = _readString(assignment, 'radioCode');
  final slot = _readInt(assignment, 'slot');
  return PoolTrack(
    id: realTrackIdForPath(file.path),
    title: title,
    artist: artist,
    source: file.path,
    durationSec: duration,
    bpm: bpm,
    key: '待分析',
    configured: configured,
    confirmed: confirmed,
    sampleRate: metadata?.sampleRate,
    channels: metadata?.channels,
    samples: metadata?.samples,
    assignedTo: assignedTo?.isNotEmpty == true ? assignedTo : null,
    slot: assignedTo?.isNotEmpty == true ? slot : null,
    sourceKind: sirenImport == null ? 'local' : 'siren',
    sourceLabel: sirenImport == null ? null : 'MSR-${sirenImport.cid}',
    sirenCid: sirenImport?.cid,
    albumName: sirenImport?.albumName,
    coverUrl: sirenImport?.coverUrl,
    coverArtPath: metadata?.coverArtPath,
    added: modifiedLabel(file),
  );
}

String realTrackIdForPath(String path) => 'real:${Uri.encodeComponent(path)}';

String realTrackKeyForPath(String path) => canonicalPathKey(path);

String? pathFromRealTrackId(String id) {
  if (!id.startsWith('real:')) return null;
  return Uri.decodeComponent(id.substring(5));
}

(String, String) guessTrackMetadata(File file) {
  final stem = p
      .basenameWithoutExtension(file.path)
      .replaceFirst(RegExp(r'^\s*\d+\s*[-_. ]+\s*'), '');
  final parts = stem.split(RegExp(r'\s+-\s+'));
  if (parts.length >= 2 && parts.first.trim().isNotEmpty) {
    return (parts.first.trim(), parts.sublist(1).join(' - ').trim());
  }
  return (
    'Unknown Artist',
    stem.trim().isEmpty ? p.basename(file.path) : stem.trim(),
  );
}

String modifiedLabel(File file) {
  try {
    final modified = file.lastModifiedSync();
    final now = DateTime.now();
    final age = now.difference(modified);
    if (age.inMinutes < 60) return '${age.inMinutes.clamp(0, 59)} 分钟前';
    if (age.inHours < 24) return '${age.inHours} 小时前';
    if (age.inDays < 7) return '${age.inDays} 天前';
    String two(int value) => value.toString().padLeft(2, '0');
    return '${modified.year}-${two(modified.month)}-${two(modified.day)}';
  } on FileSystemException {
    return '未知';
  }
}

bool _isAudioPath(String path) {
  return _audioSuffixes.contains(p.extension(path).toLowerCase());
}

String? _readString(Object? object, String name) {
  final value = _readField(object, name);
  return value == null ? null : '$value';
}

String? _meaningfulText(String? value) {
  final text = value?.trim();
  return text == null || text.isEmpty ? null : text;
}

String? _meaningfulArtist(String? value) {
  final text = _meaningfulText(value);
  if (text == null || text.toLowerCase() == 'unknown artist') return null;
  return text;
}

double? _readDouble(Object? object, String name) {
  final value = _readField(object, name);
  if (value is double) return value;
  if (value is int) return value.toDouble();
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value);
  return null;
}

int? _readInt(Object? object, String name) {
  final value = _readField(object, name);
  if (value is int) return value;
  if (value is num) return value.round();
  if (value is String) return int.tryParse(value);
  return null;
}

bool? _readBool(Object? object, String name) {
  final value = _readField(object, name);
  if (value is bool) return value;
  return null;
}

Object? _readField(Object? object, String name) {
  if (object == null) return null;
  if (object is Map) return object[name];
  try {
    final dynamic value = object;
    switch (name) {
      case 'bpm':
        return value.bpm;
      case 'confirmedGroupCount':
        return value.confirmedGroupCount;
      case 'allConfirmed':
        return value.allConfirmed;
      case 'radioCode':
        return value.radioCode;
      case 'slot':
        return value.slot;
    }
  } on Object {
    return null;
  }
  return null;
}
