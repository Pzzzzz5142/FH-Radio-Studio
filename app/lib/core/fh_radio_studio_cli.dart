import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'system_proxy.dart';

typedef CliLineHandler = void Function(String line);

const fhRadioStudioDefaultPythonVersion = '3.12';

class CliRunResult {
  const CliRunResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
    required this.commandLine,
    this.cancelled = false,
  });

  final int exitCode;
  final String stdout;
  final String stderr;
  final String commandLine;
  final bool cancelled;

  bool get ok => exitCode == 0 && !cancelled;
}

class UvInvocation {
  const UvInvocation({
    required this.executable,
    required this.args,
    required this.workingDirectory,
    required this.environment,
  });

  final String executable;
  final List<String> args;
  final String workingDirectory;
  final Map<String, String> environment;

  String get commandLine => _formatCommand([executable, ...args]);
}

class CliCancellationToken {
  final List<Future<void> Function()> _callbacks = [];
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  Future<void> cancel() async {
    if (_cancelled) return;
    _cancelled = true;
    final callbacks = List<Future<void> Function()>.from(_callbacks);
    _callbacks.clear();
    await Future.wait(callbacks.map((callback) => callback()));
  }

  void _register(Future<void> Function() callback) {
    if (_cancelled) {
      unawaited(callback());
      return;
    }
    _callbacks.add(callback);
  }

  void _unregister(Future<void> Function() callback) {
    _callbacks.remove(callback);
  }
}

class _ActiveCliProcess {
  _ActiveCliProcess(this.process);

  final Process process;
  bool cancelled = false;
}

class FhRadioStudioCli {
  FhRadioStudioCli({required this.repoRoot, UvRuntime? uvRuntime})
    : uvRuntime = uvRuntime ?? UvRuntime.resolve(repoRoot);

  final String repoRoot;
  final UvRuntime uvRuntime;
  static final Set<_ActiveCliProcess> _activeProcesses = <_ActiveCliProcess>{};

  static bool get hasActiveProcesses => _activeProcesses.isNotEmpty;

  static Future<void> killActiveProcesses() async {
    final active = List<_ActiveCliProcess>.from(_activeProcesses);
    await Future.wait(active.map(_killActiveProcess));
  }

  static Future<void> _killActiveProcess(_ActiveCliProcess active) async {
    active.cancelled = true;
    await _killProcessTree(active.process.pid);
  }

  static String defaultRepoRoot() {
    final seeds = <Directory>[
      Directory.current,
      File(Platform.resolvedExecutable).parent,
    ];

    final seen = <String>{};
    for (final seed in seeds) {
      var dir = seed.absolute;
      while (seen.add(dir.path)) {
        if (Directory(
          '${dir.path}${Platform.pathSeparator}backend${Platform.pathSeparator}fh_radio_studio_cli',
        ).existsSync()) {
          return dir.path;
        }
        if (File(
          '${dir.path}${Platform.pathSeparator}tools${Platform.pathSeparator}fh_radio_studio_cli.py',
        ).existsSync()) {
          return dir.path;
        }
        final parent = dir.parent;
        if (parent.path == dir.path) break;
        dir = parent;
      }
    }
    return Directory.current.path;
  }

  Future<CliRunResult> run(
    List<String> args, {
    Map<String, String>? extraEnvironment,
    CliLineHandler? onStdout,
    CliLineHandler? onStderr,
    CliCancellationToken? cancellationToken,
  }) async {
    return _runUv(
      uvRuntime.cliRunInvocation(
        args,
        extraEnvironment: extraEnvironment,
        allowNetwork: false,
      ),
      onStdout: onStdout,
      onStderr: onStderr,
      cancellationToken: cancellationToken,
    );
  }

  Future<CliRunResult> runBase(
    List<String> args, {
    Map<String, String>? extraEnvironment,
    CliLineHandler? onStdout,
    CliLineHandler? onStderr,
    CliCancellationToken? cancellationToken,
  }) async {
    return _runUv(
      uvRuntime.baseCliRunInvocation(
        args,
        extraEnvironment: extraEnvironment,
        allowNetwork: false,
      ),
      onStdout: onStdout,
      onStderr: onStderr,
      cancellationToken: cancellationToken,
    );
  }

  Future<CliRunResult> syncEnvironment({
    String profile = 'local-heavy',
    bool forceReinstall = false,
    Map<String, String>? extraEnvironment,
    CliLineHandler? onStdout,
    CliLineHandler? onStderr,
    CliCancellationToken? cancellationToken,
  }) async {
    return _runUv(
      uvRuntime.syncInvocation(
        profile: profile,
        forceReinstall: forceReinstall,
        extraEnvironment: extraEnvironment,
        allowNetwork: false,
      ),
      onStdout: onStdout,
      onStderr: onStderr,
      cancellationToken: cancellationToken,
    );
  }

  Future<CliRunResult> runRepair(
    List<String> args, {
    Map<String, String>? extraEnvironment,
    CliLineHandler? onStdout,
    CliLineHandler? onStderr,
    CliCancellationToken? cancellationToken,
  }) async {
    return _runUv(
      uvRuntime.cliRunInvocation(
        args,
        extraEnvironment: extraEnvironment,
        allowNetwork: true,
      ),
      onStdout: onStdout,
      onStderr: onStderr,
      cancellationToken: cancellationToken,
    );
  }

  Future<CliRunResult> runBaseRepair(
    List<String> args, {
    Map<String, String>? extraEnvironment,
    CliLineHandler? onStdout,
    CliLineHandler? onStderr,
    CliCancellationToken? cancellationToken,
  }) async {
    return _runUv(
      uvRuntime.baseCliRunInvocation(
        args,
        extraEnvironment: extraEnvironment,
        allowNetwork: true,
      ),
      onStdout: onStdout,
      onStderr: onStderr,
      cancellationToken: cancellationToken,
    );
  }

  Future<CliRunResult> syncRepairEnvironment({
    String profile = 'local-heavy',
    bool forceReinstall = false,
    Map<String, String>? extraEnvironment,
    CliLineHandler? onStdout,
    CliLineHandler? onStderr,
    CliCancellationToken? cancellationToken,
  }) async {
    return _runUv(
      uvRuntime.syncInvocation(
        profile: profile,
        forceReinstall: forceReinstall,
        extraEnvironment: extraEnvironment,
        allowNetwork: true,
      ),
      onStdout: onStdout,
      onStderr: onStderr,
      cancellationToken: cancellationToken,
    );
  }

  Future<CliRunResult> _runUv(
    UvInvocation invocation, {
    CliLineHandler? onStdout,
    CliLineHandler? onStderr,
    CliCancellationToken? cancellationToken,
  }) async {
    final process = await Process.start(
      invocation.executable,
      invocation.args,
      workingDirectory: invocation.workingDirectory,
      runInShell: true,
      environment: invocation.environment,
    );
    final activeProcess = _ActiveCliProcess(process);
    _activeProcesses.add(activeProcess);
    var cancelled = cancellationToken?.isCancelled ?? false;
    var killStarted = false;

    Future<void> killProcess() async {
      if (killStarted) return;
      killStarted = true;
      cancelled = true;
      activeProcess.cancelled = true;
      await _killProcessTree(process.pid);
    }

    cancellationToken?._register(killProcess);
    if (cancellationToken?.isCancelled ?? false) {
      await killProcess();
    }

    final out = StringBuffer();
    final err = StringBuffer();

    final outDone = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          out.writeln(line);
          onStdout?.call(line);
        })
        .asFuture<void>();

    final errDone = process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          if (line.trim().isEmpty) return;
          err.writeln(line);
          onStderr?.call(line);
        })
        .asFuture<void>();

    int exitCode;
    try {
      exitCode = await process.exitCode;
      await Future.wait([outDone, errDone]);
    } finally {
      cancellationToken?._unregister(killProcess);
      _activeProcesses.remove(activeProcess);
    }
    cancelled = cancelled || activeProcess.cancelled;

    return CliRunResult(
      exitCode: cancelled ? -1 : exitCode,
      stdout: out.toString(),
      stderr: cancelled ? 'Cancelled' : err.toString(),
      commandLine: invocation.commandLine,
      cancelled: cancelled,
    );
  }

  static Future<void> _killProcessTree(int pid) async {
    if (Platform.isWindows) {
      try {
        final script =
            '''
\$ErrorActionPreference = 'SilentlyContinue'
\$root = $pid
\$all = Get-CimInstance Win32_Process
\$children = @{}
foreach (\$proc in \$all) {
  \$parent = [int]\$proc.ParentProcessId
  if (-not \$children.ContainsKey(\$parent)) { \$children[\$parent] = @() }
  \$children[\$parent] += [int]\$proc.ProcessId
}
\$toKill = New-Object System.Collections.Generic.List[int]
function Add-Children([int]\$id) {
  if (\$children.ContainsKey(\$id)) {
    foreach (\$child in \$children[\$id]) {
      Add-Children \$child
      [void]\$toKill.Add(\$child)
    }
  }
}
Add-Children \$root
[void]\$toKill.Add(\$root)
foreach (\$id in \$toKill) { Stop-Process -Id \$id -Force }
''';
        await Process.run('powershell', [
          '-NoProfile',
          '-ExecutionPolicy',
          'Bypass',
          '-Command',
          script,
        ], runInShell: false);
        return;
      } on Object {
        try {
          Process.killPid(pid, ProcessSignal.sigterm);
        } on Object {
          // Process may have already exited between registration and cleanup.
        }
        return;
      }
    }
    try {
      Process.killPid(pid, ProcessSignal.sigterm);
    } on Object {
      // Process may have already exited between registration and cleanup.
    }
  }

  Future<bool> isGameRunning() async {
    if (!Platform.isWindows) return false;
    final result = await Process.run('powershell', [
      '-NoProfile',
      '-Command',
      r"@(Get-Process | Where-Object { $_.ProcessName -ieq 'forzahorizon6' -or $_.ProcessName -like '*ForzaHorizon6*' }).Count",
    ], runInShell: true);
    final text = '${result.stdout}'.trim();
    return int.tryParse(text) != null && int.parse(text) > 0;
  }
}

class UvRuntime {
  const UvRuntime({
    required this.uvExecutable,
    required this.appRoot,
    required this.projectRoot,
    required this.toolchainHome,
    required this.projectEnvironment,
    required this.cacheDir,
    required this.audioToolsDir,
    required this.aiModelDir,
    required this.mode,
    required this.torchExtra,
    this.profileEnvironments = false,
    this.pythonVersion = fhRadioStudioDefaultPythonVersion,
    this.cliCommand = 'fh-radio-studio',
    this.wheelhouseDir,
    this.pythonInstallDir,
    this.networkCacheDir,
    this.offline = false,
    this.noIndex = false,
    this.noPythonDownloads = false,
    this.noEditable = false,
  });

  final String uvExecutable;
  final String appRoot;
  final String projectRoot;
  final String toolchainHome;
  final String projectEnvironment;
  final String cacheDir;
  final String audioToolsDir;
  final String aiModelDir;
  final String mode;
  final String torchExtra;
  final bool profileEnvironments;
  final String pythonVersion;
  final String cliCommand;
  final String? wheelhouseDir;
  final String? pythonInstallDir;
  final String? networkCacheDir;
  final bool offline;
  final bool noIndex;
  final bool noPythonDownloads;
  final bool noEditable;

  Map<String, String> get environment => environmentForProfile('local-base');

  UvInvocation cliRunInvocation(
    List<String> cliArgs, {
    Map<String, String>? extraEnvironment,
    bool allowNetwork = false,
  }) {
    final profile = profileFromCliArgs(cliArgs);
    final groups = dependencyGroupsForProfile(profile);
    return _projectInvocation(
      profile: profile,
      extraEnvironment: extraEnvironment,
      allowNetwork: allowNetwork,
      args: [
        ..._offlineArgs(allowNetwork: allowNetwork),
        'run',
        '--project',
        projectRoot,
        if (shouldUseNoSync(profile)) '--no-sync',
        ..._projectPythonArgs,
        ..._modeRunArgs,
        ..._indexArgs,
        ..._groupArgs(groups),
        cliCommand,
        ...cliArgs,
      ],
    );
  }

  UvInvocation baseCliRunInvocation(
    List<String> cliArgs, {
    Map<String, String>? extraEnvironment,
    bool allowNetwork = false,
  }) {
    return _projectInvocation(
      profile: 'local-base',
      extraEnvironment: extraEnvironment,
      allowNetwork: allowNetwork,
      args: [
        ..._offlineArgs(allowNetwork: allowNetwork),
        'run',
        '--project',
        projectRoot,
        if (shouldUseNoSync('local-base')) '--no-sync',
        ..._projectPythonArgs,
        ..._modeRunArgs,
        ..._indexArgs,
        cliCommand,
        ...cliArgs,
      ],
    );
  }

  UvInvocation syncInvocation({
    required String profile,
    bool forceReinstall = false,
    Map<String, String>? extraEnvironment,
    bool allowNetwork = false,
  }) {
    final groups = dependencyGroupsForProfile(profile);
    return _projectInvocation(
      profile: profile,
      extraEnvironment: extraEnvironment,
      allowNetwork: allowNetwork,
      args: [
        ..._offlineArgs(allowNetwork: allowNetwork),
        'sync',
        '--project',
        projectRoot,
        ..._projectPythonArgs,
        if (forceReinstall) '--reinstall',
        ..._modeSyncArgs,
        ..._indexArgs,
        ..._groupArgs(groups),
      ],
    );
  }

  UvInvocation _projectInvocation({
    required String profile,
    required List<String> args,
    Map<String, String>? extraEnvironment,
    bool allowNetwork = false,
  }) {
    return UvInvocation(
      executable: uvExecutable,
      args: args,
      workingDirectory: projectRoot,
      environment: environmentForProfile(profile, allowNetwork: allowNetwork)
        ..addAll(extraEnvironment ?? const {}),
    );
  }

  List<String> get _projectPythonArgs => [
    '--python',
    pythonVersion,
    '--managed-python',
    if (noPythonDownloads) '--no-python-downloads',
  ];

  List<String> _offlineArgs({required bool allowNetwork}) => [
    if (offline && !allowNetwork) '--offline',
  ];

  List<String> get _modeRunArgs => [
    if (mode == 'release') '--no-dev',
    if (noEditable) '--no-editable',
  ];

  List<String> get _modeSyncArgs => [
    if (mode == 'release') '--no-dev',
    if (noEditable) '--no-editable',
  ];

  List<String> get _indexArgs => [
    if (noIndex) '--no-index',
    if (wheelhouseDir != null) ...['--find-links', wheelhouseDir!],
  ];

  List<String> _groupArgs(List<String> groups) {
    return [
      for (final group in groups) ...['--group', group],
      if (groups.isNotEmpty) ...['--extra', torchExtra],
    ];
  }

  String projectEnvironmentForProfile(String profile) {
    if (!profileEnvironments) return projectEnvironment;
    return _join(toolchainHome, 'envs', _environmentName(profile, torchExtra));
  }

  bool shouldUseNoSync(String profile) {
    if (dependencyGroupsForProfile(profile).isNotEmpty) {
      return true;
    }
    return Directory(projectEnvironmentForProfile(profile)).existsSync();
  }

  Map<String, String> environmentForProfile(
    String profile, {
    bool allowNetwork = false,
  }) {
    final profileEnvironment = projectEnvironmentForProfile(profile);
    final activeCacheDir = allowNetwork && networkCacheDir != null
        ? networkCacheDir!
        : cacheDir;
    final env = <String, String>{
      'UV_PROJECT_ENVIRONMENT': profileEnvironment,
      'UV_CACHE_DIR': activeCacheDir,
      'UV_MANAGED_PYTHON': 'true',
      if (offline && !allowNetwork) 'UV_OFFLINE': 'true',
      if (noIndex) 'UV_NO_INDEX': 'true',
      if (noPythonDownloads) 'UV_PYTHON_DOWNLOADS': 'never',
      if (mode == 'release') 'UV_LINK_MODE': 'copy',
      'FH_RADIO_STUDIO_UV_EXE': uvExecutable,
      'FH_RADIO_STUDIO_APP_ROOT': appRoot,
      'FH_RADIO_STUDIO_RUNTIME_ROOT': projectRoot,
      'FH_RADIO_STUDIO_TOOLCHAIN_HOME': toolchainHome,
      'FH_RADIO_STUDIO_AUDIO_TOOLS_DIR': audioToolsDir,
      'FH_RADIO_STUDIO_AI_MODEL_DIR': aiModelDir,
      'FH_RADIO_STUDIO_UV_PROJECT_ENVIRONMENT': profileEnvironment,
      'FH_RADIO_STUDIO_UV_CACHE_DIR': activeCacheDir,
      'FH_RADIO_STUDIO_UV_MODE': mode,
      'FH_RADIO_STUDIO_TORCH_EXTRA': torchExtra,
      'FH_RADIO_STUDIO_PYTHON_VERSION': pythonVersion,
      'FH_RADIO_STUDIO_CLI_COMMAND': cliCommand,
      'VIRTUAL_ENV': profileEnvironment,
    };
    final pythonInstall = pythonInstallDir;
    if (pythonInstall != null) {
      env['UV_PYTHON_INSTALL_DIR'] = pythonInstall;
      env['FH_RADIO_STUDIO_PYTHON_INSTALL_DIR'] = pythonInstall;
    }
    final wheels = wheelhouseDir;
    if (wheels != null) {
      env['UV_FIND_LINKS'] = wheels;
      env['FH_RADIO_STUDIO_WHEELHOUSE_DIR'] = wheels;
    }
    _applyProxyEnvironment(env);
    _appendLoopbackBypass(env);
    return env;
  }

  static UvRuntime resolve(String repoRoot) {
    const isRelease = bool.fromEnvironment('dart.vm.product');
    return isRelease ? _release(repoRoot) : _dev(repoRoot);
  }

  static List<String> dependencyGroupsForProfile(String profile) {
    return switch (profile) {
      'local-deep' => const ['ai-beat-this', 'ai-mert', 'ai-songformer'],
      'local-heavy' => const [
        'ai-beat-this',
        'ai-mert',
        'ai-songformer',
        'ai-demucs',
      ],
      _ => const [],
    };
  }

  static String profileFromCliArgs(List<String> args) {
    final index = args.indexOf('--profile');
    if (index >= 0 && index + 1 < args.length) {
      return args[index + 1];
    }
    for (final arg in args) {
      if (arg.startsWith('--profile=')) {
        return arg.substring('--profile='.length);
      }
    }
    return '';
  }

  static UvRuntime _dev(String repoRoot) {
    final uv =
        Platform.environment['FH_RADIO_STUDIO_DEV_UV_EXE'] ??
        Platform.environment['FH_RADIO_STUDIO_UV_EXE'] ??
        'uv';
    final toolchainHome =
        Platform.environment['FH_RADIO_STUDIO_DEV_TOOLCHAIN_HOME'] ??
        Platform.environment['FH_RADIO_STUDIO_TOOLCHAIN_HOME'] ??
        _join(repoRoot, '.fh-radio-studio-dev', 'toolchain');
    final projectEnvironmentOverride =
        Platform.environment['FH_RADIO_STUDIO_DEV_UV_PROJECT_ENVIRONMENT'] ??
        Platform.environment['FH_RADIO_STUDIO_UV_PROJECT_ENVIRONMENT'];
    final wheelhouseDir =
        Platform.environment['FH_RADIO_STUDIO_DEV_WHEELHOUSE_DIR'] ??
        Platform.environment['FH_RADIO_STUDIO_WHEELHOUSE_DIR'];
    final networkCacheDir =
        Platform.environment['FH_RADIO_STUDIO_DEV_NETWORK_UV_CACHE_DIR'] ??
        Platform.environment['FH_RADIO_STUDIO_NETWORK_UV_CACHE_DIR'] ??
        _defaultDevNetworkCacheDir(repoRoot);
    return UvRuntime(
      uvExecutable: uv,
      appRoot: repoRoot,
      projectRoot: repoRoot,
      toolchainHome: toolchainHome,
      projectEnvironment:
          projectEnvironmentOverride ?? _join(toolchainHome, 'envs', 'base'),
      cacheDir:
          Platform.environment['FH_RADIO_STUDIO_DEV_UV_CACHE_DIR'] ??
          Platform.environment['FH_RADIO_STUDIO_UV_CACHE_DIR'] ??
          _join(toolchainHome, 'uv', 'cache'),
      audioToolsDir:
          Platform.environment['FH_RADIO_STUDIO_DEV_AUDIO_TOOLS_DIR'] ??
          Platform.environment['FH_RADIO_STUDIO_AUDIO_TOOLS_DIR'] ??
          _join(toolchainHome, 'tools', 'audio'),
      aiModelDir:
          Platform.environment['FH_RADIO_STUDIO_DEV_AI_MODEL_DIR'] ??
          Platform.environment['FH_RADIO_STUDIO_AI_MODEL_DIR'] ??
          _join(toolchainHome, 'tools', 'ai', 'models'),
      mode: 'dev',
      torchExtra: _resolveTorchExtra(allowEnvironmentOverride: true),
      profileEnvironments: projectEnvironmentOverride == null,
      cliCommand:
          Platform.environment['FH_RADIO_STUDIO_DEV_CLI_COMMAND'] ??
          Platform.environment['FH_RADIO_STUDIO_CLI_COMMAND'] ??
          'fh-radio-studio',
      wheelhouseDir: wheelhouseDir,
      networkCacheDir: networkCacheDir,
    );
  }

  static UvRuntime _release(String repoRoot) {
    final appDir = File(Platform.resolvedExecutable).parent.path;
    final allowOverrides =
        Platform.environment['FH_RADIO_STUDIO_ALLOW_RELEASE_OVERRIDES'] == '1';
    String? releaseOverride(String name) {
      if (!allowOverrides) return null;
      final value = Platform.environment[name];
      if (value == null || value.trim().isEmpty) return null;
      return value.trim();
    }

    final uv =
        releaseOverride('FH_RADIO_STUDIO_RELEASE_UV_EXE') ??
        _firstExisting([
          _join(appDir, 'tools', 'uv', Platform.isWindows ? 'uv.exe' : 'uv'),
        ]);
    final toolchainHome =
        releaseOverride('FH_RADIO_STUDIO_RELEASE_TOOLCHAIN_HOME') ??
        _join(appDir, 'toolchain');
    final projectRoot =
        releaseOverride('FH_RADIO_STUDIO_RELEASE_RUNTIME_ROOT') ??
        _join(appDir, 'runtime');
    final projectEnvironmentOverride = releaseOverride(
      'FH_RADIO_STUDIO_RELEASE_UV_PROJECT_ENVIRONMENT',
    );
    final wheelhouseDir =
        releaseOverride('FH_RADIO_STUDIO_RELEASE_WHEELHOUSE_DIR') ??
        _join(projectRoot, 'wheels');
    final pythonInstallDir =
        releaseOverride('FH_RADIO_STUDIO_RELEASE_PYTHON_INSTALL_DIR') ??
        _join(toolchainHome, 'python');
    final networkCacheDir =
        releaseOverride('FH_RADIO_STUDIO_RELEASE_NETWORK_UV_CACHE_DIR') ??
        _defaultReleaseNetworkCacheDir(appDir);
    return UvRuntime(
      uvExecutable: uv,
      appRoot: appDir,
      projectRoot: projectRoot,
      toolchainHome: toolchainHome,
      projectEnvironment:
          projectEnvironmentOverride ?? _join(toolchainHome, 'envs', 'base'),
      cacheDir:
          releaseOverride('FH_RADIO_STUDIO_RELEASE_UV_CACHE_DIR') ??
          _join(toolchainHome, 'uv', 'cache'),
      audioToolsDir:
          releaseOverride('FH_RADIO_STUDIO_RELEASE_AUDIO_TOOLS_DIR') ??
          _join(toolchainHome, 'tools', 'audio'),
      aiModelDir:
          releaseOverride('FH_RADIO_STUDIO_RELEASE_AI_MODEL_DIR') ??
          _join(toolchainHome, 'tools', 'ai', 'models'),
      mode: 'release',
      torchExtra: _resolveTorchExtra(allowEnvironmentOverride: allowOverrides),
      profileEnvironments: projectEnvironmentOverride == null,
      cliCommand:
          releaseOverride('FH_RADIO_STUDIO_RELEASE_CLI_COMMAND') ??
          'fh-radio-studio',
      wheelhouseDir: wheelhouseDir,
      pythonInstallDir: pythonInstallDir,
      networkCacheDir: networkCacheDir,
      offline: true,
      noPythonDownloads: true,
      noEditable: true,
    );
  }

  static String _resolveTorchExtra({required bool allowEnvironmentOverride}) {
    final override = allowEnvironmentOverride
        ? Platform.environment['FH_RADIO_STUDIO_TORCH_EXTRA'] ??
              Platform.environment['FH_RADIO_STUDIO_TORCH_BACKEND']
        : null;
    if (override != null && override.trim().isNotEmpty) {
      final value = override.trim().toLowerCase();
      if (value == 'torch-cu128' || value == 'cu128' || value == 'cuda') {
        return 'torch-cu128';
      }
      if (value == 'torch-cpu' || value == 'cpu') {
        return 'torch-cpu';
      }
    }
    if (!Platform.isWindows && !Platform.isLinux) {
      return 'torch-cpu';
    }
    try {
      final result = Process.runSync('nvidia-smi', ['-L'], runInShell: true);
      if (result.exitCode == 0 && '${result.stdout}'.trim().isNotEmpty) {
        return 'torch-cu128';
      }
    } on Object {
      return 'torch-cpu';
    }
    return 'torch-cpu';
  }

  static String? _defaultReleaseNetworkCacheDir(String appDir) {
    if (Platform.isWindows) {
      final localAppData = Platform.environment['LOCALAPPDATA']?.trim();
      if (localAppData != null && localAppData.isNotEmpty) {
        return _join(localAppData, 'FH Radio Studio', 'uv-cache');
      }
    }
    return _join(appDir, 'uv-cache');
  }

  static String _defaultDevNetworkCacheDir(String repoRoot) {
    if (Platform.isWindows) {
      final localAppData = Platform.environment['LOCALAPPDATA']?.trim();
      if (localAppData != null && localAppData.isNotEmpty) {
        return _join(localAppData, 'FH Radio Studio', 'dev-uv-cache');
      }
    }
    return _join(repoRoot, '.uv-cache');
  }

  static String _firstExisting(List<String> candidates) {
    for (final candidate in candidates) {
      if (File(candidate).existsSync()) return candidate;
    }
    return candidates.first;
  }

  static bool _systemProxyLoaded = false;
  static SystemProxyConfig? _systemProxyConfig;

  static void _applyProxyEnvironment(Map<String, String> env) {
    final system = _currentSystemProxyConfig();
    _applyProxyPair(env, 'HTTP_PROXY', 'http_proxy', system?.httpProxy);
    _applyProxyPair(env, 'HTTPS_PROXY', 'https_proxy', system?.httpsProxy);
    _applyProxyPair(env, 'ALL_PROXY', 'all_proxy', system?.allProxy);
    _applyProxyPair(env, 'NO_PROXY', 'no_proxy', system?.noProxy);
  }

  static void _applyProxyPair(
    Map<String, String> env,
    String upper,
    String lower,
    String? fallback,
  ) {
    final value =
        proxyEnvironmentValue(Platform.environment, [upper, lower]) ?? fallback;
    if (value == null || value.trim().isEmpty) return;
    env[upper] = value.trim();
    env[lower] = value.trim();
  }

  static SystemProxyConfig? _currentSystemProxyConfig() {
    if (!_systemProxyLoaded) {
      _systemProxyConfig = SystemProxyConfig.readCurrent();
      _systemProxyLoaded = true;
    }
    return _systemProxyConfig;
  }

  static void _appendLoopbackBypass(Map<String, String> env) {
    final current =
        proxyEnvironmentValue(env, const ['NO_PROXY', 'no_proxy']) ??
        proxyEnvironmentValue(Platform.environment, const [
          'NO_PROXY',
          'no_proxy',
        ]);
    final value = mergeNoProxyEntries([
      current,
      'localhost',
      '127.0.0.1',
      '::1',
    ]);
    env['NO_PROXY'] = value;
    env['no_proxy'] = value;
  }

  static String _environmentName(String profile, String torchExtra) {
    final normalizedProfile = switch (profile) {
      '' => 'base',
      'local-base' => 'base',
      _ => profile,
    };
    if (normalizedProfile == 'base') return 'base';
    final torch = switch (torchExtra) {
      'torch-cu128' => 'cu128',
      'torch-cpu' => 'cpu',
      _ => torchExtra.replaceAll('torch-', ''),
    };
    return '$normalizedProfile-$torch';
  }

  static String _join(
    String first,
    String second, [
    String? third,
    String? fourth,
  ]) {
    final parts = [first, second, ?third, ?fourth];
    return parts.join(Platform.pathSeparator);
  }
}

String _formatCommand(List<String> parts) {
  return parts
      .map((part) {
        final needsQuotes = part.contains(RegExp(r'\s|["]'));
        if (!needsQuotes) return part;
        return '"${part.replaceAll('"', r'\"')}"';
      })
      .join(' ');
}
