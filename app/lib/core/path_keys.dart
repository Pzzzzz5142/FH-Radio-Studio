import 'dart:io';

import 'package:path/path.dart' as p;

String canonicalPathKey(String path) {
  return p.canonicalize(File(path).absolute.path).toLowerCase();
}

bool sameCanonicalPath(String left, String right) {
  try {
    return canonicalPathKey(left) == canonicalPathKey(right);
  } on ArgumentError {
    return p.normalize(File(left).absolute.path).toLowerCase() ==
        p.normalize(File(right).absolute.path).toLowerCase();
  }
}

bool isCanonicalPathInside(String parent, String child) {
  try {
    final normalizedParent = p.canonicalize(parent);
    final normalizedChild = p.canonicalize(child);
    return p.equals(normalizedParent, normalizedChild) ||
        p.isWithin(normalizedParent, normalizedChild);
  } on ArgumentError {
    final normalizedParent = p.normalize(parent).toLowerCase();
    final normalizedChild = p.normalize(child).toLowerCase();
    return normalizedChild == normalizedParent ||
        normalizedChild.startsWith('$normalizedParent${p.separator}');
  }
}
