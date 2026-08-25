import 'package:gossip/src/shared/domain/errors/sync_error.dart';
import 'package:gossip/src/shared/domain/value_objects/channel_id.dart';
import 'package:gossip/src/shared/domain/value_objects/log_level.dart';
import 'package:gossip/src/shared/domain/value_objects/node_id.dart';
import 'package:test/test.dart';

import '../support/coordinator_builder.dart';

/// Regression tests for audit COR3-3: the Coordinator must wire `onError`
/// into the application services it constructs, so errors they emit reach
/// `coordinator.errors` instead of vanishing (the project's no-silent-errors
/// rule).
void main() {
  group('Coordinator error wiring', () {
    test('ChannelService errors surface on coordinator.errors '
        '(membership op on a removed channel)', () async {
      final coordinator = await createTestCoordinator();
      final channelId = ChannelId('channel1');
      final channel = await coordinator.createChannel(channelId);

      final errors = <SyncError>[];
      final sub = coordinator.errors.listen(errors.add);

      // Remove the channel behind the held facade, then use the stale
      // facade. The service emits a ChannelSyncError; before the fix it
      // went to a null callback and vanished.
      await coordinator.removeChannel(channelId);
      await channel.addMember(NodeId('peer-1'));

      // Let the broadcast stream deliver.
      await Future<void>.delayed(Duration.zero);

      expect(errors, isNotEmpty, reason: 'error should reach the app');
      expect(errors.first, isA<ChannelSyncError>());

      await sub.cancel();
    });

    test(
      'an error surfacing after dispose reaches onLog instead of vanishing',
      () async {
        final logs = <List<Object?>>[];
        final coordinator = await createTestCoordinator(
          onLog: (level, message, [error, stackTrace]) =>
              logs.add([level, message, error, stackTrace]),
        );
        final channelId = ChannelId('channel1');
        final channel = await coordinator.createChannel(channelId);

        // Same real error path as the wiring test above (remove the
        // channel behind the held facade so its next op finds nothing in
        // the repository) — except this time dispose happens first, so
        // the errors stream is already closed when ChannelService.addMember
        // (which has no disposed guard of its own) calls back into
        // Coordinator._handleError.
        await coordinator.removeChannel(channelId);
        // Dispose is the act under test — not builder-teardown cleanup.
        await coordinator.dispose();

        await channel.addMember(NodeId('peer-1'));

        expect(
          logs,
          isNotEmpty,
          reason: 'onLog is the fallback error sink after dispose',
        );
        final logged = logs.first;
        expect(logged[0], LogLevel.error);
        final loggedError = logged[2];
        expect(loggedError, isA<ChannelSyncError>());
        expect((loggedError as ChannelSyncError).message, contains('channel1'));
      },
    );
  });
}
