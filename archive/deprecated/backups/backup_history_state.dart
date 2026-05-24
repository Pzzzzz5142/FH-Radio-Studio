import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import 'studio_state.dart';

@immutable
class BackupHistoryEntry {
  const BackupHistoryEntry({
    required this.manifestPath,
    required this.folderPath,
    required this.fileCount,
    required this.bankCount,
    required this.radioInfoCount,
    required this.createdAt,
    required this.packageName,
    required this.kind,
    required this.displayName,
    required this.gameVersionId,
    this.totalSize = 0,
  });

  final String manifestPath;
  final String folderPath;
  final int totalSize;
  final int fileCount;
  final int bankCount;
  final int radioInfoCount;
  final DateTime? createdAt;
  final String packageName;
  final String kind;
  final String displayName;
  final String? gameVersionId;

  bool get isManualSnapshot => kind == 'manual_snapshot';
  bool get isAutomaticBackup => !isManualSnapshot;
  String get typeLabel => isManualSnapshot ? '手动旧记录' : '自动旧记录';
  String get steamBuildLabel =>
      _steamBuildLabel(gameVersionId) ?? 'Steam build 未记录';

  String get title {
    if (!isManualSnapshot) return backupTimeTitle;
    if (displayName.trim().isNotEmpty) return displayName.trim();
    if (packageName.isNotEmpty) return packageName;
    return '手动旧记录';
  }

  String get timeLabel {
    final date = createdAt?.toLocal();
    if (date == null) return '未知时间';
    String two(int value) => value.toString().padLeft(2, '0');
    return '${date.year}-${two(date.month)}-${two(date.day)} ${two(date.hour)}:${two(date.minute)}';
  }

  String get backupTimeTitle {
    final date = createdAt?.toLocal();
    if (date == null) return '未知时间';
    String two(int value) => value.toString().padLeft(2, '0');
    return '${date.year}-${two(date.month)}-${two(date.day)} '
        '${two(date.hour)}:${two(date.minute)}:${two(date.second)}';
  }

  String get detail {
    final prefix = isManualSnapshot ? '手动旧记录' : '自动旧记录';
    return '$prefix · $fileCount 个文件 · $radioInfoCount 个语言 XML · $bankCount 个音频包';
  }
}

@immutable
class BaselineBackupEntry {
  const BaselineBackupEntry({
    required this.manifestPath,
    required this.folderPath,
    required this.state,
    required this.fileCount,
    required this.bankCount,
    required this.radioInfoCount,
    required this.stringTableCount,
    required this.totalSize,
    required this.versionId,
    required this.appId,
    required this.buildId,
    required this.contentUpdatedAt,
    required this.createdAt,
    required this.promotedAt,
  });

  final String manifestPath;
  final String folderPath;
  final String state;
  final int fileCount;
  final int bankCount;
  final int radioInfoCount;
  final int stringTableCount;
  final int totalSize;
  final String? versionId;
  final String? appId;
  final String? buildId;
  final DateTime? contentUpdatedAt;
  final DateTime? createdAt;
  final DateTime? promotedAt;

  bool get isOld => p.basename(folderPath).contains('-baseline-old-');
  bool get isCurrent => !isOld && state == 'current';
  bool get isPending => !isOld && state == 'pending-verify';

  String get title {
    final suffix = hasVersion ? ' · $versionLabel' : '';
    if (isCurrent) return '当前原始游戏基线$suffix';
    if (isPending) return '待验证游戏基线$suffix';
    if (isOld) return '历史原始游戏基线$suffix';
    return state.isEmpty ? '游戏基线$suffix' : '游戏基线 · $state$suffix';
  }

  String get badgeLabel {
    if (isCurrent) return 'current';
    if (isPending) return 'pending';
    if (isOld) return 'old';
    return state.isEmpty ? 'baseline' : state;
  }

  DateTime? get sortDate => promotedAt ?? createdAt;

  bool get hasVersion =>
      (buildId != null && buildId!.trim().isNotEmpty) ||
      (versionId != null &&
          versionId!.trim().isNotEmpty &&
          versionId != 'unknown');

  String get versionLabel {
    if (buildId != null && buildId!.trim().isNotEmpty) {
      return 'Steam build $buildId';
    }
    if (versionId != null &&
        versionId!.trim().isNotEmpty &&
        versionId != 'unknown') {
      return versionId!;
    }
    return '版本未知';
  }

  String get versionDetail {
    if (!hasVersion) return '版本未知';
    final parts = <String>[
      if (appId != null && appId!.trim().isNotEmpty) 'Steam App $appId',
      if (buildId != null && buildId!.trim().isNotEmpty) 'build $buildId',
      if (contentUpdatedAt != null)
        '内容更新 ${_formatLocalDate(contentUpdatedAt!)}',
    ];
    return parts.isEmpty ? versionLabel : parts.join(' · ');
  }

  String get timeLabel {
    final date = sortDate?.toLocal();
    if (date == null) return '未知时间';
    String two(int value) => value.toString().padLeft(2, '0');
    return '${date.year}-${two(date.month)}-${two(date.day)} ${two(date.hour)}:${two(date.minute)}';
  }

  String get detail {
    final parts = <String>[
      versionDetail,
      '$fileCount 个文件',
      if (radioInfoCount > 0) '$radioInfoCount 个语言 XML',
      if (bankCount > 0) '$bankCount 个音频 bank',
      if (stringTableCount > 0) '$stringTableCount 个语言表',
    ];
    return parts.join(' · ');
  }
}

final backupHistoryProvider = FutureProvider<List<BackupHistoryEntry>>((
  ref,
) async {
  final backupsDirPath = ref.watch(
    studioProvider.select((state) => state.backupsDir),
  );
  final backupRoots = [
    Directory(p.join(backupsDirPath, 'manual')),
    Directory(p.join(backupsDirPath, 'automatic')),
  ].where((dir) => dir.existsSync()).toList(growable: false);
  if (backupRoots.isEmpty) return const [];

  final entries = <BackupHistoryEntry>[];
  for (final root in backupRoots) {
    final manifestName = p.basename(root.path) == 'manual'
        ? 'manual_snapshot_manifest.json'
        : 'deploy_manifest.json';
    await for (final entity in root.list(followLinks: false)) {
      if (entity is! Directory) continue;
      final manifest = File(p.join(entity.path, manifestName));
      if (!manifest.existsSync()) continue;
      final entry = _readBackupEntry(manifest);
      if (entry != null) entries.add(entry);
    }
  }
  entries.sort((a, b) {
    final left = a.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
    final right = b.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
    return right.compareTo(left);
  });
  return entries;
});

final baselineBackupProvider = FutureProvider<List<BaselineBackupEntry>>((
  ref,
) async {
  final backupsDirPath = ref.watch(
    studioProvider.select((state) => state.backupsDir),
  );
  final backupsDir = Directory(backupsDirPath);
  if (!backupsDir.existsSync()) return const [];

  final entries = <BaselineBackupEntry>[];
  final roots = <Directory>[
    backupsDir,
    Directory(p.join(backupsDir.path, 'baseline-old')),
  ].where((dir) => dir.existsSync()).toList(growable: false);
  for (final root in roots) {
    await for (final entity in root.list(followLinks: false)) {
      if (entity is! Directory) continue;
      if (!_isVersionedBaselineDir(entity.path)) continue;
      final manifest = File(p.join(entity.path, 'baseline_manifest.json'));
      if (!manifest.existsSync()) continue;
      final entry = _readBaselineEntry(manifest);
      if (entry != null) entries.add(entry);
    }
  }
  entries.sort((a, b) {
    final rank = _baselineRank(a).compareTo(_baselineRank(b));
    if (rank != 0) return rank;
    final left = a.sortDate ?? DateTime.fromMillisecondsSinceEpoch(0);
    final right = b.sortDate ?? DateTime.fromMillisecondsSinceEpoch(0);
    return right.compareTo(left);
  });
  return entries;
});

BackupHistoryEntry? _readBackupEntry(File manifest) {
  try {
    final decoded = jsonDecode(manifest.readAsStringSync(encoding: utf8));
    if (decoded is! Map) return null;
    final data = decoded.map((key, value) => MapEntry('$key', value));
    final kind = '${data['kind'] ?? ''}';
    final displayName = '${data['name'] ?? data['display_name'] ?? ''}'.trim();
    final files = data['files'] is List ? data['files'] as List : const [];
    var bankCount = 0;
    var radioInfoCount = 0;
    var totalSize = 0;
    for (final item in files) {
      if (item is! Map) continue;
      final rel = '${item['relative_path'] ?? ''}'.toLowerCase();
      final base = p.basename(rel);
      if (rel.endsWith('.assets.bank')) bankCount++;
      if (base.startsWith('radioinfo_') && base.endsWith('.xml')) {
        radioInfoCount++;
      }
      totalSize += _firstIntValue(
        item['backup_size'],
        item['source_size'],
        item['size'],
      );
    }
    final packageAudio = '${data['package_audio'] ?? ''}';
    final packageName = displayName.isNotEmpty
        ? displayName
        : packageAudio.isEmpty
        ? p.basename(manifest.parent.path)
        : p.basename(p.dirname(p.dirname(p.dirname(packageAudio))));
    return BackupHistoryEntry(
      manifestPath: manifest.path,
      folderPath: manifest.parent.path,
      totalSize: totalSize,
      fileCount: files.length,
      bankCount: bankCount,
      radioInfoCount: radioInfoCount,
      createdAt: DateTime.tryParse('${data['created_at'] ?? ''}'),
      packageName: packageName,
      kind: kind,
      displayName: displayName,
      gameVersionId: _gameVersionIdFromData(data),
    );
  } on FormatException {
    return null;
  } on FileSystemException {
    return null;
  }
}

BaselineBackupEntry? _readBaselineEntry(File manifest) {
  try {
    final decoded = jsonDecode(manifest.readAsStringSync());
    if (decoded is! Map) return null;
    final data = decoded.map((key, value) => MapEntry('$key', value));
    if ('${data['kind'] ?? ''}' != 'game_baseline') return null;

    final files = data['files'] is List ? data['files'] as List : const [];
    final gameVersion = _mapValue(data['game_version']);
    final byScope = data['by_scope'] is Map
        ? (data['by_scope'] as Map).map((key, value) => MapEntry('$key', value))
        : const <String, Object?>{};
    final hasBankScope = byScope.containsKey('radio_bank');
    final hasRadioInfoScope = byScope.containsKey('radio_info');
    final hasStringTableScope = byScope.containsKey('string_table');
    var bankCount = _intValue(byScope['radio_bank']);
    var radioInfoCount = _intValue(byScope['radio_info']);
    var stringTableCount = _intValue(byScope['string_table']);
    var totalSize = 0;

    for (final item in files) {
      if (item is! Map) continue;
      final map = item.map((key, value) => MapEntry('$key', value));
      totalSize += _intValue(map['size']);
      final scope = '${map['scope'] ?? ''}';
      final rel =
          '${map['install_relative_path'] ?? map['relative_path'] ?? ''}'
              .toLowerCase();
      if (!hasBankScope &&
          (scope == 'radio_bank' || rel.endsWith('.assets.bank'))) {
        bankCount++;
      }
      if (!hasRadioInfoScope &&
          (scope == 'radio_info' ||
              (p.basename(rel).startsWith('radioinfo_') &&
                  rel.endsWith('.xml')))) {
        radioInfoCount++;
      }
      if (!hasStringTableScope &&
          (scope == 'string_table' || rel.contains('stringtables/'))) {
        stringTableCount++;
      }
    }

    return BaselineBackupEntry(
      manifestPath: manifest.path,
      folderPath: manifest.parent.path,
      state: '${data['state'] ?? ''}',
      fileCount: _intValue(data['file_count'], fallback: files.length),
      bankCount: bankCount,
      radioInfoCount: radioInfoCount,
      stringTableCount: stringTableCount,
      totalSize: totalSize,
      versionId:
          _stringValue(data['game_version_id']) ??
          _stringValue(gameVersion?['version_id']),
      appId: _stringValue(gameVersion?['app_id']),
      buildId: _stringValue(gameVersion?['build_id']),
      contentUpdatedAt: DateTime.tryParse(
        _stringValue(gameVersion?['content_updated_at']) ?? '',
      ),
      createdAt: DateTime.tryParse('${data['created_at'] ?? ''}'),
      promotedAt: DateTime.tryParse('${data['promoted_at'] ?? ''}'),
    );
  } on FormatException {
    return null;
  } on FileSystemException {
    return null;
  }
}

int _baselineRank(BaselineBackupEntry entry) {
  if (entry.isCurrent) return 0;
  if (entry.isPending) return 1;
  if (entry.isOld) return 2;
  return 3;
}

bool _isVersionedBaselineDir(String path) {
  final name = p.basename(path);
  return name.startsWith('baseline-') ||
      (name.startsWith('fh6-') && name.contains('-baseline-'));
}

int _intValue(Object? value, {int fallback = 0}) {
  if (value is int) return value;
  if (value is num) return value.round();
  if (value is String) return int.tryParse(value) ?? fallback;
  return fallback;
}

int _firstIntValue(Object? first, Object? second, Object? third) {
  for (final value in [first, second, third]) {
    if (value is int) return value;
    if (value is num) return value.round();
    if (value is String) {
      final parsed = int.tryParse(value);
      if (parsed != null) return parsed;
    }
  }
  return 0;
}

Map<String, dynamic>? _mapValue(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return value.map((key, item) => MapEntry('$key', item));
  return null;
}

String? _stringValue(Object? value) => value == null ? null : '$value';

String? _gameVersionIdFromData(Map<String, dynamic> data) {
  final direct = _stringValue(data['game_version_id']);
  if (direct != null && direct.trim().isNotEmpty) return direct;
  final version = _mapValue(data['game_version']);
  final nested = _stringValue(version?['version_id']);
  if (nested != null && nested.trim().isNotEmpty) return nested;
  final buildId = _stringValue(version?['build_id']);
  if (buildId != null && buildId.trim().isNotEmpty) return 'steam-b$buildId';
  return null;
}

String? _steamBuildLabel(String? versionId) {
  if (versionId == null) return null;
  final match = RegExp(
    r'^steam-b(.+)$',
    caseSensitive: false,
  ).firstMatch(versionId.trim());
  final buildId = match?.group(1)?.trim();
  if (buildId == null || buildId.isEmpty) return null;
  return 'Steam build $buildId';
}

String _formatLocalDate(DateTime value) {
  final date = value.toLocal();
  String two(int item) => item.toString().padLeft(2, '0');
  return '${date.year}-${two(date.month)}-${two(date.day)} ${two(date.hour)}:${two(date.minute)}';
}
