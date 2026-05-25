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

  test('cleanup interrupted import temp files only removes project temps', () {
    final root = Directory.systemTemp.createTempSync('fh-radio-workspace-');
    try {
      final projectDir = root.path;
      FhRadioStudioProject.ensure(projectDir);
      final sourceTemp = File(
        '${FhRadioStudioProject.sourcesDir(projectDir)}/.Song.fh-radio-studio-import-tmp.wav',
      )..writeAsStringSync('partial');
      final sirenTemp = File(
        '${FhRadioStudioProject.sirenDir(projectDir)}/.MSR.fh-radio-studio-import-tmp.wav',
      )..writeAsStringSync('partial');
      final realAudio = File(
        '${FhRadioStudioProject.sourcesDir(projectDir)}/Song.wav',
      )..writeAsStringSync('audio');
      final unrelatedHidden = File(
        '${FhRadioStudioProject.sirenDir(projectDir)}/.keep.wav',
      )..writeAsStringSync('audio');

      final deleted = FhRadioStudioProject.cleanupInterruptedImportFiles(
        projectDir,
      );

      expect(deleted, 2);
      expect(sourceTemp.existsSync(), isFalse);
      expect(sirenTemp.existsSync(), isFalse);
      expect(realAudio.existsSync(), isTrue);
      expect(unrelatedHidden.existsSync(), isTrue);
    } finally {
      if (root.existsSync()) {
        root.deleteSync(recursive: true);
      }
    }
  });
}
