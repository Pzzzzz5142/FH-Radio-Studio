import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:path/path.dart' as p;
import 'package:fh_radio_studio/screens/playlist.dart';
import 'package:fh_radio_studio/state/app_state.dart';
import 'package:fh_radio_studio/theme/accents.dart';
import 'package:fh_radio_studio/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets(
    'capture playlist route with Flutter render tree',
    (tester) async {
      GoogleFonts.config.allowRuntimeFetching = false;
      tester.view.devicePixelRatio = 1.5;
      tester.view.physicalSize = const Size(2048, 2700);
      addTearDown(() {
        tester.view.resetDevicePixelRatio();
        tester.view.resetPhysicalSize();
      });

      final repoRoot = p.dirname(p.current);
      final projectDir = p.join(repoRoot, 'test', 'project', 'cli-full-flow');
      SharedPreferences.setMockInitialValues({
        'rm.studio.projectDir': projectDir,
        'rm.studio.repoRoot': repoRoot,
      });
      final prefs = await SharedPreferences.getInstance();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: buildAppTheme(
              brightness: Brightness.light,
              accent: AppAccent.lime,
            ),
            home: Scaffold(body: const PlaylistScreen()),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.takeException(), isNull);

      await expectLater(
        find.byType(PlaylistScreen),
        matchesGoldenFile('goldens/playlist_flutter_render.png'),
      );
      // ignore: avoid_print
      print(
        'playlist_flutter_render=${p.join(repoRoot, 'app', 'test', 'goldens', 'playlist_flutter_render.png')}',
      );
    },
    skip: Platform.environment['CAPTURE_PLAYLIST'] != '1',
  );
}
