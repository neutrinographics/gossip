import 'package:test/test.dart';
import 'package:gossip/src/domain/errors/domain_exception.dart';

void main() {
  group('DomainException', () {
    test('DomainException contains message', () {
      const exception = DomainException('Something went wrong');

      expect(exception.message, equals('Something went wrong'));
    });

    test('toString includes "DomainException" and message', () {
      const exception = DomainException('Test error');

      expect(exception.toString(), equals('DomainException: Test error'));
    });
  });
}
