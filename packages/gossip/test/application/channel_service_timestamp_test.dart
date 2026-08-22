import 'package:gossip/src/application/services/channel_service.dart';
import 'package:gossip/src/domain/services/hlc_clock.dart';
import 'package:gossip/src/shared/domain/services/time_source.dart';
import 'package:gossip/src/shared/domain/value_objects/hlc.dart';
import 'package:gossip/src/shared/domain/value_objects/node_id.dart';
import 'package:gossip/src/shared/infrastructure/in_memory_time_port.dart';
import 'package:gossip/src/shared/infrastructure/in_memory_local_node_repository.dart';
import 'package:test/test.dart';

void main() {
  group('ChannelService.takeTimestamp', () {
    test('advances the HLC and persists the clock state', () async {
      final localNode = NodeId('local');
      final timePort = InMemoryTimePort();
      await timePort.advance(const Duration(seconds: 5));
      final clock = HlcClock(TimeSource(timePort));
      final localNodeRepository = InMemoryLocalNodeRepository(
        nodeId: localNode,
      );
      final service = ChannelService(
        localNode: localNode,
        localNodeRepository: localNodeRepository,
        hlcClock: clock,
      );

      final timestamp = await service.takeTimestamp();

      expect(timestamp, isNot(equals(Hlc.zero)));
      expect(
        await localNodeRepository.getClockState(),
        equals(clock.current),
        reason:
            'advancing the clock without persisting means a crash restores '
            'an older clock than external observers already saw',
      );
    });
  });
}
