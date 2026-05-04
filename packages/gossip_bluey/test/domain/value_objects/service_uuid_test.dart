import 'package:flutter_test/flutter_test.dart';
import 'package:gossip_bluey/src/domain/value_objects/service_uuid.dart';

void main() {
  group('ServiceUuid', () {
    test('accepts a well-formed lowercase 128-bit UUID', () {
      final uuid = ServiceUuid('f0000000-0000-0000-0000-000000000000');
      expect(uuid.value, equals('f0000000-0000-0000-0000-000000000000'));
    });

    test('lowercases mixed-case input', () {
      final uuid = ServiceUuid('F0000000-0000-0000-0000-000000000000');
      expect(uuid.value, equals('f0000000-0000-0000-0000-000000000000'));
    });

    test('throws ArgumentError on a malformed UUID', () {
      expect(() => ServiceUuid('not-a-uuid'), throwsArgumentError);
      expect(() => ServiceUuid(''), throwsArgumentError);
      expect(
        () => ServiceUuid('zzzzzzzz-0000-0000-0000-000000000000'),
        throwsArgumentError,
      );
    });

    test('compares by value', () {
      expect(
        ServiceUuid('f0000000-0000-0000-0000-000000000000'),
        equals(ServiceUuid('f0000000-0000-0000-0000-000000000000')),
      );
      expect(
        ServiceUuid('f0000000-0000-0000-0000-000000000000') ==
            ServiceUuid('f0000001-0000-0000-0000-000000000000'),
        isFalse,
      );
    });

    test('hashCode is consistent with equality', () {
      final a = ServiceUuid('f0000000-0000-0000-0000-000000000000');
      final b = ServiceUuid('f0000000-0000-0000-0000-000000000000');
      expect(a.hashCode, equals(b.hashCode));
    });
  });
}
