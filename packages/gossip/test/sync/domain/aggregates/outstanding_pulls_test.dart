import 'package:gossip/src/shared/domain/value_objects/rtt_estimate.dart';
import 'package:gossip/src/sync/domain/aggregates/outstanding_pulls.dart';
import 'package:test/test.dart';

/// The one rule the Dart aggregate carries that the Kotlin twin gets for free
/// from its `RttTracking`: the estimate and the evidence behind it are one
/// fact in two fields, and the deadline reads them apart — the cold default
/// from the absent estimate, the first-sample rule from the count — so a
/// value where they disagree would make those two readings contradict.
void main() {
  final measured = RttEstimate.initial();

  test('a value with nothing measured holds no estimate and no sample', () {
    expect(OutstandingPulls.initial.rtt, isNull);
    expect(OutstandingPulls.initial.sampleCount, equals(0));
    expect(OutstandingPulls.initial.hasMeasuredRoundTrip, isFalse);
  });

  test('an estimate without a sample behind it is refused', () {
    expect(
      () => OutstandingPulls(
        requests: const {},
        peers: const {},
        rtt: measured,
        sampleCount: 0,
        nextSequence: 0,
      ),
      throwsArgumentError,
    );
  });

  test('a sample with no estimate to show for it is refused', () {
    expect(
      () => OutstandingPulls(
        requests: const {},
        peers: const {},
        rtt: null,
        sampleCount: 1,
        nextSequence: 0,
      ),
      throwsArgumentError,
    );
  });

  test('an estimate and the samples behind it are accepted together', () {
    final pulls = OutstandingPulls(
      requests: const {},
      peers: const {},
      rtt: measured,
      sampleCount: 1,
      nextSequence: 0,
    );

    expect(pulls.hasMeasuredRoundTrip, isTrue);
  });
}
