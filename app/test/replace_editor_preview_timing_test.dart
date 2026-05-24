import 'package:flutter_test/flutter_test.dart';
import 'package:fh_radio_studio/screens/replace_editor/replace_editor.dart';

void main() {
  test('drop point preview starts exactly at the candidate marker', () {
    final window = pointPreviewWindowForTesting(
      timeSec: 68.72,
      durationSec: 180,
    );

    expect(window.start, 68.72);
    expect(window.end, moreOrLessEquals(74.72));
  });

  test('drop point preview clamps to the track duration', () {
    final late = pointPreviewWindowForTesting(timeSec: 179, durationSec: 180);
    final beyondEnd = pointPreviewWindowForTesting(
      timeSec: 200,
      durationSec: 180,
    );

    expect(late.start, 179);
    expect(late.end, 180);
    expect(beyondEnd.start, 180);
    expect(beyondEnd.end, 180);
  });

  test('loop preview keeps the end-to-start seam lead-in', () {
    expect(loopPreviewAuditionStartForTesting(startSec: 32, endSec: 64), 62);
    expect(loopPreviewAuditionStartForTesting(startSec: 63, endSec: 64), 63);
  });

  test('preview startup ignores stale zero position events', () {
    expect(
      isStalePreviewStartupPositionForTesting(positionSec: 0, targetSec: 68.72),
      isTrue,
    );
    expect(
      isStalePreviewStartupPositionForTesting(
        positionSec: 68.5,
        targetSec: 68.72,
      ),
      isFalse,
    );
  });
}
