import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'path_keys.dart';

const _legacyProjectPathFields = {
  'source',
  'path',
  'cover_art_path',
  'backup_path',
  'package_path',
  'package_audio',
  'source_baseline_manifest',
  'source_package_manifest',
  'package_root',
  'playlist_plan',
  'timing_manifest',
  'baseline_manifest',
  'source_audio_dir',
  'source_radio_info',
  'source_bank',
  'prepared_wav',
  'staged_wav',
  'source_string_tables_dir',
  'source_table',
  'target_table',
  'packaged_table',
};

class FhRadioStudioProject {
  const FhRadioStudioProject._();

  static const defaultFolderName = 'FH Radio Studio';

  static const _audioSuffixes = {
    '.wav',
    '.flac',
    '.ogg',
    '.aiff',
    '.aif',
    '.mp3',
    '.m4a',
    '.aac',
  };

  static String defaultProjectDir() {
    return p.join(_homeDir(), defaultFolderName);
  }

  static String sourcesDir(String projectDir) => p.join(projectDir, 'sources');
  static String sirenDir(String projectDir) => p.join(projectDir, 'siren');
  static String packagesDir(String projectDir) =>
      p.join(projectDir, 'packages');
  static String backupsDir(String projectDir) => p.join(projectDir, 'backups');
  static String analysisDir(String projectDir) =>
      p.join(projectDir, 'analysis');
  static String metadataDir(String projectDir) =>
      p.join(projectDir, '.fh-radio-studio');
  static String lastAppliedPackageManifestPath(String projectDir) {
    return p.join(
      metadataDir(projectDir),
      'last_applied_package_manifest.json',
    );
  }

  static String manifestPath(String projectDir) {
    return p.join(metadataDir(projectDir), 'project.json');
  }

  static bool isAudioPath(String path) {
    return _audioSuffixes.contains(p.extension(path).toLowerCase());
  }

  static void ensure(String projectDir) {
    for (final dir in [
      projectDir,
      sourcesDir(projectDir),
      sirenDir(projectDir),
      packagesDir(projectDir),
      backupsDir(projectDir),
      analysisDir(projectDir),
      metadataDir(projectDir),
    ]) {
      Directory(dir).createSync(recursive: true);
    }

    final manifest = File(manifestPath(projectDir));
    if (manifest.existsSync()) return;
    manifest.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        'schema': 1,
        'path_schema': 2,
        'current_project_dir': Directory(projectDir).absolute.path,
        'app': 'FH Radio Studio',
        'created_at': DateTime.now().toUtc().toIso8601String(),
        'folders': {
          'sources': 'sources',
          'siren': 'siren',
          'packages': 'packages',
          'backups': 'backups',
          'analysis': 'analysis',
        },
      }),
      encoding: utf8,
    );
  }

  static int cleanupInterruptedImportFiles(String projectDir) {
    var deleted = 0;
    for (final dirPath in [sourcesDir(projectDir), sirenDir(projectDir)]) {
      final dir = Directory(dirPath);
      if (!dir.existsSync()) continue;
      for (final item in dir.listSync(followLinks: false)) {
        if (item is! File) continue;
        final name = p.basename(item.path);
        if (!_isImportTempName(name)) continue;
        try {
          item.deleteSync();
          deleted += 1;
        } on FileSystemException {
          // The next startup/open can retry this stale import temp file.
        }
      }
    }
    return deleted;
  }

  static Map<String, dynamic> readSettings(String projectDir) {
    final manifest = File(manifestPath(projectDir));
    if (!manifest.existsSync()) return const {};
    try {
      final decoded = jsonDecode(manifest.readAsStringSync(encoding: utf8));
      if (decoded is! Map) return const {};
      final settings = decoded['settings'];
      if (settings is! Map) return const {};
      return settings.map((key, value) => MapEntry('$key', value));
    } on FormatException {
      return const {};
    } on FileSystemException {
      return const {};
    }
  }

  static bool needsPathMigration(String projectDir) {
    final manifest = File(manifestPath(projectDir));
    if (!manifest.existsSync()) return false;
    try {
      final decoded = jsonDecode(manifest.readAsStringSync(encoding: utf8));
      if (decoded is! Map) return true;
      if (decoded['path_schema'] != 2) return true;
      return _hasLegacyProjectPathReferences(projectDir);
    } on FormatException {
      return true;
    } on FileSystemException {
      return true;
    }
  }

  static void writeSettings(
    String projectDir, {
    String? gameDir,
    String? preferredPath,
    int? radio,
    String? sourceLang,
    String? targetLang,
    String? aiProfile,
  }) {
    ensure(projectDir);
    final manifest = File(manifestPath(projectDir));
    Map<String, dynamic> data;
    try {
      final decoded = jsonDecode(manifest.readAsStringSync(encoding: utf8));
      data = decoded is Map
          ? decoded.map((key, value) => MapEntry('$key', value))
          : <String, dynamic>{};
    } on FormatException {
      data = <String, dynamic>{};
    } on FileSystemException {
      data = <String, dynamic>{};
    }
    final settings = data['settings'] is Map
        ? (data['settings'] as Map).map((key, value) => MapEntry('$key', value))
        : <String, dynamic>{};
    if (gameDir != null) settings['game_dir'] = gameDir;
    if (preferredPath != null) settings['preferred_path'] = preferredPath;
    if (radio != null) settings['radio'] = radio;
    if (sourceLang != null) settings['source_lang'] = sourceLang;
    if (targetLang != null) settings['target_lang'] = targetLang;
    if (aiProfile != null) settings['ai_profile'] = aiProfile;
    data['schema'] = 2;
    data['current_project_dir'] = Directory(projectDir).absolute.path;
    data['app'] = data['app'] ?? 'FH Radio Studio';
    data['settings'] = settings;
    data['last_opened_at'] = DateTime.now().toUtc().toIso8601String();
    manifest.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(data),
      encoding: utf8,
    );
  }

  static List<File> collectAudioFiles(Iterable<String> inputs) {
    final files = <File>[];
    final seen = <String>{};
    for (final raw in inputs) {
      final path = raw.trim();
      if (path.isEmpty) continue;
      final file = File(path);
      if (file.existsSync()) {
        if (isAudioPath(file.path) && seen.add(_pathKey(file.path))) {
          files.add(file.absolute);
        }
        continue;
      }

      final dir = Directory(path);
      if (!dir.existsSync()) continue;
      final children =
          dir
              .listSync(followLinks: false)
              .whereType<File>()
              .where((item) => isAudioPath(item.path))
              .map((item) => item.absolute)
              .toList()
            ..sort(
              (a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()),
            );
      for (final child in children) {
        if (seen.add(_pathKey(child.path))) files.add(child);
      }
    }
    return files;
  }

  static List<String> importAudioFiles({
    required String projectDir,
    required Iterable<String> inputs,
  }) {
    ensure(projectDir);
    final sourceDir = Directory(sourcesDir(projectDir));
    final imported = <String>[];
    for (final file in collectAudioFiles(inputs)) {
      if (isCanonicalPathInside(sourceDir.path, file.path)) {
        imported.add(file.path);
        continue;
      }
      final destination = _uniqueDestination(
        sourceDir.path,
        p.basename(file.path),
      );
      file.copySync(destination.path);
      imported.add(destination.path);
    }
    return imported;
  }

  static String currentPackageDir(String projectDir) {
    return p.join(packagesDir(projectDir), 'current');
  }

  static String pendingPackageDir(String projectDir) {
    return p.join(packagesDir(projectDir), 'pending');
  }

  static String backupDir({required String projectDir, required String name}) {
    return p.join(backupsDir(projectDir), name);
  }

  static String safeName(String name) {
    final stem = name.replaceAll(RegExp(r'\.[^.]+$'), '');
    final normalized = stem
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    return normalized.isEmpty ? 'package' : normalized;
  }

  static String _homeDir() {
    final env = Platform.environment;
    if (Platform.isWindows) {
      final userProfile = env['USERPROFILE'];
      if (userProfile != null && userProfile.trim().isNotEmpty) {
        return userProfile;
      }
      final drive = env['HOMEDRIVE'];
      final path = env['HOMEPATH'];
      if (drive != null &&
          drive.trim().isNotEmpty &&
          path != null &&
          path.trim().isNotEmpty) {
        return '$drive$path';
      }
    }
    final home = env['HOME'];
    if (home != null && home.trim().isNotEmpty) return home;
    return Directory.current.absolute.path;
  }

  static File _uniqueDestination(String dir, String basename) {
    final safeBase = basename.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_');
    final extension = p.extension(safeBase);
    final stem = p.basenameWithoutExtension(safeBase).trim();
    final baseStem = stem.isEmpty ? 'track' : stem;
    var candidate = File(p.join(dir, '$baseStem$extension'));
    var index = 2;
    while (candidate.existsSync()) {
      candidate = File(p.join(dir, '$baseStem-$index$extension'));
      index += 1;
    }
    return candidate;
  }

  static bool _isImportTempName(String name) {
    return name.startsWith('.') && name.contains('.fh-radio-studio-import-tmp');
  }

  static String _pathKey(String path) => canonicalPathKey(path);

  static bool _hasLegacyProjectPathReferences(String projectDir) {
    final files = <File>[
      File(p.join(metadataDir(projectDir), 'track_metadata.json')),
      File(p.join(metadataDir(projectDir), 'playlist_plan.json')),
      File(p.join(analysisDir(projectDir), 'track_timing.json')),
      File(p.join(analysisDir(projectDir), 'build_timing_manifest.json')),
      File(p.join(sirenDir(projectDir), 'siren_imports.json')),
      File(lastAppliedPackageManifestPath(projectDir)),
    ];

    final packageRoot = Directory(packagesDir(projectDir));
    if (packageRoot.existsSync()) {
      for (final child in packageRoot.listSync(followLinks: false)) {
        if (child is! Directory) continue;
        files.add(
          File(
            p.join(
              child.path,
              'package',
              'fh_radio_studio_package_manifest.json',
            ),
          ),
        );
      }
    }

    final backupRoot = Directory(backupsDir(projectDir));
    if (backupRoot.existsSync()) {
      for (final child in backupRoot.listSync(followLinks: false)) {
        if (child is! Directory) continue;
        files.add(File(p.join(child.path, 'baseline_manifest.json')));
        files.add(File(p.join(child.path, 'derived', 'bank_order.json')));
      }
    }

    for (final file in files) {
      if (!file.existsSync()) continue;
      try {
        final decoded = jsonDecode(file.readAsStringSync(encoding: utf8));
        if (_containsLegacyProjectPath(
          projectDir,
          decoded,
          _legacyProjectPathFields,
        )) {
          return true;
        }
      } on FormatException {
        continue;
      } on FileSystemException {
        continue;
      }
    }
    return false;
  }

  static bool _containsLegacyProjectPath(
    String projectDir,
    Object? value,
    Set<String> projectPathFields,
  ) {
    if (value is Map) {
      for (final entry in value.entries) {
        final key = '${entry.key}';
        if (projectPathFields.contains(key) &&
            _isLegacyProjectPath(projectDir, entry.value)) {
          return true;
        }
        if (_containsLegacyProjectPath(
          projectDir,
          entry.value,
          projectPathFields,
        )) {
          return true;
        }
      }
    } else if (value is List) {
      for (final item in value) {
        if (_containsLegacyProjectPath(projectDir, item, projectPathFields)) {
          return true;
        }
      }
    }
    return false;
  }

  static bool _isLegacyProjectPath(String projectDir, Object? value) {
    if (value is! String || value.trim().isEmpty) return false;
    if (value.startsWith('fh-project:/')) return false;
    if (!p.isAbsolute(value)) return false;
    return isCanonicalPathInside(
      Directory(projectDir).absolute.path,
      File(value).absolute.path,
    );
  }
}
