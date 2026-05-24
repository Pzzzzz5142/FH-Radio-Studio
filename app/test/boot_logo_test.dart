import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fh_radio_studio/widgets/boot_logo.dart';

void main() {
  testWidgets('BootLogoMark renders the bundled app logo asset', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      await tester.pumpWidget(
        const MaterialApp(home: Center(child: BootLogoMark(size: 30))),
      );
      await tester.pump();

      final image = tester.widget<Image>(find.byType(Image));
      expect(image.image, isA<AssetImage>());
      expect(
        (image.image as AssetImage).assetName,
        'assets/images/app_logo.png',
      );
      expect(tester.getSize(find.byType(Image)), const Size(30, 30));
      expect(tester.takeException(), isNull);
    } finally {
      semantics.dispose();
    }
  });
}
