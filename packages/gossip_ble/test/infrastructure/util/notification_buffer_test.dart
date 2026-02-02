import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gossip_ble/src/infrastructure/util/notification_buffer.dart';

void main() {
  group('NotificationBuffer', () {
    late NotificationBuffer buffer;

    setUp(() {
      buffer = NotificationBuffer();
    });

    test('buffers notification when device setup is in progress', () {
      buffer.markSetupInProgress('device-1');

      final data = Uint8List.fromList([1, 2, 3]);
      final buffered = buffer.bufferIfNeeded('device-1', data);

      expect(buffered, isTrue);
    });

    test('does not buffer when no setup is in progress', () {
      final data = Uint8List.fromList([1, 2, 3]);
      final buffered = buffer.bufferIfNeeded('device-1', data);

      expect(buffered, isFalse);
    });

    test('isSetupInProgress returns correct state', () {
      expect(buffer.isSetupInProgress('device-1'), isFalse);

      buffer.markSetupInProgress('device-1');
      expect(buffer.isSetupInProgress('device-1'), isTrue);

      buffer.markSetupComplete('device-1');
      expect(buffer.isSetupInProgress('device-1'), isFalse);
    });

    test('flushBuffer returns buffered notifications in order', () {
      buffer.markSetupInProgress('device-1');

      buffer.bufferIfNeeded('device-1', Uint8List.fromList([1]));
      buffer.bufferIfNeeded('device-1', Uint8List.fromList([2]));
      buffer.bufferIfNeeded('device-1', Uint8List.fromList([3]));

      final flushed = buffer.flushBuffer('device-1');

      expect(flushed, hasLength(3));
      expect(flushed[0], [1]);
      expect(flushed[1], [2]);
      expect(flushed[2], [3]);
    });

    test('flushBuffer returns empty list if no buffered data', () {
      final flushed = buffer.flushBuffer('device-1');
      expect(flushed, isEmpty);
    });

    test('flushBuffer clears the buffer', () {
      buffer.markSetupInProgress('device-1');
      buffer.bufferIfNeeded('device-1', Uint8List.fromList([1, 2, 3]));

      buffer.flushBuffer('device-1');
      final secondFlush = buffer.flushBuffer('device-1');

      expect(secondFlush, isEmpty);
    });

    test('markSetupComplete clears setup state', () {
      buffer.markSetupInProgress('device-1');
      buffer.markSetupComplete('device-1');

      // Should not buffer anymore
      final data = Uint8List.fromList([1, 2, 3]);
      final buffered = buffer.bufferIfNeeded('device-1', data);

      expect(buffered, isFalse);
    });

    test('clear removes device from tracking', () {
      buffer.markSetupInProgress('device-1');
      buffer.bufferIfNeeded('device-1', Uint8List.fromList([1, 2, 3]));

      buffer.clear('device-1');

      expect(buffer.isSetupInProgress('device-1'), isFalse);
      expect(buffer.flushBuffer('device-1'), isEmpty);
    });

    test('handles multiple devices independently', () {
      buffer.markSetupInProgress('device-1');
      buffer.markSetupInProgress('device-2');

      buffer.bufferIfNeeded('device-1', Uint8List.fromList([1]));
      buffer.bufferIfNeeded('device-2', Uint8List.fromList([2]));

      buffer.markSetupComplete('device-1');

      // Device 1 should not buffer anymore
      expect(
        buffer.bufferIfNeeded('device-1', Uint8List.fromList([3])),
        isFalse,
      );

      // Device 2 should still buffer
      expect(
        buffer.bufferIfNeeded('device-2', Uint8List.fromList([4])),
        isTrue,
      );

      expect(buffer.flushBuffer('device-1'), hasLength(1));
      expect(buffer.flushBuffer('device-2'), hasLength(2));
    });

    test('dispose clears all state', () {
      buffer.markSetupInProgress('device-1');
      buffer.bufferIfNeeded('device-1', Uint8List.fromList([1, 2, 3]));

      buffer.dispose();

      expect(buffer.isSetupInProgress('device-1'), isFalse);
      expect(buffer.flushBuffer('device-1'), isEmpty);
    });
  });
}
