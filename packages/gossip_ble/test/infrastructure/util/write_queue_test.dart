import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:gossip_ble/src/infrastructure/util/write_queue.dart';

void main() {
  group('WriteQueue', () {
    late WriteQueue queue;

    setUp(() {
      queue = WriteQueue();
    });

    tearDown(() {
      queue.dispose();
    });

    test('executes single write immediately', () async {
      var executed = false;

      await queue.enqueue('device-1', () async {
        executed = true;
      });

      expect(executed, isTrue);
    });

    test('serializes writes to the same device', () async {
      final executionOrder = <int>[];
      final completer1 = Completer<void>();

      // Start first write but don't complete it yet
      final future1 = queue.enqueue('device-1', () async {
        executionOrder.add(1);
        await completer1.future;
      });

      // Second write should wait
      final future2 = queue.enqueue('device-1', () async {
        executionOrder.add(2);
      });

      // Give time for second write to be queued
      await Future<void>.delayed(const Duration(milliseconds: 10));

      // Only first should have started
      expect(executionOrder, [1]);

      // Complete first write
      completer1.complete();
      await future1;
      await future2;

      // Now both should have executed in order
      expect(executionOrder, [1, 2]);
    });

    test('allows parallel writes to different devices', () async {
      final completer1 = Completer<void>();
      final completer2 = Completer<void>();
      var write1Started = false;
      var write2Started = false;

      // Start writes to two different devices
      unawaited(
        queue.enqueue('device-1', () async {
          write1Started = true;
          await completer1.future;
        }),
      );

      unawaited(
        queue.enqueue('device-2', () async {
          write2Started = true;
          await completer2.future;
        }),
      );

      // Give time for both to start
      await Future<void>.delayed(const Duration(milliseconds: 10));

      // Both should have started (parallel execution)
      expect(write1Started, isTrue);
      expect(write2Started, isTrue);

      // Clean up
      completer1.complete();
      completer2.complete();
    });

    test('propagates errors from write operation', () async {
      expect(
        () => queue.enqueue('device-1', () async {
          throw Exception('Write failed');
        }),
        throwsException,
      );
    });

    test('continues processing after error', () async {
      // First write fails
      try {
        await queue.enqueue('device-1', () async {
          throw Exception('Write failed');
        });
      } catch (_) {}

      // Second write should still work
      var executed = false;
      await queue.enqueue('device-1', () async {
        executed = true;
      });

      expect(executed, isTrue);
    });

    test('clear removes pending writes for a device', () async {
      final completer = Completer<void>();
      var secondWriteExecuted = false;

      // Start first write
      unawaited(
        queue.enqueue('device-1', () async {
          await completer.future;
        }),
      );

      // Queue second write
      final future2 = queue.enqueue('device-1', () async {
        secondWriteExecuted = true;
      });

      // Clear the device queue
      queue.clear('device-1');

      // Complete the first write
      completer.complete();

      // The second write's future should complete (possibly with cancellation)
      // but the callback should not execute
      try {
        await future2;
      } catch (_) {
        // May throw if cancelled
      }

      // Give some time
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(secondWriteExecuted, isFalse);
    });
  });
}
