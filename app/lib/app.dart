import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/fh_radio_studio_cli.dart';
import 'state/app_state.dart';
import 'state/studio_state.dart';
import 'state/router.dart';
import 'theme/app_theme.dart';

class FhRadioStudioApp extends ConsumerStatefulWidget {
  const FhRadioStudioApp({super.key});

  @override
  ConsumerState<FhRadioStudioApp> createState() => _FhRadioStudioAppState();
}

class _FhRadioStudioAppState extends ConsumerState<FhRadioStudioApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(studioProvider.notifier).startupFullCheckOnce();
    });
  }

  @override
  Future<ui.AppExitResponse> didRequestAppExit() async {
    await FhRadioStudioCli.killActiveProcesses();
    return ui.AppExitResponse.exit;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) {
      unawaited(FhRadioStudioCli.killActiveProcesses());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(FhRadioStudioCli.killActiveProcesses());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final accent = ref.watch(accentProvider);
    final mode = ref.watch(themeModeProvider);

    return MaterialApp.router(
      title: 'FH Radio Studio',
      debugShowCheckedModeBanner: false,
      themeMode: mode,
      theme: buildAppTheme(brightness: Brightness.light, accent: accent),
      darkTheme: buildAppTheme(brightness: Brightness.dark, accent: accent),
      routerConfig: appRouter,
      builder: (context, child) {
        // 防止系统字体缩放破坏密集 UI
        return MediaQuery.withClampedTextScaling(
          minScaleFactor: 1,
          maxScaleFactor: 1,
          child: child ?? const SizedBox.shrink(),
        );
      },
    );
  }
}
