import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fh_radio_studio/screens/playlist.dart';
import 'package:fh_radio_studio/state/app_state.dart';
import 'package:fh_radio_studio/theme/accents.dart';
import 'package:fh_radio_studio/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  runApp(
    ProviderScope(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildAppTheme(
          brightness: Brightness.light,
          accent: AppAccent.lime,
        ),
        home: const Scaffold(body: PlaylistScreen()),
      ),
    ),
  );
}
