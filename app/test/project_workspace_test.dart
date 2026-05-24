import 'dart:io';

import 'package:fh_radio_studio/core/project_workspace.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('ensure does not create legacy backup subdirectories', () {
    final root = Directory.systemTemp.createTempSync('fh-radio-workspace-');
    try {
      final projectDir = root.path;

      FhRadioStudioProject.ensure(projectDir);

      expect(
        Directory(FhRadioStudioProject.backupsDir(projectDir)).existsSync(),
        isTrue,
      );
      expect(
        Directory(
          '${FhRadioStudioProject.backupsDir(projectDir)}/manual',
        ).existsSync(),
        isFalse,
      );
      expect(
        Directory(
          '${FhRadioStudioProject.backupsDir(projectDir)}/automatic',
        ).existsSync(),
        isFalse,
      );
    } finally {
      if (root.existsSync()) {
        root.deleteSync(recursive: true);
      }
    }
  });
}
