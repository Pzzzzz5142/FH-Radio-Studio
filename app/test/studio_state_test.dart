import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:fh_radio_studio/core/playlist_plan.dart';
import 'package:fh_radio_studio/core/project_workspace.dart';
import 'package:fh_radio_studio/state/studio_state.dart';
import 'package:fh_radio_studio/state/playlist_plan_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _projectDirKey = 'rm.studio.projectDir';
const _recentProjectDirsKey = 'rm.studio.recentProjectDirs';

void main() {
  group('torchWheelMirrorEnvironment', () {
    test('uses find-links for Aliyun flat wheel mirrors', () {
      expect(
        torchWheelMirrorEnvironment(
          'https://mirrors.aliyun.com/pytorch-wheels/cu128/',
          'torch-cu128',
        ),
        equals({
          'UV_FIND_LINKS': 'https://mirrors.aliyun.com/pytorch-wheels/cu128/',
          'UV_NO_SOURCES_PACKAGE': 'torch torchaudio',
        }),
      );
    });

    test('switches Aliyun flavor to match the selected torch extra', () {
      expect(
        torchWheelMirrorEnvironment(
          'https://mirrors.aliyun.com/pytorch-wheels/cu128/',
          'torch-cpu',
        )['UV_FIND_LINKS'],
        'https://mirrors.aliyun.com/pytorch-wheels/cpu/',
      );
    });

    test('allows explicit custom flat wheel overrides', () {
      expect(
        torchWheelMirrorEnvironment(
          'https://mirror.example.com/pytorch/cu128/#flat',
          'torch-cu128',
        ),
        equals({
          'UV_FIND_LINKS': 'https://mirror.example.com/pytorch/cu128/',
          'UV_NO_SOURCES_PACKAGE': 'torch torchaudio',
        }),
      );
    });

    test('can force flat mode for automatic retry', () {
      expect(
        torchWheelMirrorEnvironment(
          'https://mirror.example.com/pytorch/cu128/',
          'torch-cu128',
          modeOverride: TorchWheelMirrorMode.findLinks,
        ),
        equals({
          'UV_FIND_LINKS': 'https://mirror.example.com/pytorch/cu128/',
          'UV_NO_SOURCES_PACKAGE': 'torch torchaudio',
        }),
      );
    });

    test('strips flat query marker before passing the URL to uv', () {
      expect(
        torchWheelMirrorEnvironment(
          'https://mirror.example.com/pytorch/cu128/?format=flat',
          'torch-cu128',
        )['UV_FIND_LINKS'],
        'https://mirror.example.com/pytorch/cu128/',
      );
    });

    test('uses package find-links for simple index mirrors', () {
      expect(
        torchWheelMirrorEnvironment(
          'https://mirror.sjtu.edu.cn/pytorch-wheels/cu128/',
          'torch-cu128',
        ),
        equals({
          'UV_FIND_LINKS':
              'https://mirror.sjtu.edu.cn/pytorch-wheels/cu128/torch/ '
              'https://mirror.sjtu.edu.cn/pytorch-wheels/cu128/torchaudio/',
          'UV_NO_SOURCES_PACKAGE': 'torch torchaudio',
        }),
      );
    });

    test('allows forcing package find-links for known flat mirrors', () {
      expect(
        torchWheelMirrorEnvironment(
          'https://mirrors.aliyun.com/pytorch-wheels/cu128/#index',
          'torch-cu128',
        ),
        equals({
          'UV_FIND_LINKS':
              'https://mirrors.aliyun.com/pytorch-wheels/cu128/torch/ '
              'https://mirrors.aliyun.com/pytorch-wheels/cu128/torchaudio/',
          'UV_NO_SOURCES_PACKAGE': 'torch torchaudio',
        }),
      );
    });
  });

  test('detects Provider Warmup failures from successful CLI output', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final controller = StudioController(prefs);

    expect(
      controller.modelWarmupFailuresForTest(r'''
Created AI model manifest scaffold: C:\\FH Radio Studio\\models\\ai_tools_manifest.json
  warmed beat_this: ready
  warmed songformer: error
  warmed mert: missing
  warmed demucs: ready
退出码：0
'''),
      ['songformer=error', 'mert=missing'],
    );
  });

  group('StudioController recent projects', () {
    late Directory tempRoot;

    setUp(() {
      tempRoot = Directory.systemTemp.createTempSync(
        'fh_radio_studio_state_test_',
      );
    });

    tearDown(() {
      if (tempRoot.existsSync()) {
        tempRoot.deleteSync(recursive: true);
      }
    });

    test(
      'removes a stale current project pointer with its recent entry',
      () async {
        final staleProject = p.join(tempRoot.path, 'moved-project');
        SharedPreferences.setMockInitialValues({
          _projectDirKey: staleProject,
          _recentProjectDirsKey: [staleProject],
        });

        final prefs = await SharedPreferences.getInstance();
        final controller = StudioController(prefs);

        expect(controller.state.hasProject, isFalse);
        expect(controller.state.recentProjectDirs, contains(staleProject));

        controller.removeRecentProject(staleProject);

        expect(prefs.getString(_projectDirKey), isNull);
        expect(controller.state.hasProject, isFalse);
        expect(
          controller.state.recentProjectDirs,
          isNot(contains(staleProject)),
        );
      },
    );

    test(
      'relocates a stale current project pointer into an active project',
      () async {
        final staleProject = p.join(tempRoot.path, 'old-location');
        final relocatedProject = p.join(tempRoot.path, 'new-location');
        SharedPreferences.setMockInitialValues({
          _projectDirKey: staleProject,
          _recentProjectDirsKey: [staleProject],
        });

        final prefs = await SharedPreferences.getInstance();
        final controller = StudioController(prefs);

        controller.updateRecentProjectPath(staleProject, relocatedProject);

        final expectedProject = File(relocatedProject).absolute.path;
        expect(controller.state.hasProject, isTrue);
        expect(controller.state.projectDir, expectedProject);
        expect(controller.state.recentProjectDirs, contains(expectedProject));
        expect(
          controller.state.recentProjectDirs,
          isNot(contains(staleProject)),
        );
        expect(prefs.getString(_projectDirKey), expectedProject);
        expect(
          File(FhRadioStudioProject.manifestPath(expectedProject)).existsSync(),
          isTrue,
        );
      },
    );

    test('persists the selected AI pipeline profile in the project', () async {
      final projectDir = p.join(tempRoot.path, 'project');
      FhRadioStudioProject.ensure(projectDir);
      SharedPreferences.setMockInitialValues({_projectDirKey: projectDir});

      final prefs = await SharedPreferences.getInstance();
      final controller = StudioController(prefs);

      controller.setAiProfile('local-deep');

      expect(controller.state.aiProfile, 'local-deep');
      expect(controller.state.toolchainStatus.profile, 'local-deep');
      expect(
        FhRadioStudioProject.readSettings(projectDir)['ai_profile'],
        'local-deep',
      );
    });

    test('checks toolchain after changing the AI pipeline profile', () async {
      final projectDir = p.join(tempRoot.path, 'project');
      FhRadioStudioProject.ensure(projectDir);
      SharedPreferences.setMockInitialValues({_projectDirKey: projectDir});

      final prefs = await SharedPreferences.getInstance();
      final controller = _MutableStudioController(prefs);

      await controller.setAiProfileAndRefreshToolchain('local-deep');
      await controller.setAiProfileAndRefreshToolchain('local-deep');

      expect(controller.state.aiProfile, 'local-deep');
      expect(controller.toolchainRefreshCount, 1);
      expect(
        FhRadioStudioProject.readSettings(projectDir)['ai_profile'],
        'local-deep',
      );
    });

    test('falls back from unsupported AI profile to local', () async {
      final projectDir = p.join(tempRoot.path, 'project');
      FhRadioStudioProject.ensure(projectDir);
      FhRadioStudioProject.writeSettings(projectDir, aiProfile: 'remote-test');
      SharedPreferences.setMockInitialValues({_projectDirKey: projectDir});

      final prefs = await SharedPreferences.getInstance();
      final controller = StudioController(prefs);

      expect(controller.state.aiProfile, kDefaultAiPipelineProfile);
      controller.setAiProfile('remote-test');
      expect(controller.state.aiProfile, kDefaultAiPipelineProfile);
    });

    test('core toolchain lock ignores optional AI and hardware sections', () {
      const optionalOnly = ToolchainStatusSummary(
        checked: true,
        profile: 'local-heavy',
        status: 'ready',
        label: 'OK',
        summary: '核心工具链可用；AI 和硬件加速会按实际能力降级。',
        sections: [
          ToolchainStatusSection(
            id: 'uv',
            title: 'uv 运行时',
            status: 'ready',
            summary: 'uv ready',
            items: [],
            warnings: [],
          ),
          ToolchainStatusSection(
            id: 'audio_tools',
            title: '核心音频工具',
            status: 'ready',
            summary: '核心音频处理组件可用',
            items: [],
            warnings: [],
          ),
          ToolchainStatusSection(
            id: 'python',
            title: 'Python 环境',
            status: 'needs_sync',
            summary: '基础 Python 可用；可选 AI 依赖待同步',
            items: [],
            warnings: [],
          ),
          ToolchainStatusSection(
            id: 'hardware',
            title: '硬件加速',
            status: 'missing',
            summary: 'torch 未安装',
            items: [],
            warnings: [],
          ),
          ToolchainStatusSection(
            id: 'ai',
            title: 'AI 分析',
            status: 'missing',
            summary: '深度 AI Providers 尚未就绪',
            items: [],
            warnings: [],
          ),
        ],
        fixes: [],
      );
      const missingAudio = ToolchainStatusSummary(
        checked: true,
        profile: 'local-base',
        status: 'missing',
        label: '需要处理',
        summary: '核心工具链有缺失项，请先修复基础处理组件。',
        sections: [
          ToolchainStatusSection(
            id: 'audio_tools',
            title: '核心音频工具',
            status: 'missing',
            summary: '缺少 ffmpeg',
            items: [],
            warnings: [],
          ),
        ],
        fixes: [],
      );

      expect(optionalOnly.coreBlocking, isFalse);
      expect(missingAudio.coreBlocking, isTrue);
    });

    test(
      'downgrades unavailable AI profile and persists the fallback',
      () async {
        final projectDir = p.join(tempRoot.path, 'project');
        FhRadioStudioProject.ensure(projectDir);
        SharedPreferences.setMockInitialValues({_projectDirKey: projectDir});

        final prefs = await SharedPreferences.getInstance();
        final controller = _ToolchainFallbackController(prefs, {
          'local-heavy': _toolchainStatus(
            profile: 'local-heavy',
            python: 'needs_sync',
            ai: 'missing',
          ),
          'local-deep': _toolchainStatus(
            profile: 'local-deep',
            python: 'ready',
            ai: 'degraded',
          ),
          'local-base': _toolchainStatus(
            profile: 'local-base',
            python: 'ready',
            ai: 'ready',
          ),
        });

        await controller.refreshToolchainStatus();

        expect(controller.requestedProfiles, [
          'local-heavy',
          'local-deep',
          'local-base',
        ]);
        expect(controller.state.aiProfile, 'local-base');
        expect(controller.state.toolchainStatus.profile, 'local-base');
        expect(controller.state.aiProfileNotice, contains('自动降级'));
        expect(
          FhRadioStudioProject.readSettings(projectDir)['ai_profile'],
          'local-base',
        );
        expect(prefs.getString('rm.studio.aiProfile'), 'local-base');

        controller.setAiProfile('local-base');
        expect(controller.state.aiProfileNotice, isNull);
      },
    );

    test('core toolchain lock blocks package build actions', () async {
      final projectDir = p.join(tempRoot.path, 'project');
      _writeIntegrityFixture(projectDir, deployedBytes: 'original');
      SharedPreferences.setMockInitialValues({_projectDirKey: projectDir});

      final prefs = await SharedPreferences.getInstance();
      final controller = _MutableStudioController(prefs);
      controller.setStateForTest(
        controller.state.copyWith(
          toolchainStatus: const ToolchainStatusSummary(
            checked: true,
            profile: 'local-base',
            status: 'missing',
            label: '需要处理',
            summary: '核心工具链有缺失项，请先修复基础处理组件。',
            sections: [
              ToolchainStatusSection(
                id: 'audio_tools',
                title: '核心音频工具',
                status: 'missing',
                summary: '缺少 ffmpeg',
                items: [],
                warnings: [],
              ),
            ],
            fixes: [],
          ),
        ),
      );

      final built = await controller.buildPackage();

      expect(built, isFalse);
      expect(controller.state.projectEditingLocked, isTrue);
      expect(controller.state.customSongEditingLocked, isTrue);
      expect(controller.state.projectEditingLockMessage, contains('缺少 ffmpeg'));
      expect(controller.state.log.join('\n'), contains('已阻止：准备电台包'));
    });

    test(
      'clears stale file plan and starts a full scan when opening project',
      () async {
        final oldProject = p.join(tempRoot.path, 'old-project');
        final nextProject = p.join(tempRoot.path, 'next-project');
        FhRadioStudioProject.ensure(oldProject);
        FhRadioStudioProject.ensure(nextProject);
        SharedPreferences.setMockInitialValues({_projectDirKey: oldProject});

        final prefs = await SharedPreferences.getInstance();
        final controller = _MutableStudioController(prefs);
        controller.setStateForTest(
          controller.state.copyWith(baselinePlanSummary: _brokenBaselinePlan()),
        );

        controller.setProjectDirAndStartFullScan(nextProject);

        expect(controller.state.projectDir, File(nextProject).absolute.path);
        expect(controller.state.baselinePlanSummary, isNull);
        expect(controller.fullRefreshCount, 1);
      },
    );

    test(
      'missing baseline locks project workflows but not custom songs',
      () async {
        final projectDir = p.join(tempRoot.path, 'project');
        FhRadioStudioProject.ensure(projectDir);
        SharedPreferences.setMockInitialValues({_projectDirKey: projectDir});

        final prefs = await SharedPreferences.getInstance();
        final controller = _MutableStudioController(prefs);
        controller.setStateForTest(
          controller.state.copyWith(baselinePlanSummary: _brokenBaselinePlan()),
        );

        expect(controller.state.fileIntegrity.hasCurrentBaseline, isFalse);
        expect(controller.state.baselineIntegrityBroken, isFalse);
        expect(controller.state.baselineWorkflowLocked, isTrue);
        expect(controller.state.projectEditingLocked, isTrue);
        expect(controller.state.customSongEditingLocked, isFalse);
        expect(controller.state.baselineWorkflowLockTitle, contains('缺少原始备份'));
      },
    );

    test(
      'full file scan locks playlist workflows while keeping custom songs available',
      () async {
        final projectDir = p.join(tempRoot.path, 'project');
        FhRadioStudioProject.ensure(projectDir);
        SharedPreferences.setMockInitialValues({_projectDirKey: projectDir});

        final prefs = await SharedPreferences.getInstance();
        final controller = _MutableStudioController(prefs);
        controller.setStateForTest(
          controller.state.copyWith(
            busy: true,
            busyLabel: '完整校验当前环境',
            fileIntegrity: GameFileIntegritySummary.deferred(
              baselineManifestPath: 'baseline_manifest.json',
              pendingBaselineManifestPath: null,
              packageManifestPath: 'fh_radio_studio_package_manifest.json',
              lastAppliedPackageManifestPath: null,
            ),
          ),
        );

        expect(controller.state.baselineWorkflowLocked, isFalse);
        expect(controller.state.projectOperationLocked, isTrue);
        expect(controller.state.projectEditingLocked, isTrue);
        expect(controller.state.customSongEditingLocked, isFalse);
        expect(controller.state.projectEditingLockTitle, contains('正在处理项目'));
        expect(
          controller.state.projectEditingLockMessage,
          contains('正在扫描游戏文件'),
        );
      },
    );

    test('parses applied integrity from CLI JSON', () {
      final integrity = GameFileIntegritySummary.fromJson({
        'level': 'package_applied',
        'checked_files': 1,
        'package_matches': 1,
        'baseline_matches': 0,
        'pending_baseline_matches': 0,
        'changed_files': 0,
        'unknown_files': 0,
        'package_files': 1,
        'baseline_manifest_path': 'baseline_manifest.json',
        'package_manifest_path': 'fh_radio_studio_package_manifest.json',
        'issues': [],
      });

      expect(integrity.level, GameFileIntegrityLevel.packageApplied);
      expect(integrity.needsOverwrite, isFalse);
    });

    test('parses baseline integrity from CLI JSON', () {
      final integrity = GameFileIntegritySummary.fromJson({
        'level': 'baseline',
        'checked_files': 1,
        'package_matches': 0,
        'baseline_matches': 1,
        'pending_baseline_matches': 0,
        'changed_files': 0,
        'unknown_files': 0,
        'package_files': 1,
        'baseline_manifest_path': 'baseline_manifest.json',
        'package_manifest_path': 'fh_radio_studio_package_manifest.json',
        'issues': [],
      });

      expect(integrity.level, GameFileIntegrityLevel.baseline);
      expect(integrity.needsOverwrite, isTrue);
      expect(integrity.needsWriteVersionChoice, isFalse);
    });

    test('parses changed integrity and write choice from CLI JSON', () {
      final integrity = GameFileIntegritySummary.fromJson({
        'level': 'game_changed',
        'checked_files': 1,
        'package_matches': 0,
        'baseline_matches': 0,
        'pending_baseline_matches': 0,
        'changed_files': 1,
        'unknown_files': 0,
        'package_files': 1,
        'baseline_manifest_path': 'baseline_manifest.json',
        'package_manifest_path': 'fh_radio_studio_package_manifest.json',
        'issues': [
          {
            'label': 'media/audio/RadioInfo_CN.xml',
            'path': 'game/media/audio/RadioInfo_CN.xml',
            'detail': 'changed',
            'level': 'game_changed',
          },
        ],
      });

      expect(integrity.level, GameFileIntegrityLevel.gameChanged);
      expect(integrity.needsOverwrite, isTrue);
      expect(integrity.needsWriteVersionChoice, isTrue);
      expect(integrity.issues, isNotEmpty);
    });

    test('parses pending verify choice state from CLI JSON', () {
      final integrity = GameFileIntegritySummary.fromJson({
        'level': 'pending_verify',
        'checked_files': 1,
        'package_matches': 0,
        'baseline_matches': 0,
        'pending_baseline_matches': 1,
        'changed_files': 0,
        'unknown_files': 0,
        'package_files': 1,
        'baseline_manifest_path': 'baseline_manifest.json',
        'pending_baseline_manifest_path': 'pending_manifest.json',
        'package_manifest_path': 'fh_radio_studio_package_manifest.json',
        'issues': [],
      });

      expect(integrity.level, GameFileIntegrityLevel.pendingVerify);
      expect(integrity.needsWriteVersionChoice, isTrue);
    });

    test('hides write choices when CLI reports pending package applied', () {
      final integrity = GameFileIntegritySummary.fromJson({
        'level': 'pending_verify',
        'checked_files': 1,
        'package_matches': 1,
        'baseline_matches': 0,
        'pending_baseline_matches': 0,
        'changed_files': 0,
        'unknown_files': 0,
        'package_files': 1,
        'baseline_manifest_path': 'baseline_manifest.json',
        'pending_baseline_manifest_path': 'pending_manifest.json',
        'package_manifest_path': 'fh_radio_studio_package_manifest.json',
        'issues': [],
      });

      expect(integrity.level, GameFileIntegrityLevel.pendingVerify);
      expect(integrity.packageMatches, 1);
      expect(integrity.needsWriteVersionChoice, isFalse);
    });

    test(
      'deletes stale pending package when there is no pending baseline',
      () async {
        final projectDir = p.join(tempRoot.path, 'project');
        _writeIntegrityFixture(
          projectDir,
          deployedBytes: 'modded',
          pendingPackageBytes: 'stale pending',
        );
        SharedPreferences.setMockInitialValues({_projectDirKey: projectDir});

        final prefs = await SharedPreferences.getInstance();
        final controller = StudioController(prefs);

        expect(controller.state.pendingPackageDir, isNull);
        expect(
          Directory(
            FhRadioStudioProject.pendingPackageDir(projectDir),
          ).existsSync(),
          isFalse,
        );
      },
    );

    test(
      'keeps failed pending package slot visible while falling back to current package',
      () async {
        final projectDir = p.join(tempRoot.path, 'project');
        _writeIntegrityFixture(
          projectDir,
          deployedBytes: 'steam update',
          pendingBaselineBytes: 'steam update',
        );
        final failedPendingDir = FhRadioStudioProject.pendingPackageDir(
          projectDir,
        );
        File(
            p.join(
              failedPendingDir,
              'fh_radio_studio_package_build_failed.json',
            ),
          )
          ..createSync(recursive: true)
          ..writeAsStringSync('''
{
  "schema_version": 1,
  "kind": "pending_package_build_failure",
  "message": "fsbankcl failed"
}
''', encoding: utf8);
        SharedPreferences.setMockInitialValues({_projectDirKey: projectDir});

        final prefs = await SharedPreferences.getInstance();
        final controller = StudioController(prefs);

        expect(controller.state.pendingPackageDir, failedPendingDir);
        expect(controller.state.pendingPackageSummary, isNull);
        expect(controller.state.pendingPackageReady, isFalse);
        expect(controller.state.pendingPackageBuildFailed, isTrue);
        expect(
          controller.state.pendingPackageBuildFailureSummary,
          'fsbankcl failed',
        );
        expect(
          controller.state.integrityPackageDir,
          controller.state.lastPackageDir,
        );
      },
    );

    test(
      'hides write choices when pending verify exists but game matches original baseline',
      () {
        final integrity = GameFileIntegritySummary.fromJson({
          'level': 'baseline',
          'checked_files': 1,
          'package_matches': 0,
          'baseline_matches': 1,
          'pending_baseline_matches': 0,
          'changed_files': 0,
          'unknown_files': 0,
          'package_files': 1,
          'baseline_manifest_path': 'baseline_manifest.json',
          'pending_baseline_manifest_path': 'pending_manifest.json',
          'package_manifest_path': 'fh_radio_studio_package_manifest.json',
          'issues': [],
        });

        expect(integrity.level, GameFileIntegrityLevel.baseline);
        expect(integrity.needsWriteVersionChoice, isFalse);
      },
    );

    test(
      'promotes pending package into the single current slot on confirmation',
      () async {
        final projectDir = p.join(tempRoot.path, 'project');
        _writeIntegrityFixture(
          projectDir,
          deployedBytes: 'pending modded',
          pendingBaselineBytes: 'steam update',
          pendingPackageBytes: 'pending modded',
        );
        SharedPreferences.setMockInitialValues({_projectDirKey: projectDir});

        final prefs = await SharedPreferences.getInstance();
        final controller = StudioController(prefs);

        await controller.confirmPendingBaseline();

        final currentDir = FhRadioStudioProject.currentPackageDir(projectDir);
        final pendingDir = FhRadioStudioProject.pendingPackageDir(projectDir);
        final currentXml = File(
          p.join(currentDir, 'package', 'media', 'audio', 'RadioInfo_CN.xml'),
        );

        expect(Directory(pendingDir).existsSync(), isFalse);
        expect(controller.state.pendingPackageDir, isNull);
        expect(controller.state.lastPackageDir, currentDir);
        expect(currentXml.readAsStringSync(encoding: utf8), 'pending modded');
      },
    );

    test(
      'discarding pending baseline deletes only the pending package',
      () async {
        final projectDir = p.join(tempRoot.path, 'project');
        _writeIntegrityFixture(
          projectDir,
          deployedBytes: 'steam update',
          pendingBaselineBytes: 'steam update',
          pendingPackageBytes: 'pending modded',
        );
        SharedPreferences.setMockInitialValues({_projectDirKey: projectDir});

        final prefs = await SharedPreferences.getInstance();
        final controller = StudioController(prefs);

        await controller.discardPendingBaseline();

        expect(
          Directory(
            FhRadioStudioProject.pendingPackageDir(projectDir),
          ).existsSync(),
          isFalse,
        );
        expect(
          Directory(
            FhRadioStudioProject.currentPackageDir(projectDir),
          ).existsSync(),
          isTrue,
        );
        expect(controller.state.pendingPackageDir, isNull);
      },
    );

    test('does not build from sources when playlist draft is empty', () async {
      final projectDir = p.join(tempRoot.path, 'project');
      final paths = _writeIntegrityFixture(
        projectDir,
        deployedBytes: 'original',
      );
      Directory(paths.packageRoot).deleteSync(recursive: true);
      final source = File(
        p.join(FhRadioStudioProject.sourcesDir(projectDir), 'loose-song.wav'),
      );
      source.writeAsBytesSync([0, 1, 2, 3]);
      SharedPreferences.setMockInitialValues({_projectDirKey: projectDir});

      final prefs = await SharedPreferences.getInstance();
      final controller = StudioController(prefs);

      final built = await controller.buildPackage();

      expect(built, isFalse);
      expect(controller.state.lastPackageDir, isNull);
      expect(
        controller.state.log,
        contains('播放列表还没有分配曲目。请先在“播放列表”里把自建歌曲拖到目标电台。'),
      );
    });

    test(
      'does not rebuild when current package already matches playlist draft',
      () async {
        final projectDir = p.join(tempRoot.path, 'project');
        final paths = _writeIntegrityFixture(
          projectDir,
          deployedBytes: 'original',
        );
        final source = File(
          p.join(FhRadioStudioProject.sourcesDir(projectDir), 'same-song.wav'),
        )..createSync(recursive: true);
        _writePackageManifestFile(
          File(
            p.join(
              paths.packageRoot,
              'package',
              'fh_radio_studio_package_manifest.json',
            ),
          ),
          source: source.path,
          radioCode: 'XS',
          playlistType: 'FreeRoam',
          slot: 1,
        );
        PlaylistPlanStore.write(
          projectDir,
          const PlaylistPlan.empty().assign(
            source: source.path,
            radioCode: 'XS',
            playlistType: 'FreeRoam',
            slot: 1,
          ),
        );
        SharedPreferences.setMockInitialValues({_projectDirKey: projectDir});

        final prefs = await SharedPreferences.getInstance();
        final controller = StudioController(prefs);

        final built = await controller.buildPackage();

        expect(built, isFalse);
        expect(controller.state.log, contains('准备包已经等于当前播放列表；修改分配或语言后再重新构建。'));
      },
    );

    test(
      'uses last applied package assignments when current package is missing',
      () async {
        final projectDir = p.join(tempRoot.path, 'project');
        final paths = _writeIntegrityFixture(
          projectDir,
          deployedBytes: 'original',
        );
        Directory(paths.packageRoot).deleteSync(recursive: true);
        final missingSource = p.join(
          FhRadioStudioProject.sourcesDir(projectDir),
          'previous-song.wav',
        );
        _writePackageManifestFile(
          File(FhRadioStudioProject.lastAppliedPackageManifestPath(projectDir)),
          source: missingSource,
          radioCode: 'XS',
          playlistType: 'FreeRoam',
          slot: 1,
        );
        SharedPreferences.setMockInitialValues({_projectDirKey: projectDir});

        final prefs = await SharedPreferences.getInstance();
        final controller = StudioController(prefs);

        final built = await controller.buildPackage();

        expect(built, isFalse);
        expect(
          controller.state.log,
          isNot(contains('播放列表还没有分配曲目。请先在“播放列表”里把自建歌曲拖到目标电台。')),
        );
        expect(controller.state.log.join('\n'), contains('previous-song.wav'));
      },
    );

    test(
      'cleans missing playlist sources after package build preflight',
      () async {
        final projectDir = p.join(tempRoot.path, 'project');
        _writeIntegrityFixture(projectDir, deployedBytes: 'original');
        final source = File(
          p.join(
            FhRadioStudioProject.sourcesDir(projectDir),
            'deleted-song.wav',
          ),
        );
        source.createSync(recursive: true);
        PlaylistPlanStore.write(
          projectDir,
          const PlaylistPlan.empty().assign(
            source: source.path,
            radioCode: 'R4',
            playlistType: 'FreeRoam',
            slot: 1,
          ),
        );
        source.deleteSync();
        SharedPreferences.setMockInitialValues({_projectDirKey: projectDir});

        final prefs = await SharedPreferences.getInstance();
        final controller = StudioController(prefs);

        final built = await controller.buildPackage();

        expect(built, isFalse);
        expect(PlaylistPlanStore.read(projectDir).missingSources(), [
          source.absolute.path,
        ]);
        expect(controller.state.log.join('\n'), contains('播放列表草稿引用的项目源文件已不存在'));

        final cleaned = await controller.cleanupMissingPlaylistSources([
          source.path,
        ]);

        expect(cleaned, 1);
        expect(PlaylistPlanStore.read(projectDir).assignments, isEmpty);
        expect(
          controller.state.log.join('\n'),
          contains('已删除失效歌曲引用：deleted-song.wav。'),
        );
      },
    );

    test('tracks structured package build progress', () async {
      final projectDir = p.join(tempRoot.path, 'project');
      FhRadioStudioProject.ensure(projectDir);
      SharedPreferences.setMockInitialValues({_projectDirKey: projectDir});

      final prefs = await SharedPreferences.getInstance();
      final controller = _MutableStudioController(prefs);
      controller.setStateForTest(
        controller.state.copyWith(busy: true, busyLabel: '构建电台包'),
      );

      expect(
        controller.handleProgressLineForTest(
          'FH_RADIO_STUDIO_PROGRESS ${jsonEncode({
            'event': 'plan',
            'steps': [
              {'id': 'inspect_inputs', 'label': '读取构建输入', 'detail': '解析构建输入', 'weight': 1},
              {'id': 'radio.4.rebuild_bank', 'label': 'Horizon XS 重建 FMOD bank', 'detail': '运行 fsbankcl', 'weight': 8},
            ],
          })}',
        ),
        isTrue,
      );
      controller.handleProgressLineForTest(
        'FH_RADIO_STUDIO_PROGRESS ${jsonEncode({'event': 'step_completed', 'step_id': 'inspect_inputs', 'status': 'done', 'runtime_ms': 12})}',
      );
      controller.handleProgressLineForTest(
        'FH_RADIO_STUDIO_PROGRESS ${jsonEncode({'event': 'step_started', 'step_id': 'radio.4.rebuild_bank'})}',
      );

      final state = controller.state;
      expect(state.packageBuildProgressSteps, hasLength(2));
      expect(
        state.activePackageBuildProgressStep?.label,
        'Horizon XS 重建 FMOD bank',
      );
      expect(state.packageBuildProgressSteps.first.runtimeMs, 12);
      expect(state.packageBuildProgressPercent, 11);
    });

    test(
      'locks package edits but not custom songs when baseline is broken',
      () async {
        final projectDir = p.join(tempRoot.path, 'project');
        _writeIntegrityFixture(projectDir, deployedBytes: 'original');
        final source = File(p.join(tempRoot.path, 'song.wav'));
        _writePcmWav(source, sampleRate: 48000, frames: 2400);
        SharedPreferences.setMockInitialValues({_projectDirKey: projectDir});

        final prefs = await SharedPreferences.getInstance();
        final controller = _MutableStudioController(prefs);
        controller.setStateForTest(
          controller.state.copyWith(baselinePlanSummary: _brokenBaselinePlan()),
        );

        final built = await controller.buildPackage();
        await controller.importMusicPaths([source.path]);

        expect(built, isFalse);
        expect(controller.state.projectEditingLocked, isTrue);
        expect(controller.state.customSongEditingLocked, isFalse);
        expect(controller.state.musicPaths, hasLength(1));
        expect(p.basename(controller.state.musicPaths.single), 'song.wav');
        expect(controller.state.log.join('\n'), contains('只允许编辑歌曲的 6 个时间点'));
        expect(controller.state.log.join('\n'), contains('已阻止：准备电台包'));
        expect(controller.state.log.join('\n'), isNot(contains('已阻止：导入自建歌曲')));
      },
    );

    test('reads multi-radio package assignments into playlist plans', () async {
      final projectDir = p.join(tempRoot.path, 'project');
      FhRadioStudioProject.ensure(projectDir);
      FhRadioStudioProject.writeSettings(
        projectDir,
        gameDir: p.join(projectDir, 'game'),
      );
      final packageDir = FhRadioStudioProject.currentPackageDir(projectDir);
      final sourceXs = p.join(projectDir, 'sources', 'xs.wav');
      final sourceR5 = p.join(projectDir, 'sources', 'r5.wav');
      File(sourceXs).createSync(recursive: true);
      File(sourceR5).createSync(recursive: true);
      File(
          p.join(
            packageDir,
            'package',
            'fh_radio_studio_package_manifest.json',
          ),
        )
        ..createSync(recursive: true)
        ..writeAsStringSync('''
{
  "schema_version": 2,
  "radio": null,
  "station": "2 radios",
  "target_bank_name": "R4_Tracks_CU1.assets.bank, R5_Tracks_Disk.assets.bank",
  "bank_slots": 4,
  "playlist_mode": "only",
  "skip_bank": true,
  "radios": [
    {
      "radio": 4,
      "radio_code": "XS",
      "station": "Horizon XS",
      "music": [
        {
          "source": "${_jsonPath(sourceXs)}",
          "display_name": "XS Draft",
          "artist": "FH Radio Studio Dev"
        }
      ],
      "assignments": [
        {
          "slot_index": 0,
          "source_index": 0,
          "source": "${_jsonPath(sourceXs)}",
          "target_sound_name": "HZ6_R4_MOCK_SLOT_01",
          "playlist_entry": true,
          "playlist_types": ["FreeRoam"]
        }
      ]
    },
    {
      "radio": 5,
      "radio_code": "R5",
      "station": "Radio Eterna",
      "music": [
        {
          "source": "${_jsonPath(sourceR5)}",
          "display_name": "R5 Draft",
          "artist": "FH Radio Studio Dev"
        }
      ],
      "assignments": [
        {
          "slot_index": 0,
          "source_index": 0,
          "source": "${_jsonPath(sourceR5)}",
          "target_sound_name": "HZ6_R5_MOCK_REFERENCE",
          "playlist_entry": true,
          "playlist_types": ["Event"]
        }
      ]
    }
  ]
}
''', encoding: utf8);
      SharedPreferences.setMockInitialValues({_projectDirKey: projectDir});

      final prefs = await SharedPreferences.getInstance();
      final controller = StudioController(prefs);
      final summary = controller.state.lastPackageSummary;
      expect(summary, isNotNull);
      expect(summary!.radio, isNull);
      expect(summary.assignments, hasLength(2));
      expect(summary.assignments[0].playlistTypes, ['FreeRoam']);
      expect(summary.assignments[1].playlistTypes, ['Event']);

      final plan = playlistPlanFromPackageSummaries(
        pending: null,
        last: summary,
      );
      expect(plan.assignmentsForRadio('XS', 'FreeRoam'), hasLength(1));
      expect(plan.assignmentsForRadio('XS', 'Event'), isEmpty);
      expect(plan.assignmentsForRadio('R5', 'Event'), hasLength(1));
    });

    test('package summary displays capped replaceable slots', () async {
      final projectDir = p.join(tempRoot.path, 'project-capped-summary');
      FhRadioStudioProject.ensure(projectDir);
      FhRadioStudioProject.writeSettings(
        projectDir,
        gameDir: p.join(projectDir, 'game'),
      );
      final packageDir = FhRadioStudioProject.currentPackageDir(projectDir);
      final source = p.join(projectDir, 'sources', 'xs.wav');
      File(source).createSync(recursive: true);
      File(
          p.join(
            packageDir,
            'package',
            'fh_radio_studio_package_manifest.json',
          ),
        )
        ..createSync(recursive: true)
        ..writeAsStringSync('''
{
  "schema_version": 2,
  "radio": 4,
  "station": "Horizon XS",
  "target_bank_name": "R4_Tracks_CU1.assets.bank",
  "bank_slots": 3,
  "replaceable_slots": {"FreeRoam": 1, "Event": 1},
  "playlist_mode": "only",
  "skip_bank": true,
  "radios": [
    {
      "radio": 4,
      "radio_code": "XS",
      "station": "Horizon XS",
      "bank_slots": 3,
      "replaceable_slots": {"FreeRoam": 1, "Event": 1},
      "music": [
        {
          "source": "${_jsonPath(source)}",
          "display_name": "XS Capped",
          "artist": "FH Radio Studio Dev"
        }
      ],
      "assignments": [
        {
          "slot_index": 0,
          "source_index": 0,
          "source": "${_jsonPath(source)}",
          "target_sound_name": "HZ6_R4_MOCK_SLOT_01",
          "playlist_entry": true,
          "playlist_types": ["FreeRoam", "Event"]
        }
      ]
    }
  ]
}
''', encoding: utf8);
      SharedPreferences.setMockInitialValues({_projectDirKey: projectDir});

      final prefs = await SharedPreferences.getInstance();
      final controller = StudioController(prefs);
      final summary = controller.state.lastPackageSummary;

      expect(summary, isNotNull);
      expect(summary!.bankSlots, 3);
      expect(summary.replaceableSlots, {'FreeRoam': 1, 'Event': 1});
      expect(summary.detail, contains('1 个槽位'));
      expect(summary.detail, isNot(contains('3 个槽位')));
    });
  });
}

class _MutableStudioController extends StudioController {
  _MutableStudioController(super.prefs);

  int toolchainRefreshCount = 0;
  int fullRefreshCount = 0;

  void setStateForTest(StudioState value) {
    state = value;
  }

  @override
  Future<void> refreshToolchainStatus() async {
    toolchainRefreshCount++;
  }

  @override
  Future<void> refreshStatus({bool verifyFiles = false}) async {
    if (verifyFiles) fullRefreshCount++;
  }
}

class _ToolchainFallbackController extends StudioController {
  _ToolchainFallbackController(super.prefs, this.statuses);

  final Map<String, ToolchainStatusSummary> statuses;
  final List<String> requestedProfiles = [];

  @override
  Future<ToolchainStatusSummary?> loadToolchainStatusForProfile(
    String profile,
  ) async {
    requestedProfiles.add(profile);
    return statuses[profile];
  }
}

ToolchainStatusSummary _toolchainStatus({
  required String profile,
  required String python,
  required String ai,
}) {
  return ToolchainStatusSummary(
    checked: true,
    profile: profile,
    status: 'ready',
    label: 'OK',
    summary: '核心工具链可用；AI 和硬件加速会按实际能力降级。',
    sections: [
      const ToolchainStatusSection(
        id: 'uv',
        title: 'uv 运行时',
        status: 'ready',
        summary: 'uv ready',
        items: [],
        warnings: [],
      ),
      const ToolchainStatusSection(
        id: 'audio_tools',
        title: '核心音频工具',
        status: 'ready',
        summary: '核心音频处理组件可用',
        items: [],
        warnings: [],
      ),
      ToolchainStatusSection(
        id: 'python',
        title: 'Python 环境',
        status: python,
        summary: python == 'ready' ? 'Python 依赖已覆盖当前 profile' : '可选 AI 依赖待同步',
        items: const [],
        warnings: const [],
      ),
      ToolchainStatusSection(
        id: 'ai',
        title: 'AI 分析',
        status: ai,
        summary: ai == 'ready' ? 'AI Providers 已就绪' : '深度 AI Providers 尚未就绪',
        items: const [],
        warnings: const [],
      ),
    ],
    fixes: const [],
  );
}

BaselinePlanSummary _brokenBaselinePlan() {
  return const BaselinePlanSummary(
    fileCount: 1,
    totalSize: 1024,
    gameVersionId: 'steam-b23271700',
    byScope: {'radio_bank': 1},
    byStatus: {'backup_missing': 1},
    files: [
      BaselinePlanFile(
        scope: 'radio_bank',
        installRelativePath: 'media/audio/FMODBanks/R4_Tracks_CU1.assets.bank',
        sourceGamePath: '',
        size: 1024,
        md5: '00000000000000000000000000000000',
        exists: true,
        baselineStatus: 'backup_missing',
        backupPath: null,
        backupMd5: null,
        packageMd5: null,
        coverageStatus: 'unchecked',
      ),
    ],
  );
}

void _writePackageManifestFile(
  File manifest, {
  required String source,
  required String radioCode,
  required String playlistType,
  required int slot,
}) {
  final slotIndex = slot - 1;
  manifest.createSync(recursive: true);
  manifest.writeAsStringSync('''
{
  "schema_version": 2,
  "radio": 4,
  "radio_code": "$radioCode",
  "station": "Horizon XS",
  "target_bank_name": "R4_Tracks_CU1.assets.bank",
  "bank_slots": 4,
  "playlist_mode": "only",
  "skip_bank": true,
  "radios": [
    {
      "radio": 4,
      "radio_code": "$radioCode",
      "station": "Horizon XS",
      "target_bank_name": "R4_Tracks_CU1.assets.bank",
      "music": [
        {
          "source": "${_jsonPath(source)}",
          "display_name": "Same Song",
          "artist": "Local Artist"
        }
      ],
      "assignments": [
        {
          "slot_index": $slotIndex,
          "source_index": 0,
          "source": "${_jsonPath(source)}",
          "target_sound_name": "HZ6_R4_MOCK_REFERENCE",
          "playlist_entry": true,
          "playlist_types": ["$playlistType"]
        }
      ]
    }
  ]
}
''', encoding: utf8);
}

({
  String packageRoot,
  String? pendingPackageRoot,
  String baselineManifest,
  String? pendingBaselineManifest,
})
_writeIntegrityFixture(
  String projectDir, {
  required String deployedBytes,
  String packageBytes = 'modded',
  String? pendingBaselineBytes,
  String? pendingPackageBytes,
}) {
  FhRadioStudioProject.ensure(projectDir);
  final gameDir = p.join(projectDir, 'game');
  FhRadioStudioProject.writeSettings(projectDir, gameDir: gameDir);

  String writePackage(String root, String bytes) {
    final packageAudio = p.join(root, 'package', 'media', 'audio');
    final packageXml = File(p.join(packageAudio, 'RadioInfo_CN.xml'))
      ..createSync(recursive: true)
      ..writeAsStringSync(bytes, encoding: utf8);
    final packageMd5 = _md5(packageXml);
    File(p.join(root, 'package', 'fh_radio_studio_package_manifest.json'))
      ..createSync(recursive: true)
      ..writeAsStringSync('''
{
  "schema_version": 2,
  "radio": 4,
  "station": "Horizon XS",
  "target_bank_name": "R4_Tracks_CU1.assets.bank",
  "radios": [
    {
      "radio": 4,
      "radio_code": "XS",
      "station": "Horizon XS",
      "target_bank_name": "R4_Tracks_CU1.assets.bank",
      "music": [],
      "assignments": []
    }
  ],
  "package_files": [
    {
      "relative_path": "RadioInfo_CN.xml",
      "path": "${_jsonPath(packageXml.path)}",
      "md5": "$packageMd5"
    }
  ]
}
''', encoding: utf8);
    return root;
  }

  final packageRoot = writePackage(
    FhRadioStudioProject.currentPackageDir(projectDir),
    packageBytes,
  );
  final pendingPackageRoot = pendingPackageBytes == null
      ? null
      : writePackage(
          FhRadioStudioProject.pendingPackageDir(projectDir),
          pendingPackageBytes,
        );

  final gameXml = File(p.join(gameDir, 'media', 'audio', 'RadioInfo_CN.xml'))
    ..createSync(recursive: true)
    ..writeAsStringSync(deployedBytes, encoding: utf8);

  File writeBaseline({
    required String state,
    required String versionId,
    required String bytes,
  }) {
    final dir = p.join(
      projectDir,
      'backups',
      'baseline-${FhRadioStudioProject.safeName(state)}',
    );
    final baselineXml = File(p.join(dir, 'media', 'audio', 'RadioInfo_CN.xml'))
      ..createSync(recursive: true)
      ..writeAsStringSync(bytes, encoding: utf8);
    return File(p.join(dir, 'baseline_manifest.json'))..writeAsStringSync('''
{
  "schema_version": 1,
  "kind": "game_baseline",
  "state": "$state",
  "backup_name": "fh6-$versionId-baseline-$state",
  "created_at": "2026-05-20T00:00:00.000Z",
  "game_version_id": "$versionId",
  "game_version": {
    "source": "steam",
    "version_id": "$versionId",
    "app_id": "2483190",
    "build_id": "${versionId.replaceFirst('steam-b', '')}"
  },
  "game_dir": "${_jsonPath(gameDir)}",
  "files": [
    {
      "relative_path": "RadioInfo_CN.xml",
      "source_game_path": "${_jsonPath(gameXml.path)}",
      "backup_path": "${_jsonPath(baselineXml.path)}",
      "size": ${baselineXml.lengthSync()},
      "md5": "${_md5(baselineXml)}"
    }
  ]
}
''', encoding: utf8);
  }

  final baselineManifest = writeBaseline(
    state: 'current',
    versionId: 'steam-b23271700',
    bytes: 'original',
  );
  final pendingBaselineManifest = pendingBaselineBytes == null
      ? null
      : writeBaseline(
          state: 'pending-verify',
          versionId: 'steam-b23271800',
          bytes: pendingBaselineBytes,
        );
  return (
    packageRoot: packageRoot,
    pendingPackageRoot: pendingPackageRoot,
    baselineManifest: baselineManifest.path,
    pendingBaselineManifest: pendingBaselineManifest?.path,
  );
}

String _md5(File file) {
  return crypto.md5.convert(file.readAsBytesSync()).toString();
}

void _writePcmWav(File file, {required int sampleRate, required int frames}) {
  const channels = 2;
  const bytesPerSample = 2;
  final dataSize = frames * channels * bytesPerSample;
  final byteRate = sampleRate * channels * bytesPerSample;
  final blockAlign = channels * bytesPerSample;
  final bytes = <int>[
    ...'RIFF'.codeUnits,
    ..._le32(36 + dataSize),
    ...'WAVE'.codeUnits,
    ...'fmt '.codeUnits,
    ..._le32(16),
    ..._le16(1),
    ..._le16(channels),
    ..._le32(sampleRate),
    ..._le32(byteRate),
    ..._le16(blockAlign),
    ..._le16(16),
    ...'data'.codeUnits,
    ..._le32(dataSize),
    ...List<int>.filled(dataSize, 0),
  ];
  file.parent.createSync(recursive: true);
  file.writeAsBytesSync(bytes);
}

List<int> _le16(int value) => [value & 0xff, (value >> 8) & 0xff];

List<int> _le32(int value) => [
  value & 0xff,
  (value >> 8) & 0xff,
  (value >> 16) & 0xff,
  (value >> 24) & 0xff,
];

String _jsonPath(String path) => path.replaceAll(r'\', r'\\');
