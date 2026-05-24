import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:path/path.dart' as p;
import 'package:fh_radio_studio/core/project_workspace.dart';
import 'package:fh_radio_studio/screens/backups.dart';
import 'package:fh_radio_studio/state/app_state.dart';
import 'package:fh_radio_studio/state/backup_history_state.dart';
import 'package:fh_radio_studio/state/studio_state.dart';
import 'package:fh_radio_studio/theme/accents.dart';
import 'package:fh_radio_studio/theme/app_theme.dart';
import 'package:fh_radio_studio/theme/tokens.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _projectDirKey = 'rm.cli.projectDir';

void main() {
  testWidgets(
    'capture backups screen with Flutter render tree',
    (tester) async {
      GoogleFonts.config.allowRuntimeFetching = false;
      final tempRoot = Directory.systemTemp.createTempSync(
        'fh_radio_studio_backups_capture_',
      );
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
      });

      final projectDir = p.join(tempRoot.path, 'project');
      final gameDir = p.join(tempRoot.path, 'game');
      FhRadioStudioProject.ensure(projectDir);
      FhRadioStudioProject.writeSettings(projectDir, gameDir: gameDir);
      _writeSnapshotFolders(projectDir);
      SharedPreferences.setMockInitialValues({_projectDirKey: projectDir});
      final prefs = await SharedPreferences.getInstance();
      final controller = _CaptureStudioController(prefs);
      final entries = _backupEntries(projectDir);

      final outDir = Directory(p.join('build', 'visual_qa'))
        ..createSync(recursive: true);
      await _captureBackups(
        tester,
        prefs: prefs,
        controller: controller,
        entries: entries,
        logicalSize: const Size(1365, 900),
        outputPath: p.join(outDir.path, 'backups_regular.png'),
      );
      await _captureBackups(
        tester,
        prefs: prefs,
        controller: controller,
        entries: entries,
        logicalSize: const Size(1365, 1600),
        outputPath: p.join(outDir.path, 'backups_full.png'),
      );
      controller.setRefreshingForCapture(true);
      await _captureBackups(
        tester,
        prefs: prefs,
        controller: controller,
        entries: entries,
        logicalSize: const Size(1365, 900),
        outputPath: p.join(outDir.path, 'backups_refreshing_regular.png'),
      );
      await _captureBackups(
        tester,
        prefs: prefs,
        controller: controller,
        entries: entries,
        logicalSize: const Size(1365, 1600),
        outputPath: p.join(outDir.path, 'backups_refreshing_full.png'),
      );
    },
    skip: Platform.environment['CAPTURE_BACKUPS'] != '1',
  );
}

Future<void> _captureBackups(
  WidgetTester tester, {
  required SharedPreferences prefs,
  required _CaptureStudioController controller,
  required List<BackupHistoryEntry> entries,
  required Size logicalSize,
  required String outputPath,
}) async {
  final repaintKey = GlobalKey();
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = logicalSize;

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        studioProvider.overrideWith((ref) => controller),
        sharedPreferencesProvider.overrideWithValue(prefs),
        baselineBackupProvider.overrideWith((ref) => _baselineEntries()),
        backupHistoryProvider.overrideWith((ref) => entries),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildAppTheme(
          brightness: Brightness.light,
          accent: AppAccent.lime,
        ),
        home: Scaffold(
          body: RepaintBoundary(
            key: repaintKey,
            child: SizedBox.fromSize(
              size: logicalSize,
              child: const ColoredBox(
                color: RmTokens.bgLight,
                child: BackupsScreen(),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  expect(tester.takeException(), isNull);
  final gameCardHeight = tester
      .getSize(find.byKey(const ValueKey('backups-game-card')))
      .height;
  final configCardHeight = tester
      .getSize(find.byKey(const ValueKey('backups-config-card')))
      .height;
  expect(gameCardHeight, greaterThan(100));
  expect(configCardHeight, greaterThan(100));
  expect((gameCardHeight - configCardHeight).abs(), lessThanOrEqualTo(1));

  final boundary = repaintKey.currentContext?.findRenderObject();
  expect(boundary, isA<RenderRepaintBoundary>());
  await tester.runAsync(() async {
    final image = await (boundary! as RenderRepaintBoundary).toImage(
      pixelRatio: 1.5,
    );
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    expect(data, isNotNull);

    final output = File(outputPath);
    await output.parent.create(recursive: true);
    await output.writeAsBytes(data!.buffer.asUint8List(), flush: true);
    // ignore: avoid_print
    print('${p.basenameWithoutExtension(outputPath)}=${output.absolute.path}');
  });
}

class _CaptureStudioController extends StudioController {
  _CaptureStudioController(super.prefs) {
    state = state.copyWith(
      log: const ['视觉检查 fixture 已加载'],
      fileIntegrity: _captureIntegritySummary(),
      baselinePlanSummary: _captureBrokenBaselinePlan(),
    );
  }

  void setRefreshingForCapture(bool refreshing) {
    state = state.copyWith(
      busy: refreshing,
      busyLabel: refreshing ? '检查当前环境' : null,
    );
  }

  @override
  Future<void> refreshStatus({bool verifyFiles = false}) async {}
}

GameFileIntegritySummary _captureIntegritySummary() {
  return const GameFileIntegritySummary(
    level: GameFileIntegrityLevel.externalConflict,
    checkedFiles: 3,
    packageMatches: 0,
    lastAppliedPackageMatches: 0,
    baselineMatches: 0,
    pendingBaselineMatches: 0,
    changedFiles: 3,
    unknownFiles: 0,
    packageFiles: 0,
    baselineManifestPath: 'baseline_manifest.json',
    pendingBaselineManifestPath: null,
    packageManifestPath: null,
    lastAppliedPackageManifestPath: null,
    currentGameVersionId: 'steam-b23271700',
    baselineBuildCompatible: true,
    baselineSupportedGameVersionIds: ['steam-b23271700'],
    issues: [],
  );
}

BaselinePlanSummary _captureBrokenBaselinePlan() {
  return const BaselinePlanSummary(
    fileCount: 5,
    totalSize: 1024 * 64,
    gameVersionId: 'steam-b23271700',
    byScope: {'radio_info': 2, 'radio_bank': 2, 'string_table': 1},
    byStatus: {'backup_missing': 2, 'backup_changed': 1, 'ok': 2},
    files: [],
  );
}

List<BaselineBackupEntry> _baselineEntries() {
  return [
    BaselineBackupEntry(
      manifestPath: '',
      folderPath: '',
      state: 'current',
      fileCount: 5,
      bankCount: 3,
      radioInfoCount: 2,
      stringTableCount: 0,
      totalSize: 1024 * 1024 * 18,
      versionId: 'steam-b23271700',
      appId: '2483190',
      buildId: '23271700',
      contentUpdatedAt: DateTime.utc(2026, 5, 19, 12, 29),
      createdAt: DateTime.utc(2026, 5, 20, 4, 17),
      promotedAt: null,
    ),
  ];
}

List<BackupHistoryEntry> _backupEntries(String projectDir) {
  return [
    BackupHistoryEntry(
      manifestPath: p.join(
        projectDir,
        'backups',
        'manual',
        'manual-before-radio-test',
        'manual_snapshot_manifest.json',
      ),
      folderPath: p.join(
        projectDir,
        'backups',
        'manual',
        'manual-before-radio-test',
      ),
      fileCount: 2,
      bankCount: 0,
      radioInfoCount: 2,
      totalSize: 3 * 1024,
      createdAt: DateTime.utc(2026, 5, 20, 4, 20),
      packageName: '手动旧记录 - 音频调试前',
      kind: 'manual_snapshot',
      displayName: '手动旧记录 - 音频调试前',
      gameVersionId: 'steam-b23271700',
    ),
    BackupHistoryEntry(
      manifestPath: p.join(
        projectDir,
        'backups',
        'automatic',
        'r4-everything-s-alright-1x-20260520_163958',
        'deploy_manifest.json',
      ),
      folderPath: p.join(
        projectDir,
        'backups',
        'automatic',
        'r4-everything-s-alright-1x-20260520_163958',
      ),
      fileCount: 5,
      bankCount: 1,
      radioInfoCount: 2,
      totalSize: 5 * 1024,
      createdAt: DateTime.utc(2026, 5, 20, 8, 40),
      packageName: 'r4-everything-s-alright-1x-20260520_163958',
      kind: '',
      displayName: '',
      gameVersionId: 'steam-b23271700',
    ),
  ];
}

void _writeSnapshotFolders(String projectDir) {
  for (final folder in [
    p.join(projectDir, 'backups', 'manual', 'manual-before-radio-test'),
    p.join(
      projectDir,
      'backups',
      'automatic',
      'r4-everything-s-alright-1x-20260520_163958',
    ),
  ]) {
    final filesDir = Directory(p.join(folder, 'files', 'media', 'audio'))
      ..createSync(recursive: true);
    for (var i = 0; i < 2; i += 1) {
      File(
        p.join(filesDir.path, 'capture_$i.bin'),
      ).writeAsBytesSync(List<int>.filled(1024 * (i + 1), i), flush: true);
    }
  }
}
