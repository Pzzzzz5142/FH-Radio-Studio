import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fh_radio_studio/core/fh_radio_studio_cli.dart';

void main() {
  test('dev CLI runtime uses uv with a reusable project environment', () {
    final repoRoot = Directory.systemTemp.createTempSync(
      'fh_radio_studio_uv_runtime_',
    );
    addTearDown(() {
      if (repoRoot.existsSync()) {
        repoRoot.deleteSync(recursive: true);
      }
    });

    final runtime = UvRuntime.resolve(repoRoot.path);
    final separator = Platform.pathSeparator;
    String tail(List<String> parts) => parts.join(separator);
    final torchSuffix = runtime.torchExtra == 'torch-cu128' ? 'cu128' : 'cpu';

    expect(runtime.mode, 'dev');
    expect(runtime.uvExecutable, isNot('python'));
    expect(
      runtime.toolchainHome,
      endsWith(tail(['.fh-radio-studio-dev', 'toolchain'])),
    );
    expect(runtime.projectEnvironment, endsWith(tail(['envs', 'base'])));
    expect(runtime.cacheDir, endsWith(tail(['uv', 'cache'])));
    expect(runtime.networkCacheDir, isNotNull);
    expect(runtime.networkCacheDir, isNot(equals(runtime.cacheDir)));
    expect(runtime.audioToolsDir, endsWith(tail(['tools', 'audio'])));
    expect(runtime.aiModelDir, endsWith(tail(['tools', 'ai', 'models'])));
    expect(
      runtime.projectEnvironmentForProfile('local-heavy'),
      endsWith(tail(['envs', 'local-heavy-$torchSuffix'])),
    );
    expect(runtime.shouldUseNoSync('local-base'), isFalse);
    expect(
      runtime.projectEnvironmentIsRunnableForProfile('local-base'),
      isFalse,
    );
    expect(runtime.shouldUseNoSync('local-heavy'), isTrue);
    expect(
      runtime.environment['UV_PROJECT_ENVIRONMENT'],
      runtime.projectEnvironment,
    );
    expect(runtime.environment['UV_CACHE_DIR'], runtime.cacheDir);
    expect(runtime.environment['UV_MANAGED_PYTHON'], 'true');
    expect(runtime.environment['PYTHONUTF8'], '1');
    expect(runtime.environment['PYTHONIOENCODING'], 'utf-8:replace');
    expect(
      runtime.environmentForProfile('local-heavy')['UV_PROJECT_ENVIRONMENT'],
      runtime.projectEnvironmentForProfile('local-heavy'),
    );
    expect(
      runtime.environmentForProfile('local-heavy')['UV_CACHE_DIR'],
      runtime.cacheDir,
    );
    expect(
      runtime.environmentForProfile('local-heavy', allowNetwork: true),
      containsPair('UV_CACHE_DIR', runtime.networkCacheDir),
    );
    expect(
      runtime.environmentForProfile('local-heavy', allowNetwork: true),
      containsPair('FH_RADIO_STUDIO_UV_CACHE_DIR', runtime.networkCacheDir),
    );
    expect(
      runtime.environmentForProfile('local-heavy')['VIRTUAL_ENV'],
      runtime.projectEnvironmentForProfile('local-heavy'),
    );
    expect(
      runtime.environmentForProfile(
        'local-heavy',
      )['FH_RADIO_STUDIO_TOOLCHAIN_HOME'],
      runtime.toolchainHome,
    );
    expect(
      runtime.environmentForProfile(
        'local-heavy',
      )['FH_RADIO_STUDIO_AUDIO_TOOLS_DIR'],
      runtime.audioToolsDir,
    );
    expect(
      runtime.environmentForProfile(
        'local-heavy',
      )['FH_RADIO_STUDIO_AI_MODEL_DIR'],
      runtime.aiModelDir,
    );
    expect(['torch-cpu', 'torch-cu128'], contains(runtime.torchExtra));
    expect(
      runtime.environment['FH_RADIO_STUDIO_TORCH_EXTRA'],
      runtime.torchExtra,
    );
    expect(
      runtime.environment['FH_RADIO_STUDIO_CLI_COMMAND'],
      'fh-radio-studio',
    );
    expect(runtime.environment['NO_PROXY'], contains('localhost'));
    expect(runtime.environment['NO_PROXY'], contains('127.0.0.1'));
    expect(runtime.environment['NO_PROXY'], contains('::1'));
    expect(runtime.environment['no_proxy'], runtime.environment['NO_PROXY']);
    expect(UvRuntime.dependencyGroupsForProfile('local-base'), isEmpty);
    expect(UvRuntime.dependencyGroupsForProfile('local-deep'), [
      'ai-beat-this',
      'ai-mert',
      'ai-songformer',
    ]);
    expect(UvRuntime.dependencyGroupsForProfile('local-heavy'), [
      'ai-beat-this',
      'ai-mert',
      'ai-songformer',
      'ai-demucs',
    ]);
    expect(
      UvRuntime.profileFromCliArgs([
        'analyze-audio',
        'song.wav',
        '--profile',
        'local-heavy',
      ]),
      'local-heavy',
    );
  });

  test('all Flutter uv entrypoints require managed Python', () async {
    final repoRoot = Directory.systemTemp.createTempSync(
      'fh_radio_studio_uv_commands_',
    );
    addTearDown(() {
      if (repoRoot.existsSync()) {
        repoRoot.deleteSync(recursive: true);
      }
    });

    final separator = Platform.pathSeparator;
    String join(List<String> parts) => parts.join(separator);

    final fakeUvDir = Directory(
      '${repoRoot.path}$separator${join(['tool path with spaces'])}',
    )..createSync(recursive: true);
    final fakeUv = File(
      '${fakeUvDir.path}$separator${Platform.isWindows ? 'uv.cmd' : 'uv'}',
    );
    if (Platform.isWindows) {
      await fakeUv.writeAsString('@echo off\r\necho %*\r\nexit /b 0\r\n');
    } else {
      await fakeUv.writeAsString('#!/bin/sh\necho "\$@"\nexit 0\n');
      await Process.run('chmod', ['+x', fakeUv.path]);
    }

    final runtime = UvRuntime(
      uvExecutable: fakeUv.path,
      appRoot: repoRoot.path,
      projectRoot: repoRoot.path,
      toolchainHome: '${repoRoot.path}$separator${join(['toolchain'])}',
      projectEnvironment:
          '${repoRoot.path}$separator${join(['toolchain', 'envs', 'base'])}',
      cacheDir:
          '${repoRoot.path}$separator${join(['toolchain', 'uv', 'cache'])}',
      audioToolsDir:
          '${repoRoot.path}$separator${join(['toolchain', 'tools', 'audio'])}',
      aiModelDir:
          '${repoRoot.path}$separator${join(['toolchain', 'tools', 'ai', 'models'])}',
      mode: 'dev',
      torchExtra: 'torch-cpu',
      profileEnvironments: true,
    );
    final cli = FhRadioStudioCli(repoRoot: repoRoot.path, uvRuntime: runtime);
    expect(runtime.uvExecutable, contains(' '));

    final sync = await cli.syncEnvironment(profile: 'local-heavy');
    final run = await cli.run(['status', '--profile', 'local-heavy']);
    final runBase = await cli.runBase(['install-tools']);

    for (final result in [sync, run, runBase]) {
      expect(result.ok, isTrue);
      expect(result.commandLine, contains('--python 3.12 --managed-python'));
      expect(result.commandLine, isNot(contains('python -m')));
      expect(result.commandLine, isNot(contains('--no-editable')));
    }
    expect(run.commandLine, contains('fh-radio-studio status'));
    expect(runBase.commandLine, contains('fh-radio-studio install-tools'));
  });

  test('CLI runtime filters blank stderr lines', () async {
    final repoRoot = Directory.systemTemp.createTempSync(
      'fh_radio_studio_uv_blank_stderr_',
    );
    addTearDown(() {
      if (repoRoot.existsSync()) {
        repoRoot.deleteSync(recursive: true);
      }
    });

    final separator = Platform.pathSeparator;
    String join(List<String> parts) => parts.join(separator);

    final fakeUv = File(
      '${repoRoot.path}$separator${Platform.isWindows ? 'uv.cmd' : 'uv'}',
    );
    if (Platform.isWindows) {
      await fakeUv.writeAsString(
        '@echo off\r\necho stdout-one\r\n>&2 echo.\r\n>&2 echo stderr-one\r\nexit /b 0\r\n',
      );
    } else {
      await fakeUv.writeAsString(
        '#!/bin/sh\necho stdout-one\nprintf "\\n" >&2\necho stderr-one >&2\nexit 0\n',
      );
      await Process.run('chmod', ['+x', fakeUv.path]);
    }

    final runtime = UvRuntime(
      uvExecutable: fakeUv.path,
      appRoot: repoRoot.path,
      projectRoot: repoRoot.path,
      toolchainHome: '${repoRoot.path}$separator${join(['toolchain'])}',
      projectEnvironment:
          '${repoRoot.path}$separator${join(['toolchain', 'envs', 'base'])}',
      cacheDir:
          '${repoRoot.path}$separator${join(['toolchain', 'uv', 'cache'])}',
      audioToolsDir:
          '${repoRoot.path}$separator${join(['toolchain', 'tools', 'audio'])}',
      aiModelDir:
          '${repoRoot.path}$separator${join(['toolchain', 'tools', 'ai', 'models'])}',
      mode: 'dev',
      torchExtra: 'torch-cpu',
      profileEnvironments: true,
    );
    final cli = FhRadioStudioCli(repoRoot: repoRoot.path, uvRuntime: runtime);
    final stderrLines = <String>[];

    final result = await cli.runBase(['status'], onStderr: stderrLines.add);

    expect(result.ok, isTrue);
    expect(stderrLines, ['stderr-one']);
    expect(result.stderr.trim(), 'stderr-one');
    expect(
      result.stderr.trim().split('\n').where((line) => line.trim().isEmpty),
      isEmpty,
    );
  });

  test('CLI runtime decodes system-encoded process output bytes', () async {
    final repoRoot = Directory.systemTemp.createTempSync(
      'fh_radio_studio_uv_system_output_',
    );
    addTearDown(() {
      if (repoRoot.existsSync()) {
        repoRoot.deleteSync(recursive: true);
      }
    });

    final separator = Platform.pathSeparator;
    String join(List<String> parts) => parts.join(separator);
    const nativeText = 'é';
    final stdoutBytes = [
      ...'ok '.codeUnits,
      ...systemEncoding.encode(nativeText),
      10,
    ];
    final stderrBytes = [
      ...'err '.codeUnits,
      ...systemEncoding.encode(nativeText),
      10,
    ];

    final fakeUv = File(
      '${repoRoot.path}$separator${Platform.isWindows ? 'uv.cmd' : 'uv'}',
    );
    if (Platform.isWindows) {
      await fakeUv.writeAsString(
        '@echo off\r\n'
        'powershell -NoProfile -Command "\$out=[Console]::OpenStandardOutput();'
        '\$outBytes=[byte[]](${stdoutBytes.join(',')});'
        '\$out.Write(\$outBytes,0,\$outBytes.Length);'
        '\$err=[Console]::OpenStandardError();'
        '\$errBytes=[byte[]](${stderrBytes.join(',')});'
        '\$err.Write(\$errBytes,0,\$errBytes.Length)"\r\n'
        'exit /b 0\r\n',
      );
    } else {
      final stdoutEscapes = stdoutBytes
          .map((byte) => '\\${byte.toRadixString(8).padLeft(3, '0')}')
          .join();
      final stderrEscapes = stderrBytes
          .map((byte) => '\\${byte.toRadixString(8).padLeft(3, '0')}')
          .join();
      await fakeUv.writeAsString(
        "#!/bin/sh\nprintf '$stdoutEscapes'\nprintf '$stderrEscapes' >&2\nexit 0\n",
      );
      await Process.run('chmod', ['+x', fakeUv.path]);
    }

    final runtime = UvRuntime(
      uvExecutable: fakeUv.path,
      appRoot: repoRoot.path,
      projectRoot: repoRoot.path,
      toolchainHome: '${repoRoot.path}$separator${join(['toolchain'])}',
      projectEnvironment:
          '${repoRoot.path}$separator${join(['toolchain', 'envs', 'base'])}',
      cacheDir:
          '${repoRoot.path}$separator${join(['toolchain', 'uv', 'cache'])}',
      audioToolsDir:
          '${repoRoot.path}$separator${join(['toolchain', 'tools', 'audio'])}',
      aiModelDir:
          '${repoRoot.path}$separator${join(['toolchain', 'tools', 'ai', 'models'])}',
      mode: 'dev',
      torchExtra: 'torch-cpu',
      profileEnvironments: true,
    );
    final cli = FhRadioStudioCli(repoRoot: repoRoot.path, uvRuntime: runtime);

    final result = await cli.runBase(['status']);

    expect(result.ok, isTrue);
    expect(result.stdout, contains('ok $nativeText'));
    expect(result.stderr, contains('err $nativeText'));
  });

  test('active CLI processes can be cancelled globally', () async {
    final repoRoot = Directory.systemTemp.createTempSync(
      'fh_radio_studio_uv_global_cancel_',
    );
    addTearDown(() async {
      await FhRadioStudioCli.killActiveProcesses();
      if (repoRoot.existsSync()) {
        repoRoot.deleteSync(recursive: true);
      }
    });

    final separator = Platform.pathSeparator;
    String join(List<String> parts) => parts.join(separator);
    final fakeUv = File(
      '${repoRoot.path}$separator${Platform.isWindows ? 'uv.cmd' : 'uv'}',
    );
    if (Platform.isWindows) {
      await fakeUv.writeAsString(
        '@echo off\r\necho started\r\nping -n 30 127.0.0.1 >nul\r\necho done\r\nexit /b 0\r\n',
      );
    } else {
      await fakeUv.writeAsString(
        '#!/bin/sh\necho started\nsleep 30\necho done\nexit 0\n',
      );
      await Process.run('chmod', ['+x', fakeUv.path]);
    }

    final runtime = UvRuntime(
      uvExecutable: fakeUv.path,
      appRoot: repoRoot.path,
      projectRoot: repoRoot.path,
      toolchainHome: '${repoRoot.path}$separator${join(['toolchain'])}',
      projectEnvironment:
          '${repoRoot.path}$separator${join(['toolchain', 'envs', 'base'])}',
      cacheDir:
          '${repoRoot.path}$separator${join(['toolchain', 'uv', 'cache'])}',
      audioToolsDir:
          '${repoRoot.path}$separator${join(['toolchain', 'tools', 'audio'])}',
      aiModelDir:
          '${repoRoot.path}$separator${join(['toolchain', 'tools', 'ai', 'models'])}',
      mode: 'dev',
      torchExtra: 'torch-cpu',
      profileEnvironments: true,
    );
    final cli = FhRadioStudioCli(repoRoot: repoRoot.path, uvRuntime: runtime);
    final started = Completer<void>();
    final runFuture = cli.runBase(
      ['status'],
      onStdout: (line) {
        if (line.contains('started') && !started.isCompleted) {
          started.complete();
        }
      },
    );

    await started.future.timeout(const Duration(seconds: 5));
    expect(FhRadioStudioCli.hasActiveProcesses, isTrue);

    await FhRadioStudioCli.killActiveProcesses();
    final result = await runFuture.timeout(const Duration(seconds: 10));

    expect(result.cancelled, isTrue);
    expect(result.ok, isFalse);
    expect(FhRadioStudioCli.hasActiveProcesses, isFalse);
  });

  test('dev CLI runtime does not infer a project wheelhouse', () {
    final repoRoot = Directory.systemTemp.createTempSync(
      'fh_radio_studio_uv_wheelhouse_',
    );
    addTearDown(() {
      if (repoRoot.existsSync()) {
        repoRoot.deleteSync(recursive: true);
      }
    });

    final separator = Platform.pathSeparator;
    Directory(
      '${repoRoot.path}${separator}tools${separator}python-wheels',
    ).createSync(recursive: true);

    final runtime = UvRuntime.resolve(repoRoot.path);
    final invocation = runtime.syncInvocation(profile: 'local-heavy');

    expect(runtime.wheelhouseDir, isNull);
    expect(runtime.environment, isNot(contains('UV_FIND_LINKS')));
    expect(
      runtime.environment,
      isNot(contains('FH_RADIO_STUDIO_WHEELHOUSE_DIR')),
    );
    expect(invocation.args, isNot(contains('--find-links')));
  });

  test('dev CLI runtime ignores the deprecated third_party wheelhouse', () {
    final repoRoot = Directory.systemTemp.createTempSync(
      'fh_radio_studio_uv_legacy_wheelhouse_',
    );
    addTearDown(() {
      if (repoRoot.existsSync()) {
        repoRoot.deleteSync(recursive: true);
      }
    });

    final separator = Platform.pathSeparator;
    Directory(
      '${repoRoot.path}${separator}third_party${separator}python-wheels',
    ).createSync(recursive: true);

    final runtime = UvRuntime.resolve(repoRoot.path);
    final invocation = runtime.syncInvocation(profile: 'local-heavy');

    expect(runtime.wheelhouseDir, isNull);
    expect(runtime.environment, isNot(contains('UV_FIND_LINKS')));
    expect(
      runtime.environment,
      isNot(contains('FH_RADIO_STUDIO_WHEELHOUSE_DIR')),
    );
    expect(invocation.args, isNot(contains('--find-links')));
  });

  test('release CLI runtime is wheel-only and offline by default', () async {
    final appRoot = Directory.systemTemp.createTempSync(
      'fh_radio_studio_uv_release_',
    );
    addTearDown(() {
      if (appRoot.existsSync()) {
        appRoot.deleteSync(recursive: true);
      }
    });

    final separator = Platform.pathSeparator;
    String join(List<String> parts) => parts.join(separator);
    Directory(
      '${appRoot.path}$separator${join(['runtime', 'wheels'])}',
    ).createSync(recursive: true);

    final fakeUv = File(
      '${appRoot.path}$separator${Platform.isWindows ? 'uv.cmd' : 'uv'}',
    );
    if (Platform.isWindows) {
      await fakeUv.writeAsString('@echo off\r\necho %*\r\nexit /b 0\r\n');
    } else {
      await fakeUv.writeAsString('#!/bin/sh\necho "\$@"\nexit 0\n');
      await Process.run('chmod', ['+x', fakeUv.path]);
    }

    final runtime = UvRuntime(
      uvExecutable: fakeUv.path,
      appRoot: appRoot.path,
      projectRoot: '${appRoot.path}$separator${join(['runtime'])}',
      toolchainHome: '${appRoot.path}$separator${join(['toolchain'])}',
      projectEnvironment:
          '${appRoot.path}$separator${join(['toolchain', 'envs', 'base'])}',
      cacheDir:
          '${appRoot.path}$separator${join(['toolchain', 'uv', 'cache'])}',
      audioToolsDir:
          '${appRoot.path}$separator${join(['toolchain', 'tools', 'audio'])}',
      aiModelDir:
          '${appRoot.path}$separator${join(['toolchain', 'tools', 'ai', 'models'])}',
      mode: 'release',
      torchExtra: 'torch-cpu',
      profileEnvironments: true,
      wheelhouseDir: '${appRoot.path}$separator${join(['runtime', 'wheels'])}',
      pythonInstallDir:
          '${appRoot.path}$separator${join(['toolchain', 'python'])}',
      networkCacheDir: '${appRoot.path}$separator${join(['uv-cache'])}',
      offline: true,
      noPythonDownloads: true,
      noEditable: true,
    );
    final cli = FhRadioStudioCli(repoRoot: appRoot.path, uvRuntime: runtime);

    expect(runtime.shouldUseNoSync('local-base'), isFalse);
    expect(runtime.shouldUseNoSync('local-heavy'), isTrue);

    final sync = await cli.syncEnvironment(profile: 'local-base');
    final repairSync = await cli.syncRepairEnvironment(profile: 'local-heavy');
    final runBase = await cli.runBase(['status', '--json']);
    final mirrorRepairSync = runtime.syncInvocation(
      profile: 'local-heavy',
      allowNetwork: true,
      extraEnvironment: const {
        'UV_FIND_LINKS':
            'https://mirror.example.com/pytorch/cu128/torch/ '
            'https://mirror.example.com/pytorch/cu128/torchaudio/',
        'UV_NO_SOURCES_PACKAGE': 'torch torchaudio',
      },
    );

    for (final result in [sync, runBase]) {
      expect(result.ok, isTrue);
      expect(result.commandLine, contains('--offline'));
      expect(result.commandLine, contains('--no-dev'));
      expect(result.commandLine, contains('--no-editable'));
      expect(result.commandLine, contains('--no-python-downloads'));
      expect(result.commandLine, contains('--find-links'));
      expect(result.commandLine, isNot(contains('python -m')));
    }

    expect(runBase.commandLine, contains('fh-radio-studio status --json'));
    expect(runBase.commandLine, contains('--frozen'));
    expect(sync.commandLine, isNot(contains('--no-sync')));
    expect(runBase.commandLine, isNot(contains('--no-sync')));
    expect(repairSync.commandLine, isNot(contains('--frozen')));
    expect(repairSync.ok, isTrue);
    expect(repairSync.commandLine, isNot(contains('--offline')));
    expect(repairSync.commandLine, contains('--no-dev'));
    expect(repairSync.commandLine, contains('--no-editable'));
    expect(repairSync.commandLine, contains('--no-python-downloads'));
    expect(repairSync.commandLine, contains('--group ai-songformer'));
    expect(repairSync.commandLine, contains('--extra torch-cpu'));
    expect(
      mirrorRepairSync.commandLine,
      contains('--find-links ${runtime.wheelhouseDir}'),
    );
    expect(
      mirrorRepairSync.commandLine,
      contains('--find-links https://mirror.example.com/pytorch/cu128/torch/'),
    );
    expect(
      mirrorRepairSync.commandLine,
      contains(
        '--find-links https://mirror.example.com/pytorch/cu128/torchaudio/',
      ),
    );
    expect(
      mirrorRepairSync.commandLine,
      contains('--no-sources-package torch'),
    );
    expect(
      mirrorRepairSync.commandLine,
      contains('--no-sources-package torchaudio'),
    );
    expect(runtime.environment['UV_OFFLINE'], 'true');
    expect(
      runtime.environmentForProfile('local-heavy', allowNetwork: true),
      isNot(containsPair('UV_OFFLINE', 'true')),
    );
    expect(
      runtime.environmentForProfile('local-heavy', allowNetwork: true),
      containsPair(
        'UV_CACHE_DIR',
        '${appRoot.path}$separator${join(['uv-cache'])}',
      ),
    );
    expect(runtime.environment['UV_CACHE_DIR'], runtime.cacheDir);
    expect(runtime.environment['UV_PYTHON_DOWNLOADS'], 'never');
    expect(runtime.environment['PYTHONUTF8'], '1');
    expect(runtime.environment['PYTHONIOENCODING'], 'utf-8:replace');
    expect(
      runtime.environment['UV_PYTHON_INSTALL_DIR'],
      runtime.pythonInstallDir,
    );
    expect(runtime.environment['UV_LINK_MODE'], 'copy');

    Directory(runtime.projectEnvironment).createSync(recursive: true);
    expect(
      runtime.projectEnvironmentIsRunnableForProfile('local-base'),
      isFalse,
    );

    final stalePythonHome =
        '${appRoot.path}$separator${join(['old-location', 'toolchain', 'python', 'cpython-3.12'])}';
    _writeProjectEnvironment(
      environmentPath: runtime.projectEnvironment,
      pythonHome: stalePythonHome,
      cliCommand: runtime.cliCommand,
    );
    expect(
      runtime.projectEnvironmentIsRunnableForProfile('local-base'),
      isFalse,
    );

    final releasePythonHome =
        '${runtime.pythonInstallDir!}$separator${join(['cpython-3.12'])}';
    Directory(releasePythonHome).createSync(recursive: true);
    _writeProjectEnvironment(
      environmentPath: runtime.projectEnvironment,
      pythonHome: releasePythonHome,
      cliCommand: runtime.cliCommand,
    );
    expect(
      runtime.projectEnvironmentIsRunnableForProfile('local-base'),
      isTrue,
    );
    expect(runtime.shouldUseNoSync('local-base'), isFalse);

    final cachedRunBase = await cli.runBase(['status', '--json']);
    expect(cachedRunBase.commandLine, isNot(contains('--no-sync')));
  });
}

void _writeProjectEnvironment({
  required String environmentPath,
  required String pythonHome,
  required String cliCommand,
}) {
  final scriptsDir = Directory(
    _testJoin([environmentPath, Platform.isWindows ? 'Scripts' : 'bin']),
  )..createSync(recursive: true);
  File(
    _testJoin([scriptsDir.path, Platform.isWindows ? 'python.exe' : 'python']),
  ).writeAsStringSync('');
  final commandName =
      Platform.isWindows && !cliCommand.toLowerCase().endsWith('.exe')
      ? '$cliCommand.exe'
      : cliCommand;
  File(_testJoin([scriptsDir.path, commandName])).writeAsStringSync('');
  File(_testJoin([environmentPath, 'pyvenv.cfg'])).writeAsStringSync(
    'home = $pythonHome\ninclude-system-site-packages = false\n',
  );
}

String _testJoin(List<String> parts) {
  return parts.join(Platform.pathSeparator);
}
