import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../domain/radio_library.dart';
import 'path_keys.dart';
import 'project_workspace.dart';

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
      'source': source,
      'radio_code': radioCode,
      'playlist_type': playlistType,
      'slot': slot,
    };
  }

  factory PlaylistAssignment.fromJson(Map<String, dynamic> json) {
    final source = _asString(json['source']);
    final key = _asString(json['track_key']);
    final rawPlaylistType = _asString(json['playlist_type']).isNotEmpty
        ? _asString(json['playlist_type'])
        : _asString(json['playlistType']);
    return PlaylistAssignment(
      trackKey: key.isNotEmpty
          ? key
          : (source.isEmpty ? '' : PlaylistAssignment.keyForPath(source)),
      source: source,
      radioCode: _asString(json['radio_code']).toUpperCase(),
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
    final radio = radioCode.trim().toUpperCase();
    final type = normalizePlaylistType(playlistType);
    return '$trackKey|$radio|$type';
  }

  static String normalizePlaylistType(String value) {
    return value.trim().toLowerCase() == 'event' ? 'Event' : 'FreeRoam';
  }

  static String playlistLabel(String value) {
    return normalizePlaylistType(value) == 'Event' ? '比赛' : '漫游';
  }

  PlaylistAssignment copyWith({String? source, String? radioCode, int? slot}) {
    final nextSource = source ?? this.source;
    return PlaylistAssignment(
      trackKey: PlaylistAssignment.keyForPath(nextSource),
      source: nextSource,
      radioCode: radioCode ?? this.radioCode,
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
          (assignment) => assignment.trackKey == key && assignment.isAssigned,
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
    return assignment == null || !assignment.isAssigned ? null : assignment;
  }

  List<PlaylistAssignment> assignmentsForRadio(
    String radioCode,
    String playlistType,
  ) {
    final radio = radioCode.trim().toUpperCase();
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
    final radio = radioCode.trim().toUpperCase();
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
  }) {
    final assignment = PlaylistAssignment(
      trackKey: PlaylistAssignment.keyForPath(source),
      source: source,
      radioCode: radioCode.trim().toUpperCase(),
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
  }) {
    final trackKey = PlaylistAssignment.keyForPath(source);
    final radio = radioCode?.trim().toUpperCase();
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

  PlaylistPlan unassignSources(Iterable<String> sources) {
    final keys = {
      for (final source in sources)
        if (source.trim().isNotEmpty) PlaylistAssignment.keyForPath(source),
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
    final radio = radioCode.trim().toUpperCase();
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
    final radio = radioCode.trim().toUpperCase();
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
    return parts.first.trim().toUpperCase();
  }

  static Map<String, String> _targetJson(String key) {
    final parts = key.split('|');
    return {
      'radio_code': parts.isNotEmpty ? parts[0] : '',
      'playlist_type': parts.length > 1 ? parts[1] : 'FreeRoam',
    };
  }

  static String? _targetKeyFromJson(Object? item) {
    if (item is String) {
      final parts = item.split('|');
      if (parts.isEmpty || parts.first.trim().isEmpty) return null;
      return _targetKey(parts.first, parts.length > 1 ? parts[1] : 'FreeRoam');
    }
    if (item is! Map) return null;
    final radio = _asString(item['radio_code'] ?? item['radioCode']);
    if (radio.trim().isEmpty) return null;
    final type = _asString(item['playlist_type'] ?? item['playlistType']);
    return _targetKey(radio, type);
  }
}

class PlaylistPlanStore {
  const PlaylistPlanStore._();

  static String configPath(String projectDir) {
    return p.join(
      FhRadioStudioProject.metadataDir(projectDir),
      'playlist_plan.json',
    );
  }

  static PlaylistPlan read(
    String projectDir, {
    Set<String>? validCodes,
    Map<String, String> radioCodeAliases = const {},
  }) {
    final file = File(configPath(projectDir));
    if (!file.existsSync()) return const PlaylistPlan.empty();
    final plan = _readFile(file);
    final normalized = projectSourcesOnly(
      projectDir,
      plan,
      validCodes: validCodes,
      radioCodeAliases: radioCodeAliases,
    );
    if (!_samePlan(plan, normalized)) {
      write(
        projectDir,
        normalized,
        validCodes: validCodes,
        radioCodeAliases: radioCodeAliases,
      );
    }
    return normalized;
  }

  static PlaylistPlan _readFile(File file) {
    try {
      final decoded = jsonDecode(file.readAsStringSync(encoding: utf8));
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
    } on FormatException {
      return const PlaylistPlan.empty();
    } on FileSystemException {
      return const PlaylistPlan.empty();
    }
  }

  static void write(
    String projectDir,
    PlaylistPlan plan, {
    Set<String>? validCodes,
    Map<String, String> radioCodeAliases = const {},
  }) {
    final normalized = projectSourcesOnly(
      projectDir,
      plan,
      validCodes: validCodes,
      radioCodeAliases: radioCodeAliases,
    );
    if (!normalized.hasDraft) {
      delete(projectDir);
      return;
    }
    FhRadioStudioProject.ensure(projectDir);
    final file = File(configPath(projectDir));
    file.parent.createSync(recursive: true);
    final ordered = normalized.assignments.values.toList()
      ..sort(PlaylistPlan._assignmentSort);
    final targets = normalized.builtinTargets.toList()..sort();
    file.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        'schema_version': 2,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
        'assignments': [for (final assignment in ordered) assignment.toJson()],
        'builtin_targets': [
          for (final target in targets) PlaylistPlan._targetJson(target),
        ],
      }),
      encoding: utf8,
    );
  }

  static void delete(String projectDir) {
    final file = File(configPath(projectDir));
    if (!file.existsSync()) return;
    try {
      file.deleteSync();
    } on FileSystemException {
      // Best-effort cleanup; callers can still overwrite on the next write.
    }
  }

  static PlaylistPlan projectSourcesOnly(
    String projectDir,
    PlaylistPlan plan, {
    Set<String>? validCodes,
    Map<String, String> radioCodeAliases = const {},
  }) {
    final out = <String, PlaylistAssignment>{};
    for (final assignment in plan.assignments.values) {
      final radioCode = canonicalRadioCode(
        assignment.radioCode,
        aliases: radioCodeAliases,
      );
      if (validCodes != null && !validCodes.contains(radioCode)) {
        continue;
      }
      final normalized = _normalizeProjectSource(
        projectDir,
        assignment.copyWith(radioCode: radioCode),
      );
      if (normalized == null) continue;
      out[normalized.assignmentKey] = normalized;
    }
    final builtinTargets = {
      for (final target in plan.builtinTargets)
        ?_canonicalTargetKey(target, validCodes, radioCodeAliases),
    };
    return PlaylistPlan(assignments: out, builtinTargets: builtinTargets);
  }

  static String? _canonicalTargetKey(
    String target,
    Set<String>? validCodes,
    Map<String, String> radioCodeAliases,
  ) {
    final radio = PlaylistPlan._targetRadioCode(target);
    if (radio == null) return null;
    final playlistType = target.split('|').length > 1
        ? target.split('|')[1]
        : 'FreeRoam';
    final code = canonicalRadioCode(radio, aliases: radioCodeAliases);
    if (validCodes != null && !validCodes.contains(code)) return null;
    return PlaylistPlan._targetKey(code, playlistType);
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
    return assignment.copyWith(source: absolute);
  }

  static bool _samePlan(PlaylistPlan a, PlaylistPlan b) {
    final aAssignments = a.assignments.values.map(_assignmentSignature).toList()
      ..sort();
    final bAssignments = b.assignments.values.map(_assignmentSignature).toList()
      ..sort();
    if (aAssignments.length != bAssignments.length) return false;
    for (var index = 0; index < aAssignments.length; index += 1) {
      if (aAssignments[index] != bAssignments[index]) return false;
    }
    final aTargets = a.builtinTargets.toList()..sort();
    final bTargets = b.builtinTargets.toList()..sort();
    if (aTargets.length != bTargets.length) return false;
    for (var index = 0; index < aTargets.length; index += 1) {
      if (aTargets[index] != bTargets[index]) return false;
    }
    return true;
  }

  static String _assignmentSignature(PlaylistAssignment assignment) {
    return jsonEncode(assignment.toJson());
  }
}

String _asString(Object? value) => value == null ? '' : '$value';

int _asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.round();
  if (value is String) return int.tryParse(value) ?? 0;
  return 0;
}
