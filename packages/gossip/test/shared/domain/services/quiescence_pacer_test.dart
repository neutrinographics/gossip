import 'package:test/test.dart';
import 'package:gossip/src/shared/domain/services/quiescence_pacer.dart';

void main() {
  group('QuiescencePacer', () {
    test('applies the base unchanged before any quiet round', () {
      final pacer = QuiescencePacer(ceiling: const Duration(seconds: 30));
      expect(
        pacer.apply(const Duration(seconds: 1)),
        const Duration(seconds: 1),
      );
    });

    test('each quiet round grows the applied interval by 1.5x', () {
      final pacer = QuiescencePacer(ceiling: const Duration(seconds: 30));
      pacer.quietRound();
      expect(
        pacer.apply(const Duration(seconds: 1)),
        const Duration(milliseconds: 1500),
      );
      pacer.quietRound();
      expect(
        pacer.apply(const Duration(seconds: 1)),
        const Duration(milliseconds: 2250),
      );
    });

    test('news snaps the multiplier back to 1', () {
      final pacer = QuiescencePacer(ceiling: const Duration(seconds: 30));
      for (var i = 0; i < 5; i++) {
        pacer.quietRound();
      }
      pacer.news();
      expect(
        pacer.apply(const Duration(seconds: 1)),
        const Duration(seconds: 1),
      );
    });

    test('the applied interval never exceeds the ceiling', () {
      final pacer = QuiescencePacer(ceiling: const Duration(seconds: 30));
      for (var i = 0; i < 20; i++) {
        pacer.quietRound();
      }
      expect(
        pacer.apply(const Duration(seconds: 5)),
        const Duration(seconds: 30),
      );
    });

    test('eternal idleness cannot overflow the multiplier', () {
      final pacer = QuiescencePacer(ceiling: const Duration(seconds: 30));
      for (var i = 0; i < 10000; i++) {
        pacer.quietRound();
      }
      // Still clamps sanely and news still resets.
      expect(
        pacer.apply(const Duration(milliseconds: 100)),
        const Duration(seconds: 30),
      );
      pacer.news();
      expect(
        pacer.apply(const Duration(milliseconds: 100)),
        const Duration(milliseconds: 100),
      );
    });
  });
}
