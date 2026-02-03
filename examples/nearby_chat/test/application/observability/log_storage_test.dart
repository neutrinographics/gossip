import 'package:flutter_test/flutter_test.dart';

import 'package:nearby_chat/application/observability/log_storage.dart';

void main() {
  group('LogStorage', () {
    late LogStorage storage;

    setUp(() {
      storage = LogStorage(maxEntries: 100);
    });

    group('append', () {
      test('should store log entries', () {
        storage.append('TEST', 'Hello world');

        final entries = storage.entries;
        expect(entries, hasLength(1));
        expect(entries.first.category, 'TEST');
        expect(entries.first.message, 'Hello world');
      });

      test('should store timestamp with each entry', () {
        final before = DateTime.now();
        storage.append('TEST', 'Message');
        final after = DateTime.now();

        final entry = storage.entries.first;
        expect(
          entry.timestamp.isAfter(before) || entry.timestamp == before,
          isTrue,
        );
        expect(
          entry.timestamp.isBefore(after) || entry.timestamp == after,
          isTrue,
        );
      });

      test('should store multiple entries in order', () {
        storage.append('A', 'First');
        storage.append('B', 'Second');
        storage.append('C', 'Third');

        final entries = storage.entries;
        expect(entries, hasLength(3));
        expect(entries[0].message, 'First');
        expect(entries[1].message, 'Second');
        expect(entries[2].message, 'Third');
      });

      test('should evict oldest entries when max is exceeded', () {
        final smallStorage = LogStorage(maxEntries: 3);

        smallStorage.append('A', 'One');
        smallStorage.append('B', 'Two');
        smallStorage.append('C', 'Three');
        smallStorage.append('D', 'Four');

        final entries = smallStorage.entries;
        expect(entries, hasLength(3));
        expect(entries[0].message, 'Two');
        expect(entries[1].message, 'Three');
        expect(entries[2].message, 'Four');
      });
    });

    group('clear', () {
      test('should remove all entries', () {
        storage.append('A', 'One');
        storage.append('B', 'Two');
        expect(storage.entries, hasLength(2));

        storage.clear();

        expect(storage.entries, isEmpty);
      });
    });

    group('export', () {
      test('should export entries as formatted text', () {
        storage.append('TEST', 'Hello');
        storage.append('SYNC', 'World');

        final exported = storage.export();

        expect(exported, contains('[TEST] Hello'));
        expect(exported, contains('[SYNC] World'));
      });

      test('should include timestamps in export', () {
        storage.append('TEST', 'Message');

        final exported = storage.export();

        // Should have timestamp format like [HH:mm:ss.SSS]
        expect(exported, matches(RegExp(r'\[\d{2}:\d{2}:\d{2}\.\d{3}\]')));
      });

      test('should export entries in chronological order', () {
        storage.append('A', 'First');
        storage.append('B', 'Second');
        storage.append('C', 'Third');

        final exported = storage.export();
        final firstIndex = exported.indexOf('First');
        final secondIndex = exported.indexOf('Second');
        final thirdIndex = exported.indexOf('Third');

        expect(firstIndex, lessThan(secondIndex));
        expect(secondIndex, lessThan(thirdIndex));
      });

      test('should return empty string when no entries', () {
        final exported = storage.export();
        expect(exported, isEmpty);
      });
    });

    group('exportSince', () {
      test('should export only entries after given time', () async {
        storage.append('A', 'Before');
        await Future.delayed(const Duration(milliseconds: 10));
        final cutoff = DateTime.now();
        await Future.delayed(const Duration(milliseconds: 10));
        storage.append('B', 'After');

        final exported = storage.exportSince(cutoff);

        expect(exported, isNot(contains('Before')));
        expect(exported, contains('After'));
      });

      test('should return empty when all entries are before cutoff', () {
        storage.append('A', 'Old');
        final future = DateTime.now().add(const Duration(hours: 1));

        final exported = storage.exportSince(future);

        expect(exported, isEmpty);
      });
    });

    group('entryCount', () {
      test('should return number of entries', () {
        expect(storage.entryCount, 0);

        storage.append('A', 'One');
        expect(storage.entryCount, 1);

        storage.append('B', 'Two');
        expect(storage.entryCount, 2);
      });
    });
  });

  group('LogEntry', () {
    test('should format as string correctly', () {
      final timestamp = DateTime(2024, 1, 15, 10, 30, 45, 123);
      final entry = LogEntry(
        timestamp: timestamp,
        category: 'TEST',
        message: 'Hello world',
      );

      final formatted = entry.format();

      expect(formatted, '[10:30:45.123][TEST] Hello world');
    });
  });
}
