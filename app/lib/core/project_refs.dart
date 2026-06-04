import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'path_keys.dart';

const projectRefScheme = 'fh-project';
const projectRefPrefix = '$projectRefScheme:/';

const projectRefRoots = {
  '.fh-radio-studio',
  'analysis',
  'backups',
  'packages',
  'siren',
  'sources',
};

final _windowsDriveSegment = RegExp(r'^[A-Za-z]:$');
final _invalidPercent = RegExp(r'%(?![0-9A-Fa-f]{2})');

class ProjectRefException implements Exception {
  const ProjectRefException(this.message);

  final String message;

  @override
  String toString() => 'ProjectRefException: $message';
}

bool isProjectRef(Object? value) =>
    value is String && value.startsWith(projectRefPrefix);

String normalizeProjectRef(String value) {
  final segments = _parseProjectRefSegments(value);
  return _formatProjectRef(segments);
}

String? projectRefForPath(String projectDir, String path) {
  final root = p.normalize(Directory(projectDir).absolute.path);
  final child = p.normalize(File(path).absolute.path);
  if (!isCanonicalPathInside(root, child)) return null;

  final relative = p.normalize(p.relative(child, from: root));
  final segments = _normalizePathParts(p.split(relative));
  if (segments.isEmpty) return null;
  _validateProjectRefSegments(segments);
  return _formatProjectRef(segments);
}

String projectPathOrAbsolute(String projectDir, String path) {
  final sourceRef = projectRefForPath(projectDir, path);
  if (sourceRef != null) return sourceRef;
  return File(path).absolute.path;
}

String resolveProjectRef(String projectDir, String sourceRef) {
  final segments = _parseProjectRefSegments(sourceRef);
  final root = p.normalize(Directory(projectDir).absolute.path);
  final resolved = p.normalize(p.joinAll([root, ...segments]));
  if (!isCanonicalPathInside(root, resolved)) {
    throw ProjectRefException('Project ref escapes project root: $sourceRef');
  }
  return resolved;
}

String trackKeyForSourceRef(String sourceRef) {
  final canonical = normalizeProjectRef(sourceRef);
  final digest = sha256.convert(utf8.encode(canonical)).toString();
  return 'trkref_${digest.substring(0, 32)}';
}

String? trackKeyForProjectPath(String projectDir, String path) {
  final sourceRef = projectRefForPath(projectDir, path);
  return sourceRef == null ? null : trackKeyForSourceRef(sourceRef);
}

List<String> _parseProjectRefSegments(String value) {
  if (!value.startsWith(projectRefPrefix)) {
    throw ProjectRefException('Invalid project ref scheme: $value');
  }
  final rawPath = value.substring(projectRefPrefix.length);
  if (rawPath.isEmpty || rawPath.startsWith('/')) {
    throw ProjectRefException('Invalid project ref path: $value');
  }
  if (rawPath.contains('?') || rawPath.contains('#')) {
    throw ProjectRefException(
      'Project ref path must percent-encode reserved characters: $value',
    );
  }
  if (_invalidPercent.hasMatch(rawPath)) {
    throw ProjectRefException('Invalid percent escape in project ref: $value');
  }

  final decoded = <String>[];
  for (final rawSegment in rawPath.split('/')) {
    if (rawSegment.isEmpty || rawSegment == '.') continue;
    if (rawSegment == '..') {
      throw ProjectRefException("Project ref cannot contain '..': $value");
    }
    late final String segment;
    try {
      segment = Uri.decodeComponent(rawSegment);
    } on FormatException catch (error) {
      throw ProjectRefException(
        'Project ref segment is not UTF-8: $value ($error)',
      );
    }
    _validateDecodedSegment(segment, value);
    decoded.add(segment);
  }
  if (decoded.isEmpty) {
    throw ProjectRefException('Project ref path is empty: $value');
  }
  _validateProjectRefSegments(decoded);
  return decoded;
}

List<String> _normalizePathParts(List<String> parts) {
  final out = <String>[];
  for (final raw in parts) {
    if (raw.isEmpty || raw == '.') continue;
    if (raw == '..') {
      throw const ProjectRefException("Project path cannot contain '..'");
    }
    _validateDecodedSegment(raw, raw);
    out.add(raw);
  }
  return out;
}

void _validateProjectRefSegments(List<String> segments) {
  if (segments.isEmpty) {
    throw const ProjectRefException('Project ref path is empty');
  }
  if (!projectRefRoots.contains(segments.first)) {
    throw ProjectRefException(
      'Project ref root is not allowed: ${segments.first}',
    );
  }
  for (final segment in segments) {
    _validateDecodedSegment(segment, segments.join('/'));
  }
}

void _validateDecodedSegment(String segment, String source) {
  if (segment.isEmpty || segment == '.' || segment == '..') {
    throw ProjectRefException('Invalid project ref segment: $source');
  }
  if (segment.codeUnits.any((unit) => unit < 0x20 || unit == 0x7F)) {
    throw ProjectRefException(
      'Project ref segment contains a control character: $source',
    );
  }
  if (segment.contains('/') || segment.contains(r'\')) {
    throw ProjectRefException(
      'Project ref segment contains a path separator: $source',
    );
  }
  if (_windowsDriveSegment.hasMatch(segment)) {
    throw ProjectRefException(
      'Project ref segment contains a Windows drive: $source',
    );
  }
}

String _formatProjectRef(List<String> segments) {
  return '$projectRefPrefix${segments.map(_encodeSegment).join('/')}';
}

// RFC 3986 unreserved characters. Both the Dart and Python codecs must encode any
// byte outside this set as upper-case percent escapes so that the same project
// path yields a byte-identical `source_ref` (and therefore an identical
// `track_key`) on every platform. Do not swap this for `Uri.encodeComponent`;
// it leaves `!*'()` unencoded, which would fork the cross-platform identity from
// the Python codec.
String _encodeSegment(String segment) {
  final buffer = StringBuffer();
  for (final byte in utf8.encode(segment)) {
    if (_isUnreservedByte(byte)) {
      buffer.writeCharCode(byte);
    } else {
      buffer
        ..write('%')
        ..write(byte.toRadixString(16).toUpperCase().padLeft(2, '0'));
    }
  }
  return buffer.toString();
}

bool _isUnreservedByte(int byte) {
  final isDigit = byte >= 0x30 && byte <= 0x39;
  final isUpper = byte >= 0x41 && byte <= 0x5A;
  final isLower = byte >= 0x61 && byte <= 0x7A;
  // '-' 0x2D, '.' 0x2E, '_' 0x5F, '~' 0x7E
  final isMark = byte == 0x2D || byte == 0x2E || byte == 0x5F || byte == 0x7E;
  return isDigit || isUpper || isLower || isMark;
}
