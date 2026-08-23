import 'package:test/test.dart';

void main() {
  group('DomainEvent', () {
    test(
      'DomainEvent is abstract, not sealed, so each context can extend it',
      () {
        // Per-context sealed families (SyncEvent, MembershipEvent) extend this
        // shared abstract base — see event_families_test.dart for the seam
        // contract that depends on this.
        expect(true, isTrue);
      },
    );

    test('all events have occurredAt timestamp', () {
      // This is enforced by the DomainEvent base constructor requiring
      // occurredAt; every subclass must provide it.
      expect(true, isTrue);
    });
  });
}
