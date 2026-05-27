import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

const appDisplayName = 'FH Radio Studio';
const fallbackAppReleaseId = '0.2.0-rc.1';
const noneBuildCommitSha256 = 'None';

const _definedReleaseId = String.fromEnvironment('FH_RADIO_STUDIO_RELEASE_ID');
const _definedCommitSha256 = String.fromEnvironment(
  'FH_RADIO_STUDIO_COMMIT_SHA256',
);
const _definedBranchName = String.fromEnvironment(
  'FH_RADIO_STUDIO_BRANCH_NAME',
);

const defaultAppReleaseId = _definedReleaseId == ''
    ? fallbackAppReleaseId
    : _definedReleaseId;

final appInfoProvider = FutureProvider<AppInfo>((ref) {
  return AppInfo.load();
});

@immutable
class AppInfo {
  const AppInfo({
    required this.releaseId,
    required this.buildCommitSha256,
    required this.showBuild,
  });

  static final fallback = AppInfo(
    releaseId: defaultAppReleaseId,
    buildCommitSha256: noneBuildCommitSha256,
    showBuild: shouldShowBuildInfoForBranchName(_definedBranchName),
  );

  final String releaseId;
  final String buildCommitSha256;
  final bool showBuild;

  static Future<AppInfo> load() async {
    final releaseId = await _resolveReleaseId();
    final branchName = await _resolveBranchName();
    final showBuild = shouldShowBuildInfoForBranchName(branchName);
    final buildCommitSha256 = showBuild
        ? await _resolveCommitSha256()
        : noneBuildCommitSha256;
    return AppInfo(
      releaseId: releaseId,
      buildCommitSha256: buildCommitSha256,
      showBuild: showBuild,
    );
  }

  List<String> get sidebarLines => [
    '$appDisplayName $releaseId',
    if (showBuild) 'build $buildCommitSha256',
  ];
}

String fhRadioStudioUserAgent([String? suffix]) {
  final base = '$appDisplayName/$defaultAppReleaseId';
  final extra = suffix?.trim();
  return extra == null || extra.isEmpty ? base : '$base $extra';
}

Future<String> _resolveReleaseId() async {
  final defined = _cleanValue(_definedReleaseId);
  if (defined != null) return defined;

  try {
    final info = await PackageInfo.fromPlatform();
    final version = _cleanValue(info.version);
    final buildNumber = _cleanValue(info.buildNumber);
    if (version != null && buildNumber != null) {
      return '$version+$buildNumber';
    }
    if (version != null) return version;
  } catch (_) {
    // Widget tests and partial desktop harnesses may not have the plugin ready.
  }

  return fallbackAppReleaseId;
}

Future<String> _resolveCommitSha256() async {
  final defined = _cleanValue(_definedCommitSha256);
  if (defined != null) return defined;

  final env = _cleanValue(
    Platform.environment['FH_RADIO_STUDIO_COMMIT_SHA256'],
  );
  if (env != null) return env;

  try {
    final result = await Process.run('git', const [
      'rev-parse',
      '--verify',
      'HEAD',
    ], workingDirectory: Directory.current.path);
    if (result.exitCode == 0) {
      return _cleanValue('${result.stdout}') ?? noneBuildCommitSha256;
    }
  } catch (_) {
    // Git is optional for local dev snapshots.
  }

  return noneBuildCommitSha256;
}

Future<String?> _resolveBranchName() async {
  final defined = _cleanValue(_definedBranchName);
  if (defined != null) return defined;

  final env = _cleanValue(Platform.environment['FH_RADIO_STUDIO_BRANCH_NAME']);
  if (env != null) return env;

  try {
    final result = await Process.run('git', const [
      'branch',
      '--show-current',
    ], workingDirectory: Directory.current.path);
    if (result.exitCode == 0) {
      return _cleanValue('${result.stdout}');
    }
  } catch (_) {
    // Git is optional for packaged builds and local snapshots.
  }

  return null;
}

String? _cleanValue(String? value) {
  final cleaned = value?.trim();
  return cleaned == null || cleaned.isEmpty ? null : cleaned;
}

@visibleForTesting
bool shouldShowBuildInfoForBranchName(String? branchName) {
  return !_isReleaseBranchName(branchName);
}

bool _isReleaseBranchName(String? branchName) {
  final normalized = branchName?.trim().toLowerCase();
  if (normalized == null || normalized.isEmpty) return false;
  return RegExp(r'^release/v\d+\.\d+\.\d+(-rc\.\d+)?$').hasMatch(normalized);
}
