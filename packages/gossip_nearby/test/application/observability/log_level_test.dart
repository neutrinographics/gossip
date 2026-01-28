import 'package:flutter_test/flutter_test.dart';
import 'package:gossip_nearby/src/application/observability/log_level.dart';

void main() {
  group('LogLevel', () {
    test('has all expected levels', () {
      expect(
        LogLevel.values,
        containsAll([
          LogLevel.trace,
          LogLevel.debug,
          LogLevel.info,
          LogLevel.warning,
          LogLevel.error,
        ]),
      );
    });

    test('levels are ordered from least to most severe', () {
      expect(LogLevel.trace.index, lessThan(LogLevel.debug.index));
      expect(LogLevel.debug.index, lessThan(LogLevel.info.index));
      expect(LogLevel.info.index, lessThan(LogLevel.warning.index));
      expect(LogLevel.warning.index, lessThan(LogLevel.error.index));
    });
  });

  group('LogCallback', () {
    test('can be invoked with just level and message', () {
      LogLevel? capturedLevel;
      String? capturedMessage;

      final LogCallback callback = (level, message, [error, stackTrace]) {
        capturedLevel = level;
        capturedMessage = message;
      };

      callback(LogLevel.info, 'Test message');

      expect(capturedLevel, equals(LogLevel.info));
      expect(capturedMessage, equals('Test message'));
    });

    test('can be invoked with error and stackTrace', () {
      Object? capturedError;
      StackTrace? capturedStack;

      final LogCallback callback = (level, message, [error, stackTrace]) {
        capturedError = error;
        capturedStack = stackTrace;
      };

      final error = Exception('test');
      final stack = StackTrace.current;
      callback(LogLevel.error, 'Error occurred', error, stack);

      expect(capturedError, equals(error));
      expect(capturedStack, equals(stack));
    });
  });
}
