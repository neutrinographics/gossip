import 'package:test/test.dart';

import 'failure_detector_test_harness.dart';

void main() {
  group('FailureDetector scheduling', () {
    test('start begins periodic probes', () {
      final h = FailureDetectorTestHarness();
      h.detector.start();
      expect(h.detector.isRunning, isTrue);
    });

    test('stop cancels probes', () {
      final h = FailureDetectorTestHarness();
      h.detector.start();
      expect(h.detector.isRunning, isTrue);

      h.detector.stop();
      expect(h.detector.isRunning, isFalse);
    });
  });
}
