import 'package:bluey/bluey.dart';

import '../../domain/value_objects/gossip_characteristic_uuids.dart';
import '../../domain/value_objects/service_uuid.dart';

/// Builds the [HostedService] that registers the gossip data
/// characteristic with bluey's GATT server.
///
/// The data characteristic supports both write-without-response (centrals
/// push data to us) and notify (we push data to subscribed centrals).
class GossipGattService {
  static HostedService build(ServiceUuid serviceUuid) {
    final uuids = GossipCharacteristicUuids.derive(serviceUuid);
    return HostedService(
      uuid: UUID(serviceUuid.value),
      characteristics: [
        HostedCharacteristic(
          uuid: UUID(uuids.dataCharacteristic),
          properties: const CharacteristicProperties(
            canWriteWithoutResponse: true,
            canNotify: true,
          ),
          permissions: const [GattPermission.write],
        ),
      ],
    );
  }
}
