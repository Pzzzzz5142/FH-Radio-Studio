import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fh_radio_studio/theme/accents.dart';
import 'package:fh_radio_studio/theme/app_theme.dart';

void main() {
  test('app tooltip theme uses FH Radio Studio popover styling', () {
    final theme = buildAppTheme(
      brightness: Brightness.light,
      accent: AppAccent.lime,
    );
    final rm = theme.extension<RmTheme>()!;
    final tooltip = theme.tooltipTheme;

    expect(
      tooltip.constraints,
      const BoxConstraints(minHeight: 28, maxWidth: 320),
    );
    expect(
      tooltip.padding,
      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    );
    expect(tooltip.margin, const EdgeInsets.all(12));
    expect(tooltip.verticalOffset, 10);
    expect(tooltip.preferBelow, isFalse);
    expect(tooltip.waitDuration, const Duration(milliseconds: 280));
    expect(tooltip.showDuration, const Duration(milliseconds: 1800));
    expect(tooltip.exitDuration, const Duration(milliseconds: 90));
    expect(tooltip.enableFeedback, isFalse);
    expect(tooltip.textAlign, TextAlign.center);
    expect(tooltip.textStyle?.fontFamily, 'Noto Sans SC');
    expect(tooltip.textStyle?.fontSize, 12.5);
    expect(tooltip.textStyle?.fontWeight, FontWeight.w500);
    expect(tooltip.textStyle?.height, 1.25);
    expect(tooltip.textStyle?.color, rm.fg);

    final decoration = tooltip.decoration;
    expect(decoration, isA<BoxDecoration>());
    final box = decoration! as BoxDecoration;
    expect(box.color, Color.alphaBlend(rm.accent.bg, rm.panel));
    expect(box.borderRadius, BorderRadius.circular(6));
    expect(box.border, isNotNull);
    expect(box.boxShadow, isNotEmpty);
  });

  testWidgets('themed tooltip renders as a hover label', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(600, 320);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });

    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildAppTheme(
          brightness: Brightness.light,
          accent: AppAccent.lime,
        ),
        home: const Scaffold(
          body: Center(
            child: Tooltip(
              message: '在线试听',
              child: SizedBox(
                key: ValueKey('tooltip-anchor'),
                width: 32,
                height: 32,
              ),
            ),
          ),
        ),
      ),
    );

    final anchor = find.byKey(const ValueKey('tooltip-anchor'));
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: const Offset(1, 1));
    await tester.pump();
    await gesture.moveTo(tester.getCenter(anchor));
    await tester.pump(const Duration(milliseconds: 520));

    expect(find.text('在线试听'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await gesture.removePointer();
  });
}
