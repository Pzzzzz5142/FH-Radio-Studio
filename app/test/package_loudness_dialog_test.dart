import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:fh_radio_studio/widgets/package_loudness_dialog.dart';

// libmpv `volume` 属性的实际作用：
//   gain = (volume / 100)^3   （player/audio.c::audio_update_volume, commit 652a1dd）
// 所有断言都假设这个曲线；如果未来 mpv 改成线性或别的，这些 expect 会失败，
// 提醒我们重新校正 `previewMpvVolume` 的反推公式。
double _mpvAmplitude(double volume) =>
    math.pow(math.max(volume, 0) / 100.0, 3).toDouble();

double _dbFromAmplitude(double amplitude) =>
    20.0 * math.log(amplitude) / math.ln10;

double _roundTripGainDb({
  required double targetLufs,
  required double inputLufs,
}) {
  final volume = previewMpvVolume(targetLufs: targetLufs, inputLufs: inputLufs);
  return _dbFromAmplitude(_mpvAmplitude(volume));
}

void main() {
  group('previewMpvVolume cubic-inverse', () {
    test('round-trip lands on requested gain within clamp range', () {
      // 输入 input 固定 -20 LUFS，target 扫一圈，确认实际 dB 跟期望差 < 0.05。
      for (final wantedGain in <double>[
        0.0,
        -3.0,
        -6.0,
        -11.6, // user reported case (~-9.4 input, ~-21 target)
        -24.0,
        -40.0,
        8.0,
      ]) {
        final actual = _roundTripGainDb(
          targetLufs: -20.0 + wantedGain,
          inputLufs: -20.0,
        );
        expect(
          actual,
          closeTo(wantedGain, 0.05),
          reason: 'gainDb=$wantedGain 反推失败：实际 ${actual.toStringAsFixed(2)} dB',
        );
      }
    });

    test('user-reported case: -9.4 -> -21 LUFS lands at -11.6 dB', () {
      // 之前 bug：线性公式让 mpv 立方化后衰减 35 dB → -44 LUFS。
      // 立方反推后应回到 -11.6 dB → -21 LUFS。
      expect(
        _roundTripGainDb(targetLufs: -21.0, inputLufs: -9.4),
        closeTo(-11.6, 0.05),
      );
    });

    test('volume value for -11.6 dB sits around 64, not 26', () {
      // 直接锁定 volume 数值，防止以后有人误改回线性公式（线性会给 ~26）。
      final volume = previewMpvVolume(targetLufs: -21.0, inputLufs: -9.4);
      expect(volume, closeTo(64.1, 0.5));
    });

    test('positive gain is clamped to previewVolumeMaxGainDb', () {
      // input 比 target 低很多 → 巨幅 boost 请求，应被截到 +8 dB。
      final actual = _roundTripGainDb(targetLufs: 0.0, inputLufs: -100.0);
      expect(actual, closeTo(previewVolumeMaxGainDb, 0.05));
    });

    test('negative gain is clamped to previewVolumeMinGainDb', () {
      // target 比 input 低很多 → 巨幅衰减请求，应被截到 -48 dB。
      final actual = _roundTripGainDb(targetLufs: -100.0, inputLufs: 0.0);
      expect(actual, closeTo(previewVolumeMinGainDb, 0.05));
    });

    test('non-finite inputs fall back to volume 100 (unity)', () {
      expect(previewMpvVolume(targetLufs: double.nan, inputLufs: -10.0), 100.0);
      expect(
        previewMpvVolume(targetLufs: -10.0, inputLufs: double.infinity),
        100.0,
      );
      expect(
        previewMpvVolume(
          targetLufs: double.negativeInfinity,
          inputLufs: double.nan,
        ),
        100.0,
      );
    });
  });
}
