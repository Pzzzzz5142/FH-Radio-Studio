import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../core/project_workspace.dart';
import '../core/playlist_plan.dart';
import '../core/fh_radio_studio_cli.dart';
import '../core/package_manifest.dart';
import '../core/path_keys.dart';
import '../core/siren_catalog.dart';
import '../core/siren_imports.dart';
import '../core/track_metadata_cache.dart';
import '../core/track_timing_config.dart';
import 'app_state.dart';

class _StudioPrefsKeys {
  static const repoRoot = 'rm.studio.repoRoot';
  static const projectDir = 'rm.studio.projectDir';
  static const recentProjectDirs = 'rm.studio.recentProjectDirs';
  static const aiProfile = 'rm.studio.aiProfile';
  static const aiUsePipMirror = 'rm.studio.aiUsePipMirror';
  static const aiPipIndexUrl = 'rm.studio.aiPipIndexUrl';
  static const aiUseTorchWheelMirror = 'rm.studio.aiUseTorchWheelMirror';
  static const aiTorchWheelMirrorUrl = 'rm.studio.aiTorchWheelMirrorUrl';
  static const aiUseHfMirror = 'rm.studio.aiUseHfMirror';
  static const aiHfEndpoint = 'rm.studio.aiHfEndpoint';
}

class _RefreshScope {
  static const fileIntegrity = 'fileIntegrity';
  static const toolchain = 'toolchain';
}

const _pendingPackageFailureFileName =
    'fh_radio_studio_package_build_failed.json';
const _pendingBaselineSelectionFileName =
    'fh_radio_studio_pending_baseline_selected.json';

const _cliProgressPrefix = 'FH_RADIO_STUDIO_PROGRESS ';

const kAiPipelineProfiles = ['local-base', 'local-deep', 'local-heavy'];

const kDefaultAiPipelineProfile = 'local-heavy';

const kAiWarmupProviders = ['beat_this', 'songformer', 'mert', 'demucs'];

const kDefaultPipIndexMirror = 'https://mirrors.aliyun.com/pypi/simple/';

const kDefaultTorchWheelMirror =
    'https://mirrors.aliyun.com/pytorch-wheels/cu128/';

const kTorchMirrorNoSourcesPackages = 'torch torchaudio';

enum TorchWheelMirrorMode { namedIndex, findLinks }

String torchIndexNameForExtra(String? torchExtra) {
  return torchExtra == 'torch-cpu' ? 'pytorch-cpu' : 'pytorch-cu128';
}

String torchIndexUrlForExtra(String url, String? torchExtra) {
  final target = torchExtra == 'torch-cpu' ? 'cpu' : 'cu128';
  final trimmed = _torchMirrorDataUrl(url);
  if (trimmed.isEmpty) return trimmed;
  final uri = Uri.tryParse(trimmed);
  if (uri != null && uri.hasScheme && uri.path.isNotEmpty) {
    final withoutTrailingSlash = uri.path.replaceFirst(RegExp(r'/+$'), '');
    final lowerPath = withoutTrailingSlash.toLowerCase();
    final matchedFlavor = _torchWheelFlavors.firstWhereOrNull(
      (flavor) => lowerPath.endsWith('/$flavor'),
    );
    if (matchedFlavor != null) {
      final nextPath =
          '${withoutTrailingSlash.substring(0, withoutTrailingSlash.length - matchedFlavor.length)}$target/';
      return _trimEmptyQueryOrFragment(uri.replace(path: nextPath).toString());
    }
  }
  final withoutTrailingSlash = trimmed.replaceFirst(RegExp(r'/+$'), '');
  final lower = withoutTrailingSlash.toLowerCase();
  for (final flavor in _torchWheelFlavors) {
    if (lower.endsWith('/$flavor')) {
      return '${withoutTrailingSlash.substring(0, withoutTrailingSlash.length - flavor.length)}$target/';
    }
  }
  return trimmed;
}

bool torchMirrorUsesFindLinks(String url) {
  final uri = Uri.tryParse(url.trim());
  final host = uri?.host.toLowerCase();
  final path = uri?.path.toLowerCase() ?? '';
  return host == 'mirrors.aliyun.com' && path.contains('/pytorch-wheels/');
}

TorchWheelMirrorMode torchWheelMirrorModeForUrl(String rawUrl, String dataUrl) {
  final forcedMode = _torchMirrorForcedMode(rawUrl);
  if (forcedMode != null) return forcedMode;
  return torchMirrorUsesFindLinks(dataUrl)
      ? TorchWheelMirrorMode.findLinks
      : TorchWheelMirrorMode.namedIndex;
}

Map<String, String> torchWheelMirrorEnvironment(
  String url,
  String? torchExtra, {
  TorchWheelMirrorMode? modeOverride,
}) {
  final indexUrl = torchIndexUrlForExtra(url, torchExtra);
  if (indexUrl.trim().isEmpty) return const {};
  final mode = modeOverride ?? torchWheelMirrorModeForUrl(url, indexUrl);
  if (mode == TorchWheelMirrorMode.findLinks) {
    return {
      'UV_FIND_LINKS': indexUrl,
      'UV_NO_SOURCES_PACKAGE': kTorchMirrorNoSourcesPackages,
    };
  }
  final indexName = torchIndexNameForExtra(torchExtra);
  return {'UV_INDEX': '$indexName=$indexUrl'};
}

List<String> torchWheelMirrorEnvironmentPreview(
  String url,
  String? torchExtra,
) {
  final env = torchWheelMirrorEnvironment(url, torchExtra);
  final lines = <String>[];
  for (final key in ['UV_INDEX', 'UV_FIND_LINKS', 'UV_NO_SOURCES_PACKAGE']) {
    final value = env[key];
    if (value != null && value.isNotEmpty) lines.add('$key=$value');
  }
  return lines;
}

const _torchWheelFlavors = [
  'cpu',
  'cu118',
  'cu121',
  'cu124',
  'cu126',
  'cu128',
  'cu129',
  'cu130',
];

const _torchMirrorModeQueryKeys = {
  'format',
  'mode',
  'uv',
  'uv-format',
  'uv_format',
};

const _torchMirrorFindLinksTokens = {
  'flat',
  'find-links',
  'find_links',
  'links',
};

const _torchMirrorNamedIndexTokens = {
  'index',
  'named-index',
  'named_index',
  'simple',
  'pep503',
};

String _torchMirrorDataUrl(String url) {
  final trimmed = url.trim();
  final uri = Uri.tryParse(trimmed);
  if (uri == null || !uri.hasScheme) return trimmed;
  final stripFragment = _isTorchMirrorModeToken(uri.fragment);
  final filteredQuery = <String, String>{};
  var strippedQuery = false;
  for (final entry in uri.queryParameters.entries) {
    if (_isTorchMirrorModeQuery(entry.key, entry.value)) {
      strippedQuery = true;
    } else {
      filteredQuery[entry.key] = entry.value;
    }
  }
  if (!stripFragment && !strippedQuery) return trimmed;
  final next = uri.replace(
    queryParameters: uri.hasQuery ? filteredQuery : null,
    fragment: stripFragment ? '' : uri.fragment,
  );
  return _trimEmptyQueryOrFragment(next.toString());
}

String _trimEmptyQueryOrFragment(String url) {
  return url.replaceFirst(RegExp(r'[#?]$'), '');
}

TorchWheelMirrorMode? _torchMirrorForcedMode(String url) {
  final uri = Uri.tryParse(url.trim());
  if (uri == null || !uri.hasScheme) return null;
  final fragmentMode = _torchMirrorModeToken(uri.fragment);
  if (fragmentMode != null) return fragmentMode;
  for (final entry in uri.queryParameters.entries) {
    if (!_torchMirrorModeQueryKeys.contains(entry.key.toLowerCase())) continue;
    final mode = _torchMirrorModeToken(entry.value);
    if (mode != null) return mode;
  }
  return null;
}

bool _isTorchMirrorModeQuery(String key, String value) {
  return _torchMirrorModeQueryKeys.contains(key.toLowerCase()) &&
      _isTorchMirrorModeToken(value);
}

bool _isTorchMirrorModeToken(String value) {
  return _torchMirrorModeToken(value) != null;
}

TorchWheelMirrorMode? _torchMirrorModeToken(String value) {
  final token = value.trim().toLowerCase();
  if (_torchMirrorFindLinksTokens.contains(token)) {
    return TorchWheelMirrorMode.findLinks;
  }
  if (_torchMirrorNamedIndexTokens.contains(token)) {
    return TorchWheelMirrorMode.namedIndex;
  }
  return null;
}

const kDefaultHfEndpointMirror = 'https://hf-mirror.com';

String aiProfileCupLabel(String profile) {
  final normalized = profile.trim();
  return switch (normalized) {
    '' => '超大杯',
    'local-base' => '中杯',
    'local-deep' => '大杯',
    'local-heavy' => '超大杯',
    _ => normalized,
  };
}

String aiProfileUserText(String value) {
  return value
      .replaceAll('local-base profile', '中杯')
      .replaceAll('local-deep profile', '大杯')
      .replaceAll('local-heavy profile', '超大杯')
      .replaceAll('local-base', '中杯')
      .replaceAll('local-deep', '大杯')
      .replaceAll('local-heavy', '超大杯')
      .replaceAll('当前 profile', '当前杯型')
      .replaceAll('AI providers', 'AI Providers')
      .replaceAll('AI provider', 'AI Provider')
      .replaceAll('providers', 'Providers')
      .replaceAll('provider', 'Provider')
      .replaceAll('warmup', 'Warmup');
}

List<String> aiWarmupProvidersForProfile(String profile) {
  return switch (_validatedAiProfile(profile)) {
    'local-heavy' => kAiWarmupProviders,
    'local-deep' => const ['beat_this', 'songformer', 'mert'],
    _ => const [],
  };
}

@immutable
class AiEnvironmentSyncOptions {
  const AiEnvironmentSyncOptions({
    required this.profile,
    this.syncDependencies = true,
    this.forceReinstall = false,
    this.prepareModelCache = false,
    this.warmupProviders = const [],
    this.usePipIndexMirror = false,
    this.pipIndexUrl = kDefaultPipIndexMirror,
    this.useTorchWheelMirror = false,
    this.torchWheelMirrorUrl = kDefaultTorchWheelMirror,
    this.useHfMirror = false,
    this.hfEndpoint = kDefaultHfEndpointMirror,
  });

  final String profile;
  final bool syncDependencies;
  final bool forceReinstall;
  final bool prepareModelCache;
  final List<String> warmupProviders;
  final bool usePipIndexMirror;
  final String pipIndexUrl;
  final bool useTorchWheelMirror;
  final String torchWheelMirrorUrl;
  final bool useHfMirror;
  final String hfEndpoint;

  bool get hasWork => syncDependencies || forceReinstall || prepareModelCache;
}

@immutable
class AiEnvironmentProgressStep {
  const AiEnvironmentProgressStep({
    required this.id,
    required this.label,
    required this.detail,
    required this.status,
  });

  final String id;
  final String label;
  final String detail;
  final String status;

  bool get terminal =>
      status == 'done' ||
      status == 'skipped' ||
      status == 'warning' ||
      status == 'error';

  AiEnvironmentProgressStep copyWith({String? detail, String? status}) {
    return AiEnvironmentProgressStep(
      id: id,
      label: label,
      detail: detail ?? this.detail,
      status: status ?? this.status,
    );
  }
}

@immutable
class RadioStatusOption {
  const RadioStatusOption({
    required this.number,
    required this.name,
    required this.tracks,
    required this.bankSlots,
    required this.freeRoam,
    required this.event,
  });

  final int number;
  final String name;
  final int? tracks;
  final int? bankSlots;
  final int? freeRoam;
  final int? event;

  String get menuLabel {
    final count = tracks == null ? '' : ' · $tracks 首';
    return 'R$number · $name$count';
  }
}

@immutable
class ToolchainStatusItem {
  const ToolchainStatusItem({
    required this.label,
    required this.value,
    required this.detail,
    required this.status,
  });

  final String label;
  final String value;
  final String detail;
  final String status;

  factory ToolchainStatusItem.fromJson(Map<String, dynamic> json) {
    return ToolchainStatusItem(
      label: '${json['label'] ?? ''}',
      value: '${json['value'] ?? ''}',
      detail: '${json['detail'] ?? ''}',
      status: '${json['status'] ?? 'info'}',
    );
  }
}

@immutable
class ToolchainStatusSection {
  const ToolchainStatusSection({
    required this.id,
    required this.title,
    required this.status,
    required this.summary,
    required this.items,
    required this.warnings,
  });

  final String id;
  final String title;
  final String status;
  final String summary;
  final List<ToolchainStatusItem> items;
  final List<String> warnings;

  factory ToolchainStatusSection.fromJson(
    String id,
    Map<String, dynamic> json,
  ) {
    return ToolchainStatusSection(
      id: id,
      title: '${json['title'] ?? id}',
      status: '${json['status'] ?? 'unknown'}',
      summary: '${json['summary'] ?? ''}',
      items: [
        for (final item in _jsonList(json['items']))
          if (_jsonMap(item) case final map?) ToolchainStatusItem.fromJson(map),
      ],
      warnings: _jsonStringList(json['warnings']),
    );
  }
}

@immutable
class ToolchainFix {
  const ToolchainFix({
    required this.id,
    required this.label,
    required this.detail,
    required this.command,
    required this.severity,
  });

  final String id;
  final String label;
  final String detail;
  final String command;
  final String severity;

  factory ToolchainFix.fromJson(Map<String, dynamic> json) {
    return ToolchainFix(
      id: '${json['id'] ?? ''}',
      label: '${json['label'] ?? '修复项'}',
      detail: '${json['detail'] ?? ''}',
      command: '${json['command'] ?? ''}',
      severity: '${json['severity'] ?? 'info'}',
    );
  }
}

@immutable
class ToolchainStatusSummary {
  const ToolchainStatusSummary({
    required this.checked,
    required this.profile,
    required this.status,
    required this.label,
    required this.summary,
    required this.sections,
    required this.fixes,
    this.checking = false,
    this.error,
  });

  const ToolchainStatusSummary.notChecked({
    String profile = kDefaultAiPipelineProfile,
  }) : this(
         checked: false,
         profile: profile,
         status: 'unknown',
         label: '未检查',
         summary: '点击“检查工具链”查看 uv、Python、音频工具和 AI Provider 状态。',
         sections: const [],
         fixes: const [],
       );

  final bool checked;
  final String profile;
  final String status;
  final String label;
  final String summary;
  final List<ToolchainStatusSection> sections;
  final List<ToolchainFix> fixes;
  final bool checking;
  final String? error;

  bool get ready => !checking && status == 'ready';
  bool get needsAttention =>
      !checking &&
      (status == 'missing' ||
          status == 'error' ||
          status == 'degraded' ||
          status == 'needs_sync');
  bool get coreBlocking {
    if (!checked || checking) return false;
    final coreSections = sections
        .where((section) => _coreToolchainSectionIds.contains(section.id))
        .toList(growable: false);
    if (coreSections.isEmpty) return {'missing', 'error'}.contains(status);
    return coreSections.any(_sectionBlocksCoreToolchain);
  }

  bool get coreReady => checked && !checking && !coreBlocking;

  String get coreIssueSummary {
    final blockers = sections
        .where((section) => _sectionBlocksCoreToolchain(section))
        .map((section) {
          final summary = section.summary.trim();
          return summary.isEmpty ? section.title : '${section.title}：$summary';
        })
        .toList(growable: false);
    if (blockers.isEmpty) return summary;
    return blockers.take(3).join('；');
  }

  ToolchainStatusSection? section(String id) {
    return sections.firstWhereOrNull((section) => section.id == id);
  }

  factory ToolchainStatusSummary.fromJson(Map<String, dynamic> json) {
    final overall = _jsonMap(json['overall']) ?? const {};
    final sectionsJson = _jsonMap(json['sections']) ?? const {};
    return ToolchainStatusSummary(
      checked: true,
      profile: '${json['profile'] ?? kDefaultAiPipelineProfile}',
      status: '${overall['status'] ?? 'unknown'}',
      label: '${overall['label'] ?? '未知'}',
      summary: '${overall['summary'] ?? ''}',
      sections: [
        for (final entry in sectionsJson.entries)
          if (_jsonMap(entry.value) case final map?)
            ToolchainStatusSection.fromJson(entry.key, map),
      ],
      fixes: [
        for (final item in _jsonList(json['fixes']))
          if (_jsonMap(item) case final map?) ToolchainFix.fromJson(map),
      ],
    );
  }

  factory ToolchainStatusSummary.checking({
    ToolchainStatusSummary? previous,
    String? summary,
  }) {
    return ToolchainStatusSummary(
      checked: previous?.checked ?? false,
      profile: previous?.profile ?? kDefaultAiPipelineProfile,
      status: 'checking',
      label: '检测中',
      summary: summary ?? '正在检查 uv、Python、音频工具和 AI Provider 状态。',
      sections: previous?.sections ?? const [],
      fixes: const [],
      checking: true,
    );
  }

  factory ToolchainStatusSummary.error(String message) {
    return ToolchainStatusSummary(
      checked: true,
      profile: kDefaultAiPipelineProfile,
      status: 'error',
      label: '检查失败',
      summary: message,
      sections: const [],
      fixes: const [],
      error: message,
    );
  }
}

const _coreToolchainSectionIds = {'uv', 'audio_tools', 'python'};

bool _sectionBlocksCoreToolchain(ToolchainStatusSection section) {
  if (!_coreToolchainSectionIds.contains(section.id)) return false;
  return {'missing', 'error'}.contains(section.status);
}

@immutable
class PackageTrackAssignment {
  const PackageTrackAssignment({
    required this.source,
    required this.radioLabel,
    required this.slot,
    this.playlistTypes = const ['FreeRoam', 'Event'],
  });

  final String source;
  final String radioLabel;
  final int slot;
  final List<String> playlistTypes;

  String get label {
    final types = normalizedPlaylistTypes;
    if (types.length == 1) {
      return '$radioLabel · ${PlaylistAssignment.playlistLabel(types.single)} slot $slot';
    }
    return '$radioLabel · slot $slot';
  }

  List<String> get normalizedPlaylistTypes {
    final out = <String>[];
    for (final type in playlistTypes) {
      final normalized = PlaylistAssignment.normalizePlaylistType(type);
      if (!out.contains(normalized)) out.add(normalized);
    }
    return out.isEmpty ? const ['FreeRoam', 'Event'] : out;
  }

  static String keyForPath(String path) {
    return canonicalPathKey(path);
  }
}

@immutable
class PackageArtifactSummary {
  const PackageArtifactSummary({
    required this.radio,
    required this.station,
    required this.bankName,
    required this.musicCount,
    required this.bankSlots,
    required this.playlistMode,
    required this.skipBank,
    required this.runtimeVerified,
    this.currentRadioPassthrough = false,
    required this.sourceLang,
    required this.targetLang,
    required this.previewTracks,
    required this.assignments,
  });

  final int? radio;
  final String station;
  final String bankName;
  final int musicCount;
  final int? bankSlots;
  final String playlistMode;
  final bool skipBank;
  final bool runtimeVerified;
  final bool currentRadioPassthrough;
  final String? sourceLang;
  final String? targetLang;
  final List<String> previewTracks;
  final List<PackageTrackAssignment> assignments;

  String get title {
    final prefix = radio == null ? station : 'R$radio · $station';
    return prefix.trim().isEmpty ? '已准备电台包' : prefix;
  }

  String get detail {
    if (currentRadioPassthrough) {
      final language = sourceLang == null || targetLang == null
          ? '语言设置'
          : '$sourceLang 显示 / $targetLang 语音';
      final slots = bankSlots == null ? '' : ' · $bankSlots 个槽位';
      return '当前游戏 radio 原样打包$slots · $language';
    }
    final slots = bankSlots == null ? '' : ' · $bankSlots 个槽位';
    final mode = playlistMode == 'add' ? '保留原播放列表' : '替换播放列表';
    final packageState = skipBank ? '仅生成预览' : '可写入音频包';
    final language = sourceLang == null || targetLang == null
        ? ''
        : ' · $sourceLang 显示 / $targetLang 语音';
    return '$musicCount 首输入$slots · $mode · $packageState$language';
  }

  String get trackPreview {
    if (currentRadioPassthrough && previewTracks.isEmpty) {
      return 'RadioInfo 与 bank 保持当前游戏内容';
    }
    if (previewTracks.isEmpty) return '未读取到曲目信息';
    final names = previewTracks.take(3).join(', ');
    return previewTracks.length > 3 ? '$names...' : names;
  }

  PackageTrackAssignment? assignmentForSource(String source) {
    if (source.trim().isEmpty) return null;
    final key = PackageTrackAssignment.keyForPath(source);
    for (final assignment in assignments) {
      if (PackageTrackAssignment.keyForPath(assignment.source) == key) {
        return assignment;
      }
    }
    return null;
  }
}

@immutable
class PackageBuildProgressStep {
  const PackageBuildProgressStep({
    required this.id,
    required this.label,
    required this.detail,
    required this.status,
    required this.weight,
    this.summary = '',
    this.runtimeMs,
  });

  final String id;
  final String label;
  final String detail;
  final String status;
  final int weight;
  final String summary;
  final int? runtimeMs;

  bool get terminal =>
      status == 'done' ||
      status == 'skipped' ||
      status == 'warning' ||
      status == 'error';

  PackageBuildProgressStep copyWith({
    String? status,
    String? summary,
    int? runtimeMs,
  }) {
    return PackageBuildProgressStep(
      id: id,
      label: label,
      detail: detail,
      status: status ?? this.status,
      weight: weight,
      summary: summary ?? this.summary,
      runtimeMs: runtimeMs ?? this.runtimeMs,
    );
  }

  factory PackageBuildProgressStep.fromJson(Map<String, dynamic> json) {
    return PackageBuildProgressStep(
      id: '${json['id'] ?? ''}',
      label: '${json['label'] ?? json['id'] ?? '步骤'}',
      detail: '${json['detail'] ?? ''}',
      status: 'pending',
      weight: _objectInt(json['weight']) ?? 1,
    );
  }
}

@immutable
class BaselinePlanSummary {
  const BaselinePlanSummary({
    required this.fileCount,
    required this.totalSize,
    required this.gameVersionId,
    required this.byScope,
    required this.byStatus,
    required this.files,
  });

  final int fileCount;
  final int totalSize;
  final String? gameVersionId;
  final Map<String, int> byScope;
  final Map<String, int> byStatus;
  final List<BaselinePlanFile> files;

  int get radioInfoCount => byScope['radio_info'] ?? 0;
  int get bankCount => byScope['radio_bank'] ?? 0;
  int get stringTableCount => byScope['string_table'] ?? 0;
  int get okCount => byStatus['ok'] ?? 0;
  int get backedUpCount =>
      okCount + (byStatus['backup_differs_from_current'] ?? 0);
  int get packageReadyCount => files.where((file) => file.hasPackage).length;
  int get coveredCount =>
      files.where((file) => file.coverageStatus == 'covered').length;
  int get missingCount => byStatus['backup_missing'] ?? 0;
  int get unbackedProtectedFileCount => byStatus['not_backed_up'] ?? 0;
  int get changedCount =>
      (byStatus['backup_changed'] ?? 0) +
      (byStatus['backup_differs_from_current'] ?? 0);
  int get integrityBreakCount =>
      (byStatus['backup_changed'] ?? 0) + missingCount;
  bool get hasIntegrityBreak => integrityBreakCount > 0;
  bool get hasBackupStatus => byStatus.isNotEmpty;

  String get summary {
    final parts = <String>[
      '$fileCount 个文件',
      if (radioInfoCount > 0) '$radioInfoCount 个 RadioInfo',
      if (bankCount > 0) '$bankCount 个电台 bank',
      if (stringTableCount > 0) '$stringTableCount 个语言表',
    ];
    return parts.join(' · ');
  }
}

@immutable
class BaselinePlanFile {
  const BaselinePlanFile({
    required this.scope,
    required this.installRelativePath,
    required this.sourceGamePath,
    required this.size,
    required this.md5,
    required this.exists,
    required this.baselineStatus,
    required this.backupPath,
    required this.backupMd5,
    this.recordedBaselineMd5,
    required this.packageMd5,
    required this.coverageStatus,
  });

  final String scope;
  final String installRelativePath;
  final String sourceGamePath;
  final int size;
  final String md5;
  final bool exists;
  final String baselineStatus;
  final String? backupPath;
  final String? backupMd5;
  final String? recordedBaselineMd5;
  final String? packageMd5;
  final String coverageStatus;

  bool get backupComplete =>
      baselineStatus == 'ok' || baselineStatus == 'backup_differs_from_current';

  bool get currentDiffersFromBackup =>
      baselineStatus == 'backup_differs_from_current';

  bool get hasPackage => packageMd5 != null && packageMd5!.isNotEmpty;

  BaselinePlanFile copyWith({String? packageMd5, String? coverageStatus}) {
    return BaselinePlanFile(
      scope: scope,
      installRelativePath: installRelativePath,
      sourceGamePath: sourceGamePath,
      size: size,
      md5: md5,
      exists: exists,
      baselineStatus: baselineStatus,
      backupPath: backupPath,
      backupMd5: backupMd5,
      recordedBaselineMd5: recordedBaselineMd5,
      packageMd5: packageMd5 ?? this.packageMd5,
      coverageStatus: coverageStatus ?? this.coverageStatus,
    );
  }
}

enum GameFileIntegrityLevel {
  noPackage,
  noBaseline,
  packageApplied,
  previousPackageApplied,
  baseline,
  buildBumpAvailable,
  gameChanged,
  externalConflict,
  pendingVerify,
  unknown,
}

GameFileIntegrityLevel _gameFileIntegrityLevelFromJson(Object? value) {
  final raw = _objectString(value)?.split('.').last ?? '';
  final normalized = raw
      .replaceAll('-', '_')
      .replaceAll(' ', '_')
      .toLowerCase();
  final compact = normalized.replaceAll('_', '');
  return switch (compact) {
    'nopackage' => GameFileIntegrityLevel.noPackage,
    'nobaseline' => GameFileIntegrityLevel.noBaseline,
    'packageapplied' => GameFileIntegrityLevel.packageApplied,
    'previouspackageapplied' => GameFileIntegrityLevel.previousPackageApplied,
    'baseline' => GameFileIntegrityLevel.baseline,
    'buildbumpavailable' => GameFileIntegrityLevel.buildBumpAvailable,
    'gamechanged' => GameFileIntegrityLevel.gameChanged,
    'externalconflict' => GameFileIntegrityLevel.externalConflict,
    'pendingverify' => GameFileIntegrityLevel.pendingVerify,
    _ => GameFileIntegrityLevel.unknown,
  };
}

@immutable
class GameFileIntegrityIssue {
  const GameFileIntegrityIssue({
    required this.label,
    required this.path,
    required this.detail,
    required this.level,
  });

  factory GameFileIntegrityIssue.fromJson(Map<String, dynamic> data) {
    return GameFileIntegrityIssue(
      label: _objectString(data['label']) ?? '',
      path: _objectString(data['path']) ?? '',
      detail: _objectString(data['detail']) ?? '',
      level: _gameFileIntegrityLevelFromJson(data['level']),
    );
  }

  final String label;
  final String path;
  final String detail;
  final GameFileIntegrityLevel level;
}

@immutable
class GameFileIntegritySummary {
  const GameFileIntegritySummary({
    required this.level,
    required this.checkedFiles,
    required this.packageMatches,
    required this.lastAppliedPackageMatches,
    required this.baselineMatches,
    required this.pendingBaselineMatches,
    required this.changedFiles,
    required this.unknownFiles,
    required this.packageFiles,
    required this.baselineManifestPath,
    required this.pendingBaselineManifestPath,
    required this.packageManifestPath,
    required this.lastAppliedPackageManifestPath,
    required this.currentGameVersionId,
    required this.baselineBuildCompatible,
    required this.baselineSupportedGameVersionIds,
    required this.issues,
  });

  factory GameFileIntegritySummary.notChecked() {
    return const GameFileIntegritySummary(
      level: GameFileIntegrityLevel.unknown,
      checkedFiles: 0,
      packageMatches: 0,
      lastAppliedPackageMatches: 0,
      baselineMatches: 0,
      pendingBaselineMatches: 0,
      changedFiles: 0,
      unknownFiles: 0,
      packageFiles: 0,
      baselineManifestPath: null,
      pendingBaselineManifestPath: null,
      packageManifestPath: null,
      lastAppliedPackageManifestPath: null,
      currentGameVersionId: null,
      baselineBuildCompatible: true,
      baselineSupportedGameVersionIds: [],
      issues: [],
    );
  }

  factory GameFileIntegritySummary.deferred({
    required String? baselineManifestPath,
    required String? pendingBaselineManifestPath,
    required String? packageManifestPath,
    required String? lastAppliedPackageManifestPath,
  }) {
    return GameFileIntegritySummary(
      level: GameFileIntegrityLevel.unknown,
      checkedFiles: 0,
      packageMatches: 0,
      lastAppliedPackageMatches: 0,
      baselineMatches: 0,
      pendingBaselineMatches: 0,
      changedFiles: 0,
      unknownFiles: 0,
      packageFiles: 0,
      baselineManifestPath: baselineManifestPath,
      pendingBaselineManifestPath: pendingBaselineManifestPath,
      packageManifestPath: packageManifestPath,
      lastAppliedPackageManifestPath: lastAppliedPackageManifestPath,
      currentGameVersionId: null,
      baselineBuildCompatible: true,
      baselineSupportedGameVersionIds: const [],
      issues: const [],
    );
  }

  factory GameFileIntegritySummary.fromJson(Map<String, dynamic> data) {
    final issueItems = data['issues'] is List
        ? data['issues'] as List
        : const [];
    return GameFileIntegritySummary(
      level: _gameFileIntegrityLevelFromJson(data['level']),
      checkedFiles: _objectInt(data['checked_files']) ?? 0,
      packageMatches: _objectInt(data['package_matches']) ?? 0,
      lastAppliedPackageMatches:
          _objectInt(data['last_applied_package_matches']) ?? 0,
      baselineMatches: _objectInt(data['baseline_matches']) ?? 0,
      pendingBaselineMatches: _objectInt(data['pending_baseline_matches']) ?? 0,
      changedFiles: _objectInt(data['changed_files']) ?? 0,
      unknownFiles: _objectInt(data['unknown_files']) ?? 0,
      packageFiles: _objectInt(data['package_files']) ?? 0,
      baselineManifestPath: _objectString(data['baseline_manifest_path']),
      pendingBaselineManifestPath: _objectString(
        data['pending_baseline_manifest_path'],
      ),
      packageManifestPath: _objectString(data['package_manifest_path']),
      lastAppliedPackageManifestPath: _objectString(
        data['last_applied_package_manifest_path'],
      ),
      currentGameVersionId: _objectString(data['current_game_version_id']),
      baselineBuildCompatible:
          _objectBool(data['baseline_build_compatible']) ?? true,
      baselineSupportedGameVersionIds: _objectStringList(
        data['baseline_supported_game_version_ids'],
      ),
      issues: [
        for (final item in issueItems)
          if (_objectMap(item) case final map?)
            GameFileIntegrityIssue.fromJson(map),
      ],
    );
  }

  final GameFileIntegrityLevel level;
  final int checkedFiles;
  final int packageMatches;
  final int lastAppliedPackageMatches;
  final int baselineMatches;
  final int pendingBaselineMatches;
  final int changedFiles;
  final int unknownFiles;
  final int packageFiles;
  final String? baselineManifestPath;
  final String? pendingBaselineManifestPath;
  final String? packageManifestPath;
  final String? lastAppliedPackageManifestPath;
  final String? currentGameVersionId;
  final bool baselineBuildCompatible;
  final List<String> baselineSupportedGameVersionIds;
  final List<GameFileIntegrityIssue> issues;

  bool get hasPackage => packageManifestPath != null;
  bool get hasCurrentBaseline => baselineManifestPath != null;
  bool get hasPendingBaseline => pendingBaselineManifestPath != null;
  bool get hasLastAppliedPackage => lastAppliedPackageManifestPath != null;

  bool get needsOverwrite =>
      level == GameFileIntegrityLevel.baseline ||
      level == GameFileIntegrityLevel.previousPackageApplied ||
      level == GameFileIntegrityLevel.gameChanged ||
      level == GameFileIntegrityLevel.externalConflict;

  bool get needsWriteVersionChoice =>
      level != GameFileIntegrityLevel.unknown &&
      level != GameFileIntegrityLevel.externalConflict &&
      level != GameFileIntegrityLevel.previousPackageApplied &&
      level != GameFileIntegrityLevel.buildBumpAvailable &&
      hasPackage &&
      hasCurrentBaseline &&
      checkedFiles > 0 &&
      packageMatches != checkedFiles &&
      baselineMatches != checkedFiles;

  String get title {
    return switch (level) {
      GameFileIntegrityLevel.noPackage =>
        hasCurrentBaseline ? '原始备份已存在，尚未准备电台包' : '尚未准备电台包',
      GameFileIntegrityLevel.noBaseline => '需要创建原始备份',
      GameFileIntegrityLevel.packageApplied => '当前游戏文件等于准备包',
      GameFileIntegrityLevel.previousPackageApplied => '上一版准备包已写入',
      GameFileIntegrityLevel.baseline => '当前游戏文件等于原始备份',
      GameFileIntegrityLevel.buildBumpAvailable => 'Steam build 可安全更新',
      GameFileIntegrityLevel.gameChanged => '检测到游戏文件已更新',
      GameFileIntegrityLevel.externalConflict => '游戏文件冲突',
      GameFileIntegrityLevel.pendingVerify => '新游戏文件待验证',
      GameFileIntegrityLevel.unknown => '部分文件缺少校验记录',
    };
  }

  String get detail {
    if (level == GameFileIntegrityLevel.noPackage) {
      return hasCurrentBaseline
          ? '下方是原始备份保护清单；准备电台包后才会出现待写入文件校验。'
          : '先在 fresh install 或 Steam 验证完整性后创建原始备份；准备电台包是后续步骤。';
    }
    if (level == GameFileIntegrityLevel.noBaseline) {
      return '请在 fresh install 或 Steam 验证游戏完整性之后，创建一次原始备份。';
    }
    if (level == GameFileIntegrityLevel.previousPackageApplied) {
      return '当前游戏文件等于上次成功写入的包；新的准备包还没有覆盖进去。';
    }
    if (level == GameFileIntegrityLevel.buildBumpAvailable) {
      return 'Steam build id 已变化，但受保护文件仍等于原始备份，可以安全更新兼容记录。';
    }
    if (level == GameFileIntegrityLevel.externalConflict) {
      return 'Steam build 未变化，但当前文件不等于原始备份、准备包或上次写入包。';
    }
    final parts = <String>[
      '$checkedFiles 个文件已检查',
      if (packageMatches > 0) '$packageMatches 个等于准备包',
      if (lastAppliedPackageMatches > 0) '$lastAppliedPackageMatches 个等于上次写入包',
      if (baselineMatches > 0) '$baselineMatches 个等于原始备份',
      if (pendingBaselineMatches > 0) '$pendingBaselineMatches 个等于新游戏文件',
      if (changedFiles > 0) '$changedFiles 个不同于所有记录',
      if (unknownFiles > 0) '$unknownFiles 个缺少校验记录',
      if (packageFiles > 0) '包内 $packageFiles 个文件已记录',
    ];
    return parts.join(' · ');
  }
}

@immutable
class StudioState {
  const StudioState({
    required this.hasProject,
    required this.repoRoot,
    required this.projectDir,
    required this.recentProjectDirs,
    required this.gameDir,
    required this.preferredPath,
    required this.musicPaths,
    required this.radio,
    required this.aiProfile,
    required this.aiProfileNotice,
    required this.aiUsePipMirror,
    required this.aiPipIndexUrl,
    required this.aiUseTorchWheelMirror,
    required this.aiTorchWheelMirrorUrl,
    required this.aiUseHfMirror,
    required this.aiHfEndpoint,
    required this.sourceLang,
    required this.targetLang,
    required this.gameSourceLang,
    required this.gameTargetLang,
    required this.gameVersionId,
    required this.availableLanguages,
    required this.busy,
    required this.busyLabel,
    required this.aiEnvironmentProgressLabel,
    required this.aiEnvironmentProgressDetail,
    required this.aiEnvironmentProgressPercent,
    this.aiEnvironmentProgressSteps = const [],
    this.aiEnvironmentProgressLog = const [],
    required this.packageBuildProgressSteps,
    required this.gameRunning,
    required this.preferredLang,
    required this.languageReady,
    required this.languageSummary,
    required this.sourceLanguageExists,
    required this.targetLanguageExists,
    required this.targetMatchesSource,
    required this.preferredMatchesTarget,
    required this.voiceSlotVerified,
    required this.sourceLanguageBaselineStatus,
    required this.targetLanguageBaselineStatus,
    required this.sourceLanguageMd5,
    required this.targetLanguageMd5,
    required this.toolsOk,
    required this.toolchainStatus,
    required this.radioOptions,
    required this.lastPackageDir,
    required this.lastPackageSummary,
    required this.pendingPackageDir,
    required this.pendingPackageSummary,
    required this.fileIntegrity,
    required this.baselinePlanSummary,
    required this.refreshingPanels,
    required this.log,
    required this.toolInstallLog,
    required this.toolInstallFailureSummary,
    required this.statusSummary,
  });

  factory StudioState.initial(SharedPreferences prefs) {
    final repoRoot =
        prefs.getString(_StudioPrefsKeys.repoRoot) ??
        FhRadioStudioCli.defaultRepoRoot();
    final storedProjectRaw = prefs.getString(_StudioPrefsKeys.projectDir);
    final storedProjectDir =
        storedProjectRaw == null || storedProjectRaw.trim().isEmpty
        ? null
        : File(storedProjectRaw).absolute.path;
    final storedProjectExists =
        storedProjectDir != null && Directory(storedProjectDir).existsSync();
    final hasProject = storedProjectExists;
    final projectDir =
        storedProjectDir ?? FhRadioStudioProject.defaultProjectDir();
    if (hasProject) _ensureProjectQuietly(projectDir);
    final recentProjectDirs = _recentProjects(
      current: storedProjectDir,
      stored:
          prefs.getStringList(_StudioPrefsKeys.recentProjectDirs) ?? const [],
    );
    final projectSettings = hasProject
        ? FhRadioStudioProject.readSettings(projectDir)
        : const <String, dynamic>{};
    final gameDir =
        _objectString(projectSettings['game_dir']) ?? _defaultGameDir();
    final preferredPath =
        _objectString(projectSettings['preferred_path']) ?? '';
    final sourceLang =
        _objectString(projectSettings['source_lang'])?.toUpperCase() ?? 'CHS';
    final targetLang =
        _objectString(projectSettings['target_lang'])?.toUpperCase() ?? 'EN';
    final aiProfile = _validatedAiProfile(
      _objectString(projectSettings['ai_profile']) ??
          prefs.getString(_StudioPrefsKeys.aiProfile),
    );
    final aiUsePipMirror =
        prefs.getBool(_StudioPrefsKeys.aiUsePipMirror) ?? false;
    final aiPipIndexUrl = _pipIndexOrDefault(
      prefs.getString(_StudioPrefsKeys.aiPipIndexUrl),
    );
    final aiUseTorchWheelMirror =
        prefs.getBool(_StudioPrefsKeys.aiUseTorchWheelMirror) ?? false;
    final aiTorchWheelMirrorUrl = _nonEmptyOrDefault(
      prefs.getString(_StudioPrefsKeys.aiTorchWheelMirrorUrl),
      kDefaultTorchWheelMirror,
    );
    final aiUseHfMirror =
        prefs.getBool(_StudioPrefsKeys.aiUseHfMirror) ?? false;
    final aiHfEndpoint = _nonEmptyOrDefault(
      prefs.getString(_StudioPrefsKeys.aiHfEndpoint),
      kDefaultHfEndpointMirror,
    );
    final projectMusicPaths = _initialProjectMusicPaths(
      projectDir: projectDir,
      hasProject: hasProject,
    );
    final projectPackageDir = hasProject ? _latestPackageDir(projectDir) : null;
    final projectPendingPackageDir = hasProject
        ? _latestPendingPackageDir(projectDir)
        : null;
    final radio = _objectInt(projectSettings['radio']) ?? 4;
    if (hasProject) {
      FhRadioStudioProject.writeSettings(
        projectDir,
        gameDir: gameDir,
        radio: radio,
        sourceLang: sourceLang,
        targetLang: targetLang,
        aiProfile: aiProfile,
      );
    }
    return StudioState(
      hasProject: hasProject,
      repoRoot: repoRoot,
      projectDir: projectDir,
      recentProjectDirs: recentProjectDirs,
      gameDir: gameDir,
      preferredPath: preferredPath,
      musicPaths: projectMusicPaths,
      radio: radio,
      aiProfile: aiProfile,
      aiProfileNotice: null,
      aiUsePipMirror: aiUsePipMirror,
      aiPipIndexUrl: aiPipIndexUrl,
      aiUseTorchWheelMirror: aiUseTorchWheelMirror,
      aiTorchWheelMirrorUrl: aiTorchWheelMirrorUrl,
      aiUseHfMirror: aiUseHfMirror,
      aiHfEndpoint: aiHfEndpoint,
      sourceLang: sourceLang,
      targetLang: targetLang,
      gameSourceLang: sourceLang,
      gameTargetLang: targetLang,
      gameVersionId: null,
      availableLanguages: const [],
      busy: false,
      busyLabel: null,
      aiEnvironmentProgressLabel: null,
      aiEnvironmentProgressDetail: null,
      aiEnvironmentProgressPercent: null,
      packageBuildProgressSteps: const [],
      gameRunning: false,
      preferredLang: '未知',
      languageReady: false,
      languageSummary: '$sourceLang 显示 · $targetLang 语音',
      sourceLanguageExists: false,
      targetLanguageExists: false,
      targetMatchesSource: false,
      preferredMatchesTarget: false,
      voiceSlotVerified: false,
      sourceLanguageBaselineStatus: 'no_baseline',
      targetLanguageBaselineStatus: 'no_baseline',
      sourceLanguageMd5: null,
      targetLanguageMd5: null,
      toolsOk: false,
      toolchainStatus: ToolchainStatusSummary.notChecked(profile: aiProfile),
      radioOptions: const [],
      lastPackageDir: projectPackageDir,
      lastPackageSummary: _readPackageSummary(projectPackageDir),
      pendingPackageDir: projectPendingPackageDir,
      pendingPackageSummary: _readPackageSummary(projectPendingPackageDir),
      fileIntegrity: GameFileIntegritySummary.deferred(
        baselineManifestPath: hasProject
            ? _currentBaselineManifest(projectDir)
            : null,
        pendingBaselineManifestPath: hasProject
            ? _pendingBaselineManifest(projectDir)
            : null,
        packageManifestPath: _packageManifestPath(
          _integrityPackageDirFor(projectPendingPackageDir, projectPackageDir),
        ),
        lastAppliedPackageManifestPath: hasProject
            ? _existingLastAppliedPackageManifest(projectDir)
            : null,
      ),
      baselinePlanSummary: null,
      refreshingPanels: const {},
      log: const [],
      toolInstallLog: const [],
      toolInstallFailureSummary: null,
      statusSummary: '尚未检查',
    );
  }

  final String repoRoot;
  final bool hasProject;
  final String projectDir;
  final List<String> recentProjectDirs;
  final String gameDir;
  final String preferredPath;
  final List<String> musicPaths;
  final int radio;
  final String aiProfile;
  final String? aiProfileNotice;
  final bool aiUsePipMirror;
  final String aiPipIndexUrl;
  final bool aiUseTorchWheelMirror;
  final String aiTorchWheelMirrorUrl;
  final bool aiUseHfMirror;
  final String aiHfEndpoint;
  final String sourceLang;
  final String targetLang;
  final String gameSourceLang;
  final String gameTargetLang;
  final String? gameVersionId;
  final List<String> availableLanguages;
  final bool busy;
  final String? busyLabel;
  final String? aiEnvironmentProgressLabel;
  final String? aiEnvironmentProgressDetail;
  final int? aiEnvironmentProgressPercent;
  final List<AiEnvironmentProgressStep> aiEnvironmentProgressSteps;
  final List<String> aiEnvironmentProgressLog;
  final List<PackageBuildProgressStep> packageBuildProgressSteps;
  final bool gameRunning;
  final String preferredLang;
  final bool languageReady;
  final String languageSummary;
  final bool sourceLanguageExists;
  final bool targetLanguageExists;
  final bool targetMatchesSource;
  final bool preferredMatchesTarget;
  final bool voiceSlotVerified;
  final String sourceLanguageBaselineStatus;
  final String targetLanguageBaselineStatus;
  final String? sourceLanguageMd5;
  final String? targetLanguageMd5;
  final bool toolsOk;
  final ToolchainStatusSummary toolchainStatus;
  final List<RadioStatusOption> radioOptions;
  final String? lastPackageDir;
  final PackageArtifactSummary? lastPackageSummary;
  final String? pendingPackageDir;
  final PackageArtifactSummary? pendingPackageSummary;
  final GameFileIntegritySummary fileIntegrity;
  final BaselinePlanSummary? baselinePlanSummary;
  final Set<String> refreshingPanels;
  final List<String> log;
  final List<String> toolInstallLog;
  final String? toolInstallFailureSummary;
  final String statusSummary;

  String get musicPath => musicPaths.isEmpty ? '' : musicPaths.first;
  String get sourcesDir => FhRadioStudioProject.sourcesDir(projectDir);
  String get packagesDir => FhRadioStudioProject.packagesDir(projectDir);
  String get backupsDir => FhRadioStudioProject.backupsDir(projectDir);
  String get analysisDir => FhRadioStudioProject.analysisDir(projectDir);
  String get currentBaselineDir => _plannedBaselineDir(
    projectDir: projectDir,
    state: 'current',
    versionId: baselinePlanSummary?.gameVersionId,
  );
  String get pendingBaselineDir => _plannedBaselineDir(
    projectDir: projectDir,
    state: 'pending-verify',
    versionId: baselinePlanSummary?.gameVersionId,
  );
  String get oldBaselinesDir => p.join(backupsDir, 'baseline-old');
  String get currentBaselineManifest =>
      p.join(currentBaselineDir, 'baseline_manifest.json');
  String get pendingBaselineManifest =>
      p.join(pendingBaselineDir, 'baseline_manifest.json');
  String get lastAppliedPackageManifest =>
      FhRadioStudioProject.lastAppliedPackageManifestPath(projectDir);
  String get currentBaselineAudioDir =>
      p.join(currentBaselineDir, 'media', 'audio');
  String get pendingBaselineAudioDir =>
      p.join(pendingBaselineDir, 'media', 'audio');
  bool get pendingPackageReady =>
      pendingPackageDir != null &&
      (pendingPackageSummary != null ||
          _packageManifestPath(pendingPackageDir) != null);
  bool get currentPackageReady =>
      lastPackageDir != null &&
      (lastPackageSummary != null ||
          _packageManifestPath(lastPackageDir) != null);
  bool get pendingPackageBuildFailed =>
      pendingPackageDir != null &&
      !pendingPackageReady &&
      _pendingPackageFailureMarkerExists(pendingPackageDir);
  bool get pendingBaselineSelectedForConfirmation =>
      _pendingBaselineSelectionMarkerExists(pendingPackageDir);
  String get pendingPackageBuildFailureSummary =>
      _pendingPackageFailureSummary(pendingPackageDir) ?? '测试准备包生成失败。';
  String? get integrityPackageDir =>
      pendingPackageReady ? pendingPackageDir : lastPackageDir;
  String? get effectiveGameVersionId {
    final id = gameVersionId ?? baselinePlanSummary?.gameVersionId;
    return id == null || id.trim().isEmpty || id == 'unknown' ? null : id;
  }

  String? get currentBaselineVersionId {
    if (!File(currentBaselineManifest).existsSync()) return null;
    final id = _baselineVersionIdFromManifest(currentBaselineManifest);
    return id == 'unknown' ? null : id;
  }

  String get gameSteamBuildLabel =>
      _steamBuildLabel(effectiveGameVersionId) ?? '当前 Steam build 未校验';

  String get currentBaselineSteamBuildLabel =>
      _steamBuildLabel(currentBaselineVersionId) ?? '原始备份 build 未记录';

  bool get localBaselineSteamBuildVerified =>
      (fileIntegrity.currentGameVersionId != null &&
          fileIntegrity.baselineBuildCompatible) ||
      _sameSteamBuild(effectiveGameVersionId, currentBaselineVersionId);

  String get localBaselineSteamBuildSummary {
    final game = gameSteamBuildLabel;
    final baseline = currentBaselineSteamBuildLabel;
    if (localBaselineSteamBuildVerified) return 'Steam build 已验证：$game';
    return 'Steam build 不匹配或未校验：当前 $game · 原始备份 $baseline';
  }

  bool get checkingToolchain => toolchainStatus.checking;
  bool get refreshingStatus =>
      busy && (busyLabel == '检查当前环境' || busyLabel == '完整校验当前环境');
  bool get fileIntegrityRefreshing =>
      refreshingStatus ||
      refreshingPanels.contains(_RefreshScope.fileIntegrity);
  bool get toolchainRefreshing =>
      toolchainStatus.checking ||
      refreshingPanels.contains(_RefreshScope.toolchain);
  bool get toolchainWorkflowLocked => toolchainStatus.coreBlocking;
  String get toolchainWorkflowLockTitle => '核心工具链缺失，内容页面已锁定。';
  String get toolchainWorkflowLockMessage {
    final detail = toolchainStatus.coreIssueSummary.trim();
    if (detail.isEmpty) {
      return '请先在概览页修复 uv、Python 或核心音频处理组件；塞壬唱片仍可查看。';
    }
    return '请先在概览页修复：$detail。塞壬唱片仍可查看。';
  }

  bool get hasPackageBuildProgress => packageBuildProgressSteps.isNotEmpty;
  bool get hasAiEnvironmentProgress =>
      aiEnvironmentProgressLabel != null ||
      aiEnvironmentProgressPercent != null ||
      aiEnvironmentProgressSteps.isNotEmpty ||
      aiEnvironmentProgressLog.isNotEmpty;
  PackageBuildProgressStep? get activePackageBuildProgressStep {
    for (final step in packageBuildProgressSteps) {
      if (step.status == 'running') return step;
    }
    return null;
  }

  PackageBuildProgressStep? get lastVisiblePackageBuildProgressStep {
    for (final step in packageBuildProgressSteps.reversed) {
      if (step.status != 'pending') return step;
    }
    return packageBuildProgressSteps.isEmpty
        ? null
        : packageBuildProgressSteps.first;
  }

  int get packageBuildProgressPercent {
    if (packageBuildProgressSteps.isEmpty) return busy ? 0 : 100;
    final total = packageBuildProgressSteps.fold<int>(
      0,
      (sum, step) => sum + (step.weight <= 0 ? 1 : step.weight),
    );
    if (total <= 0) return 0;
    final completed = packageBuildProgressSteps.fold<int>(0, (sum, step) {
      if (!step.terminal) return sum;
      return sum + (step.weight <= 0 ? 1 : step.weight);
    });
    return ((completed / total) * 100).clamp(0, 100).round();
  }

  bool get projectOperationLocked => busy || fileIntegrityRefreshing;
  bool get baselineIntegrityBroken =>
      fileIntegrity.hasCurrentBaseline &&
      (baselinePlanSummary?.hasIntegrityBreak ?? false);
  bool get baselineWorkflowLocked =>
      !fileIntegrity.hasCurrentBaseline || baselineIntegrityBroken;
  String get baselineWorkflowLockTitle =>
      fileIntegrity.hasCurrentBaseline ? '原始备份不完整，编辑已锁定。' : '缺少原始备份，编辑已锁定。';
  String get baselineWorkflowLockMessage => fileIntegrity.hasCurrentBaseline
      ? '只允许编辑歌曲的 6 个时间点；请先确认 Steam build 并修复原始备份。'
      : '请先 fresh install 或 Steam 验证完整性，再创建原始备份。';
  bool get projectEditingLocked =>
      projectOperationLocked ||
      toolchainWorkflowLocked ||
      baselineWorkflowLocked;
  String get projectEditingLockTitle => projectOperationLocked
      ? '正在处理项目，编辑已锁定。'
      : toolchainWorkflowLocked
      ? toolchainWorkflowLockTitle
      : baselineWorkflowLockTitle;
  String get projectEditingLockMessage {
    if (fileIntegrityRefreshing) {
      return '正在扫描游戏文件、原始备份和准备包，完成后会恢复播放列表编辑。';
    }
    if (busy) {
      final label = busyLabel == null ? 'CLI 任务' : busyLabel!;
      return '当前正在执行：$label，完成后会恢复播放列表编辑。';
    }
    if (toolchainWorkflowLocked) return toolchainWorkflowLockMessage;
    return baselineWorkflowLockMessage;
  }

  bool get customSongEditingLocked => toolchainWorkflowLocked;

  bool get languageSelectionMatchesGame =>
      sourceLang == gameSourceLang && targetLang == gameTargetLang;

  PackageArtifactSummary? get languagePreparedPackage {
    final candidates = [pendingPackageSummary, lastPackageSummary];
    for (final package in candidates) {
      if (package == null) continue;
      if (package.sourceLang?.toUpperCase() == sourceLang &&
          package.targetLang?.toUpperCase() == targetLang) {
        return package;
      }
    }
    return null;
  }

  bool get languageSelectionPrepared =>
      !languageSelectionMatchesGame && languagePreparedPackage != null;

  String? get lastPackageDeployDir {
    final dir = lastPackageDir;
    if (dir == null) return null;
    return p.join(dir, 'package');
  }

  String? get pendingPackageDeployDir {
    final dir = pendingPackageDir;
    if (dir == null || !pendingPackageReady) return null;
    return p.join(dir, 'package');
  }

  StudioState copyWith({
    bool? hasProject,
    String? repoRoot,
    String? projectDir,
    List<String>? recentProjectDirs,
    String? gameDir,
    String? preferredPath,
    List<String>? musicPaths,
    int? radio,
    String? aiProfile,
    Object? aiProfileNotice = _sentinel,
    bool? aiUsePipMirror,
    String? aiPipIndexUrl,
    bool? aiUseTorchWheelMirror,
    String? aiTorchWheelMirrorUrl,
    bool? aiUseHfMirror,
    String? aiHfEndpoint,
    String? sourceLang,
    String? targetLang,
    String? gameSourceLang,
    String? gameTargetLang,
    Object? gameVersionId = _sentinel,
    List<String>? availableLanguages,
    bool? busy,
    Object? busyLabel = _sentinel,
    Object? aiEnvironmentProgressLabel = _sentinel,
    Object? aiEnvironmentProgressDetail = _sentinel,
    Object? aiEnvironmentProgressPercent = _sentinel,
    List<AiEnvironmentProgressStep>? aiEnvironmentProgressSteps,
    List<String>? aiEnvironmentProgressLog,
    List<PackageBuildProgressStep>? packageBuildProgressSteps,
    bool? gameRunning,
    String? preferredLang,
    bool? languageReady,
    String? languageSummary,
    bool? sourceLanguageExists,
    bool? targetLanguageExists,
    bool? targetMatchesSource,
    bool? preferredMatchesTarget,
    bool? voiceSlotVerified,
    String? sourceLanguageBaselineStatus,
    String? targetLanguageBaselineStatus,
    Object? sourceLanguageMd5 = _sentinel,
    Object? targetLanguageMd5 = _sentinel,
    bool? toolsOk,
    ToolchainStatusSummary? toolchainStatus,
    List<RadioStatusOption>? radioOptions,
    Object? lastPackageDir = _sentinel,
    Object? lastPackageSummary = _sentinel,
    Object? pendingPackageDir = _sentinel,
    Object? pendingPackageSummary = _sentinel,
    GameFileIntegritySummary? fileIntegrity,
    Object? baselinePlanSummary = _sentinel,
    Set<String>? refreshingPanels,
    List<String>? log,
    List<String>? toolInstallLog,
    Object? toolInstallFailureSummary = _sentinel,
    String? statusSummary,
  }) {
    return StudioState(
      hasProject: hasProject ?? this.hasProject,
      repoRoot: repoRoot ?? this.repoRoot,
      projectDir: projectDir ?? this.projectDir,
      recentProjectDirs: recentProjectDirs ?? this.recentProjectDirs,
      gameDir: gameDir ?? this.gameDir,
      preferredPath: preferredPath ?? this.preferredPath,
      musicPaths: musicPaths ?? this.musicPaths,
      radio: radio ?? this.radio,
      aiProfile: aiProfile ?? this.aiProfile,
      aiProfileNotice: identical(aiProfileNotice, _sentinel)
          ? this.aiProfileNotice
          : aiProfileNotice as String?,
      aiUsePipMirror: aiUsePipMirror ?? this.aiUsePipMirror,
      aiPipIndexUrl: aiPipIndexUrl ?? this.aiPipIndexUrl,
      aiUseTorchWheelMirror:
          aiUseTorchWheelMirror ?? this.aiUseTorchWheelMirror,
      aiTorchWheelMirrorUrl:
          aiTorchWheelMirrorUrl ?? this.aiTorchWheelMirrorUrl,
      aiUseHfMirror: aiUseHfMirror ?? this.aiUseHfMirror,
      aiHfEndpoint: aiHfEndpoint ?? this.aiHfEndpoint,
      sourceLang: sourceLang ?? this.sourceLang,
      targetLang: targetLang ?? this.targetLang,
      gameSourceLang: gameSourceLang ?? this.gameSourceLang,
      gameTargetLang: gameTargetLang ?? this.gameTargetLang,
      gameVersionId: identical(gameVersionId, _sentinel)
          ? this.gameVersionId
          : gameVersionId as String?,
      availableLanguages: availableLanguages ?? this.availableLanguages,
      busy: busy ?? this.busy,
      busyLabel: identical(busyLabel, _sentinel)
          ? this.busyLabel
          : busyLabel as String?,
      aiEnvironmentProgressLabel:
          identical(aiEnvironmentProgressLabel, _sentinel)
          ? this.aiEnvironmentProgressLabel
          : aiEnvironmentProgressLabel as String?,
      aiEnvironmentProgressDetail:
          identical(aiEnvironmentProgressDetail, _sentinel)
          ? this.aiEnvironmentProgressDetail
          : aiEnvironmentProgressDetail as String?,
      aiEnvironmentProgressPercent:
          identical(aiEnvironmentProgressPercent, _sentinel)
          ? this.aiEnvironmentProgressPercent
          : aiEnvironmentProgressPercent as int?,
      aiEnvironmentProgressSteps:
          aiEnvironmentProgressSteps ?? this.aiEnvironmentProgressSteps,
      aiEnvironmentProgressLog:
          aiEnvironmentProgressLog ?? this.aiEnvironmentProgressLog,
      packageBuildProgressSteps:
          packageBuildProgressSteps ?? this.packageBuildProgressSteps,
      gameRunning: gameRunning ?? this.gameRunning,
      preferredLang: preferredLang ?? this.preferredLang,
      languageReady: languageReady ?? this.languageReady,
      languageSummary: languageSummary ?? this.languageSummary,
      sourceLanguageExists: sourceLanguageExists ?? this.sourceLanguageExists,
      targetLanguageExists: targetLanguageExists ?? this.targetLanguageExists,
      targetMatchesSource: targetMatchesSource ?? this.targetMatchesSource,
      preferredMatchesTarget:
          preferredMatchesTarget ?? this.preferredMatchesTarget,
      voiceSlotVerified: voiceSlotVerified ?? this.voiceSlotVerified,
      sourceLanguageBaselineStatus:
          sourceLanguageBaselineStatus ?? this.sourceLanguageBaselineStatus,
      targetLanguageBaselineStatus:
          targetLanguageBaselineStatus ?? this.targetLanguageBaselineStatus,
      sourceLanguageMd5: identical(sourceLanguageMd5, _sentinel)
          ? this.sourceLanguageMd5
          : sourceLanguageMd5 as String?,
      targetLanguageMd5: identical(targetLanguageMd5, _sentinel)
          ? this.targetLanguageMd5
          : targetLanguageMd5 as String?,
      toolsOk: toolsOk ?? this.toolsOk,
      toolchainStatus: toolchainStatus ?? this.toolchainStatus,
      radioOptions: radioOptions ?? this.radioOptions,
      lastPackageDir: identical(lastPackageDir, _sentinel)
          ? this.lastPackageDir
          : lastPackageDir as String?,
      lastPackageSummary: identical(lastPackageSummary, _sentinel)
          ? this.lastPackageSummary
          : lastPackageSummary as PackageArtifactSummary?,
      pendingPackageDir: identical(pendingPackageDir, _sentinel)
          ? this.pendingPackageDir
          : pendingPackageDir as String?,
      pendingPackageSummary: identical(pendingPackageSummary, _sentinel)
          ? this.pendingPackageSummary
          : pendingPackageSummary as PackageArtifactSummary?,
      fileIntegrity: fileIntegrity ?? this.fileIntegrity,
      baselinePlanSummary: identical(baselinePlanSummary, _sentinel)
          ? this.baselinePlanSummary
          : baselinePlanSummary as BaselinePlanSummary?,
      refreshingPanels: refreshingPanels ?? this.refreshingPanels,
      log: log ?? this.log,
      toolInstallLog: toolInstallLog ?? this.toolInstallLog,
      toolInstallFailureSummary: identical(toolInstallFailureSummary, _sentinel)
          ? this.toolInstallFailureSummary
          : toolInstallFailureSummary as String?,
      statusSummary: statusSummary ?? this.statusSummary,
    );
  }
}

const Object _sentinel = Object();

Map<String, dynamic>? _jsonMap(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) {
    return value.map((key, item) => MapEntry('$key', item));
  }
  return null;
}

List<Object?> _jsonList(Object? value) {
  return value is List ? value : const [];
}

List<String> _jsonStringList(Object? value) {
  return [
    for (final item in _jsonList(value))
      if (item != null) '$item',
  ];
}

bool _isPackageBuildBusyLabel(String? label) {
  return label == '构建电台包' || label == '生成测试准备包';
}

List<PackageBuildProgressStep> _packageBuildStartupProgressSteps() {
  return const [
    PackageBuildProgressStep(
      id: 'app.start_cli',
      label: '启动构建 CLI',
      detail: '准备 uv runtime 并启动 build-package。',
      status: 'running',
      weight: 1,
    ),
  ];
}

StudioState _stateWithPackageBuildProgressEvent(
  StudioState current,
  Map<String, dynamic> event,
) {
  final type = '${event['event'] ?? ''}';
  if (type == 'plan') {
    final steps = [
      for (final item in _jsonList(event['steps']))
        if (_jsonMap(item) case final map?)
          PackageBuildProgressStep.fromJson(map),
    ];
    if (steps.isEmpty) return current;
    return current.copyWith(packageBuildProgressSteps: steps);
  }

  final stepId = '${event['step_id'] ?? ''}';
  if (stepId.isEmpty) return current;
  if (type == 'step_started') {
    return _updatePackageBuildProgressStep(current, stepId, (step) {
      return step.copyWith(status: 'running');
    });
  }
  if (type == 'step_completed') {
    final status = '${event['status'] ?? 'done'}';
    return _updatePackageBuildProgressStep(current, stepId, (step) {
      return step.copyWith(
        status: status,
        summary: '${event['summary'] ?? step.summary}',
        runtimeMs: _objectInt(event['runtime_ms']),
      );
    });
  }
  if (type == 'step_failed') {
    return _updatePackageBuildProgressStep(current, stepId, (step) {
      return step.copyWith(
        status: 'error',
        summary: '${event['summary'] ?? '执行失败'}',
        runtimeMs: _objectInt(event['runtime_ms']),
      );
    });
  }
  return current;
}

StudioState _updatePackageBuildProgressStep(
  StudioState current,
  String stepId,
  PackageBuildProgressStep Function(PackageBuildProgressStep step) update,
) {
  final steps = [...current.packageBuildProgressSteps];
  final index = steps.indexWhere((step) => step.id == stepId);
  final fallback = PackageBuildProgressStep(
    id: stepId,
    label: stepId,
    detail: '',
    status: 'pending',
    weight: 1,
  );
  if (index < 0) {
    steps.add(update(fallback));
  } else {
    steps[index] = update(steps[index]);
  }
  return current.copyWith(packageBuildProgressSteps: steps);
}

List<String> _importedPathsFromPayload(Map<String, dynamic>? payload) {
  if (payload == null) return const [];
  return [
    for (final item in _jsonList(payload['imported']))
      if (_jsonMap(item)?['path'] case final path?) File('$path').absolute.path,
  ];
}

String? _vendoredFfmpeg(String repoRoot) {
  final executable = Platform.isWindows ? 'ffmpeg.exe' : 'ffmpeg';
  final runtime = UvRuntime.resolve(repoRoot);
  final candidate = p.join(runtime.audioToolsDir, 'ffmpeg', executable);
  return File(candidate).existsSync() ? candidate : null;
}

String _validatedAiProfile(String? value) {
  final normalized = value?.trim();
  if (normalized == null || normalized.isEmpty) {
    return kDefaultAiPipelineProfile;
  }
  return kAiPipelineProfiles.contains(normalized)
      ? normalized
      : kDefaultAiPipelineProfile;
}

void _ensureProjectQuietly(String projectDir) {
  try {
    FhRadioStudioProject.ensure(projectDir);
  } on FileSystemException {
    // The dashboard will surface later failures in its action log.
  }
}

List<String> _initialProjectMusicPaths({
  required String projectDir,
  required bool hasProject,
}) {
  if (!hasProject) return const [];
  return _projectMusicPaths(projectDir);
}

List<String> _projectMusicPaths(String projectDir) {
  return FhRadioStudioProject.collectAudioFiles([
    FhRadioStudioProject.sourcesDir(projectDir),
    FhRadioStudioProject.sirenDir(projectDir),
  ]).map((file) => file.path).toList(growable: false);
}

List<String> _uniqueMissingSources(Iterable<String> values) {
  final out = <String>[];
  final seen = <String>{};
  for (final value in values) {
    final source = value.trim();
    if (source.isEmpty) continue;
    final absolute = File(source).absolute.path;
    final key = TrackTimingConfig.keyForPath(absolute);
    if (!seen.add(key)) continue;
    if (!File(absolute).existsSync() && !Directory(absolute).existsSync()) {
      out.add(absolute);
    }
  }
  out.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  return out;
}

List<String> _recentProjects({
  required String? current,
  required List<String> stored,
}) {
  final seen = <String>{};
  final result = <String>[];
  for (final raw in [?current, ...stored]) {
    final path = raw.trim();
    if (path.isEmpty) continue;
    final normalized = File(path).absolute.path;
    final key = canonicalPathKey(normalized);
    if (seen.add(key)) result.add(normalized);
    if (result.length == 8) break;
  }
  return result;
}

bool _projectArtifactPath(String? path, String projectDir) {
  if (path == null || path.trim().isEmpty) return false;
  return isCanonicalPathInside(projectDir, path);
}

bool _sameProjectPath(String a, String b) {
  return sameCanonicalPath(a, b);
}

String? _latestPackageDir(String projectDir, {bool pending = false}) {
  final dir = pending
      ? FhRadioStudioProject.pendingPackageDir(projectDir)
      : FhRadioStudioProject.currentPackageDir(projectDir);
  return _packageManifestPath(dir) == null ? null : dir;
}

String? _latestPendingPackageDir(String projectDir) {
  if (_pendingBaselineManifest(projectDir) == null) return null;
  final dir = FhRadioStudioProject.pendingPackageDir(projectDir);
  if (_packageManifestPath(dir) != null) return dir;
  if (_pendingPackageFailureMarkerExists(dir)) return dir;
  return null;
}

String? _integrityPackageDirFor(String? pendingPackageDir, String? packageDir) {
  return _packageManifestPath(pendingPackageDir) == null
      ? packageDir
      : pendingPackageDir;
}

String _pendingPackageFailureMarkerPath(String packageDir) {
  return p.join(packageDir, _pendingPackageFailureFileName);
}

String _pendingBaselineSelectionMarkerPath(String packageDir) {
  return p.join(packageDir, _pendingBaselineSelectionFileName);
}

bool _pendingPackageFailureMarkerExists(String? packageDir) {
  if (packageDir == null || packageDir.trim().isEmpty) return false;
  return File(_pendingPackageFailureMarkerPath(packageDir)).existsSync();
}

bool _pendingBaselineSelectionMarkerExists(String? packageDir) {
  if (packageDir == null || packageDir.trim().isEmpty) return false;
  return File(_pendingBaselineSelectionMarkerPath(packageDir)).existsSync();
}

String? _pendingPackageFailureSummary(String? packageDir) {
  if (packageDir == null || packageDir.trim().isEmpty) return null;
  final data = _readJsonMap(File(_pendingPackageFailureMarkerPath(packageDir)));
  final message = _objectString(data?['message'])?.trim();
  if (message != null && message.isNotEmpty) return message;
  return _pendingPackageFailureMarkerExists(packageDir) ? '测试准备包生成失败。' : null;
}

String? _existingLastAppliedPackageManifest(String projectDir) {
  final path = FhRadioStudioProject.lastAppliedPackageManifestPath(projectDir);
  return File(path).existsSync() ? path : null;
}

String? _currentBaselineManifest(String projectDir) {
  return _baselineManifestForState(projectDir, 'current');
}

String? _pendingBaselineManifest(String projectDir) {
  return _baselineManifestForState(projectDir, 'pending-verify');
}

String? _baselineManifestForState(String projectDir, String state) {
  final file = File(
    p.join(
      _plannedBaselineDir(
        projectDir: projectDir,
        state: state,
        versionId: null,
      ),
      'baseline_manifest.json',
    ),
  );
  if (!file.existsSync()) return null;
  final data = _readJsonMap(file);
  if (_objectString(data?['kind']) != 'game_baseline') return null;
  if (_objectString(data?['state']) != state) return null;
  return file.path;
}

String _plannedBaselineDir({
  required String projectDir,
  required String state,
  required String? versionId,
}) {
  return p.join(
    FhRadioStudioProject.backupsDir(projectDir),
    _baselineDirName(state: state, versionId: versionId),
  );
}

String _baselineDirName({required String state, required String? versionId}) {
  final stateSlug = FhRadioStudioProject.safeName(state);
  return 'baseline-$stateSlug';
}

String _baselineVersionIdFromManifest(String manifestPath) {
  final data = _readJsonMap(File(manifestPath));
  final direct = _objectString(data?['game_version_id']);
  if (direct != null && direct.trim().isNotEmpty && direct != 'unknown') {
    return direct;
  }
  final version = _objectMap(data?['game_version']);
  final nested = _objectString(version?['version_id']);
  if (nested != null && nested.trim().isNotEmpty && nested != 'unknown') {
    return nested;
  }
  final buildId = _objectString(version?['build_id']);
  if (buildId != null && buildId.trim().isNotEmpty) return 'steam-b$buildId';
  return 'unknown';
}

String? _packageManifestPath(String? packageDir) {
  return packageManifestFile(packageDir)?.path;
}

PackageArtifactSummary? _readPackageSummary(String? packageDir) {
  final manifest = packageManifestFile(packageDir);
  if (manifest == null) return null;
  final data = _readJsonMap(manifest);
  if (data == null) return null;
  final language = _objectMap(data['language']);
  final previews = <String>[];
  final assignments = <PackageTrackAssignment>[];
  final previewKeys = <String>{};
  final musicKeys = <String>{};
  final assignmentKeys = <String>{};

  void readPackageUnit(Map<String, dynamic> unit) {
    final music = unit['music'] is List ? unit['music'] as List : const [];
    final sourceByIndex = <int, String>{};
    for (int index = 0; index < music.length; index++) {
      final item = music[index];
      final map = _objectMap(item);
      if (map == null) continue;
      final source = _objectString(map['source']);
      final title = _objectString(map['display_name']) ?? 'Unknown Track';
      final artist = _objectString(map['artist']);
      final preview = artist == null || artist.isEmpty
          ? title
          : '$artist - $title';
      final key = source == null || source.isEmpty
          ? '$index:$preview'
          : PackageTrackAssignment.keyForPath(source);
      if (source != null && source.isNotEmpty) {
        sourceByIndex[index] = source;
        musicKeys.add(key);
      }
      if (previewKeys.add(key)) previews.add(preview);
    }

    final radio = _objectInt(unit['radio']);
    final station = _objectString(unit['station']) ?? '';
    final radioLabel =
        _objectString(unit['radio_code']) ??
        _radioAssignmentLabel(radio, station);
    final assignmentItems = unit['assignments'] is List
        ? unit['assignments'] as List
        : const [];
    for (final item in assignmentItems) {
      final map = _objectMap(item);
      if (map == null) continue;
      if (!(_objectBool(map['playlist_entry']) ?? false)) continue;
      final sourceIndex = _objectInt(map['source_index']);
      final slotIndex = _objectInt(map['slot_index']);
      if (slotIndex == null) continue;
      final directSource = _objectString(map['source']);
      final source = directSource == null || directSource.isEmpty
          ? (sourceIndex == null ? null : sourceByIndex[sourceIndex])
          : directSource;
      if (source == null || source.isEmpty) continue;
      final playlistTypes = _objectStringList(map['playlist_types']);
      final types = playlistTypes.isEmpty
          ? const ['FreeRoam', 'Event']
          : playlistTypes
                .map(PlaylistAssignment.normalizePlaylistType)
                .toSet()
                .toList(growable: false);
      final key =
          '${PackageTrackAssignment.keyForPath(source)}|$radioLabel|$slotIndex|${types.join(',')}';
      if (!assignmentKeys.add(key)) continue;
      assignments.add(
        PackageTrackAssignment(
          source: source,
          radioLabel: radioLabel,
          slot: slotIndex + 1,
          playlistTypes: types,
        ),
      );
    }
  }

  final radios = data['radios'] is List ? data['radios'] as List : const [];
  for (final item in radios) {
    final unit = _objectMap(item);
    if (unit != null) readPackageUnit(unit);
  }

  final radio = _objectInt(data['radio']);
  final station = _objectString(data['station']) ?? '';
  return PackageArtifactSummary(
    radio: radio,
    station: station,
    bankName: _objectString(data['target_bank_name']) ?? '',
    musicCount: musicKeys.isEmpty ? previews.length : musicKeys.length,
    bankSlots: _objectInt(data['bank_slots']),
    playlistMode: _objectString(data['playlist_mode']) ?? 'only',
    skipBank: _objectBool(data['skip_bank']) ?? false,
    runtimeVerified: _objectBool(data['runtime_verified']) ?? false,
    currentRadioPassthrough:
        _objectBool(data['current_radio_passthrough']) ?? false,
    sourceLang: _objectString(language?['source_lang']),
    targetLang: _objectString(language?['target_lang']),
    previewTracks: previews,
    assignments: assignments,
  );
}

void _writePendingPackageFailureMarker(String packageDir, CliRunResult result) {
  Directory(packageDir).createSync(recursive: true);
  final marker = File(_pendingPackageFailureMarkerPath(packageDir));
  final message = _buildPackageFailureMessage(result);
  marker.writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert({
      'schema_version': 1,
      'kind': 'pending_package_build_failure',
      'created_at': DateTime.now().toUtc().toIso8601String(),
      'exit_code': result.exitCode,
      'message': message,
      'command_line': result.commandLine,
    }),
    encoding: utf8,
  );
}

void _writePendingBaselineSelectionMarker(String packageDir) {
  Directory(packageDir).createSync(recursive: true);
  final marker = File(_pendingBaselineSelectionMarkerPath(packageDir));
  marker.writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert({
      'schema_version': 1,
      'kind': 'pending_baseline_selection',
      'created_at': DateTime.now().toUtc().toIso8601String(),
    }),
    encoding: utf8,
  );
}

String _buildPackageFailureMessage(CliRunResult result) {
  final lines = [
    ...const LineSplitter().convert(result.stderr),
    ...const LineSplitter().convert(result.stdout),
  ].reversed;
  for (final line in lines) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) continue;
    if (trimmed.startsWith('FH_RADIO_STUDIO_PROGRESS')) continue;
    return trimmed;
  }
  return result.cancelled
      ? '测试准备包生成已取消。'
      : 'build-package 退出码 ${result.exitCode}。';
}

String _radioAssignmentLabel(int? radio, String station) {
  final normalized = station.toLowerCase();
  if (normalized.contains('horizon pulse')) return 'HOR';
  if (normalized.contains('bass arena')) return 'BAS';
  if (normalized.contains('block party')) return 'BLK';
  if (normalized.contains('eurobeat')) return 'EUR';
  if (normalized.contains('rocas')) return 'ROC';
  if (normalized == 'xs' || normalized.contains('horizon xs')) return 'XS';
  if (normalized.contains('timeless')) return 'TIM';
  if (normalized.contains('mixmaster')) return 'MIX';
  if (radio != null) return 'R$radio';
  return station.trim().isEmpty ? 'R?' : station;
}

String? _steamBuildLabel(String? versionId) {
  if (versionId == null) return null;
  final buildId = _steamBuildId(versionId);
  if (buildId == null || buildId.isEmpty) return null;
  return 'Steam build $buildId';
}

String? _steamBuildId(String? versionId) {
  if (versionId == null) return null;
  final match = RegExp(
    r'^steam-b(.+)$',
    caseSensitive: false,
  ).firstMatch(versionId.trim());
  final buildId = match?.group(1)?.trim();
  return buildId == null || buildId.isEmpty || buildId == 'unknown'
      ? null
      : buildId;
}

bool _sameSteamBuild(String? left, String? right) {
  final leftBuild = _steamBuildId(left);
  final rightBuild = _steamBuildId(right);
  return leftBuild != null && rightBuild != null && leftBuild == rightBuild;
}

BaselinePlanSummary? _decodeBaselinePlan(String stdout) {
  try {
    final data = _objectMap(jsonDecode(stdout));
    return data == null ? null : _decodeBaselinePlanFromMap(data);
  } on FormatException {
    return null;
  }
}

BaselinePlanSummary _decodeBaselinePlanFromMap(Map<String, dynamic> data) {
  final scopeData = _objectMap(data['by_scope']) ?? const {};
  final byScope = <String, int>{};
  for (final entry in scopeData.entries) {
    byScope[entry.key] = _objectInt(entry.value) ?? 0;
  }
  final statusData = _objectMap(data['by_status']) ?? const {};
  final byStatus = <String, int>{};
  for (final entry in statusData.entries) {
    byStatus[entry.key] = _objectInt(entry.value) ?? 0;
  }
  final fileItems = data['files'] is List ? data['files'] as List : const [];
  final files = <BaselinePlanFile>[];
  for (final item in fileItems) {
    final map = _objectMap(item);
    if (map == null) continue;
    files.add(
      BaselinePlanFile(
        scope: _objectString(map['scope']) ?? '',
        installRelativePath:
            _objectString(map['install_relative_path']) ??
            _objectString(map['relative_path']) ??
            '',
        sourceGamePath: _objectString(map['source_game_path']) ?? '',
        size: _objectInt(map['size']) ?? 0,
        md5: _objectString(map['md5']) ?? '',
        exists: _objectBool(map['exists']) ?? true,
        baselineStatus:
            _objectString(map['baseline_status']) ?? 'not_backed_up',
        backupPath: _objectString(map['backup_path']),
        backupMd5: _objectString(map['backup_md5']),
        recordedBaselineMd5: _objectString(map['recorded_baseline_md5']),
        packageMd5: _objectString(map['package_md5']),
        coverageStatus: _objectString(map['coverage_status']) ?? 'unchecked',
      ),
    );
  }
  return BaselinePlanSummary(
    fileCount: _objectInt(data['file_count']) ?? files.length,
    totalSize: _objectInt(data['total_size']) ?? 0,
    gameVersionId: _objectString(data['game_version_id']),
    byScope: byScope,
    byStatus: byStatus,
    files: files,
  );
}

({BaselinePlanSummary? baselinePlan, GameFileIntegritySummary? integrity})?
_decodeIntegrityPayload(String stdout) {
  try {
    final data = _objectMap(jsonDecode(stdout));
    if (data == null) return null;
    final planData = _objectMap(data['baseline_plan']);
    final integrityData = _objectMap(data['integrity']);
    return (
      baselinePlan: planData == null
          ? null
          : _decodeBaselinePlanFromMap(planData),
      integrity: integrityData == null
          ? null
          : GameFileIntegritySummary.fromJson(integrityData),
    );
  } on FormatException {
    return null;
  }
}

Map<String, dynamic>? _readJsonMap(File file) {
  try {
    return _objectMap(jsonDecode(file.readAsStringSync(encoding: utf8)));
  } on FormatException {
    return null;
  } on FileSystemException {
    return null;
  }
}

Map<String, dynamic>? _objectMap(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return value.map((key, item) => MapEntry('$key', item));
  return null;
}

String? _objectString(Object? value) => value == null ? null : '$value';

String _nonEmptyOrDefault(String? value, String fallback) {
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? fallback : trimmed;
}

String _pipIndexOrDefault(String? value) {
  final trimmed = value?.trim();
  if (trimmed == null || trimmed.isEmpty) return kDefaultPipIndexMirror;
  return trimmed;
}

List<String> _objectStringList(Object? value) {
  if (value is List) {
    return [
      for (final item in value)
        if ('$item'.trim().isNotEmpty) '$item',
    ];
  }
  if (value is String && value.trim().isNotEmpty) return [value];
  return const [];
}

bool? _objectBool(Object? value) {
  if (value is bool) return value;
  if (value is String) {
    final lower = value.toLowerCase();
    if (lower == 'true') return true;
    if (lower == 'false') return false;
  }
  return null;
}

int? _objectInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.round();
  if (value is String) return int.tryParse(value);
  return null;
}

String _defaultGameDir() {
  if (Platform.isWindows) {
    return r'C:\Program Files (x86)\Steam\steamapps\common\ForzaHorizon6';
  }
  return '';
}

class StudioController extends StateNotifier<StudioState> {
  StudioController(this._prefs) : super(StudioState.initial(_prefs)) {
    if (state.hasProject) _deleteStalePendingPackage(state.projectDir);
  }

  final SharedPreferences _prefs;
  bool _startupFullCheckStarted = false;
  CliCancellationToken? _activeAiEnvironmentSyncToken;

  FhRadioStudioCli get _cli => FhRadioStudioCli(repoRoot: state.repoRoot);

  void setRepoRoot(String value) {
    state = state.copyWith(repoRoot: value);
    _prefs.setString(_StudioPrefsKeys.repoRoot, value);
  }

  void setProjectDir(String value) {
    final next = value.trim().isEmpty
        ? FhRadioStudioProject.defaultProjectDir()
        : File(value.trim()).absolute.path;
    _startupFullCheckStarted = false;
    FhRadioStudioProject.ensure(next);
    _deleteStalePendingPackage(next);
    final recentProjectDirs = _recentProjects(
      current: next,
      stored: state.recentProjectDirs,
    );
    final packageDir = _latestPackageDir(next);
    final pendingPackageDir = _latestPendingPackageDir(next);
    final musicPaths = _projectMusicPaths(next);
    final projectSettings = FhRadioStudioProject.readSettings(next);
    final gameDir =
        _objectString(projectSettings['game_dir']) ?? _defaultGameDir();
    final preferredPath =
        _objectString(projectSettings['preferred_path']) ?? '';
    final radio = _objectInt(projectSettings['radio']) ?? state.radio;
    final sourceLang =
        _objectString(projectSettings['source_lang'])?.toUpperCase() ??
        state.sourceLang;
    final targetLang =
        _objectString(projectSettings['target_lang'])?.toUpperCase() ??
        state.targetLang;
    final aiProfile = _validatedAiProfile(
      _objectString(projectSettings['ai_profile']) ?? state.aiProfile,
    );
    FhRadioStudioProject.writeSettings(
      next,
      gameDir: gameDir,
      preferredPath: preferredPath,
      radio: radio,
      sourceLang: sourceLang,
      targetLang: targetLang,
      aiProfile: aiProfile,
    );
    state = state.copyWith(
      hasProject: true,
      projectDir: next,
      recentProjectDirs: recentProjectDirs,
      gameDir: gameDir,
      preferredPath: preferredPath,
      musicPaths: musicPaths,
      radio: radio,
      aiProfile: aiProfile,
      sourceLang: sourceLang,
      targetLang: targetLang,
      gameSourceLang: sourceLang,
      gameTargetLang: targetLang,
      gameVersionId: null,
      availableLanguages: const [],
      languageReady: false,
      languageSummary: '$sourceLang 显示 · $targetLang 语音',
      sourceLanguageExists: false,
      targetLanguageExists: false,
      targetMatchesSource: false,
      preferredMatchesTarget: false,
      voiceSlotVerified: false,
      sourceLanguageBaselineStatus: 'no_baseline',
      targetLanguageBaselineStatus: 'no_baseline',
      sourceLanguageMd5: null,
      targetLanguageMd5: null,
      toolchainStatus: ToolchainStatusSummary.notChecked(profile: aiProfile),
      lastPackageDir: packageDir,
      lastPackageSummary: _readPackageSummary(packageDir),
      pendingPackageDir: pendingPackageDir,
      pendingPackageSummary: _readPackageSummary(pendingPackageDir),
      baselinePlanSummary: null,
      refreshingPanels: const {},
      fileIntegrity: GameFileIntegritySummary.deferred(
        baselineManifestPath: _currentBaselineManifest(next),
        pendingBaselineManifestPath: _pendingBaselineManifest(next),
        packageManifestPath: _packageManifestPath(
          _integrityPackageDirFor(pendingPackageDir, packageDir),
        ),
        lastAppliedPackageManifestPath: _existingLastAppliedPackageManifest(
          next,
        ),
      ),
    );
    _prefs.setString(_StudioPrefsKeys.projectDir, next);
    _prefs.setStringList(_StudioPrefsKeys.recentProjectDirs, recentProjectDirs);
    _append('项目目录：$next');
  }

  void setProjectDirAndStartFullScan(String value) {
    setProjectDir(value);
    unawaited(refreshStatus(verifyFiles: true));
  }

  void updateRecentProjectPath(String oldPath, String newPath) {
    final next = newPath.trim().isEmpty
        ? FhRadioStudioProject.defaultProjectDir()
        : File(newPath.trim()).absolute.path;
    if (_pointsToCurrentProject(oldPath)) {
      setProjectDir(next);
      removeRecentProject(oldPath);
      unawaited(refreshStatus(verifyFiles: true));
      return;
    }

    FhRadioStudioProject.ensure(next);
    final replaced = [
      for (final path in state.recentProjectDirs)
        if (_sameProjectPath(path, oldPath)) next else path,
    ];
    final recentProjectDirs = _recentProjects(
      current: state.hasProject ? state.projectDir : null,
      stored: replaced,
    );
    state = state.copyWith(recentProjectDirs: recentProjectDirs);
    _prefs.setStringList(_StudioPrefsKeys.recentProjectDirs, recentProjectDirs);
  }

  void removeRecentProject(String path) {
    final recentProjectDirs = state.recentProjectDirs
        .where((item) => !_sameProjectPath(item, path))
        .toList(growable: false);
    final removingCurrentPointer = _pointsToCurrentProject(path);
    if (removingCurrentPointer) {
      state = state.copyWith(
        hasProject: false,
        projectDir: FhRadioStudioProject.defaultProjectDir(),
        recentProjectDirs: recentProjectDirs,
        musicPaths: const [],
        lastPackageDir: null,
        lastPackageSummary: null,
        pendingPackageDir: null,
        pendingPackageSummary: null,
        fileIntegrity: GameFileIntegritySummary.notChecked(),
        baselinePlanSummary: null,
      );
      _prefs.remove(_StudioPrefsKeys.projectDir);
    } else {
      state = state.copyWith(recentProjectDirs: recentProjectDirs);
    }
    _prefs.setStringList(_StudioPrefsKeys.recentProjectDirs, recentProjectDirs);
  }

  bool _pointsToCurrentProject(String path) {
    if (state.hasProject && _sameProjectPath(state.projectDir, path)) {
      return true;
    }
    final storedCurrent = _prefs.getString(_StudioPrefsKeys.projectDir);
    return storedCurrent != null &&
        storedCurrent.trim().isNotEmpty &&
        _sameProjectPath(storedCurrent, path);
  }

  void setGameDir(String value) {
    _startupFullCheckStarted = false;
    state = state.copyWith(
      gameDir: value,
      availableLanguages: const [],
      languageReady: false,
      sourceLanguageExists: false,
      targetLanguageExists: false,
      targetMatchesSource: false,
      preferredMatchesTarget: false,
      voiceSlotVerified: false,
      sourceLanguageBaselineStatus: 'no_baseline',
      targetLanguageBaselineStatus: 'no_baseline',
      sourceLanguageMd5: null,
      targetLanguageMd5: null,
      baselinePlanSummary: null,
      refreshingPanels: const {},
    );
    FhRadioStudioProject.writeSettings(
      state.projectDir,
      gameDir: value,
      radio: state.radio,
      sourceLang: state.sourceLang,
      targetLang: state.targetLang,
      aiProfile: state.aiProfile,
    );
    _refreshFileIntegrity();
  }

  void setMusicPath(String value) {
    setMusicPaths([value]);
  }

  void setMusicPaths(List<String> values) {
    final seen = <String>{};
    final next = <String>[];
    for (final raw in values) {
      final value = raw.trim();
      if (value.isEmpty || !seen.add(value.toLowerCase())) continue;
      next.add(value);
    }
    state = state.copyWith(musicPaths: next);
  }

  void addMusicPaths(List<String> values) {
    setMusicPaths([...state.musicPaths, ...values]);
  }

  Future<void> importMusicPaths(List<String> values) async {
    if (state.busy) return;
    final inputs = values
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toList(growable: false);
    if (inputs.isEmpty) return;
    await _withBusy('导入自建歌曲', () async {
      final result = await _run([
        'import-audio',
        ...inputs,
        '--project-dir',
        state.projectDir,
        if (_vendoredFfmpeg(state.repoRoot) case final ffmpeg?) ...[
          '--ffmpeg',
          ffmpeg,
        ],
        '--json',
      ], streamOutput: false);
      if (!result.ok) {
        _append('导入失败：音频无法复制或转码。');
        return;
      }
      final payload = _decodeJsonObject(result.stdout, label: '导入结果');
      final imported = _importedPathsFromPayload(payload);
      if (imported.isEmpty) {
        _append('没有找到可导入的音频文件。');
        return;
      }
      await _refreshTrackMetadataCacheWithinBusy(allSources: true);
      setMusicPaths([...state.musicPaths, ...imported]);
      _append('已导入 ${imported.length} 首到项目 sources。');
    });
  }

  Future<String?> importSirenTrack({
    required SirenTrack track,
    required SirenSongDetail detail,
    required String cachedAudioPath,
    String? coverImagePath,
  }) async {
    if (state.busy || !state.hasProject) return null;
    String? importedPath;
    await _withBusy('导入塞壬唱片', () async {
      final sirenArtists = sirenArtistsForDisplay(
        detail.artists.isEmpty ? track.artists : detail.artists,
      );
      final result = await _run([
        'import-audio',
        cachedAudioPath,
        '--project-dir',
        state.projectDir,
        '--target-folder',
        'siren',
        '--title',
        detail.name.isEmpty ? track.name : detail.name,
        '--artist',
        sirenArtists.join(sirenArtistDisplaySeparator),
        '--album',
        track.albumName,
        if (coverImagePath != null && coverImagePath.trim().isNotEmpty) ...[
          '--cover-image',
          coverImagePath,
        ],
        if (_vendoredFfmpeg(state.repoRoot) case final ffmpeg?) ...[
          '--ffmpeg',
          ffmpeg,
        ],
        '--json',
      ], streamOutput: false);
      if (!result.ok) {
        _append('塞壬导入失败：音频无法复制或转码。');
        return;
      }
      final payload = _decodeJsonObject(result.stdout, label: '塞壬导入结果');
      final imported = _importedPathsFromPayload(payload);
      if (imported.isEmpty) {
        _append('塞壬导入失败：没有生成项目音频。');
        return;
      }
      importedPath = imported.first;
      SirenImportRegistry.upsert(
        state.projectDir,
        SirenImportEntry.fromSiren(
          track: track,
          detail: detail,
          path: importedPath!,
        ),
      );
      await _refreshTrackMetadataCacheWithinBusy(allSources: true);
      setMusicPaths([...state.musicPaths, importedPath!]);
      _append('已导入塞壬唱片：${detail.name}');
    });
    return importedPath;
  }

  void removeMusicPath(String value) {
    setMusicPaths(state.musicPaths.where((path) => path != value).toList());
  }

  Future<bool> deleteMusicPath(String value) async {
    if (state.busy || !state.hasProject) return false;
    final target = File(value).absolute;
    final source = target.path;
    final sourceKey = TrackTimingConfig.keyForPath(source);
    var deleted = false;
    await _withBusy('删除自建歌曲', () async {
      final sourcesDir = FhRadioStudioProject.sourcesDir(state.projectDir);
      final sirenDir = FhRadioStudioProject.sirenDir(state.projectDir);
      final isProjectSource =
          _projectArtifactPath(source, sourcesDir) ||
          _projectArtifactPath(source, sirenDir);
      final isSirenSource = _projectArtifactPath(source, sirenDir);
      if (target.existsSync() && isProjectSource) {
        target.deleteSync();
        deleted = true;
      } else if (!target.existsSync()) {
        deleted = true;
        _append('音频文件已经不存在，正在清理项目引用。');
      } else {
        deleted = true;
        _append('已移除外部音频引用，未删除磁盘原文件：$source');
      }

      TrackTimingStore.remove(state.projectDir, source);
      TrackMetadataCache.remove(state.projectDir, source);
      if (isSirenSource) {
        SirenImportRegistry.removeByPath(state.projectDir, source);
      }
      final planFile = File(PlaylistPlanStore.configPath(state.projectDir));
      final plan = PlaylistPlanStore.read(state.projectDir);
      if (plan.hasDraft || planFile.existsSync()) {
        PlaylistPlanStore.write(state.projectDir, plan.unassign(source));
      }

      final next = <String>[];
      final seen = <String>{};
      for (final path in [
        ..._projectMusicPaths(state.projectDir),
        for (final path in state.musicPaths)
          if (TrackTimingConfig.keyForPath(path) != sourceKey &&
              File(path).existsSync())
            path,
      ]) {
        final key = TrackTimingConfig.keyForPath(path);
        if (seen.add(key)) next.add(File(path).absolute.path);
      }
      state = state.copyWith(musicPaths: next);
      _append('已删除自建歌曲：${p.basename(source)}');
    });
    return deleted;
  }

  Future<int> cleanupMissingPlaylistSources(Iterable<String> values) async {
    if (state.busy || !state.hasProject) return 0;
    final sources = _uniqueMissingSources(values);
    if (sources.isEmpty) {
      _append('没有发现需要清理的失效歌曲。');
      return 0;
    }

    var cleaned = 0;
    await _withBusy('清理失效歌曲', () async {
      final sirenDir = FhRadioStudioProject.sirenDir(state.projectDir);
      for (final source in sources) {
        TrackTimingStore.remove(state.projectDir, source);
        TrackMetadataCache.remove(state.projectDir, source);
        if (_projectArtifactPath(source, sirenDir)) {
          SirenImportRegistry.removeByPath(state.projectDir, source);
        }
        cleaned += 1;
      }

      final planFile = File(PlaylistPlanStore.configPath(state.projectDir));
      final plan = PlaylistPlanStore.read(state.projectDir);
      if (plan.hasDraft || planFile.existsSync()) {
        PlaylistPlanStore.write(
          state.projectDir,
          plan.unassignSources(sources),
        );
      }

      final sourceKeys = {
        for (final source in sources) TrackTimingConfig.keyForPath(source),
      };
      final next = <String>[];
      final seen = <String>{};
      for (final path in [
        ..._projectMusicPaths(state.projectDir),
        for (final path in state.musicPaths)
          if (!sourceKeys.contains(TrackTimingConfig.keyForPath(path)) &&
              File(path).existsSync())
            path,
      ]) {
        final key = TrackTimingConfig.keyForPath(path);
        if (seen.add(key)) next.add(File(path).absolute.path);
      }
      state = state.copyWith(musicPaths: next);

      final names = sources.map(p.basename).take(3).join('、');
      final suffix = sources.length > 3 ? ' 等' : '';
      _append(
        sources.length == 1
            ? '已删除失效歌曲引用：$names。'
            : '已删除 ${sources.length} 首失效歌曲引用：$names$suffix。',
      );
    });
    return cleaned;
  }

  void clearMusicPaths() {
    setMusicPaths(const []);
    _append('已清空音乐输入队列。');
  }

  void setRadio(String value) {
    final next = int.tryParse(value) ?? state.radio;
    setRadioNumber(next);
  }

  void setRadioNumber(int next) {
    state = state.copyWith(radio: next);
    FhRadioStudioProject.writeSettings(
      state.projectDir,
      gameDir: state.gameDir,
      radio: next,
      sourceLang: state.sourceLang,
      targetLang: state.targetLang,
      aiProfile: state.aiProfile,
    );
  }

  bool setAiProfile(String value) {
    final next = _validatedAiProfile(value);
    if (next == state.aiProfile) {
      clearAiProfileNotice();
      return false;
    }
    state = state.copyWith(
      aiProfile: next,
      aiProfileNotice: null,
      toolchainStatus: ToolchainStatusSummary.notChecked(profile: next),
    );
    _persistAiProfile(next);
    _append('AI pipeline：$next');
    return true;
  }

  Future<void> setAiProfileAndRefreshToolchain(String value) async {
    final changed = setAiProfile(value);
    if (!changed || state.busy) return;
    await refreshToolchainStatus();
  }

  void clearAiProfileNotice() {
    if (!mounted) return;
    if (state.aiProfileNotice == null) return;
    state = state.copyWith(aiProfileNotice: null);
  }

  void _persistAiProfile(String value) {
    FhRadioStudioProject.writeSettings(
      state.projectDir,
      gameDir: state.gameDir,
      radio: state.radio,
      sourceLang: state.sourceLang,
      targetLang: state.targetLang,
      aiProfile: value,
    );
    _prefs.setString(_StudioPrefsKeys.aiProfile, value);
  }

  void setSourceLang(String value) {
    final next = value.trim().toUpperCase();
    final exists =
        state.availableLanguages.isEmpty ||
        state.availableLanguages.contains(next);
    state = state.copyWith(
      sourceLang: next,
      languageReady: false,
      languageSummary: '$next 显示 · ${state.targetLang} 语音',
      sourceLanguageExists: exists,
      targetMatchesSource:
          next == state.gameSourceLang && state.targetMatchesSource,
      sourceLanguageMd5: null,
    );
    FhRadioStudioProject.writeSettings(
      state.projectDir,
      gameDir: state.gameDir,
      radio: state.radio,
      sourceLang: next,
      targetLang: state.targetLang,
      aiProfile: state.aiProfile,
    );
  }

  void setTargetLang(String value) {
    final next = value.trim().toUpperCase();
    final exists =
        state.availableLanguages.isEmpty ||
        state.availableLanguages.contains(next);
    state = state.copyWith(
      targetLang: next,
      languageReady: false,
      languageSummary: '${state.sourceLang} 显示 · $next 语音',
      targetLanguageExists: exists,
      targetMatchesSource:
          next == state.gameTargetLang && state.targetMatchesSource,
      preferredMatchesTarget: next == state.gameTargetLang,
    );
    FhRadioStudioProject.writeSettings(
      state.projectDir,
      gameDir: state.gameDir,
      radio: state.radio,
      sourceLang: state.sourceLang,
      targetLang: next,
      aiProfile: state.aiProfile,
    );
  }

  Future<void> refreshStatus({bool verifyFiles = false}) async {
    if (state.busy) return;
    final refreshProjectDir = state.projectDir;
    final refreshGameDir = state.gameDir;
    await _withBusy(verifyFiles ? '完整校验当前环境' : '检查当前环境', () async {
      state = state.copyWith(
        statusSummary: verifyFiles ? '正在完整校验当前环境' : '正在检查当前环境',
        toolchainStatus: ToolchainStatusSummary.checking(
          previous: state.toolchainStatus,
          summary: verifyFiles
              ? '正在完整校验游戏文件，并检查 uv、Python、音频工具和 AI Provider。'
              : '正在检查当前环境和工具链组件。',
        ),
      );
      final result = await _run(_statusArgs(), streamOutput: false);
      if (!result.ok) {
        state = state.copyWith(
          toolsOk: false,
          statusSummary: '状态检查失败',
          toolchainStatus: ToolchainStatusSummary.error('当前环境状态检查失败'),
        );
        return;
      }
      final payload = _decodeStatus(result.stdout);
      if (payload == null) {
        state = state.copyWith(
          statusSummary: '状态解析失败',
          toolchainStatus: ToolchainStatusSummary.error('当前环境状态解析失败'),
        );
        return;
      }
      if (!_isCurrentRefreshTarget(refreshProjectDir, refreshGameDir)) {
        _append('已忽略旧项目的状态结果。');
        return;
      }
      _applyStatusPayload(payload);
      await _refreshToolchainStatusWithinBusy();
      await _refreshTrackMetadataCacheWithinBusy(onlyIfMissing: true);
      if (verifyFiles) {
        await _refreshIntegrityFromCli();
      }
      _append('状态：${state.statusSummary}');
    });
  }

  Future<void> verifyFileIntegrity() async {
    if (state.busy) return;
    await _withPanelRefresh(_RefreshScope.fileIntegrity, '刷新文件校验', () async {
      await _refreshIntegrityFromCli();
    });
  }

  Future<void> refreshToolchainStatus() async {
    if (state.busy ||
        state.fileIntegrityRefreshing ||
        state.toolchainRefreshing) {
      return;
    }
    await _withPanelRefresh(
      _RefreshScope.toolchain,
      '检查工具链',
      _refreshToolchainStatusWithinBusy,
    );
  }

  Future<bool> syncToolchainEnvironment({
    AiEnvironmentSyncOptions? options,
  }) async {
    if (state.busy ||
        state.fileIntegrityRefreshing ||
        state.toolchainRefreshing) {
      return false;
    }
    final plan =
        options ??
        AiEnvironmentSyncOptions(
          profile: state.aiProfile,
          usePipIndexMirror: state.aiUsePipMirror,
          pipIndexUrl: state.aiPipIndexUrl,
          useTorchWheelMirror: state.aiUseTorchWheelMirror,
          torchWheelMirrorUrl: state.aiTorchWheelMirrorUrl,
          useHfMirror: state.aiUseHfMirror,
          hfEndpoint: state.aiHfEndpoint,
        );
    if (!plan.hasWork) return false;
    final profile = _validatedAiProfile(plan.profile);
    final pipIndexUrl = _pipIndexOrDefault(plan.pipIndexUrl);
    final hfEndpoint = _nonEmptyOrDefault(
      plan.hfEndpoint,
      kDefaultHfEndpointMirror,
    );
    final torchWheelMirrorUrl = _nonEmptyOrDefault(
      plan.torchWheelMirrorUrl,
      kDefaultTorchWheelMirror,
    );
    final mirrorEnvironment = _aiSyncMirrorEnvironment(
      usePipMirror: plan.usePipIndexMirror,
      pipIndexUrl: pipIndexUrl,
      useTorchWheelMirror: plan.useTorchWheelMirror,
      torchWheelMirrorUrl: torchWheelMirrorUrl,
      torchExtra: _cli.uvRuntime.torchExtra,
      torchMirrorMode: null,
      useHfMirror: plan.useHfMirror,
      hfEndpoint: hfEndpoint,
    );
    _prefs.setBool(_StudioPrefsKeys.aiUsePipMirror, plan.usePipIndexMirror);
    _prefs.setString(_StudioPrefsKeys.aiPipIndexUrl, pipIndexUrl);
    _prefs.setBool(
      _StudioPrefsKeys.aiUseTorchWheelMirror,
      plan.useTorchWheelMirror,
    );
    _prefs.setString(
      _StudioPrefsKeys.aiTorchWheelMirrorUrl,
      torchWheelMirrorUrl,
    );
    _prefs.setBool(_StudioPrefsKeys.aiUseHfMirror, plan.useHfMirror);
    _prefs.setString(_StudioPrefsKeys.aiHfEndpoint, hfEndpoint);
    state = state.copyWith(
      aiUsePipMirror: plan.usePipIndexMirror,
      aiPipIndexUrl: pipIndexUrl,
      aiUseTorchWheelMirror: plan.useTorchWheelMirror,
      aiTorchWheelMirrorUrl: torchWheelMirrorUrl,
      aiUseHfMirror: plan.useHfMirror,
      aiHfEndpoint: hfEndpoint,
    );
    final warmupProviders = plan.prepareModelCache
        ? (plan.warmupProviders.isNotEmpty
              ? plan.warmupProviders
              : aiWarmupProvidersForProfile(profile))
        : const <String>[];
    final shouldSyncDependencies = plan.syncDependencies || plan.forceReinstall;
    if (profile != state.aiProfile) {
      setAiProfile(profile);
    }
    final syncToken = CliCancellationToken();
    _activeAiEnvironmentSyncToken = syncToken;
    var completedOk = false;
    try {
      await _withBusy('同步 AI 环境', () async {
        var ok = true;
        var cancelled = false;
        var dependenciesOk = !shouldSyncDependencies;
        var modelWarmupFailed = false;
        state = state.copyWith(
          aiEnvironmentProgressSteps: _aiEnvironmentProgressStartupSteps(
            profile: profile,
            plan: plan,
            shouldSyncDependencies: shouldSyncDependencies,
            warmupProviders: warmupProviders,
            pipIndexUrl: pipIndexUrl,
            torchWheelMirrorUrl: torchWheelMirrorUrl,
            hfEndpoint: hfEndpoint,
          ),
          aiEnvironmentProgressLog: const [],
        );
        _setAiEnvironmentProgress(
          label: '准备下载清单',
          detail:
              '${aiProfileCupLabel(profile)} · ${_aiPackageSourceSummary(plan, pipIndexUrl, torchWheelMirrorUrl)} · ${_aiModelSourceSummary(plan, hfEndpoint)}',
          percent: 6,
        );
        _updateAiEnvironmentProgressStep('plan', 'done');
        if (shouldSyncDependencies) {
          final action = plan.forceReinstall ? '强制重装' : '同步';
          _updateAiEnvironmentProgressStep('dependencies', 'running');
          _setAiEnvironmentProgress(
            label: '$action Python / AI 依赖下载',
            detail:
                'uv sync 正在解析锁文件、下载缺失 wheel，并写入${aiProfileCupLabel(profile)}环境。${plan.useTorchWheelMirror ? ' PyTorch wheel 走镜像源。' : ''}',
            percent: plan.prepareModelCache ? 18 : 28,
          );
          _append('执行：$action ${aiProfileCupLabel(profile)} Python / AI 环境');
          _appendAiEnvironmentProgressLog(
            '执行：$action ${aiProfileCupLabel(profile)} Python / AI 环境',
          );
          _appendAiEnvironmentWorkflowLog(
            '提示：uv 在解析依赖、下载 wheel 或解压缓存时可能暂时不刷输出；只要没有失败提示，进程仍会继续。',
          );
          final dependenciesHeartbeat = _startAiEnvironmentHeartbeat(
            stageLabel: '$action Python / AI 依赖下载',
            quietHint: 'uv 可能正在解析依赖、下载 wheel 或解压缓存，输出有时不会实时刷新。',
          );
          void streamStdout(String line) {
            if (line.trim().isEmpty) return;
            dependenciesHeartbeat.markActivity();
            _append(line);
            _appendAiEnvironmentProgressLog(line);
          }

          void streamStderr(String line) {
            final entry = _cliStderrLogEntry(line);
            if (entry == null) return;
            dependenciesHeartbeat.markActivity();
            _append(entry);
            _appendAiEnvironmentProgressLog(entry);
          }

          late CliRunResult result;
          try {
            result = await _cli.syncRepairEnvironment(
              profile: profile,
              forceReinstall: plan.forceReinstall,
              extraEnvironment: mirrorEnvironment,
              cancellationToken: syncToken,
              onStdout: streamStdout,
              onStderr: streamStderr,
            );
            if (_shouldRetryTorchMirrorAsFlat(
              result: result,
              plan: plan,
              environment: mirrorEnvironment,
              cancellationToken: syncToken,
            )) {
              final retryEnvironment = _aiSyncMirrorEnvironment(
                usePipMirror: plan.usePipIndexMirror,
                pipIndexUrl: pipIndexUrl,
                useTorchWheelMirror: plan.useTorchWheelMirror,
                torchWheelMirrorUrl: torchWheelMirrorUrl,
                torchExtra: _cli.uvRuntime.torchExtra,
                torchMirrorMode: TorchWheelMirrorMode.findLinks,
                useHfMirror: plan.useHfMirror,
                hfEndpoint: hfEndpoint,
              );
              const retryLine =
                  'Torch mirror named index 解析失败，自动改用 flat wheel 目录重试。';
              const retryAction = '执行：重试 Python / AI 依赖下载';
              final firstExitLine = result.ok
                  ? '退出码：0'
                  : '退出码：${result.exitCode}';
              dependenciesHeartbeat.markActivity();
              _append(firstExitLine);
              _appendAiEnvironmentProgressLog(firstExitLine);
              _append(retryLine);
              _appendAiEnvironmentProgressLog(retryLine);
              _append(retryAction);
              _appendAiEnvironmentProgressLog(retryAction);
              _setAiEnvironmentProgress(
                label: '$action Python / AI 依赖下载',
                detail:
                    '当前 Torch mirror 不像 PEP 503 named index，正在改用 find-links 模式重试。',
                percent: plan.prepareModelCache ? 24 : 34,
              );
              result = await _cli.syncRepairEnvironment(
                profile: profile,
                forceReinstall: plan.forceReinstall,
                extraEnvironment: retryEnvironment,
                cancellationToken: syncToken,
                onStdout: streamStdout,
                onStderr: streamStderr,
              );
            }
          } finally {
            dependenciesHeartbeat.dispose();
          }
          final exitLine = result.cancelled
              ? '已取消：Python / AI 依赖下载'
              : result.ok
              ? '退出码：0'
              : '退出码：${result.exitCode}';
          _append(exitLine);
          _appendAiEnvironmentProgressLog(exitLine);
          cancelled = result.cancelled || syncToken.isCancelled;
          ok = result.ok && !cancelled;
          dependenciesOk = result.ok;
          if (ok) {
            _updateAiEnvironmentProgressStep(
              'dependencies',
              'done',
              detail: 'uv sync 完成，Python 包和 wheel 缓存已写入本地环境。',
            );
            _setAiEnvironmentProgress(
              label: '依赖同步完成',
              detail: plan.prepareModelCache
                  ? 'Python / AI 依赖已就绪，准备下载并预热模型缓存。'
                  : 'Python / AI 依赖已就绪，准备复检工具链状态。',
              percent: plan.prepareModelCache ? 46 : 72,
            );
          } else {
            _updateAiEnvironmentProgressStep(
              'dependencies',
              cancelled ? 'warning' : 'error',
              detail: cancelled
                  ? '用户已取消 uv sync；已下载的缓存会保留，下次同步可继续复用。'
                  : 'uv sync 未完成，请查看下方最近输出或错误弹窗。',
            );
          }
        } else {
          _updateAiEnvironmentProgressStep('dependencies', 'skipped');
          _setAiEnvironmentProgress(
            label: '跳过依赖同步',
            detail: '当前选项不需要运行 uv sync，继续后续检查。',
            percent: plan.prepareModelCache ? 36 : 72,
          );
        }
        if (ok && plan.prepareModelCache) {
          _updateAiEnvironmentProgressStep('models', 'running');
          _setAiEnvironmentProgress(
            label: 'AI 模型缓存下载 / Warmup',
            detail: warmupProviders.isEmpty
                ? '中杯不需要深度 Provider，正在确认缓存状态。'
                : '正在通过 ${_aiModelSourceSummary(plan, hfEndpoint)} 下载并加载 ${warmupProviders.length} 个 Provider：${warmupProviders.join(', ')}。',
            percent: 58,
          );
          if (warmupProviders.isNotEmpty) {
            _appendAiEnvironmentWorkflowLog(
              '提示：模型下载和首次加载可能在 Provider 之间短暂停顿；Hugging Face/torch 可能正在校验、续传或解压缓存。',
            );
          }
          final modelsHeartbeat = _startAiEnvironmentHeartbeat(
            stageLabel: 'AI 模型缓存 Warmup',
            quietHint: 'Hugging Face 或 torch 可能正在校验、续传、解压或加载模型；已完成的缓存会保留。',
          );
          void streamModelWarmupLog(String line) {
            modelsHeartbeat.markActivity();
            _appendAiEnvironmentProgressLog(line);
          }

          final args = [
            'prepare-ai-cache',
            '--profile',
            profile,
            for (final provider in warmupProviders) ...[
              '--warmup-provider',
              provider,
            ],
          ];
          late CliRunResult result;
          try {
            result = warmupProviders.isEmpty
                ? await _runBase(
                    args,
                    extraEnvironment: mirrorEnvironment,
                    repairNetwork: true,
                    streamLog: streamModelWarmupLog,
                    cancellationToken: syncToken,
                  )
                : await _run(
                    args,
                    extraEnvironment: mirrorEnvironment,
                    repairNetwork: true,
                    streamLog: streamModelWarmupLog,
                    cancellationToken: syncToken,
                  );
          } finally {
            modelsHeartbeat.dispose();
          }
          cancelled = result.cancelled || syncToken.isCancelled;
          final warmupFailures = _modelWarmupFailures(result.stdout);
          if (warmupFailures.isNotEmpty && !cancelled) {
            final summary = '模型 Warmup 失败：${warmupFailures.join('；')}';
            _append(summary);
            _appendAiEnvironmentProgressLog(summary);
          }
          ok = result.ok && warmupFailures.isEmpty && !cancelled;
          modelWarmupFailed =
              (!result.ok || warmupFailures.isNotEmpty) && !cancelled;
          if (ok) {
            _updateAiEnvironmentProgressStep(
              'models',
              warmupProviders.isEmpty ? 'skipped' : 'done',
              detail: warmupProviders.isEmpty
                  ? '中杯没有深度 Provider，模型缓存 Warmup 已跳过。'
                  : '${warmupProviders.length} 个 Provider 的模型缓存 Warmup 已完成。',
            );
            _setAiEnvironmentProgress(
              label: '模型缓存完成',
              detail: '准备重新检查 uv、Python、AI Provider 和硬件状态。',
              percent: 84,
            );
          } else {
            _updateAiEnvironmentProgressStep(
              'models',
              cancelled ? 'warning' : 'error',
              detail: cancelled
                  ? '用户已取消模型缓存下载；已下载的缓存会保留，下次 Warmup 可继续复用。'
                  : warmupFailures.isEmpty
                  ? '模型缓存下载或 Warmup 未完成，请查看下方最近输出或错误弹窗。'
                  : '以下 Provider Warmup 失败：${warmupFailures.join('；')}。',
            );
          }
        } else if (!plan.prepareModelCache) {
          _updateAiEnvironmentProgressStep('models', 'skipped');
        }
        if (ok) {
          _updateAiEnvironmentProgressStep('verify', 'running');
          _setAiEnvironmentProgress(
            label: '刷新工具链状态',
            detail: '正在重新检查 uv、Python、音频工具和 AI Provider。',
            percent: 92,
          );
          await _refreshToolchainStatusWithinBusy();
          _setAiEnvironmentProgress(
            label: 'AI 环境同步完成',
            detail: '工具链状态已刷新。',
            percent: 100,
          );
          _updateAiEnvironmentProgressStep(
            'verify',
            'done',
            detail: '工具链状态已刷新，后续页面会按最新能力启用或降级。',
          );
          completedOk = true;
        } else if (cancelled) {
          _updateAiEnvironmentProgressStep(
            'verify',
            'skipped',
            detail: '用户取消下载，未执行复检。',
          );
          _setAiEnvironmentProgress(
            label: '已取消 AI 环境下载',
            detail: '已终止 uv / 模型 Warmup 进程；已下载的缓存会保留。',
            percent: state.aiEnvironmentProgressPercent ?? 100,
          );
          _append('AI 环境同步已取消。');
        } else {
          if (dependenciesOk && modelWarmupFailed) {
            _updateAiEnvironmentProgressStep(
              'verify',
              'running',
              detail: '模型缓存失败，仍在复检已完成的依赖环境。',
            );
          } else if (state.aiEnvironmentProgressSteps.any(
            (step) => step.id == 'verify' && step.status == 'pending',
          )) {
            _updateAiEnvironmentProgressStep(
              'verify',
              'skipped',
              detail: '前一步失败，未执行复检。',
            );
          }
          _setAiEnvironmentProgress(
            label: dependenciesOk && modelWarmupFailed
                ? '模型缓存 Warmup 失败'
                : 'AI 环境同步失败',
            detail: dependenciesOk && modelWarmupFailed
                ? '依赖阶段已完成，正在刷新状态以保留已就绪信息。'
                : '请查看错误弹窗中的关键日志。',
            percent: 100,
          );
          if (dependenciesOk && modelWarmupFailed) {
            await _refreshToolchainStatusWithinBusy(
              profileOverride: profile,
              resolveAiProfile: false,
            );
            _updateAiEnvironmentProgressStep(
              'verify',
              'done',
              detail: '工具链状态已刷新，依赖就绪信息已保留。',
            );
          } else {
            state = state.copyWith(
              toolchainStatus: ToolchainStatusSummary.error('AI 环境修复失败'),
            );
          }
        }
      });
    } finally {
      if (_activeAiEnvironmentSyncToken == syncToken) {
        _activeAiEnvironmentSyncToken = null;
      }
    }
    return completedOk;
  }

  Future<void> cancelAiEnvironmentSync() async {
    final token = _activeAiEnvironmentSyncToken;
    if (token == null || token.isCancelled) return;
    _setAiEnvironmentProgress(
      label: '正在取消下载',
      detail: '正在终止 uv / prepare-ai-cache 进程；已下载的缓存会保留。',
      percent: state.aiEnvironmentProgressPercent ?? 0,
    );
    _appendAiEnvironmentProgressLog('用户取消：正在终止 AI 环境下载');
    _append('用户取消 AI 环境同步。');
    await token.cancel();
  }

  @override
  void dispose() {
    final token = _activeAiEnvironmentSyncToken;
    _activeAiEnvironmentSyncToken = null;
    if (token != null && !token.isCancelled) {
      unawaited(token.cancel());
    }
    super.dispose();
  }

  List<AiEnvironmentProgressStep> _aiEnvironmentProgressStartupSteps({
    required String profile,
    required AiEnvironmentSyncOptions plan,
    required bool shouldSyncDependencies,
    required List<String> warmupProviders,
    required String pipIndexUrl,
    required String torchWheelMirrorUrl,
    required String hfEndpoint,
  }) {
    final action = plan.forceReinstall ? '强制重装' : '同步';
    final providers = warmupProviders.isEmpty
        ? '中杯不需要深度 Provider'
        : warmupProviders.join(', ');
    return [
      AiEnvironmentProgressStep(
        id: 'plan',
        label: '计划下载任务',
        detail:
            '${aiProfileCupLabel(profile)} · ${_aiPackageSourceSummary(plan, pipIndexUrl, torchWheelMirrorUrl)} · ${_aiModelSourceSummary(plan, hfEndpoint)}',
        status: 'running',
      ),
      AiEnvironmentProgressStep(
        id: 'dependencies',
        label: 'Python / AI 依赖',
        detail: shouldSyncDependencies
            ? '$action uv sync；下载缺失 wheel 并写入${aiProfileCupLabel(profile)}环境。'
            : '当前选项不需要运行 uv sync。',
        status: shouldSyncDependencies ? 'pending' : 'skipped',
      ),
      AiEnvironmentProgressStep(
        id: 'models',
        label: '模型缓存',
        detail: plan.prepareModelCache
            ? '从 ${_aiModelSourceSummary(plan, hfEndpoint)} 下载或复用缓存；Providers: $providers。'
            : '当前杯型不需要模型缓存 Warmup。',
        status: plan.prepareModelCache ? 'pending' : 'skipped',
      ),
      const AiEnvironmentProgressStep(
        id: 'verify',
        label: '完成后复检',
        detail: '重新检查 uv、Python、音频工具、AI Provider 和硬件能力。',
        status: 'pending',
      ),
    ];
  }

  String _aiPackageSourceSummary(
    AiEnvironmentSyncOptions plan,
    String pipIndexUrl,
    String torchWheelMirrorUrl,
  ) {
    final pip = plan.usePipIndexMirror ? 'PyPI $pipIndexUrl' : 'PyPI 官方源';
    final torch = plan.useTorchWheelMirror
        ? 'Torch mirror $torchWheelMirrorUrl'
        : 'Torch wheels 官方源';
    return '$pip · $torch';
  }

  String _aiModelSourceSummary(
    AiEnvironmentSyncOptions plan,
    String hfEndpoint,
  ) {
    return plan.useHfMirror ? 'HF $hfEndpoint' : 'HF 官方源';
  }

  void _updateAiEnvironmentProgressStep(
    String id,
    String status, {
    String? detail,
  }) {
    if (state.aiEnvironmentProgressSteps.isEmpty) return;
    state = state.copyWith(
      aiEnvironmentProgressSteps: [
        for (final step in state.aiEnvironmentProgressSteps)
          step.id == id ? step.copyWith(status: status, detail: detail) : step,
      ],
    );
  }

  bool _shouldRetryTorchMirrorAsFlat({
    required CliRunResult result,
    required AiEnvironmentSyncOptions plan,
    required Map<String, String> environment,
    required CliCancellationToken cancellationToken,
  }) {
    if (!plan.useTorchWheelMirror ||
        result.ok ||
        result.cancelled ||
        cancellationToken.isCancelled) {
      return false;
    }
    if (environment['UV_NO_SOURCES_PACKAGE']
            ?.split(RegExp(r'\s+'))
            .contains('torch') ??
        false) {
      return false;
    }
    final output = '${result.stdout}\n${result.stderr}'.toLowerCase();
    return output.contains('torch') || output.contains('torchaudio');
  }

  Map<String, String> _aiSyncMirrorEnvironment({
    required bool usePipMirror,
    required String pipIndexUrl,
    required bool useTorchWheelMirror,
    required String torchWheelMirrorUrl,
    required String torchExtra,
    TorchWheelMirrorMode? torchMirrorMode,
    required bool useHfMirror,
    required String hfEndpoint,
  }) {
    final env = <String, String>{};
    if (usePipMirror) {
      env['UV_DEFAULT_INDEX'] = pipIndexUrl;
      env['PIP_INDEX_URL'] = pipIndexUrl;
    }
    if (useTorchWheelMirror) {
      env.addAll(
        torchWheelMirrorEnvironment(
          torchWheelMirrorUrl,
          torchExtra,
          modeOverride: torchMirrorMode,
        ),
      );
    }
    if (useHfMirror) {
      env['HF_ENDPOINT'] = hfEndpoint;
    }
    return env;
  }

  Future<void> startupFullCheckOnce() async {
    if (_startupFullCheckStarted || !state.hasProject) return;
    _startupFullCheckStarted = true;
    await refreshStatus(verifyFiles: true);
  }

  Future<bool> installTools() async {
    if (state.busy) return false;
    var installed = false;
    state = state.copyWith(
      toolInstallLog: const ['== 安装本地处理组件 =='],
      toolInstallFailureSummary: null,
    );
    await _withBusy('安装本地处理组件', () async {
      try {
        final result = await _run(
          ['install-tools', '--force'],
          streamLog: _appendToolInstallLog,
          repairNetwork: true,
        );
        installed = result.ok;
        if (!result.ok) {
          final summary = _toolInstallFailureSummary(exitCode: result.exitCode);
          state = state.copyWith(
            toolsOk: false,
            toolInstallFailureSummary: summary,
          );
          _appendToolInstallLog('安装失败：install-tools 退出码 ${result.exitCode}');
          _append('本地处理组件安装失败：install-tools 退出码 ${result.exitCode}');
          return;
        }
        state = state.copyWith(toolsOk: true, toolInstallFailureSummary: null);
        final status = await _run(_statusArgs(), streamOutput: false);
        final payload = status.ok ? _decodeStatus(status.stdout) : null;
        if (payload != null) _applyStatusPayload(payload);
        await _refreshToolchainStatusWithinBusy();
        await _refreshIntegrityFromCli();
      } on Object catch (error) {
        installed = false;
        final summary = _toolInstallFailureSummary(error: error);
        state = state.copyWith(
          toolsOk: false,
          toolInstallFailureSummary: summary,
        );
        final message = '安装失败：${error.runtimeType}: $error';
        _appendToolInstallLog('ERR $message');
        _append('本地处理组件$message');
      }
    });
    return installed;
  }

  Future<bool> buildPackage() async {
    if (state.busy) return false;
    if (_rejectProjectEditWhenBaselineBroken('准备电台包')) return false;
    FhRadioStudioProject.ensure(state.projectDir);
    if (_canCreatePendingPackage) {
      _append('当前游戏文件还没确认。请先在概览里保存新文件记录、生成测试准备包，或写回旧的基线；确认或放弃后再准备普通电台包。');
      return false;
    }
    final draft = _playlistDraftForBuild();
    final canBuildLanguageChange = !state.languageSelectionMatchesGame;
    if (!draft.hasPlan && !canBuildLanguageChange) {
      _append('播放列表还没有分配曲目。请先在“播放列表”里把自建歌曲拖到目标电台。');
      return false;
    }
    final musicInputs = draft.inputs;
    if (musicInputs.isEmpty && !canBuildLanguageChange) {
      _append('播放列表草稿为空。请先在“播放列表”里分配至少一首自建歌曲。');
      return false;
    }
    final missing = musicInputs
        .where((path) {
          return !File(path).existsSync() && !Directory(path).existsSync();
        })
        .toList(growable: false);
    if (missing.isNotEmpty) {
      _append(_missingMusicInputMessage(missing.first));
      return false;
    }
    final outDir = FhRadioStudioProject.currentPackageDir(state.projectDir);
    final timingManifest = TrackTimingStore.writeBuildManifest(
      projectDir: state.projectDir,
      musicInputs: musicInputs,
    );
    var built = false;
    await _withBusy('构建电台包', () async {
      _resetPackageDir(outDir);
      _deletePackageDir(
        FhRadioStudioProject.pendingPackageDir(state.projectDir),
      );
      if (canBuildLanguageChange && musicInputs.isEmpty) {
        _append('播放列表草稿为空；将把当前 radio 原样准备进包，并加入语言设置。');
      }
      final result = await _run([
        'build-package',
        ...musicInputs,
        '--game-dir',
        state.gameDir,
        '--radio',
        '${state.radio}',
        '--source',
        state.sourceLang,
        '--target',
        state.targetLang,
        if (File(state.currentBaselineManifest).existsSync()) ...[
          '--source-audio-dir',
          state.currentBaselineAudioDir,
          '--source-string-tables-dir',
          p.join(state.currentBaselineDir, 'media', 'Stripped', 'StringTables'),
          '--baseline-manifest',
          state.currentBaselineManifest,
        ],
        '--playlist-mode',
        'only',
        if (draft.playlistPlanPath != null && musicInputs.isNotEmpty) ...[
          '--playlist-plan',
          draft.playlistPlanPath!,
        ],
        if (timingManifest != null) ...['--timing-manifest', timingManifest],
        '--metadata-cache',
        TrackMetadataCache.configPath(state.projectDir),
        '--out-dir',
        outDir,
        '--progress-jsonl',
      ]);
      if (result.ok) {
        final packageDir = File(outDir).absolute.path;
        state = state.copyWith(
          lastPackageDir: packageDir,
          lastPackageSummary: _readPackageSummary(packageDir),
          pendingPackageDir: null,
          pendingPackageSummary: null,
        );
        built = true;
        await _refreshIntegrityFromCli();
        if (_canCreatePendingPackage) {
          _append('准备包已生成；但当前游戏文件还没确认，写入前仍需要先处理新文件记录。');
        }
      } else {
        state = state.copyWith(
          lastPackageDir: null,
          lastPackageSummary: null,
          pendingPackageDir: null,
          pendingPackageSummary: null,
        );
        await _refreshIntegrityFromCli();
      }
    });
    return built;
  }

  Future<bool> createPendingBaselineAndBuildPackage() async {
    if (state.busy) return false;
    if (_rejectProjectEditWhenBaselineBroken('生成测试准备包')) return false;
    if (!_canCreatePendingPackage) {
      _append(
        '当前没有发现需要单独测试的新游戏文件；这个入口只在游戏文件不同于原始备份或准备包时使用。要按当前播放列表生成普通包，请用「准备电台包」。',
      );
      return false;
    }
    if (!state.currentPackageReady) {
      _append('还没有准备包，不能生成测试准备包。请先去播放列表准备电台包。');
      return false;
    }
    var handled = false;
    await _withBusy('生成测试准备包', () async {
      final running = await _cli.isGameRunning();
      state = state.copyWith(gameRunning: running);
      if (running) {
        _append('检测到 FH6 正在运行，已拒绝创建测试准备包。请先退出游戏。');
        return;
      }
      final baselineOk = await _ensurePendingBaseline();
      if (!baselineOk) return;
      handled = true;

      final musicInputs = _musicInputsFromCurrentPackage();
      final missing = musicInputs
          .where(
            (path) => !File(path).existsSync() && !Directory(path).existsSync(),
          )
          .toList(growable: false);
      if (missing.isNotEmpty) {
        _append(_missingMusicInputMessage(missing.first));
        return;
      }
      final outDir = FhRadioStudioProject.pendingPackageDir(state.projectDir);
      _resetPackageDir(outDir);
      final timingManifest = TrackTimingStore.writeBuildManifest(
        projectDir: state.projectDir,
        musicInputs: musicInputs,
      );
      final result = await _run([
        'build-package',
        '--game-dir',
        state.gameDir,
        '--source-audio-dir',
        state.pendingBaselineAudioDir,
        '--source-string-tables-dir',
        p.join(state.pendingBaselineDir, 'media', 'Stripped', 'StringTables'),
        '--baseline-manifest',
        state.pendingBaselineManifest,
        '--radio',
        '${state.radio}',
        '--source',
        state.sourceLang,
        '--target',
        state.targetLang,
        '--playlist-mode',
        'only',
        '--playlist-from-package',
        state.lastPackageDir!,
        if (timingManifest != null) ...['--timing-manifest', timingManifest],
        '--metadata-cache',
        TrackMetadataCache.configPath(state.projectDir),
        '--out-dir',
        outDir,
        '--progress-jsonl',
      ]);
      if (result.ok) {
        final packageDir = File(outDir).absolute.path;
        state = state.copyWith(
          pendingPackageDir: packageDir,
          pendingPackageSummary: _readPackageSummary(packageDir),
        );
        await _refreshIntegrityFromCli();
      } else {
        handled = false;
        final packageDir = File(outDir).absolute.path;
        _deletePackageDir(outDir);
        _writePendingPackageFailureMarker(packageDir, result);
        state = state.copyWith(
          pendingPackageDir: packageDir,
          pendingPackageSummary: null,
        );
        await _refreshIntegrityFromCli();
        _append(
          '测试准备包构建失败。已保留测试准备包记录但没有可写入文件；你仍然可以确认新游戏文件、写回旧的基线，或修复后重建测试准备包。',
        );
      }
    });
    return handled;
  }

  List<String> _musicInputsFromCurrentPackage() {
    final summary =
        state.lastPackageSummary ?? _readPackageSummary(state.lastPackageDir);
    if (summary == null || summary.assignments.isEmpty) return const [];
    final inputs = <String>[];
    final seen = <String>{};
    for (final assignment in summary.assignments) {
      final source = assignment.source.trim();
      if (source.isEmpty) continue;
      final key = PackageTrackAssignment.keyForPath(source);
      if (seen.add(key)) inputs.add(source);
    }
    return inputs;
  }

  Future<bool> createPendingBaselineOnly() async {
    if (state.busy) return false;
    if (_rejectProjectEditWhenBaselineBroken('保存新文件记录')) return false;
    if (!_canCreatePendingPackage) {
      _append('当前没有发现需要单独保存的新游戏文件。');
      return false;
    }
    var created = false;
    await _withBusy('保存新文件记录', () async {
      final running = await _cli.isGameRunning();
      state = state.copyWith(gameRunning: running);
      if (running) {
        _append('检测到 FH6 正在运行，已拒绝保存新文件记录。请先退出游戏。');
        return;
      }
      created = await _ensurePendingBaseline();
    });
    return created;
  }

  ({List<String> inputs, String? playlistPlanPath, bool hasPlan})
  _playlistDraftForBuild() {
    final plan = PlaylistPlanStore.read(state.projectDir);
    if (!plan.hasDraft) {
      return (inputs: const [], playlistPlanPath: null, hasPlan: false);
    }
    final ordered = plan.assignments.values.toList()
      ..sort((a, b) {
        final byRadio = a.radioCode.compareTo(b.radioCode);
        if (byRadio != 0) return byRadio;
        final byType = a.playlistType.compareTo(b.playlistType);
        if (byType != 0) return byType;
        final bySlot = a.slot.compareTo(b.slot);
        if (bySlot != 0) return bySlot;
        return a.source.toLowerCase().compareTo(b.source.toLowerCase());
      });
    final inputs = <String>[];
    final seen = <String>{};
    for (final assignment in ordered) {
      if (!assignment.isAssigned) continue;
      if (seen.add(assignment.trackKey)) inputs.add(assignment.source);
    }
    return (
      inputs: inputs,
      playlistPlanPath: PlaylistPlanStore.configPath(state.projectDir),
      hasPlan: true,
    );
  }

  String _missingMusicInputMessage(String source) {
    final absolute = File(source).absolute.path;
    if (_projectArtifactPath(absolute, state.sourcesDir)) {
      return '播放列表草稿引用的项目源文件已不存在：$absolute。请重新导入这首歌，或从播放列表移除后再准备包。';
    }
    return '播放列表草稿引用了项目 sources 之外的旧路径：$absolute。请先重新导入到项目 sources，再分配到播放列表。';
  }

  Future<BaselinePlanSummary?> previewPristineBaselinePlan() async {
    if (state.busy) return null;
    await _withPanelRefresh(_RefreshScope.fileIntegrity, '生成原始备份清单', () async {
      await _refreshIntegrityFromCli();
    });
    return state.baselinePlanSummary;
  }

  Future<void> createPristineBaseline() async {
    if (state.busy) return;
    if (File(state.currentBaselineManifest).existsSync()) {
      _append('原始备份已经存在。如需重建，请先处理当前原始备份。');
      return;
    }
    await _withBusy('创建原始备份', () async {
      final running = await _cli.isGameRunning();
      state = state.copyWith(gameRunning: running);
      if (running) {
        _append('检测到 FH6 正在运行，已拒绝创建原始备份。请先退出游戏。');
        return;
      }
      await _refreshBaselinePlan();
      final outDir = _plannedBaselineDir(
        projectDir: state.projectDir,
        state: 'current',
        versionId: state.baselinePlanSummary?.gameVersionId,
      );
      final result = await _run([
        'baseline',
        'create',
        '--game-dir',
        state.gameDir,
        '--out-dir',
        outDir,
        '--state',
        'current',
        '--yes',
      ]);
      if (result.ok) {
        _bumpCurrentBuildArtifacts();
        await _refreshIntegrityFromCli();
      }
    });
  }

  Future<void> bumpBaselineBuildCompatibility() async {
    if (state.busy) return;
    if (!File(state.currentBaselineManifest).existsSync()) {
      _append('找不到可更新的原始备份记录。');
      return;
    }
    await _withBusy('更新原始备份支持的 Steam build', () async {
      final result = await _run([
        'baseline',
        'bump-build',
        '--game-dir',
        state.gameDir,
        '--manifest',
        state.currentBaselineManifest,
        '--yes',
      ]);
      if (result.ok) {
        _bumpCurrentBuildArtifacts();
        await _refreshIntegrityFromCli();
      }
    });
  }

  Future<void> rebuildBaselineFromCurrentGame() async {
    if (state.busy) return;
    await _withBusy('用当前游戏文件重建原始备份', () async {
      final running = await _cli.isGameRunning();
      state = state.copyWith(gameRunning: running);
      if (running) {
        _append('检测到 FH6 正在运行，已拒绝重建原始备份。请先退出游戏。');
        return;
      }
      _deleteCurrentBuildArtifacts();
      final outDir = _plannedBaselineDir(
        projectDir: state.projectDir,
        state: 'current',
        versionId: state.effectiveGameVersionId,
      );
      final result = await _run([
        'baseline',
        'create',
        '--game-dir',
        state.gameDir,
        '--out-dir',
        outDir,
        '--state',
        'current',
        '--overwrite',
        '--yes',
      ]);
      if (result.ok) {
        final packageDir = _latestPackageDir(state.projectDir);
        final pendingPackageDir = _latestPendingPackageDir(state.projectDir);
        state = state.copyWith(
          lastPackageDir: packageDir,
          lastPackageSummary: _readPackageSummary(packageDir),
          pendingPackageDir: pendingPackageDir,
          pendingPackageSummary: _readPackageSummary(pendingPackageDir),
        );
        await _refreshIntegrityFromCli();
      }
    });
  }

  Future<void> createPendingBaselineAndForceDeploy() async {
    if (state.busy) return;
    if (_rejectProjectEditWhenBaselineBroken('保存新文件记录并强制写入')) return;
    final packageDir =
        state.lastPackageDir ??
        (state.pendingPackageReady ? state.pendingPackageDir : null);
    if (packageDir == null) {
      _append('还没有可强制写入的电台包。先准备电台包。');
      return;
    }
    await _withBusy('保存新文件记录并强制写入', () async {
      final running = await _cli.isGameRunning();
      state = state.copyWith(gameRunning: running);
      if (running) {
        _append('检测到 FH6 正在运行，已拒绝保存新文件记录。请先退出游戏。');
        return;
      }
      final baselineOk = await _ensurePendingBaseline();
      if (!baselineOk) return;
      await _deployPackage(packageDir, force: true);
    });
  }

  Future<bool> applyCurrentBaseline() async {
    if (_rejectProjectEditWhenBaselineBroken('写回旧的基线')) return false;
    return _applyBaseline(state.currentBaselineDir, '写回旧的基线');
  }

  Future<bool> applyPendingBaseline() async {
    if (_rejectProjectEditWhenBaselineBroken('写回新游戏文件')) return false;
    final applied = await _applyBaseline(state.pendingBaselineDir, '写回新游戏文件');
    if (applied && state.pendingPackageBuildFailed) {
      final packageDir = state.pendingPackageDir;
      if (packageDir != null) _writePendingBaselineSelectionMarker(packageDir);
      await _refreshIntegrityFromCli();
    }
    return applied;
  }

  Future<bool> applyBaselineBackup(String baselineDir, String label) async {
    if (_rejectProjectEditWhenBaselineBroken(label)) return false;
    return _applyBaseline(baselineDir, label);
  }

  Future<void> deployOldPackage() async {
    if (_rejectProjectEditWhenBaselineBroken('写入旧准备包')) return;
    final packageDir = state.lastPackageDir;
    if (packageDir == null) {
      _append('还没有旧准备包可以写入。');
      return;
    }
    await _withBusy('写入旧准备包', () async {
      await _deployPackage(packageDir, force: true);
    });
  }

  Future<void> deployPendingPackage() async {
    if (_rejectProjectEditWhenBaselineBroken('写入测试准备包')) return;
    final packageDir = state.pendingPackageDir;
    if (packageDir == null || !state.pendingPackageReady) {
      _append('测试准备包没有生成出可写入文件。请先重新生成测试准备包。');
      return;
    }
    await _withBusy('写入测试准备包', () async {
      await _deployPackage(packageDir, force: true);
    });
  }

  bool get _canCreatePendingPackage {
    return state.fileIntegrity.level == GameFileIntegrityLevel.gameChanged ||
        state.fileIntegrity.level == GameFileIntegrityLevel.externalConflict ||
        state.fileIntegrity.level == GameFileIntegrityLevel.pendingVerify ||
        File(state.pendingBaselineManifest).existsSync();
  }

  void _resetPackageDir(String packageDir) {
    _deletePackageDir(packageDir);
    Directory(packageDir).createSync(recursive: true);
  }

  void _deletePackageDir(String packageDir) {
    _deletePackageDirForProject(state.projectDir, packageDir);
  }

  void _deleteStalePendingPackage(String projectDir) {
    if (_pendingBaselineManifest(projectDir) != null) return;
    _deletePackageDirForProject(
      projectDir,
      FhRadioStudioProject.pendingPackageDir(projectDir),
    );
  }

  void _deletePackageDirForProject(String projectDir, String packageDir) {
    FhRadioStudioProject.ensure(projectDir);
    final packagesRoot = Directory(
      FhRadioStudioProject.packagesDir(projectDir),
    ).absolute.path;
    final targetPath = Directory(packageDir).absolute.path;
    final currentPath = Directory(
      FhRadioStudioProject.currentPackageDir(projectDir),
    ).absolute.path;
    final pendingPath = Directory(
      FhRadioStudioProject.pendingPackageDir(projectDir),
    ).absolute.path;
    final isKnownSlot =
        sameCanonicalPath(targetPath, currentPath) ||
        sameCanonicalPath(targetPath, pendingPath);
    final isInsidePackages = isCanonicalPathInside(packagesRoot, targetPath);
    if (!isKnownSlot || !isInsidePackages) {
      throw StateError('Refusing to modify package directory outside slots.');
    }
    final target = Directory(targetPath);
    if (target.existsSync()) target.deleteSync(recursive: true);
  }

  String? get _currentIntegrityBuildId {
    final id =
        state.fileIntegrity.currentGameVersionId ??
        state.effectiveGameVersionId;
    return id == null || id.trim().isEmpty || id == 'unknown' ? null : id;
  }

  bool _manifestBelongsToCurrentBuild(File manifestFile) {
    final currentId = _currentIntegrityBuildId;
    if (currentId == null || !manifestFile.existsSync()) return false;
    final data = _readJsonMap(manifestFile);
    if (data == null) return false;
    if (_objectString(data['game_version_id']) == currentId) return true;
    final supported = _objectStringList(data['supported_game_version_ids']);
    if (supported.contains(currentId)) return true;
    final gameVersion = _objectMap(data['game_version']);
    final nested = _objectString(gameVersion?['version_id']);
    if (nested == currentId) return true;
    final buildId = _objectString(gameVersion?['build_id']);
    return buildId != null && currentId == 'steam-b$buildId';
  }

  bool _manifestHasAnyBuildId(File manifestFile, Set<String> buildIds) {
    if (buildIds.isEmpty || !manifestFile.existsSync()) return false;
    final data = _readJsonMap(manifestFile);
    if (data == null) return false;
    final ids = <String>[
      ?_objectString(data['game_version_id']),
      ..._objectStringList(data['supported_game_version_ids']),
      ?_objectString(_objectMap(data['game_version'])?['version_id']),
    ];
    final buildId = _objectString(
      _objectMap(data['game_version'])?['build_id'],
    );
    if (buildId != null && buildId.isNotEmpty) ids.add('steam-b$buildId');
    return ids.any(buildIds.contains);
  }

  bool _appendCurrentBuildSupport(File manifestFile) {
    final currentId = _currentIntegrityBuildId;
    if (currentId == null || !manifestFile.existsSync()) return false;
    final data = _readJsonMap(manifestFile);
    if (data == null) return false;
    final supported = _objectStringList(data['supported_game_version_ids']);
    final direct = _objectString(data['game_version_id']);
    if (direct != null && direct.isNotEmpty && direct != 'unknown') {
      supported.insert(0, direct);
    }
    final gameVersion = _objectMap(data['game_version']);
    final nested = _objectString(gameVersion?['version_id']);
    if (nested != null && nested.isNotEmpty && nested != 'unknown') {
      supported.insert(0, nested);
    }
    final unique = <String>[];
    for (final id in [...supported, currentId]) {
      if (id.trim().isNotEmpty && id != 'unknown' && !unique.contains(id)) {
        unique.add(id);
      }
    }
    data['supported_game_version_ids'] = unique;
    data['build_compatibility_updated_at'] = DateTime.now()
        .toUtc()
        .toIso8601String();
    manifestFile.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(data),
      encoding: utf8,
    );
    return true;
  }

  void _bumpCurrentBuildArtifacts() {
    final lineageIds = {
      ...state.fileIntegrity.baselineSupportedGameVersionIds,
      ?state.currentBaselineVersionId,
    }..removeWhere((id) => id.trim().isEmpty || id == 'unknown');
    final packageManifestFiles = <File>[];
    final packageManifestKeys = <String>{};
    for (final packageDir in [
      FhRadioStudioProject.currentPackageDir(state.projectDir),
      FhRadioStudioProject.pendingPackageDir(state.projectDir),
    ]) {
      final path = packageManifestPath(packageDir);
      packageManifestFiles.add(File(path));
      packageManifestKeys.add(canonicalPathKey(path));
    }
    final candidates = <File>[
      File(state.currentBaselineManifest),
      File(state.lastAppliedPackageManifest),
      ...packageManifestFiles,
    ];
    var updated = 0;
    for (final manifest in candidates) {
      if (p.equals(manifest.path, state.currentBaselineManifest) ||
          packageManifestKeys.contains(canonicalPathKey(manifest.path)) ||
          _manifestHasAnyBuildId(manifest, lineageIds)) {
        if (_appendCurrentBuildSupport(manifest)) updated++;
      }
    }
    _append('已更新 $updated 个项目 artifact 的 Steam build 兼容记录。');
  }

  void _deleteCurrentBuildArtifacts() {
    final backups = Directory(
      FhRadioStudioProject.backupsDir(state.projectDir),
    );
    if (backups.existsSync()) {
      for (final dir
          in backups.listSync(followLinks: false).whereType<Directory>()) {
        final name = p.basename(dir.path);
        if (name == 'manual' || name == 'automatic' || name == 'baseline-old') {
          continue;
        }
        final manifest = File(p.join(dir.path, 'baseline_manifest.json'));
        if (_manifestBelongsToCurrentBuild(manifest)) {
          dir.deleteSync(recursive: true);
        }
      }
    }

    for (final packageDir in [
      FhRadioStudioProject.currentPackageDir(state.projectDir),
      FhRadioStudioProject.pendingPackageDir(state.projectDir),
    ]) {
      if (_manifestBelongsToCurrentBuild(
        File(packageManifestPath(packageDir)),
      )) {
        _deletePackageDir(packageDir);
      }
    }

    final lastApplied = File(state.lastAppliedPackageManifest);
    if (_manifestBelongsToCurrentBuild(lastApplied)) {
      lastApplied.deleteSync();
    }
  }

  void _promotePendingPackageToCurrent() {
    final pendingDir = FhRadioStudioProject.pendingPackageDir(state.projectDir);
    if (_packageManifestPath(pendingDir) == null) {
      _deletePackageDir(pendingDir);
      return;
    }
    final currentDir = FhRadioStudioProject.currentPackageDir(state.projectDir);
    _deletePackageDir(currentDir);
    Directory(pendingDir).renameSync(currentDir);
  }

  Future<bool> _ensurePendingBaseline() async {
    if (File(state.pendingBaselineManifest).existsSync()) {
      _append('已存在新文件记录，继续使用它。');
      return true;
    }
    await _refreshBaselinePlan();
    final outDir = _plannedBaselineDir(
      projectDir: state.projectDir,
      state: 'pending-verify',
      versionId: state.baselinePlanSummary?.gameVersionId,
    );
    final baseline = await _run([
      'baseline',
      'create',
      '--game-dir',
      state.gameDir,
      '--out-dir',
      outDir,
      '--state',
      'pending-verify',
      '--yes',
    ]);
    if (baseline.ok) await _refreshIntegrityFromCli();
    return baseline.ok;
  }

  Future<bool> _applyBaseline(String baselineDir, String label) async {
    if (state.busy) return false;
    final manifest = p.join(baselineDir, 'baseline_manifest.json');
    if (!File(manifest).existsSync()) {
      _append('找不到可写回的游戏文件备份：$manifest');
      return false;
    }
    var applied = false;
    await _withBusy(label, () async {
      final running = await _cli.isGameRunning();
      state = state.copyWith(gameRunning: running);
      if (running) {
        _append('检测到 FH6 正在运行，已拒绝写回游戏文件。请先退出游戏。');
        return;
      }
      final result = await _run([
        'baseline',
        'apply',
        '--game-dir',
        state.gameDir,
        '--baseline-dir',
        baselineDir,
        '--yes',
      ]);
      if (result.ok) {
        await _refreshIntegrityFromCli();
        applied = true;
      }
    });
    return applied;
  }

  Future<void> confirmPendingBaseline() async {
    if (state.busy) return;
    if (_rejectProjectEditWhenBaselineBroken('确认新的原始备份')) return;
    if (!File(state.pendingBaselineManifest).existsSync()) {
      _append('没有新文件记录可以确认。');
      return;
    }
    await _withBusy('确认新的原始备份', () async {
      await _refreshIntegrityFromCli();
      final shouldPromotePendingPackage = _currentMatchesPendingPackage();
      final pendingManifest = state.pendingBaselineManifest;
      final targetCurrentDir = _plannedBaselineDir(
        projectDir: state.projectDir,
        state: 'current',
        versionId: _baselineVersionIdFromManifest(pendingManifest),
      );
      final result = await _run([
        'baseline',
        'promote',
        '--current-dir',
        state.currentBaselineDir,
        '--pending-dir',
        state.pendingBaselineDir,
        '--target-current-dir',
        targetCurrentDir,
        '--old-root',
        state.oldBaselinesDir,
        '--yes',
      ]);
      if (result.ok) {
        if (shouldPromotePendingPackage) {
          _promotePendingPackageToCurrent();
        } else {
          _deletePackageDir(
            FhRadioStudioProject.pendingPackageDir(state.projectDir),
          );
        }
        final packageDir = _latestPackageDir(state.projectDir);
        state = state.copyWith(
          lastPackageDir: packageDir,
          lastPackageSummary: _readPackageSummary(packageDir),
          pendingPackageDir: null,
          pendingPackageSummary: null,
        );
        await _refreshIntegrityFromCli();
      }
    });
  }

  bool _currentMatchesPendingPackage() {
    final integrity = state.fileIntegrity;
    return state.pendingPackageReady &&
        integrity.checkedFiles > 0 &&
        integrity.packageMatches == integrity.checkedFiles;
  }

  Future<void> discardPendingBaseline() async {
    if (state.busy) return;
    if (_rejectProjectEditWhenBaselineBroken('放弃新文件记录')) return;
    await _withBusy('放弃新文件记录', () async {
      final result = await _run([
        'baseline',
        'discard-pending',
        '--pending-dir',
        state.pendingBaselineDir,
        '--yes',
      ]);
      if (result.ok) {
        _deletePackageDir(
          FhRadioStudioProject.pendingPackageDir(state.projectDir),
        );
        state = state.copyWith(
          pendingPackageDir: null,
          pendingPackageSummary: null,
        );
        await _refreshIntegrityFromCli();
      }
    });
  }

  Future<void> deployLastPackage({bool force = false}) async {
    if (state.busy) return;
    if (_rejectProjectEditWhenBaselineBroken('写入游戏')) return;
    final packageDir = state.lastPackageDir;
    if (packageDir == null) {
      _append('还没有可部署的包。先点击“构建包”。');
      return;
    }
    await _withBusy(force ? '强制部署包到游戏目录' : '部署包到游戏目录', () async {
      await _deployPackage(packageDir, force: force);
    });
  }

  Future<void> _deployPackage(String packageDir, {required bool force}) async {
    if (!force && !File(state.currentBaselineManifest).existsSync()) {
      _append('缺少原始备份。请先在 fresh install 或 Steam 验证完整性之后创建原始备份。');
      return;
    }
    final plan = await _refreshIntegrityFromCli();
    if (File(state.currentBaselineManifest).existsSync() &&
        (plan?.hasIntegrityBreak ?? false)) {
      _append(
        '原始备份不完整：${plan!.integrityBreakCount} 个保护文件缺少备份、备份文件缺失或校验不一致。已禁止写入。',
      );
      return;
    }
    final running = await _cli.isGameRunning();
    state = state.copyWith(gameRunning: running);
    if (running) {
      _append('检测到 FH6 正在运行，已拒绝部署。请先退出游戏。');
      return;
    }
    final args = [
      'deploy-package',
      p.join(packageDir, 'package'),
      '--game-dir',
      state.gameDir,
    ];
    if (state.preferredPath.trim().isNotEmpty) {
      args.addAll(['--preferred-path', state.preferredPath]);
    }
    if (File(state.currentBaselineManifest).existsSync()) {
      args.addAll(['--baseline-manifest', state.currentBaselineManifest]);
    }
    args.addAll(['--last-applied-manifest', state.lastAppliedPackageManifest]);
    if (force) args.add('--force');
    args.add('--yes');
    final result = await _run(args);
    if (result.ok) {
      final status = await _run(_statusArgs(), streamOutput: false);
      final payload = status.ok ? _decodeStatus(status.stdout) : null;
      if (payload != null) _applyStatusPayload(payload);
      await _refreshIntegrityFromCli();
    }
  }

  void clearLog() {
    state = state.copyWith(log: const []);
  }

  bool _rejectProjectEditWhenBaselineBroken(String action) {
    if (!state.projectEditingLocked) return false;
    _append(
      '${state.projectEditingLockTitle}${state.projectEditingLockMessage} 已阻止：$action。',
    );
    return true;
  }

  void clearRecentArtifacts() {
    state = state.copyWith(
      lastPackageDir: null,
      lastPackageSummary: null,
      pendingPackageDir: null,
      pendingPackageSummary: null,
      fileIntegrity: GameFileIntegritySummary.notChecked(),
      baselinePlanSummary: state.baselinePlanSummary,
    );
    _append('已清除最近准备结果和最近写入记录。');
  }

  void _refreshFileIntegrity() {
    final baselineManifestPath = _currentBaselineManifest(state.projectDir);
    final pendingBaselineManifestPath = _pendingBaselineManifest(
      state.projectDir,
    );
    state = state.copyWith(
      fileIntegrity: GameFileIntegritySummary.deferred(
        baselineManifestPath: baselineManifestPath,
        pendingBaselineManifestPath: pendingBaselineManifestPath,
        packageManifestPath: _packageManifestPath(state.integrityPackageDir),
        lastAppliedPackageManifestPath: _existingLastAppliedPackageManifest(
          state.projectDir,
        ),
      ),
    );
  }

  Future<BaselinePlanSummary?> _refreshIntegrityFromCli() async {
    final refreshProjectDir = state.projectDir;
    final refreshGameDir = state.gameDir;
    final baselineManifest = _currentBaselineManifest(state.projectDir);
    final pendingBaselineManifest = _pendingBaselineManifest(state.projectDir);
    final packageDir = state.integrityPackageDir;
    final oldPackageManifestForPending = pendingBaselineManifest == null
        ? null
        : _packageManifestPath(state.lastPackageDir);
    final lastAppliedPackageManifest =
        oldPackageManifestForPending ??
        (File(state.lastAppliedPackageManifest).existsSync()
            ? state.lastAppliedPackageManifest
            : null);
    final result = await _run([
      'verify-integrity',
      '--game-dir',
      refreshGameDir,
      if (packageDir != null) ...['--package-dir', packageDir],
      if (baselineManifest != null) ...[
        '--baseline-manifest',
        baselineManifest,
      ],
      if (pendingBaselineManifest != null) ...[
        '--pending-baseline-manifest',
        pendingBaselineManifest,
      ],
      if (lastAppliedPackageManifest != null) ...[
        '--last-applied-package-manifest',
        lastAppliedPackageManifest,
      ],
      '--json',
    ], streamOutput: false);
    if (!_isCurrentRefreshTarget(refreshProjectDir, refreshGameDir)) {
      _append('已忽略旧项目的文件校验结果。');
      return null;
    }
    if (!result.ok) {
      state = state.copyWith(
        baselinePlanSummary: null,
        fileIntegrity: GameFileIntegritySummary.notChecked(),
      );
      return null;
    }
    final decoded = _decodeIntegrityPayload(result.stdout);
    if (decoded == null || decoded.integrity == null) {
      state = state.copyWith(
        baselinePlanSummary: null,
        fileIntegrity: GameFileIntegritySummary.notChecked(),
      );
      _append('文件校验结果解析失败。');
      return null;
    }
    final summary = decoded.baselinePlan;
    state = state.copyWith(
      baselinePlanSummary: summary,
      gameVersionId: summary?.gameVersionId,
      fileIntegrity: decoded.integrity,
    );
    if (summary != null) _append('原始备份清单：${summary.summary}');
    return summary;
  }

  Future<BaselinePlanSummary?> _refreshBaselinePlan() async {
    final refreshProjectDir = state.projectDir;
    final refreshGameDir = state.gameDir;
    final baselineManifest = state.currentBaselineManifest;
    final result = await _run([
      'baseline',
      'plan',
      '--game-dir',
      refreshGameDir,
      if (File(baselineManifest).existsSync()) ...[
        '--baseline-manifest',
        baselineManifest,
      ],
      '--json',
    ], streamOutput: false);
    if (!_isCurrentRefreshTarget(refreshProjectDir, refreshGameDir)) {
      _append('已忽略旧项目的文件清单结果。');
      return null;
    }
    if (!result.ok) {
      state = state.copyWith(baselinePlanSummary: null);
      return null;
    }
    final decoded = _decodeBaselinePlan(result.stdout);
    if (decoded == null) {
      state = state.copyWith(baselinePlanSummary: null);
      _append('原始备份清单解析失败。');
      return null;
    }
    state = state.copyWith(
      baselinePlanSummary: decoded,
      gameVersionId: decoded.gameVersionId,
    );
    _append('原始备份清单：${decoded.summary}');
    return decoded;
  }

  bool _isCurrentRefreshTarget(String projectDir, String gameDir) {
    return _sameProjectPath(state.projectDir, projectDir) &&
        _sameProjectPath(state.gameDir, gameDir);
  }

  Future<void> _withBusy(String label, Future<void> Function() body) async {
    state = state.copyWith(
      busy: true,
      busyLabel: label,
      packageBuildProgressSteps: _isPackageBuildBusyLabel(label)
          ? _packageBuildStartupProgressSteps()
          : state.packageBuildProgressSteps,
    );
    _append('== $label ==');
    try {
      await body();
    } finally {
      state = state.copyWith(
        busy: false,
        busyLabel: null,
        aiEnvironmentProgressLabel: label == '同步 AI 环境' ? null : _sentinel,
        aiEnvironmentProgressDetail: label == '同步 AI 环境' ? null : _sentinel,
        aiEnvironmentProgressPercent: label == '同步 AI 环境' ? null : _sentinel,
        aiEnvironmentProgressSteps: label == '同步 AI 环境'
            ? const []
            : state.aiEnvironmentProgressSteps,
        aiEnvironmentProgressLog: label == '同步 AI 环境'
            ? const []
            : state.aiEnvironmentProgressLog,
      );
    }
  }

  void _setAiEnvironmentProgress({
    required String label,
    required String detail,
    required int percent,
  }) {
    state = state.copyWith(
      aiEnvironmentProgressLabel: label,
      aiEnvironmentProgressDetail: detail,
      aiEnvironmentProgressPercent: percent.clamp(0, 100).toInt(),
    );
  }

  Future<void> _withPanelRefresh(
    String scope,
    String label,
    Future<void> Function() body,
  ) async {
    if (state.busy || state.refreshingPanels.contains(scope)) return;
    state = state.copyWith(
      refreshingPanels: {...state.refreshingPanels, scope},
    );
    _append('== $label ==');
    try {
      await body();
    } finally {
      final next = {...state.refreshingPanels}..remove(scope);
      state = state.copyWith(refreshingPanels: next);
    }
  }

  Future<CliRunResult> _run(
    List<String> args, {
    bool streamOutput = true,
    void Function(String line)? streamLog,
    Map<String, String>? extraEnvironment,
    bool repairNetwork = false,
    CliCancellationToken? cancellationToken,
  }) async {
    final cli = _cli;
    final action = '执行：${_describeAction(args)}';
    _append(action);
    streamLog?.call(action);
    final stdout = streamOutput
        ? (String line) {
            _handleCliStdout(line, streamLog: streamLog);
          }
        : null;
    final stderr = streamOutput
        ? (String line) {
            _handleCliStderr(line, streamLog: streamLog);
          }
        : null;
    final result = repairNetwork
        ? await cli.runRepair(
            args,
            extraEnvironment: extraEnvironment,
            cancellationToken: cancellationToken,
            onStdout: stdout,
            onStderr: stderr,
          )
        : await cli.run(
            args,
            extraEnvironment: extraEnvironment,
            cancellationToken: cancellationToken,
            onStdout: stdout,
            onStderr: stderr,
          );
    if (!streamOutput && !result.ok) {
      _appendCompact(result.stdout);
      _appendCompact(result.stderr, prefix: 'ERR ');
    }
    final exitLine = result.cancelled
        ? '已取消：${_describeAction(args)}'
        : result.ok
        ? '退出码：0'
        : '退出码：${result.exitCode}';
    _append(exitLine);
    streamLog?.call(exitLine);
    return result;
  }

  Future<CliRunResult> _runBase(
    List<String> args, {
    bool streamOutput = true,
    void Function(String line)? streamLog,
    Map<String, String>? extraEnvironment,
    bool repairNetwork = false,
    CliCancellationToken? cancellationToken,
  }) async {
    final cli = _cli;
    final action = '执行：${_describeAction(args)}';
    _append(action);
    streamLog?.call(action);
    final stdout = streamOutput
        ? (String line) {
            _handleCliStdout(line, streamLog: streamLog);
          }
        : null;
    final stderr = streamOutput
        ? (String line) {
            _handleCliStderr(line, streamLog: streamLog);
          }
        : null;
    final result = repairNetwork
        ? await cli.runBaseRepair(
            args,
            extraEnvironment: extraEnvironment,
            cancellationToken: cancellationToken,
            onStdout: stdout,
            onStderr: stderr,
          )
        : await cli.runBase(
            args,
            extraEnvironment: extraEnvironment,
            cancellationToken: cancellationToken,
            onStdout: stdout,
            onStderr: stderr,
          );
    if (!streamOutput && !result.ok) {
      _appendCompact(result.stdout);
      _appendCompact(result.stderr, prefix: 'ERR ');
    }
    final exitLine = result.cancelled
        ? '已取消：${_describeAction(args)}'
        : result.ok
        ? '退出码：0'
        : '退出码：${result.exitCode}';
    _append(exitLine);
    streamLog?.call(exitLine);
    return result;
  }

  void _handleCliStdout(String line, {void Function(String line)? streamLog}) {
    if (_handleCliProgressLine(line)) return;
    if (line.trim().isEmpty) return;
    _append(line);
    streamLog?.call(line);
  }

  void _handleCliStderr(String line, {void Function(String line)? streamLog}) {
    if (_handleCliProgressLine(line)) return;
    final entry = _cliStderrLogEntry(line);
    if (entry == null) return;
    _append(entry);
    streamLog?.call(entry);
  }

  @visibleForTesting
  bool handleProgressLineForTest(String line) {
    return _handleCliProgressLine(line);
  }

  @visibleForTesting
  List<String> modelWarmupFailuresForTest(String stdout) {
    return _modelWarmupFailures(stdout);
  }

  bool _handleCliProgressLine(String line) {
    if (!line.startsWith(_cliProgressPrefix)) return false;
    try {
      final decoded = jsonDecode(line.substring(_cliProgressPrefix.length));
      final event = _jsonMap(decoded);
      if (event != null) {
        state = _stateWithPackageBuildProgressEvent(state, event);
      }
    } on FormatException {
      return true;
    }
    return true;
  }

  Future<void> _refreshTrackMetadataCacheWithinBusy({
    bool allSources = false,
    bool onlyIfMissing = false,
  }) async {
    if (!state.hasProject || (!allSources && state.musicPaths.isEmpty)) return;
    final cachePath = TrackMetadataCache.configPath(state.projectDir);
    if (onlyIfMissing && File(cachePath).existsSync()) return;
    final args = [
      'scan-metadata',
      '--project-dir',
      state.projectDir,
      if (allSources) '--all-sources' else ...state.musicPaths,
      '--json',
    ];
    final result = await _run(args, streamOutput: false);
    if (!result.ok) {
      _append('音频信息读取失败，暂时使用文件名。');
      return;
    }
    final payload = _decodeJsonObject(result.stdout, label: '音频信息');
    final scanned = _asInt(payload?['scanned']) ?? state.musicPaths.length;
    if (scanned > 0) {
      _append('已读取 $scanned 首音频信息。');
      setMusicPaths(state.musicPaths);
    }
  }

  String _describeAction(List<String> args) {
    if (args.isEmpty) return '准备任务';
    if (args.first == 'status') return '刷新当前状态';
    if (args.first == 'check-tools') return '检查本地处理组件';
    if (args.first == 'install-tools') return '安装或修复本地处理组件';
    if (args.first == 'toolchain-status') return '检查工具链健康';
    if (args.first == 'prepare-ai-cache') return '准备 AI 模型缓存';
    if (args.first == 'import-audio') return '导入并规范化音频';
    if (args.first == 'scan-metadata') return '读取音频信息';
    if (args.first == 'list-radios') return '读取游戏电台信息';
    if (args.first == 'build-package') return '准备电台替换包';
    if (args.first == 'baseline' && args.length > 1) {
      if (args[1] == 'plan') return '扫描文件保护清单';
      if (args[1] == 'create') return '创建原始备份';
      if (args[1] == 'promote') return '确认新游戏文件';
      if (args[1] == 'discard-pending') return '放弃新文件记录';
      if (args[1] == 'apply') return '写回已记录游戏文件';
    }
    if (args.first == 'deploy-package') return '写入游戏文件';
    if (args.first == 'language-swap' && args.length > 1) {
      if (args[1] == 'list') return '读取语言文件';
      if (args[1] == 'preferred') return '读取当前语言偏好';
    }
    return args.first;
  }

  Future<void> _refreshToolchainStatusWithinBusy({
    String? profileOverride,
    bool resolveAiProfile = true,
  }) async {
    state = state.copyWith(
      toolchainStatus: ToolchainStatusSummary.checking(
        previous: state.toolchainStatus,
      ),
    );
    final requestedProfile = profileOverride ?? state.aiProfile;
    final parsed = await loadToolchainStatusForProfile(requestedProfile);
    if (parsed == null) return;

    if (!resolveAiProfile) {
      state = state.copyWith(aiProfileNotice: null, toolchainStatus: parsed);
      _append(
        '工具链：${state.toolchainStatus.label} · ${state.toolchainStatus.summary}',
      );
      return;
    }

    final resolved = await _resolveAiProfileForToolchain(
      requestedProfile,
      parsed,
    );
    if (resolved.profile != requestedProfile) {
      final notice =
          '已从 ${_aiProfileShortLabel(requestedProfile)} 自动降级到 ${_aiProfileShortLabel(resolved.profile)}；'
          '深度 AI 模型或依赖缺失时会优先保证核心处理流程可用。';
      state = state.copyWith(
        aiProfile: resolved.profile,
        aiProfileNotice: notice,
        toolchainStatus: resolved.status,
      );
      _persistAiProfile(resolved.profile);
      _append(
        'AI pipeline 自动降级：${aiProfileCupLabel(requestedProfile)} -> ${aiProfileCupLabel(resolved.profile)}',
      );
      _append(notice);
    } else {
      state = state.copyWith(aiProfileNotice: null, toolchainStatus: parsed);
    }
    _append(
      '工具链：${state.toolchainStatus.label} · ${state.toolchainStatus.summary}',
    );
  }

  @protected
  Future<ToolchainStatusSummary?> loadToolchainStatusForProfile(
    String profile,
  ) async {
    final args = _toolchainArgsForProfile(profile);
    var result = profile == 'local-base'
        ? await _runBase(args, streamOutput: false)
        : await _run(args, streamOutput: false);
    if (!result.ok && profile != 'local-base') {
      _append('所选杯型环境检查失败，回退到中杯环境读取缺失状态。');
      result = await _runBase(args, streamOutput: false);
    }
    if (!result.ok) {
      state = state.copyWith(
        toolchainStatus: ToolchainStatusSummary.error('工具链检查命令执行失败'),
      );
      return null;
    }
    final payload = _decodeToolchainStatus(result.stdout);
    if (payload == null) {
      state = state.copyWith(
        toolchainStatus: ToolchainStatusSummary.error('工具链状态解析失败'),
      );
      return null;
    }
    return ToolchainStatusSummary.fromJson(payload);
  }

  Future<ToolchainStatusSummary?> checkToolchainStatusForProfile(
    String profile,
  ) {
    return loadToolchainStatusForProfile(profile);
  }

  Future<({String profile, ToolchainStatusSummary status})>
  _resolveAiProfileForToolchain(
    String requestedProfile,
    ToolchainStatusSummary initial,
  ) async {
    if (!_shouldFallbackAiProfile(initial)) {
      return (profile: requestedProfile, status: initial);
    }
    for (final candidate in _lowerAiProfiles(requestedProfile)) {
      final status = await loadToolchainStatusForProfile(candidate);
      if (status == null) break;
      if (_aiProfileUsable(status)) {
        return (profile: candidate, status: status);
      }
      if (candidate == 'local-base') {
        return (profile: candidate, status: status);
      }
    }
    return (profile: requestedProfile, status: initial);
  }

  bool _shouldFallbackAiProfile(ToolchainStatusSummary status) {
    if (status.profile == 'local-base') return false;
    return !_aiProfileUsable(status);
  }

  bool _aiProfileUsable(ToolchainStatusSummary status) {
    final python = status.section('python');
    if (python != null &&
        {'missing', 'error', 'needs_sync'}.contains(python.status)) {
      return false;
    }
    final ai = status.section('ai');
    if (ai == null) return false;
    return {'ready', 'ok'}.contains(ai.status);
  }

  Iterable<String> _lowerAiProfiles(String profile) sync* {
    final index = kAiPipelineProfiles.indexOf(profile);
    if (index <= 0) return;
    for (var i = index - 1; i >= 0; i -= 1) {
      yield kAiPipelineProfiles[i];
    }
  }

  String _aiProfileShortLabel(String profile) {
    return aiProfileCupLabel(profile);
  }

  List<String> _toolchainArgsForProfile(String profile) {
    return ['toolchain-status', '--profile', profile, '--json'];
  }

  List<String> _statusArgs() {
    final args = <String>[
      'status',
      '--radio',
      '${state.radio}',
      '--source',
      state.sourceLang,
      '--target',
      state.targetLang,
      if (state.preferredPath.trim().isNotEmpty) ...[
        '--preferred-path',
        state.preferredPath,
      ],
      if (File(state.currentBaselineManifest).existsSync()) ...[
        '--baseline-manifest',
        state.currentBaselineManifest,
      ],
      '--json',
    ];
    if (state.gameDir.trim().isNotEmpty) {
      args.insertAll(1, ['--game-dir', state.gameDir]);
    }
    return args;
  }

  Map<String, dynamic>? _decodeStatus(String stdout) {
    final decoded = _decodeJsonObject(stdout, label: '状态');
    return decoded;
  }

  Map<String, dynamic>? _decodeToolchainStatus(String stdout) {
    return _decodeJsonObject(stdout, label: '工具链');
  }

  Map<String, dynamic>? _decodeJsonObject(
    String stdout, {
    required String label,
  }) {
    try {
      final decoded = jsonDecode(stdout);
      return _asMap(decoded);
    } on FormatException catch (error) {
      _append('$label JSON 解析失败：${error.message}');
      return null;
    }
  }

  void _applyStatusPayload(Map<String, dynamic> payload) {
    final selected = _asMap(payload['selected_radio']);
    final language = _asMap(payload['language']);
    final radioOptions = _radioOptions(payload['radios']);
    final preferred = _asString(payload['preferred_lang']);
    final preferredDisplay = preferred == null || preferred.isEmpty
        ? '未设置'
        : preferred;
    final sourceLang =
        _asString(language?['source_lang'])?.toUpperCase() ?? state.sourceLang;
    final targetLang =
        _asString(language?['target_lang'])?.toUpperCase() ?? state.targetLang;
    final sourceExists = _asBool(language?['source_exists']) ?? false;
    final targetExists = _asBool(language?['target_exists']) ?? false;
    final targetMatchesSource =
        _asBool(language?['target_matches_source']) ?? false;
    final availableLanguages = _asStringList(language?['available']);
    final sourceBaseline = _asMap(language?['source_baseline']);
    final targetBaseline = _asMap(language?['target_baseline']);
    final voiceSlotVerified =
        _asBool(language?['voice_slot_verified']) ?? false;
    final previousSourceLang = state.sourceLang;
    final previousTargetLang = state.targetLang;
    final hadLocalLanguageChange = !state.languageSelectionMatchesGame;
    final nextSourceLang = hadLocalLanguageChange
        ? state.sourceLang
        : sourceLang;
    final nextTargetLang = hadLocalLanguageChange
        ? state.targetLang
        : targetLang;
    final nextPreferredMatches =
        preferred != null && preferred.toUpperCase() == nextTargetLang;
    final nextSourceExists = hadLocalLanguageChange
        ? state.sourceLanguageExists
        : sourceExists;
    final nextTargetExists = hadLocalLanguageChange
        ? state.targetLanguageExists
        : targetExists;
    final nextTargetMatchesSource = hadLocalLanguageChange
        ? state.targetMatchesSource
        : targetMatchesSource;

    state = state.copyWith(
      gameRunning: _asBool(payload['game_running']) ?? false,
      gameVersionId: _asString(payload['game_version_id']),
      toolsOk: _asBool(payload['tools_ok']) ?? false,
      sourceLang: nextSourceLang,
      targetLang: nextTargetLang,
      gameSourceLang: sourceLang,
      gameTargetLang: targetLang,
      availableLanguages: availableLanguages.isEmpty
          ? state.availableLanguages
          : availableLanguages,
      preferredLang: preferredDisplay,
      languageReady:
          nextSourceExists &&
          nextTargetExists &&
          nextPreferredMatches &&
          nextTargetMatchesSource &&
          voiceSlotVerified,
      sourceLanguageExists: nextSourceExists,
      targetLanguageExists: nextTargetExists,
      targetMatchesSource: nextTargetMatchesSource,
      preferredMatchesTarget: nextPreferredMatches,
      voiceSlotVerified: voiceSlotVerified,
      sourceLanguageBaselineStatus:
          _asString(sourceBaseline?['status']) ?? 'no_baseline',
      targetLanguageBaselineStatus:
          _asString(targetBaseline?['status']) ?? 'no_baseline',
      sourceLanguageMd5: _asString(language?['source_md5']),
      targetLanguageMd5: _asString(language?['target_md5']),
      radioOptions: radioOptions.isEmpty ? state.radioOptions : radioOptions,
      languageSummary: _languageSummary(
        sourceLang: nextSourceLang,
        targetLang: nextTargetLang,
        preferredLang: preferredDisplay,
        sourceExists: nextSourceExists,
        targetExists: nextTargetExists,
        preferredMatches: nextPreferredMatches,
        targetMatchesSource: nextTargetMatchesSource,
        voiceSlotVerified: voiceSlotVerified,
        targetBaselineStatus:
            _asString(targetBaseline?['status']) ?? 'no_baseline',
      ),
      statusSummary: _radioSummary(selected) ?? 'RadioInfo 可读取',
    );
    if (state.sourceLang != previousSourceLang ||
        state.targetLang != previousTargetLang) {
      FhRadioStudioProject.writeSettings(
        state.projectDir,
        gameDir: state.gameDir,
        radio: state.radio,
        sourceLang: state.sourceLang,
        targetLang: state.targetLang,
        aiProfile: state.aiProfile,
      );
    }
  }

  List<RadioStatusOption> _radioOptions(Object? raw) {
    if (raw is! List) return const [];
    final options = <RadioStatusOption>[];
    for (final item in raw) {
      final map = _asMap(item);
      if (map == null) continue;
      final number = _asInt(map['number']);
      final name = _asString(map['name']);
      if (number == null || name == null || name.isEmpty) continue;
      final playlists = _asMap(map['playlists']);
      options.add(
        RadioStatusOption(
          number: number,
          name: name,
          tracks: _asInt(map['tracks']),
          bankSlots: _asInt(map['bank_slots']),
          freeRoam: _asInt(playlists?['FreeRoam']),
          event: _asInt(playlists?['Event']),
        ),
      );
    }
    return options;
  }

  String _baselineStatusText(String status) {
    return switch (status) {
      'ok' => '原始备份已覆盖',
      'backup_differs_from_current' => '原始备份完整，当前文件已变化',
      'backup_missing' => '备份文件缺失',
      'backup_changed' => '备份记录校验不一致',
      'missing_entry' => '备份记录缺少该槽',
      _ => '缺少原始备份',
    };
  }

  String _languageSummary({
    required String sourceLang,
    required String targetLang,
    required String preferredLang,
    required bool sourceExists,
    required bool targetExists,
    required bool preferredMatches,
    required bool targetMatchesSource,
    required bool voiceSlotVerified,
    required String targetBaselineStatus,
  }) {
    if (!sourceExists || !targetExists) {
      final missing = [
        if (!sourceExists) '$sourceLang.zip',
        if (!targetExists) '$targetLang.zip',
      ].join('、');
      return '缺少 $missing';
    }
    if (!voiceSlotVerified) {
      return '语音槽未验证：${_baselineStatusText(targetBaselineStatus)}';
    }
    if (preferredMatches && targetMatchesSource) {
      return '$sourceLang 显示 · $targetLang 语音';
    }
    if (!preferredMatches && !targetMatchesSource) {
      return 'UserPreferredLang $preferredLang · 表单选择 $targetLang';
    }
    if (!preferredMatches) {
      return 'UserPreferredLang $preferredLang · 表单选择 $targetLang';
    }
    return '$targetLang 槽尚未同步 $sourceLang 显示';
  }

  String? _radioSummary(Map<String, dynamic>? selected) {
    if (selected == null) return null;
    final name = _asString(selected['name']) ?? 'R${state.radio}';
    final tracks = _asInt(selected['tracks']);
    final playlists = _asMap(selected['playlists']);
    final free = _asInt(playlists?['FreeRoam']);
    final event = _asInt(playlists?['Event']);
    if (tracks == null) return name;
    if (free == null || event == null) return '$name · $tracks 首';
    return '$name · $tracks 首 · Free/Event $free/$event';
  }

  Map<String, dynamic>? _asMap(Object? value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) {
      return value.map((key, item) => MapEntry('$key', item));
    }
    return null;
  }

  String? _asString(Object? value) => value == null ? null : '$value';

  List<String> _asStringList(Object? value) {
    if (value is! List) return const [];
    final result = <String>[];
    for (final item in value) {
      final text = _asString(item)?.trim().toUpperCase();
      if (text == null || text.isEmpty) continue;
      result.add(text);
    }
    result.sort();
    return result;
  }

  bool? _asBool(Object? value) {
    if (value is bool) return value;
    if (value is String) {
      final lower = value.toLowerCase();
      if (lower == 'true') return true;
      if (lower == 'false') return false;
    }
    return null;
  }

  int? _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.round();
    if (value is String) return int.tryParse(value);
    return null;
  }

  void _append(String line) {
    final next = [...state.log, line];
    state = state.copyWith(
      log: next.length > 400 ? next.sublist(next.length - 400) : next,
    );
  }

  void _appendToolInstallLog(String line) {
    final next = [...state.toolInstallLog, line];
    state = state.copyWith(
      toolInstallLog: next.length > 160
          ? next.sublist(next.length - 160)
          : next,
    );
  }

  void _appendAiEnvironmentProgressLog(String line) {
    final compact = _compactAiEnvironmentLogLine(line);
    if (compact == null) return;
    final next = [...state.aiEnvironmentProgressLog, compact];
    state = state.copyWith(
      aiEnvironmentProgressLog: next.length > 12
          ? next.sublist(next.length - 12)
          : next,
    );
  }

  void _appendAiEnvironmentWorkflowLog(String line) {
    _append(line);
    _appendAiEnvironmentProgressLog(line);
  }

  _AiEnvironmentHeartbeat _startAiEnvironmentHeartbeat({
    required String stageLabel,
    required String quietHint,
  }) {
    return _AiEnvironmentHeartbeat(
      stageLabel: stageLabel,
      quietHint: quietHint,
      onPulse: _appendAiEnvironmentWorkflowLog,
    )..start();
  }

  String? _cliStderrLogEntry(String line) {
    final trimmedRight = line.trimRight();
    if (trimmedRight.trim().isEmpty) return null;
    return 'ERR $trimmedRight';
  }

  String? _compactAiEnvironmentLogLine(String line) {
    var trimmed = line.trim();
    if (trimmed.isEmpty || trimmed.startsWith(_cliProgressPrefix)) {
      return null;
    }
    if (trimmed.startsWith('ERR ')) {
      trimmed = trimmed.substring(4).trimLeft();
    }
    if (trimmed.length <= 180) return trimmed;
    return '${trimmed.substring(0, 177)}...';
  }

  List<String> _modelWarmupFailures(String stdout) {
    final failures = <String>[];
    final warmedLine = RegExp(
      r'^\s*warmed\s+([A-Za-z0-9_-]+)\s*:\s*([A-Za-z0-9_-]+)\s*$',
      caseSensitive: false,
    );
    for (final line in stdout.split('\n')) {
      final match = warmedLine.firstMatch(line.trim());
      if (match == null) continue;
      final provider = match.group(1) ?? 'provider';
      final status = (match.group(2) ?? '').toLowerCase();
      if (status != 'ready' && status != 'ok') {
        failures.add('$provider=$status');
      }
    }
    return failures;
  }

  String _toolInstallFailureSummary({int? exitCode, Object? error}) {
    final header = error == null
        ? 'install-tools 非正常退出：退出码 ${exitCode ?? 'unknown'}。'
        : 'install-tools 启动或执行失败：${error.runtimeType}: $error';
    final tail = state.toolInstallLog
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList(growable: false);
    final lastLines = tail.length <= 8 ? tail : tail.sublist(tail.length - 8);
    if (lastLines.isEmpty) return header;
    return '$header\n\n最近日志：\n${lastLines.join('\n')}';
  }

  void _appendCompact(String text, {String prefix = ''}) {
    for (final line in text.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isNotEmpty) _append('$prefix$trimmed');
    }
  }
}

class _AiEnvironmentHeartbeat {
  _AiEnvironmentHeartbeat({
    required this.stageLabel,
    required this.quietHint,
    required this.onPulse,
  });

  final String stageLabel;
  final String quietHint;
  final void Function(String line) onPulse;
  final Stopwatch _elapsed = Stopwatch();
  DateTime _lastActivity = DateTime.now();
  Timer? _timer;

  void start() {
    _elapsed.start();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) {
      final now = DateTime.now();
      final quietSeconds = now.difference(_lastActivity).inSeconds;
      if (quietSeconds < 25) return;
      onPulse(
        '仍在处理：$stageLabel 已运行 ${_elapsedLabel(_elapsed.elapsed)}，'
        '最近 ${quietSeconds}s 没有新输出；$quietHint',
      );
      _lastActivity = now;
    });
  }

  void markActivity() {
    _lastActivity = DateTime.now();
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
    _elapsed.stop();
  }

  static String _elapsedLabel(Duration duration) {
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds.remainder(60);
    if (minutes <= 0) return '${duration.inSeconds}s';
    return '${minutes}m ${seconds.toString().padLeft(2, '0')}s';
  }
}

final studioProvider = StateNotifierProvider<StudioController, StudioState>((
  ref,
) {
  return StudioController(ref.watch(sharedPreferencesProvider));
});
