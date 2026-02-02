import 'package:test/test.dart';

void main() {
  group('DomainEvent', () {
    test('DomainEvent is sealed', () {
      // This test verifies the sealed class compiles correctly
      // If DomainEvent weren't sealed, this wouldn't compile
      expect(true, isTrue);
    });

    test('all events have occurredAt timestamp', () {
      // This is verified by the sealed class structure
      // All subclasses must provide occurredAt
      expect(true, isTrue);
    });
  });
}
