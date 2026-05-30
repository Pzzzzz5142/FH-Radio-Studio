import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fh_radio_studio/core/app_info.dart';

void main() {
  test('fallback release id mirrors pubspec version', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final versionLine = pubspec
        .split('\n')
        .firstWhere((line) => line.trimLeft().startsWith('version:'));
    var version = versionLine
        .split('#')
        .first
        .split(':')
        .skip(1)
        .join(':')
        .trim();
    if (version.length >= 2 &&
        ((version.startsWith("'") && version.endsWith("'")) ||
            (version.startsWith('"') && version.endsWith('"')))) {
      version = version.substring(1, version.length - 1);
    }

    expect(fallbackAppReleaseId, version);
  });

  test('app info sidebar lines include dev build only when enabled', () {
    const devInfo = AppInfo(
      releaseId: '0.1.0-dev.7',
      buildCommitSha256: 'None',
      showBuild: true,
    );
    const releaseInfo = AppInfo(
      releaseId: '0.1.0-rc.1',
      buildCommitSha256: 'abc123',
      showBuild: false,
    );

    expect(devInfo.sidebarLines, ['FH Radio Studio 0.1.0-dev.7', 'build None']);
    expect(releaseInfo.sidebarLines, ['FH Radio Studio 0.1.0-rc.1']);
  });

  test('fallback main-style build exposes build commit line', () {
    expect(fallbackAppReleaseId, '0.1.0');
    expect(AppInfo.fallback.sidebarLines, [
      'FH Radio Studio 0.1.0',
      'build None',
    ]);
  });

  test('only release branch names hide build visibility', () {
    expect(shouldShowBuildInfoForBranchName('release/v0.1.0'), isFalse);
    expect(shouldShowBuildInfoForBranchName('release/v0.1.0-rc.1'), isFalse);

    expect(shouldShowBuildInfoForBranchName(null), isTrue);
    expect(shouldShowBuildInfoForBranchName('main'), isTrue);
    expect(shouldShowBuildInfoForBranchName('main+local'), isTrue);
    expect(shouldShowBuildInfoForBranchName('dev/audio-pipeline'), isTrue);
    expect(shouldShowBuildInfoForBranchName('feature/versioning'), isTrue);
    expect(shouldShowBuildInfoForBranchName('release/0.1.0'), isTrue);
    expect(shouldShowBuildInfoForBranchName('release/v0.1'), isTrue);
  });
}
