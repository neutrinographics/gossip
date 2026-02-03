import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gossip/gossip.dart';

import 'package:nearby_chat/application/services/indirect_peer_service.dart';

void main() {
  group('IndirectPeerService', () {
    late IndirectPeerService service;
    late NodeId localNodeId;

    setUp(() {
      localNodeId = NodeId('local-node');
      service = IndirectPeerService(localNodeId: localNodeId);
    });

    LogEntry _createEntry(NodeId author, int physicalMs) {
      return LogEntry(
        author: author,
        sequence: 1,
        timestamp: Hlc(physicalMs, 0),
        payload: Uint8List(0),
      );
    }

    group('initial state', () {
      test('should have no known authors initially', () {
        expect(service.knownAuthors, isEmpty);
      });

      test('should have no indirect peers initially', () {
        expect(service.getIndirectPeers(directPeerIds: {}), isEmpty);
      });
    });

    group('onEntriesMerged', () {
      test('should track authors from version vector', () {
        // Arrange
        final author1 = NodeId('author-1');
        final author2 = NodeId('author-2');
        final versionVector = VersionVector({author1: 1, author2: 3});

        // Act
        service.onEntriesMerged(versionVector, []);

        // Assert
        expect(service.knownAuthors, containsAll([author1, author2]));
      });

      test('should accumulate authors across multiple events', () {
        // Arrange
        final author1 = NodeId('author-1');
        final author2 = NodeId('author-2');
        final author3 = NodeId('author-3');

        // Act
        service.onEntriesMerged(VersionVector({author1: 1}), []);
        service.onEntriesMerged(VersionVector({author2: 2, author3: 1}), []);

        // Assert
        expect(service.knownAuthors, containsAll([author1, author2, author3]));
      });

      test('should not duplicate authors', () {
        // Arrange
        final author1 = NodeId('author-1');

        // Act
        service.onEntriesMerged(VersionVector({author1: 1}), []);
        service.onEntriesMerged(VersionVector({author1: 5}), []);

        // Assert
        expect(service.knownAuthors.length, 1);
        expect(service.knownAuthors, contains(author1));
      });

      test('should exclude local node from known authors', () {
        // Arrange
        final remoteAuthor = NodeId('remote-author');
        final versionVector = VersionVector({localNodeId: 5, remoteAuthor: 3});

        // Act
        service.onEntriesMerged(versionVector, []);

        // Assert
        expect(service.knownAuthors, isNot(contains(localNodeId)));
        expect(service.knownAuthors, contains(remoteAuthor));
      });
    });

    group('getIndirectPeers', () {
      test('should return authors that are not direct peers', () {
        // Arrange
        final directPeer = NodeId('direct-peer');
        final indirectPeer = NodeId('indirect-peer');
        service.onEntriesMerged(
          VersionVector({directPeer: 1, indirectPeer: 2}),
          [],
        );

        // Act
        final result = service.getIndirectPeers(directPeerIds: {directPeer});

        // Assert
        expect(result, contains(indirectPeer));
        expect(result, isNot(contains(directPeer)));
      });

      test('should return empty set when all authors are direct peers', () {
        // Arrange
        final peer1 = NodeId('peer-1');
        final peer2 = NodeId('peer-2');
        service.onEntriesMerged(VersionVector({peer1: 1, peer2: 2}), []);

        // Act
        final result = service.getIndirectPeers(directPeerIds: {peer1, peer2});

        // Assert
        expect(result, isEmpty);
      });

      test('should return all authors when no direct peers', () {
        // Arrange
        final author1 = NodeId('author-1');
        final author2 = NodeId('author-2');
        service.onEntriesMerged(VersionVector({author1: 1, author2: 2}), []);

        // Act
        final result = service.getIndirectPeers(directPeerIds: {});

        // Assert
        expect(result, containsAll([author1, author2]));
      });

      test('should not include local node in indirect peers', () {
        // Arrange
        final remoteAuthor = NodeId('remote-author');
        service.onEntriesMerged(
          VersionVector({localNodeId: 5, remoteAuthor: 3}),
          [],
        );

        // Act
        final result = service.getIndirectPeers(directPeerIds: {});

        // Assert
        expect(result, isNot(contains(localNodeId)));
        expect(result, contains(remoteAuthor));
      });
    });

    group('clear', () {
      test('should remove all tracked authors', () {
        // Arrange
        final author = NodeId('author-1');
        service.onEntriesMerged(VersionVector({author: 1}), []);
        expect(service.knownAuthors, isNotEmpty);

        // Act
        service.clear();

        // Assert
        expect(service.knownAuthors, isEmpty);
      });

      test('should clear last seen timestamps', () {
        // Arrange
        final author = NodeId('author-1');
        final now = DateTime.now().millisecondsSinceEpoch;
        service.onEntriesMerged(VersionVector({author: 1}), [
          _createEntry(author, now),
        ]);
        expect(service.getLastSeenAt(author), isNotNull);

        // Act
        service.clear();

        // Assert
        expect(service.getLastSeenAt(author), isNull);
      });
    });

    group('last seen tracking', () {
      test('should track last seen timestamp from entries', () {
        // Arrange
        final author = NodeId('author-1');
        final timestamp = DateTime.now().millisecondsSinceEpoch;

        // Act
        service.onEntriesMerged(VersionVector({author: 1}), [
          _createEntry(author, timestamp),
        ]);

        // Assert
        final lastSeen = service.getLastSeenAt(author);
        expect(lastSeen, isNotNull);
        expect(lastSeen!.millisecondsSinceEpoch, timestamp);
      });

      test('should update to most recent timestamp', () {
        // Arrange
        final author = NodeId('author-1');
        final olderTime = DateTime.now().millisecondsSinceEpoch - 10000;
        final newerTime = DateTime.now().millisecondsSinceEpoch;

        // Act
        service.onEntriesMerged(VersionVector({author: 1}), [
          _createEntry(author, olderTime),
        ]);
        service.onEntriesMerged(VersionVector({author: 2}), [
          _createEntry(author, newerTime),
        ]);

        // Assert
        final lastSeen = service.getLastSeenAt(author);
        expect(lastSeen!.millisecondsSinceEpoch, newerTime);
      });

      test('should not update to older timestamp', () {
        // Arrange
        final author = NodeId('author-1');
        final newerTime = DateTime.now().millisecondsSinceEpoch;
        final olderTime = newerTime - 10000;

        // Act
        service.onEntriesMerged(VersionVector({author: 1}), [
          _createEntry(author, newerTime),
        ]);
        service.onEntriesMerged(VersionVector({author: 2}), [
          _createEntry(author, olderTime),
        ]);

        // Assert
        final lastSeen = service.getLastSeenAt(author);
        expect(lastSeen!.millisecondsSinceEpoch, newerTime);
      });

      test('should track multiple authors independently', () {
        // Arrange
        final author1 = NodeId('author-1');
        final author2 = NodeId('author-2');
        final time1 = DateTime.now().millisecondsSinceEpoch - 5000;
        final time2 = DateTime.now().millisecondsSinceEpoch;

        // Act
        service.onEntriesMerged(VersionVector({author1: 1, author2: 1}), [
          _createEntry(author1, time1),
          _createEntry(author2, time2),
        ]);

        // Assert
        expect(service.getLastSeenAt(author1)!.millisecondsSinceEpoch, time1);
        expect(service.getLastSeenAt(author2)!.millisecondsSinceEpoch, time2);
      });

      test('should not track local node timestamps', () {
        // Arrange
        final now = DateTime.now().millisecondsSinceEpoch;

        // Act
        service.onEntriesMerged(VersionVector({localNodeId: 1}), [
          _createEntry(localNodeId, now),
        ]);

        // Assert
        expect(service.getLastSeenAt(localNodeId), isNull);
      });

      test('should return null for unknown author', () {
        // Arrange
        final unknownAuthor = NodeId('unknown');

        // Assert
        expect(service.getLastSeenAt(unknownAuthor), isNull);
      });
    });

    group('getActivityStatus', () {
      test('should return active for entries within 15 seconds', () {
        // Arrange
        final author = NodeId('author-1');
        final now = DateTime.now();
        final recentTime = now.subtract(const Duration(seconds: 10));

        service.onEntriesMerged(VersionVector({author: 1}), [
          _createEntry(author, recentTime.millisecondsSinceEpoch),
        ]);

        // Act
        final status = service.getActivityStatus(author, now: now);

        // Assert
        expect(status, IndirectPeerActivityStatus.active);
      });

      test('should return recent for entries within 1 minute', () {
        // Arrange
        final author = NodeId('author-1');
        final now = DateTime.now();
        final time = now.subtract(const Duration(seconds: 30));

        service.onEntriesMerged(VersionVector({author: 1}), [
          _createEntry(author, time.millisecondsSinceEpoch),
        ]);

        // Act
        final status = service.getActivityStatus(author, now: now);

        // Assert
        expect(status, IndirectPeerActivityStatus.recent);
      });

      test('should return away for entries within 5 minutes', () {
        // Arrange
        final author = NodeId('author-1');
        final now = DateTime.now();
        final time = now.subtract(const Duration(minutes: 3));

        service.onEntriesMerged(VersionVector({author: 1}), [
          _createEntry(author, time.millisecondsSinceEpoch),
        ]);

        // Act
        final status = service.getActivityStatus(author, now: now);

        // Assert
        expect(status, IndirectPeerActivityStatus.away);
      });

      test('should return stale for entries older than 5 minutes', () {
        // Arrange
        final author = NodeId('author-1');
        final now = DateTime.now();
        final time = now.subtract(const Duration(minutes: 10));

        service.onEntriesMerged(VersionVector({author: 1}), [
          _createEntry(author, time.millisecondsSinceEpoch),
        ]);

        // Act
        final status = service.getActivityStatus(author, now: now);

        // Assert
        expect(status, IndirectPeerActivityStatus.stale);
      });

      test('should return unknown for untracked author', () {
        // Arrange
        final unknownAuthor = NodeId('unknown');

        // Act
        final status = service.getActivityStatus(unknownAuthor);

        // Assert
        expect(status, IndirectPeerActivityStatus.unknown);
      });
    });
  });
}
