import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fh_radio_studio/domain/replacement_models.dart';
import 'package:fh_radio_studio/screens/replace_editor/waveform_painter.dart';
import 'package:fh_radio_studio/theme/accents.dart';
import 'package:fh_radio_studio/theme/app_theme.dart';

void main() {
  test('WaveformBars accepts arbitrary CLI segment labels', () {
    final bars = WaveformBars.build(
      duration: 90,
      barCount: 16,
      segments: const [
        Segment(start: 0, end: 30, label: 'drop_2 / final hook'),
        Segment(start: 30, end: 60, label: 'guitar solo'),
        Segment(start: 60, end: 90, label: 'OUTRO-B'),
      ],
    );

    expect(bars.values, hasLength(16));
    expect(bars.values.every((value) => value >= 0.05 && value <= 1.0), isTrue);
  });

  test('WaveformBars.fromValues keeps headroom for peak-limited audio', () {
    final bars = WaveformBars.fromValues([
      1.0,
      0.99,
      0.98,
      0.96,
      0.48,
      0.46,
      0.44,
      0.43,
    ]);

    expect(bars.values.reduce((a, b) => a > b ? a : b), lessThan(0.9));
    expect(
      bars.values.reduce((a, b) => a > b ? a : b) -
          bars.values.reduce((a, b) => a < b ? a : b),
      greaterThan(0.35),
    );
  });

  testWidgets('WaveformPainter renders arbitrary CLI segment labels', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(720, 240);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });

    const segments = [
      Segment(start: 0, end: 30, label: 'drop_2 / final hook'),
      Segment(start: 30, end: 60, label: 'guitar solo'),
      Segment(start: 60, end: 90, label: 'OUTRO-B'),
    ];
    final bars = WaveformBars.build(
      duration: 90,
      barCount: 32,
      segments: segments,
    );

    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildAppTheme(
          brightness: Brightness.light,
          accent: AppAccent.lime,
        ),
        home: Builder(
          builder: (context) {
            final rm = context.rm;
            return Center(
              child: CustomPaint(
                size: const Size(680, WaveformPainter.totalHeight),
                painter: WaveformPainter(
                  rm: rm,
                  bars: bars,
                  beats: const [0, 1, 2, 3, 4, 5, 6, 7, 8, 9],
                  segments: segments,
                  duration: 90,
                  markers: const [],
                  tlLoop: null,
                  plLoop: null,
                  playhead: 45,
                ),
              ),
            );
          },
        ),
      ),
    );

    expect(tester.takeException(), isNull);
  });
}
