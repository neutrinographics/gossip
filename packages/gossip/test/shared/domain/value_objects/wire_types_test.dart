import 'package:test/test.dart';
import 'package:gossip/src/shared/domain/value_objects/wire_types.dart';

void main() {
  test('the type-byte partition has no overlaps and covers 0-6', () {
    expect(WireTypes.membership.intersection(WireTypes.sync), isEmpty);
    expect(WireTypes.membership.union(WireTypes.sync), {0, 1, 2, 3, 4, 5, 6});
  });
}
