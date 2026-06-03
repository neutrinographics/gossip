import 'package:flutter_test/flutter_test.dart';
import 'package:gossip_bluey/src/domain/value_objects/connection_mode.dart';

void main() {
  group('ConnectionMode', () {
    test('has the two expected values', () {
      expect(ConnectionMode.values, hasLength(2));
      expect(ConnectionMode.values, contains(ConnectionMode.manual));
      expect(ConnectionMode.values, contains(ConnectionMode.auto));
    });

    test('value names are stable', () {
      expect(ConnectionMode.manual.name, 'manual');
      expect(ConnectionMode.auto.name, 'auto');
    });
  });
}
