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
        service.onEntriesMerged(versionVector);

        // Assert
        expect(service.knownAuthors, containsAll([author1, author2]));
      });

      test('should accumulate authors across multiple events', () {
        // Arrange
        final author1 = NodeId('author-1');
        final author2 = NodeId('author-2');
        final author3 = NodeId('author-3');

        // Act
        service.onEntriesMerged(VersionVector({author1: 1}));
        service.onEntriesMerged(VersionVector({author2: 2, author3: 1}));

        // Assert
        expect(service.knownAuthors, containsAll([author1, author2, author3]));
      });

      test('should not duplicate authors', () {
        // Arrange
        final author1 = NodeId('author-1');

        // Act
        service.onEntriesMerged(VersionVector({author1: 1}));
        service.onEntriesMerged(VersionVector({author1: 5}));

        // Assert
        expect(service.knownAuthors.length, 1);
        expect(service.knownAuthors, contains(author1));
      });

      test('should exclude local node from known authors', () {
        // Arrange
        final remoteAuthor = NodeId('remote-author');
        final versionVector = VersionVector({localNodeId: 5, remoteAuthor: 3});

        // Act
        service.onEntriesMerged(versionVector);

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
        service.onEntriesMerged(VersionVector({peer1: 1, peer2: 2}));

        // Act
        final result = service.getIndirectPeers(directPeerIds: {peer1, peer2});

        // Assert
        expect(result, isEmpty);
      });

      test('should return all authors when no direct peers', () {
        // Arrange
        final author1 = NodeId('author-1');
        final author2 = NodeId('author-2');
        service.onEntriesMerged(VersionVector({author1: 1, author2: 2}));

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
        service.onEntriesMerged(VersionVector({author: 1}));
        expect(service.knownAuthors, isNotEmpty);

        // Act
        service.clear();

        // Assert
        expect(service.knownAuthors, isEmpty);
      });
    });
  });
}
