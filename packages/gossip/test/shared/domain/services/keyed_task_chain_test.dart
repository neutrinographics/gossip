import 'dart:async';
import 'package:gossip/src/shared/domain/services/keyed_task_chain.dart';
import 'package:test/test.dart';

void main() {
  group('KeyedTaskChain', () {
    test('tasks with the same key run strictly in order', () async {
      final chain = KeyedTaskChain<String>();
      final log = <int>[];
      final gate = Completer<void>();
      final first = chain.enqueue('k', () async {
        await gate.future;
        log.add(1);
      });
      final second = chain.enqueue('k', () async => log.add(2));
      gate.complete();
      await Future.wait([first, second]);
      expect(log, [1, 2]);
    });

    test('tasks with different keys do not block each other', () async {
      final chain = KeyedTaskChain<String>();
      final gate = Completer<void>();
      // ignore: unawaited_futures
      chain.enqueue('a', () => gate.future);
      final other = await chain
          .enqueue('b', () async => 'ran')
          .timeout(const Duration(seconds: 1));
      expect(other, 'ran');
      gate.complete();
    });

    test('a failed predecessor does not block the chain', () async {
      final chain = KeyedTaskChain<String>();
      final first = chain.enqueue('k', () async => throw StateError('boom'));
      final second = chain.enqueue('k', () async => 42);
      await expectLater(first, throwsStateError);
      expect(await second, 42);
    });

    test('an error surfaces only to its own awaiter', () async {
      final chain = KeyedTaskChain<String>();
      final failing = chain.enqueue('k', () async => throw StateError('boom'));
      final ok = chain.enqueue('k', () async => 'fine');
      // The failing task's error must not become an unhandled async error
      // via the internal chain future — only via `failing` itself.
      await expectLater(failing, throwsStateError);
      expect(await ok, 'fine');
    });

    test('returns the typed result of the task', () async {
      final chain = KeyedTaskChain<int>();
      expect(await chain.enqueue(1, () async => 'typed'), 'typed');
    });

    test('drained keys are cleaned up (no unbounded map growth)', () async {
      final chain = KeyedTaskChain<String>();
      await chain.enqueue('k', () async {});
      await pumpEventQueue();
      expect(chain.pendingKeyCount, 0);
    });

    test('cleanup does not remove a newer chain for the same key', () async {
      final chain = KeyedTaskChain<String>();
      final gate = Completer<void>();
      final first = chain.enqueue('k', () async {});
      final second = chain.enqueue('k', () => gate.future);
      await first;
      await pumpEventQueue();
      expect(
        chain.pendingKeyCount,
        1,
        reason: 'the live second task must keep its chain entry',
      );
      gate.complete();
      await second;
    });

    test('regression: enqueue-await-enqueue does not self-deadlock', () async {
      // Pins the Dart whenComplete self-deadlock class this utility exists
      // to centralize: the returned future must never be the map entry.
      final chain = KeyedTaskChain<String>();
      await chain.enqueue('k', () async {});
      await chain.enqueue('k', () async {}).timeout(const Duration(seconds: 2));
    });
  });
}
