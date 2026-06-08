import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'path_keys.dart';
import 'project_refs.dart';
import 'project_workspace.dart';
import 'track_metadata_cache.dart';

class PlaylistAssignment {
  const PlaylistAssignment({
    required this.trackKey,
    required this.source,
    required this.radioCode,
    required this.playlistType,
    required this.slot,
  });

  final String trackKey;
  final String source;
  final String radioCode;
  final String playlistType;
  final int slot;

  bool get isValid => trackKey.isNotEmpty && source.isNotEmpty;
  bool get isAssigned => radioCode.isNotEmpty && slot > 0;
  String get assignmentKey => keyForAssignment(
    source: source,
    radioCode: radioCode,
    playlistType: playlistType,
  );
  String get listLabel => '$radioCode · ${playlistLabel(playlistType)}$slot';

  Map<String, dynamic> toJson() {
    return {
      'track_key': trackKey,
      if (!_isProjectTrackKey(trackKey)) 'source': source,
      'radio_code': radioCode,
      'playlist_type': playlistType,
      'slot': slot,
    };
  }

  factory PlaylistAssignment.fromJson(
    Map<String, dynamic> json, {
    String? projectDir,
  }) {
    final source = _asString(json['source']);
    final key = _asString(json['track_key']);
    final resolvedSource = source.isNotEmpty
        ? source
        : (projectDir == null || key.isEmpty
              ? ''
              : TrackMetadataCache.resolveTrackKey(projectDir, key) ?? '');
    if (key.isEmpty &&
        projectDir != null &&
        _isProjectInternalSource(projectDir, source)) {
      throw ProjectRefException(
        'Legacy project playlist source requires migration: $source',
      );
    }
    final rawPlaylistType = _asString(json['playlist_type']);
    return PlaylistAssignment(
      trackKey: key.isNotEmpty
          ? key
          : (resolvedSource.isEmpty
                ? ''
                : PlaylistAssignment.keyForPath(resolvedSource)),
      source: resolvedSource,
      radioCode: _canonicalRadioCodeOrEmpty(_asString(json['radio_code'])),
      playlistType: normalizePlaylistType(rawPlaylistType),
      slot: _asInt(json['slot']),
    );
  }

  static String keyForPath(String path) {
    return canonicalPathKey(path);
  }

  static String keyForAssignment({
    required String source,
    required String radioCode,
    required String playlistType,
  }) {
    final trackKey = keyForPath(source);
    final radio = _canonicalRadioCodeOrEmpty(radioCode);
    final type = normalizePlaylistType(playlistType);
    return '$trackKey|$radio|$type';
  }

  static String normalizePlaylistType(String value) {
    return value.trim().toLowerCase() == 'event' ? 'Event' : 'FreeRoam';
  }

  static String playlistLabel(String value) {
    return normalizePlaylistType(value) == 'Event' ? '比赛' : '漫游';
  }

  PlaylistAssignment copyWith({String? source, int? slot, String? trackKey}) {
    final nextSource = source ?? this.source;
    return PlaylistAssignment(
      trackKey:
          trackKey ??
          (source == null
              ? this.trackKey
              : PlaylistAssignment.keyForPath(nextSource)),
      source: nextSource,
      radioCode: radioCode,
      playlistType: playlistType,
      slot: slot ?? this.slot,
    );
  }
}

class PlaylistPlan {
  const PlaylistPlan({
    required this.assignments,
    this.builtinTargets = const {},
  });
  const PlaylistPlan.empty()
    : assignments = const {},
      builtinTargets = const {};

  final Map<String, PlaylistAssignment> assignments;
  final Set<String> builtinTargets;

  bool get hasDraft => assignments.isNotEmpty || builtinTargets.isNotEmpty;

  bool hasBuiltinOverride(String radioCode, String playlistType) {
    return builtinTargets.contains(_targetKey(radioCode, playlistType));
  }

  PlaylistAssignment? assignmentForPath(String path) {
    final items = assignmentsForPath(path);
    return items.isEmpty ? null : items.first;
  }

  List<PlaylistAssignment> assignmentsForPath(String path) {
    final key = PlaylistAssignment.keyForPath(path);
    final items = assignments.values
        .where(
          (assignment) =>
              assignment.isAssigned &&
              (assignment.trackKey == key ||
                  sameCanonicalPath(assignment.source, path)),
        )
        .toList();
    items.sort(_assignmentSort);
    return items;
  }

  PlaylistAssignment? assignmentFor({
    required String source,
    required String radioCode,
    required String playlistType,
  }) {
    final key = PlaylistAssignment.keyForAssignment(
      source: source,
      radioCode: radioCode,
      playlistType: playlistType,
    );
    final assignment = assignments[key];
    if (assignment != null && assignment.isAssigned) return assignment;
    final radio = _canonicalRadioCodeOrEmpty(radioCode);
    for (final item in assignments.values) {
      if (!item.isAssigned) continue;
      if (item.radioCode != radio) continue;
      if (item.playlistType !=
          PlaylistAssignment.normalizePlaylistType(playlistType)) {
        continue;
      }
      if (sameCanonicalPath(item.source, source)) return item;
    }
    return null;
  }

  List<PlaylistAssignment> assignmentsForRadio(
    String radioCode,
    String playlistType,
  ) {
    final radio = _canonicalRadioCodeOrEmpty(radioCode);
    final type = PlaylistAssignment.normalizePlaylistType(playlistType);
    final items = assignments.values
        .where(
          (assignment) =>
              assignment.isAssigned &&
              assignment.radioCode == radio &&
              assignment.playlistType == type,
        )
        .toList();
    items.sort(_assignmentSort);
    return items;
  }

  bool hasAssignmentsForRadio(String radioCode, String playlistType) {
    return assignmentsForRadio(radioCode, playlistType).isNotEmpty;
  }

  bool get hasSplitPlaylistDifferences {
    for (final radioCode in _radioCodesWithPlaylistState()) {
      final freeRoam = _playlistSignature(radioCode, 'FreeRoam');
      final event = _playlistSignature(radioCode, 'Event');
      if (!_sameStringList(freeRoam, event)) return true;
    }
    return false;
  }

  List<String> sourcesForRadio(String radioCode) {
    final radio = _canonicalRadioCodeOrEmpty(radioCode);
    final out = <String>[];
    final seen = <String>{};
    final items = assignments.values
        .where(
          (assignment) =>
              assignment.isAssigned && assignment.radioCode == radio,
        )
        .toList();
    items.sort(_assignmentSort);
    for (final assignment in items) {
      if (seen.add(assignment.trackKey)) out.add(assignment.source);
    }
    return out;
  }

  List<String> missingSources() {
    final out = <String>[];
    final seen = <String>{};
    final ordered = assignments.values.toList()..sort(_assignmentSort);
    for (final assignment in ordered) {
      if (!assignment.isAssigned || assignment.source.trim().isEmpty) continue;
      final absolute = File(assignment.source).absolute.path;
      final key = PlaylistAssignment.keyForPath(absolute);
      if (!seen.add(key)) continue;
      if (!File(absolute).existsSync() && !Directory(absolute).existsSync()) {
        out.add(absolute);
      }
    }
    return out;
  }

  PlaylistPlan assign({
    required String source,
    required String radioCode,
    required String playlistType,
    required int slot,
    String? projectDir,
  }) {
    final trackKey = projectDir == null
        ? PlaylistAssignment.keyForPath(source)
        : _trackKeyForSource(projectDir, source);
    final assignment = PlaylistAssignment(
      trackKey: trackKey,
      source: source,
      radioCode: _canonicalRadioCodeOrEmpty(radioCode),
      playlistType: PlaylistAssignment.normalizePlaylistType(playlistType),
      slot: slot,
    );
    final targets = {...builtinTargets}
      ..remove(_targetKey(radioCode, playlistType));
    final existing = assignments[assignment.assignmentKey];
    if (existing != null && existing.isAssigned) {
      return PlaylistPlan(assignments: assignments, builtinTargets: targets);
    }
    return PlaylistPlan(
      assignments: {...assignments, assignment.assignmentKey: assignment},
      builtinTargets: targets,
    );
  }

  PlaylistPlan unassign(
    String source, {
    String? radioCode,
    String? playlistType,
    String? projectDir,
  }) {
    final trackKey = projectDir == null
        ? PlaylistAssignment.keyForPath(source)
        : _trackKeyForSource(projectDir, source);
    final radio = radioCode == null
        ? null
        : _canonicalRadioCodeOrEmpty(radioCode);
    final type = playlistType == null
        ? null
        : PlaylistAssignment.normalizePlaylistType(playlistType);
    final kept = assignments.values.where((assignment) {
      if (assignment.trackKey != trackKey) return true;
      if (radio != null && assignment.radioCode != radio) return true;
      if (type != null && assignment.playlistType != type) return true;
      return false;
    }).toList();
    return PlaylistPlan(
      assignments: _compactedAssignments(kept),
      builtinTargets: builtinTargets,
    );
  }

  PlaylistPlan unassignSources(Iterable<String> sources, {String? projectDir}) {
    final keys = {
      for (final source in sources)
        if (source.trim().isNotEmpty)
          projectDir == null
              ? PlaylistAssignment.keyForPath(source)
              : _trackKeyForSource(projectDir, source),
    };
    if (keys.isEmpty) return this;
    final kept = assignments.values.where((assignment) {
      return !keys.contains(assignment.trackKey);
    }).toList();
    return PlaylistPlan(
      assignments: _compactedAssignments(kept),
      builtinTargets: builtinTargets,
    );
  }

  PlaylistPlan restoreBuiltin({
    required String radioCode,
    required String playlistType,
  }) {
    final radio = _canonicalRadioCodeOrEmpty(radioCode);
    final type = PlaylistAssignment.normalizePlaylistType(playlistType);
    final kept = assignments.values.where((assignment) {
      return assignment.radioCode != radio || assignment.playlistType != type;
    }).toList();
    return PlaylistPlan(
      assignments: _compactedAssignments(kept),
      builtinTargets: {...builtinTargets, _targetKey(radio, type)},
    );
  }

  PlaylistPlan syncPlaylistTypesFrom(String keepPlaylistType) {
    final keepType = PlaylistAssignment.normalizePlaylistType(keepPlaylistType);
    const playlistTypes = ['FreeRoam', 'Event'];
    final radios = _radioCodesWithPlaylistState();
    if (radios.isEmpty) return this;

    final out = <String, PlaylistAssignment>{};
    for (final assignment in assignments.values) {
      if (radios.contains(assignment.radioCode) &&
          playlistTypes.contains(assignment.playlistType)) {
        continue;
      }
      out[assignment.assignmentKey] = assignment;
    }

    final targets = <String>{};
    for (final target in builtinTargets) {
      final radio = _targetRadioCode(target);
      if (radio == null || !radios.contains(radio)) targets.add(target);
    }

    for (final radioCode in radios) {
      final kept = assignmentsForRadio(radioCode, keepType);
      if (kept.isEmpty) {
        for (final type in playlistTypes) {
          targets.add(_targetKey(radioCode, type));
        }
        continue;
      }
      for (final type in playlistTypes) {
        for (final assignment in kept) {
          final synced = PlaylistAssignment(
            trackKey: assignment.trackKey,
            source: assignment.source,
            radioCode: assignment.radioCode,
            playlistType: type,
            slot: assignment.slot,
          );
          out[synced.assignmentKey] = synced;
        }
      }
    }

    return PlaylistPlan(
      assignments: _compactedAssignments(out.values.toList()),
      builtinTargets: targets,
    );
  }

  /// Serialize to the schema_version 2 document that `build-package
  /// --playlist-plan -` reads from stdin. Same shape as the legacy
  /// `playlist_plan.json`, emitted compactly for a single pipe write.
  String encodeForCli() {
    final ordered = assignments.values.toList()..sort(_assignmentSort);
    final targets = builtinTargets.toList()..sort();
    return jsonEncode({
      'schema_version': 2,
      'assignments': [for (final assignment in ordered) assignment.toJson()],
      'builtin_targets': [for (final target in targets) _targetJson(target)],
    });
  }

  static int _assignmentSort(PlaylistAssignment a, PlaylistAssignment b) {
    final byRadio = a.radioCode.compareTo(b.radioCode);
    if (byRadio != 0) return byRadio;
    final byType = _playlistSortKey(
      a.playlistType,
    ).compareTo(_playlistSortKey(b.playlistType));
    if (byType != 0) return byType;
    final bySlot = a.slot.compareTo(b.slot);
    if (bySlot != 0) return bySlot;
    return a.source.toLowerCase().compareTo(b.source.toLowerCase());
  }

  static int _playlistSortKey(String type) {
    return PlaylistAssignment.normalizePlaylistType(type) == 'FreeRoam' ? 0 : 1;
  }

  static Map<String, PlaylistAssignment> _compactedAssignments(
    List<PlaylistAssignment> items,
  ) {
    final grouped = <String, List<PlaylistAssignment>>{};
    for (final item in items.where((assignment) => assignment.isAssigned)) {
      final key = '${item.radioCode}|${item.playlistType}';
      grouped.putIfAbsent(key, () => []).add(item);
    }
    final out = <String, PlaylistAssignment>{};
    for (final group in grouped.values) {
      group.sort(_assignmentSort);
      for (var index = 0; index < group.length; index += 1) {
        final assignment = group[index].copyWith(slot: index + 1);
        out[assignment.assignmentKey] = assignment;
      }
    }
    return out;
  }

  static String _targetKey(String radioCode, String playlistType) {
    final radio = _canonicalRadioCodeOrEmpty(radioCode);
    final type = PlaylistAssignment.normalizePlaylistType(playlistType);
    return '$radio|$type';
  }

  Set<String> _radioCodesWithPlaylistState() {
    final out = <String>{};
    for (final assignment in assignments.values) {
      if (assignment.radioCode.trim().isNotEmpty) {
        out.add(assignment.radioCode.trim().toUpperCase());
      }
    }
    for (final target in builtinTargets) {
      final radio = _targetRadioCode(target);
      if (radio != null) out.add(radio);
    }
    return out;
  }

  List<String> _playlistSignature(String radioCode, String playlistType) {
    return [
      for (final assignment in assignmentsForRadio(radioCode, playlistType))
        '${assignment.slot}:${assignment.trackKey}',
    ];
  }

  static bool _sameStringList(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var index = 0; index < a.length; index += 1) {
      if (a[index] != b[index]) return false;
    }
    return true;
  }

  static String? _targetRadioCode(String key) {
    final parts = key.split('|');
    if (parts.isEmpty || parts.first.trim().isEmpty) return null;
    return _canonicalRadioCodeOrEmpty(parts.first);
  }

  static Map<String, String> _targetJson(String key) {
    final parts = key.split('|');
    return {
      'radio_code': parts.isNotEmpty ? parts[0] : '',
      'playlist_type': parts.length > 1 ? parts[1] : 'FreeRoam',
    };
  }

  static String? _targetKeyFromJson(Object? item) {
    if (item is! Map) return null;
    final radio = _asString(item['radio_code']);
    if (radio.trim().isEmpty) return null;
    final type = _asString(item['playlist_type']);
    return _targetKey(_canonicalRadioCodeOrEmpty(radio), type);
  }
}

/// Normalizes current-schema radio codes. Legacy abbreviations (HOR/XS/…)
/// belong to the project migration step, not runtime loading.
String _canonicalRadioCodeOrEmpty(String raw) {
  final code = raw.trim().toUpperCase();
  return code.isEmpty ? '' : code;
}

class PlaylistPlanStore {
  const PlaylistPlanStore._();

  static String configPath(String projectDir) {
    return p.join(
      FhRadioStudioProject.metadataDir(projectDir),
      'playlist_plan.json',
    );
  }

  static PlaylistPlan read(String projectDir) {
    final file = File(configPath(projectDir));
    if (!file.existsSync()) return const PlaylistPlan.empty();
    final plan = _readFile(file, projectDir: projectDir);
    return projectSourcesOnly(projectDir, plan);
  }

  static PlaylistPlan _readFile(File file, {String? projectDir}) {
    try {
      return PlaylistPlanCodec.fromDecoded(
        jsonDecode(file.readAsStringSync(encoding: utf8)),
        projectDir: projectDir,
      );
    } on FormatException {
      return const PlaylistPlan.empty();
    } on FileSystemException {
      return const PlaylistPlan.empty();
    }
  }

  static void delete(String projectDir) {
    final file = File(configPath(projectDir));
    if (!file.existsSync()) return;
    try {
      file.deleteSync();
    } on FileSystemException {
      // Best-effort cleanup; the next project open can retry this legacy file.
    }
  }

  static PlaylistPlan projectSourcesOnly(String projectDir, PlaylistPlan plan) {
    final out = <String, PlaylistAssignment>{};
    for (final assignment in plan.assignments.values) {
      final normalized = _normalizeProjectSource(projectDir, assignment);
      if (normalized == null) continue;
      out[normalized.assignmentKey] = normalized;
    }
    return PlaylistPlan(assignments: out, builtinTargets: plan.builtinTargets);
  }

  static PlaylistAssignment? _normalizeProjectSource(
    String projectDir,
    PlaylistAssignment assignment,
  ) {
    final source = assignment.source.trim();
    if (source.isEmpty || !FhRadioStudioProject.isAudioPath(source)) {
      return null;
    }
    final absolute = File(source).absolute.path;
    final projectAudioDirs = [
      FhRadioStudioProject.sourcesDir(projectDir),
      FhRadioStudioProject.sirenDir(projectDir),
    ].map((path) => Directory(path).absolute.path);
    if (!projectAudioDirs.any((dir) => isCanonicalPathInside(dir, absolute))) {
      return null;
    }
    return assignment.copyWith(source: absolute, trackKey: assignment.trackKey);
  }
}

/// Decodes a schema_version 2 playlist plan document into a [PlaylistPlan].
/// Used to read `reconstruct-plan --out -` output captured from CLI stdout,
/// keeping the parsing identical to [PlaylistPlanStore] (no disk file involved).
class PlaylistPlanCodec {
  const PlaylistPlanCodec._();

  static PlaylistPlan decodeJson(String source, {String? projectDir}) {
    if (source.trim().isEmpty) return const PlaylistPlan.empty();
    try {
      return fromDecoded(jsonDecode(source), projectDir: projectDir);
    } on FormatException {
      return const PlaylistPlan.empty();
    }
  }

  static PlaylistPlan fromDecoded(Object? decoded, {String? projectDir}) {
    final items = decoded is Map ? decoded['assignments'] : null;
    final rawBuiltinTargets = decoded is Map
        ? decoded['builtin_targets']
        : null;
    if (items is! List) return const PlaylistPlan.empty();
    final out = <String, PlaylistAssignment>{};
    for (final item in items) {
      if (item is! Map) continue;
      final assignment = PlaylistAssignment.fromJson(
        item.map((key, value) => MapEntry('$key', value)),
        projectDir: projectDir,
      );
      if (!assignment.isValid) continue;
      if (!assignment.isAssigned) continue;
      out[assignment.assignmentKey] = assignment;
    }
    final builtinTargets = <String>{};
    if (rawBuiltinTargets is List) {
      for (final item in rawBuiltinTargets) {
        final key = PlaylistPlan._targetKeyFromJson(item);
        if (key != null) builtinTargets.add(key);
      }
    }
    return PlaylistPlan(assignments: out, builtinTargets: builtinTargets);
  }
}

String _asString(Object? value) => value == null ? '' : '$value';

int _asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.round();
  if (value is String) return int.tryParse(value) ?? 0;
  return 0;
}

bool _isProjectTrackKey(String value) => value.startsWith('trkref_');

String _trackKeyForSource(String projectDir, String source) {
  try {
    return trackKeyForProjectPath(projectDir, source) ??
        PlaylistAssignment.keyForPath(source);
  } on ProjectRefException {
    return PlaylistAssignment.keyForPath(source);
  } on ArgumentError {
    return PlaylistAssignment.keyForPath(source);
  }
}

bool _isProjectInternalSource(String projectDir, String source) {
  if (source.trim().isEmpty) return false;
  try {
    return trackKeyForProjectPath(projectDir, source) != null;
  } on ProjectRefException {
    return false;
  } on ArgumentError {
    return false;
  }
}
