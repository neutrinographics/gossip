import 'dart:convert';
import 'dart:typed_data';

import 'package:gossip/gossip.dart';

/// Example demonstrating basic usage of the gossip sync library.
///
/// This example shows how to:
/// 1. Create a coordinator with in-memory storage
/// 2. Create channels and streams
/// 3. Append and read entries
/// 4. Use state materialization
void main() async {
  // 1. Create repositories (use in-memory for this example)
  final channelRepo = InMemoryChannelRepository();
  final peerRepo = InMemoryPeerRepository();
  final entryRepo = InMemoryEntryRepository();

  // 2. Create coordinator
  final coordinator = await Coordinator.create(
    localNode: NodeId('example-device'),
    channelRepository: channelRepo,
    peerRepository: peerRepo,
    entryRepository: entryRepo,
  );

  // 3. Create a channel
  final channel = await coordinator.createChannel(ChannelId('my-channel'));
  print('Created channel: ${channel.id}');

  // 4. Create a stream within the channel
  final stream = await channel.getOrCreateStream(StreamId('messages'));
  print('Created stream: ${stream.id}');

  // 5. Append some entries
  final messages = ['Hello', 'World', 'From Gossip!'];
  for (final message in messages) {
    final payload = Uint8List.fromList(utf8.encode(message));
    await stream.append(payload);
    print('Appended: $message');
  }

  // 6. Read all entries
  final entries = await stream.getAll();
  print('\nAll entries (${entries.length}):');
  for (final entry in entries) {
    final text = utf8.decode(entry.payload);
    print('  - $text (author: ${entry.author}, seq: ${entry.sequence})');
  }

  // 7. Use state materialization to count entries
  await stream.registerMaterializer(_CountMaterializer());
  final count = await stream.getState<int>();
  print('\nMaterialized count: $count');

  // 8. Check health status
  final health = await coordinator.getHealth();
  print('\nHealth status:');
  print('  State: ${health.state}');
  print('  Channels: ${health.resourceUsage.channelCount}');
  print('  Entries: ${health.resourceUsage.totalEntries}');

  // 9. Clean up
  await coordinator.dispose();
  print('\nCoordinator disposed.');
}

/// Simple materializer that counts entries.
class _CountMaterializer implements StateMaterializer<int> {
  @override
  int initial() => 0;

  @override
  int fold(int state, LogEntry entry) => state + 1;
}
