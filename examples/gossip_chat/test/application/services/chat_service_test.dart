import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gossip/gossip.dart';
import 'package:gossip_chat/application/services/chat_service.dart';
import 'package:gossip_chat/domain/entities/typing_event.dart';
import 'package:gossip_chat/domain/entities/channel_metadata.dart';
import 'package:gossip_chat/infrastructure/codecs/typing_event_codec.dart';
import 'package:gossip_chat/infrastructure/codecs/channel_metadata_codec.dart';

void main() {
  group('ChatService', () {
    late Coordinator coordinator;
    late ChatService chatService;
    late NodeId localNodeId;
    final displayName = 'TestUser';

    setUp(() async {
      localNodeId = NodeId('test-node-123');

      // Create a real Coordinator with in-memory repositories for testing
      final messageBus = InMemoryMessageBus();
      coordinator = await Coordinator.create(
        localNode: localNodeId,
        channelRepository: InMemoryChannelRepository(),
        peerRepository: InMemoryPeerRepository(),
        entryRepository: InMemoryEntryRepository(),
        messagePort: InMemoryMessagePort(localNodeId, messageBus),
        timerPort: InMemoryTimePort(),
      );

      chatService = ChatService(
        coordinator: coordinator,
        localNodeId: localNodeId,
        displayName: displayName,
      );
    });

    tearDown(() async {
      await coordinator.dispose();
    });

    group('createChannel', () {
      test('should create a channel with metadata and streams', () async {
        // Act
        final channelId = await chatService.createChannel('General');

        // Assert
        expect(chatService.channelIds, contains(channelId));

        final metadata = await chatService.getChannelMetadata(channelId);
        expect(metadata, isNotNull);
        expect(metadata!.name, 'General');
        expect(metadata.createdAt, isNotNull);

        // Verify streams exist
        final channel = coordinator.getChannel(channelId);
        expect(channel, isNotNull);
        expect(channel!.getStream(StreamIds.messages), isNotNull);
        expect(channel.getStream(StreamIds.presence), isNotNull);
        expect(channel.getStream(StreamIds.metadata), isNotNull);
      });

      test('should create multiple channels', () async {
        // Act
        final channel1 = await chatService.createChannel('General');
        final channel2 = await chatService.createChannel('Random');

        // Assert
        expect(chatService.channelIds.length, 2);
        expect(chatService.channelIds, containsAll([channel1, channel2]));

        final metadata1 = await chatService.getChannelMetadata(channel1);
        final metadata2 = await chatService.getChannelMetadata(channel2);
        expect(metadata1!.name, 'General');
        expect(metadata2!.name, 'Random');
      });
    });

    group('joinChannel', () {
      test('should join an existing channel', () async {
        // Arrange - Create channel with one instance
        final channelId = ChannelId('shared-channel');
        await chatService.joinChannel(channelId);

        // Assert
        expect(chatService.channelIds, contains(channelId));

        final channel = coordinator.getChannel(channelId);
        expect(channel, isNotNull);
      });
    });

    group('leaveChannel', () {
      test('should remove a channel', () async {
        // Arrange
        final channelId = await chatService.createChannel('ToLeave');
        expect(chatService.channelIds, contains(channelId));

        // Act
        await chatService.leaveChannel(channelId);

        // Assert
        expect(chatService.channelIds, isNot(contains(channelId)));
      });
    });

    group('sendMessage', () {
      test('should send a message to a channel', () async {
        // Arrange
        final channelId = await chatService.createChannel('Chat');

        // Act
        await chatService.sendMessage(channelId, 'Hello, World!');

        // Assert
        final messages = await chatService.getMessages(channelId);
        expect(messages.length, 1);
        expect(messages[0].text, 'Hello, World!');
        expect(messages[0].senderName, displayName);
        expect(messages[0].senderNode, localNodeId);
      });

      test('should send multiple messages in order', () async {
        // Arrange
        final channelId = await chatService.createChannel('Chat');

        // Act
        await chatService.sendMessage(channelId, 'First');
        await chatService.sendMessage(channelId, 'Second');
        await chatService.sendMessage(channelId, 'Third');

        // Assert
        final messages = await chatService.getMessages(channelId);
        expect(messages.length, 3);
        expect(messages[0].text, 'First');
        expect(messages[1].text, 'Second');
        expect(messages[2].text, 'Third');
      });

      test('should generate unique message IDs', () async {
        // Arrange
        final channelId = await chatService.createChannel('Chat');

        // Act
        await chatService.sendMessage(channelId, 'Message 1');
        await chatService.sendMessage(channelId, 'Message 2');

        // Assert
        final messages = await chatService.getMessages(channelId);
        expect(messages[0].id, isNot(messages[1].id));
      });
    });

    group('getMessages', () {
      test('should return empty list for channel with no messages', () async {
        // Arrange
        final channelId = await chatService.createChannel('Empty');

        // Act
        final messages = await chatService.getMessages(channelId);

        // Assert
        expect(messages, isEmpty);
      });

      test('should return empty list for non-existent channel', () async {
        // Arrange
        final nonExistentId = ChannelId('does-not-exist');

        // Act
        final messages = await chatService.getMessages(nonExistentId);

        // Assert
        expect(messages, isEmpty);
      });

      test('should skip malformed message payloads', () async {
        // Arrange
        final channelId = await chatService.createChannel('Mixed');
        await chatService.sendMessage(channelId, 'Valid message');

        // Manually append a malformed entry
        final channel = coordinator.getChannel(channelId)!;
        final messageStream = channel.getStream(StreamIds.messages);
        await messageStream.append(Uint8List.fromList([0xFF, 0xFE]));

        // Act
        final messages = await chatService.getMessages(channelId);

        // Assert - Should only get the valid message
        expect(messages.length, 1);
        expect(messages[0].text, 'Valid message');
      });
    });

    group('setTyping and getTypingUsers', () {
      test('should set and retrieve typing state', () async {
        // Arrange
        final channelId = await chatService.createChannel('Chat');

        // Act
        await chatService.setTyping(channelId, true);

        // Assert
        final typingUsers = await chatService.getTypingUsers(channelId);
        expect(typingUsers, isEmpty); // Local user excluded from typing list
      });

      test('should filter expired typing events', () async {
        // Arrange
        final channelId = await chatService.createChannel('Chat');
        final channel = coordinator.getChannel(channelId)!;
        final presenceStream = channel.getStream(StreamIds.presence);

        // Manually add an old typing event (more than 5 seconds ago)
        final oldTimestamp = DateTime.now().subtract(
          const Duration(seconds: 10),
        );
        final oldEvent = TypingEvent(
          senderNode: NodeId('other-node'),
          senderName: 'OtherUser',
          isTyping: true,
          timestamp: oldTimestamp,
        );

        // Use the codec to encode
        final codec =
            const TypingEventCodec(); // Import from infrastructure if needed
        await presenceStream.append(codec.encode(oldEvent));

        // Act
        final typingUsers = await chatService.getTypingUsers(channelId);

        // Assert - Expired event should be filtered out
        expect(typingUsers, isEmpty);
      });

      test('should exclude local user from typing users', () async {
        // Arrange
        final channelId = await chatService.createChannel('Chat');

        // Act
        await chatService.setTyping(channelId, true);
        final typingUsers = await chatService.getTypingUsers(channelId);

        // Assert
        expect(typingUsers.keys, isNot(contains(localNodeId)));
      });

      test('should filter out isTyping=false events', () async {
        // Arrange
        final channelId = await chatService.createChannel('Chat');
        final channel = coordinator.getChannel(channelId)!;
        final presenceStream = channel.getStream(StreamIds.presence);

        // Add a typing event with isTyping=false
        final notTypingEvent = TypingEvent(
          senderNode: NodeId('other-node'),
          senderName: 'OtherUser',
          isTyping: false,
          timestamp: DateTime.now(),
        );

        final codec = const TypingEventCodec();
        await presenceStream.append(codec.encode(notTypingEvent));

        // Act
        final typingUsers = await chatService.getTypingUsers(channelId);

        // Assert
        expect(typingUsers, isEmpty);
      });
    });

    group('getChannelMetadata', () {
      test('should return null for non-existent channel', () async {
        // Arrange
        final nonExistentId = ChannelId('does-not-exist');

        // Act
        final metadata = await chatService.getChannelMetadata(nonExistentId);

        // Assert
        expect(metadata, isNull);
      });

      test('should return null for channel with no metadata', () async {
        // Arrange - Join channel without creating metadata
        final channelId = ChannelId('no-metadata');
        await chatService.joinChannel(channelId);

        // Act
        final metadata = await chatService.getChannelMetadata(channelId);

        // Assert
        expect(metadata, isNull);
      });

      test('should return most recent metadata when multiple exist', () async {
        // Arrange
        final channelId = await chatService.createChannel('Original Name');

        // Manually update metadata by appending a new one
        final channel = coordinator.getChannel(channelId)!;
        final metadataStream = channel.getStream(StreamIds.metadata);
        final updatedMetadata = ChannelMetadata(
          name: 'Updated Name',
          createdAt: DateTime.now(),
        );
        final codec = const ChannelMetadataCodec();
        await metadataStream.append(codec.encode(updatedMetadata));

        // Act
        final metadata = await chatService.getChannelMetadata(channelId);

        // Assert - Should get the most recent one
        expect(metadata, isNotNull);
        expect(metadata!.name, 'Updated Name');
      });
    });

    group('error callback', () {
      test('should invoke error callback on channel not found', () async {
        // Arrange
        String? errorOperation;
        Object? errorObject;

        final serviceWithCallback = ChatService(
          coordinator: coordinator,
          localNodeId: localNodeId,
          displayName: displayName,
          onError: (operation, error) {
            errorOperation = operation;
            errorObject = error;
          },
        );

        final nonExistentChannel = ChannelId('does-not-exist');

        // Act & Assert
        await expectLater(
          () => serviceWithCallback.sendMessage(nonExistentChannel, 'Test'),
          throwsStateError,
        );
        expect(errorOperation, 'sendMessage');
        expect(errorObject.toString(), contains('Channel not found'));
      });
    });

    group('localNodeId', () {
      test('should expose local node ID', () {
        // Assert
        expect(chatService.localNodeId, localNodeId);
      });
    });
  });
}
