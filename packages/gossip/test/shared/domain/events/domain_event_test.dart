import 'package:test/test.dart';
import 'package:gossip/gossip.dart';

// All events have an occurredAt timestamp: this is enforced by the
// DomainEvent base constructor requiring it, not by a runtime assertion
// here — every subclass must provide it to compile.
void main() {
  group('DomainEvent', () {
    test(
      'DomainEvent is abstract, not sealed, so each context can extend it',
      () {
        // Per-context sealed families (SyncEvent, MembershipEvent) extend this
        // shared abstract base — see event_families_test.dart for the seam
        // contract that depends on this.
        //
        // The real guarantee is that _TestEvent, declared below in this test
        // library (not domain_event.dart's library), extends DomainEvent
        // successfully. That fails to COMPILE if DomainEvent is ever changed
        // to `sealed` or `final`, either of which would restrict extension
        // to subclasses declared in the same library as DomainEvent itself.
        final event = _TestEvent(occurredAt: DateTime(2024, 1, 1));
        expect(event, isA<DomainEvent>());
      },
    );
  });
}

class _TestEvent extends DomainEvent {
  _TestEvent({required super.occurredAt});
}
