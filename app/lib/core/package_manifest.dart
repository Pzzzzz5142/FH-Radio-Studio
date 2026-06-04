import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

const packageManifestFileName = 'fh_radio_studio_package_manifest.json';

String packageManifestPath(String packageDir) {
  return p.join(packageDir, 'package', packageManifestFileName);
}

File? packageManifestFile(String? packageDir) {
  if (packageDir == null || packageDir.trim().isEmpty) return null;
  final file = File(packageManifestPath(packageDir));
  return file.existsSync() ? file : null;
}

Map<String, dynamic>? readPackageManifest(String? packageDir) {
  final manifest = packageManifestFile(packageDir);
  return readPackageManifestFile(manifest?.path);
}

Map<String, dynamic>? readPackageManifestFile(String? manifestPath) {
  if (manifestPath == null || manifestPath.trim().isEmpty) return null;
  final manifest = File(manifestPath);
  if (!manifest.existsSync()) return null;
  try {
    final decoded = jsonDecode(manifest.readAsStringSync(encoding: utf8));
    if (decoded is! Map) return null;
    return decoded.map((key, value) => MapEntry('$key', value))
      ..['_manifest_path'] = manifest.absolute.path;
  } on FormatException {
    return null;
  } on FileSystemException {
    return null;
  }
}
