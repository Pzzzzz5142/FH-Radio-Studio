import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'path_keys.dart';
import 'project_refs.dart';

const projectJsonPathFields = {
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

class ProjectJsonPathViolation {
  const ProjectJsonPathViolation({
    required this.pointer,
    required this.field,
    required this.value,
    required this.message,
  });

  final String pointer;
  final String field;
  final String value;
  final String message;
}

class ProjectJsonPathSchemaException implements Exception {
  const ProjectJsonPathSchemaException({
    required this.projectDir,
    required this.violations,
    this.filePath,
  });

  final String projectDir;
  final String? filePath;
  final List<ProjectJsonPathViolation> violations;

  @override
  String toString() {
    final target = filePath == null ? 'project JSON' : filePath!;
    final first = violations
        .take(5)
        .map((violation) {
          return '${violation.pointer}: ${violation.message} (${violation.value})';
        })
        .join('; ');
    final suffix = violations.length > 5
        ? '; ... ${violations.length - 5} more'
        : '';
    return 'ProjectJsonPathSchemaException: $target has '
        '${violations.length} project path schema violation(s): $first$suffix';
  }
}

List<ProjectJsonPathViolation> findProjectJsonPathViolations({
  required String projectDir,
  required Object? payload,
  Set<String> pathFields = projectJsonPathFields,
}) {
  final root = p.normalize(Directory(projectDir).absolute.path);
  final violations = <ProjectJsonPathViolation>[];

  void walk(Object? value, List<String> pointer, String? field) {
    if (value is Map) {
      for (final entry in value.entries) {
        final key = '${entry.key}';
        walk(entry.value, [...pointer, key], key);
      }
      return;
    }
    if (value is List) {
      for (var index = 0; index < value.length; index += 1) {
        walk(value[index], [...pointer, '$index'], field);
      }
      return;
    }
    if (field == null || !pathFields.contains(field) || value is! String) {
      return;
    }

    final text = value.trim();
    if (text.isEmpty) return;
    final location = _jsonPointer(pointer);
    if (isProjectRef(text)) {
      try {
        normalizeProjectRef(text);
      } on ProjectRefException catch (error) {
        violations.add(
          ProjectJsonPathViolation(
            pointer: location,
            field: field,
            value: text,
            message: error.message,
          ),
        );
      }
      return;
    }
    if (!p.isAbsolute(text)) return;
    final absolute = p.normalize(File(text).absolute.path);
    if (!isCanonicalPathInside(root, absolute)) return;
    violations.add(
      ProjectJsonPathViolation(
        pointer: location,
        field: field,
        value: text,
        message: 'project-owned absolute path must be written as fh-project:/',
      ),
    );
  }

  walk(payload, const [], null);
  return violations;
}

void assertProjectJsonPathSchema({
  required String projectDir,
  required Object? payload,
  String? filePath,
  Set<String> pathFields = projectJsonPathFields,
}) {
  final violations = findProjectJsonPathViolations(
    projectDir: projectDir,
    payload: payload,
    pathFields: pathFields,
  );
  if (violations.isEmpty) return;
  throw ProjectJsonPathSchemaException(
    projectDir: projectDir,
    filePath: filePath,
    violations: violations,
  );
}

void writeProjectJsonSync({
  required String projectDir,
  required File file,
  required Object? payload,
  JsonEncoder encoder = const JsonEncoder.withIndent('  '),
  Set<String> pathFields = projectJsonPathFields,
}) {
  assertProjectJsonPathSchema(
    projectDir: projectDir,
    payload: payload,
    filePath: file.path,
    pathFields: pathFields,
  );
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(encoder.convert(payload), encoding: utf8);
}

String _jsonPointer(List<String> segments) {
  if (segments.isEmpty) return '/';
  return segments.map((segment) {
    return '/${segment.replaceAll('~', '~0').replaceAll('/', '~1')}';
  }).join();
}
