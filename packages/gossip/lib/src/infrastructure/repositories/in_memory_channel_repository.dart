import '../../domain/value_objects/channel_id.dart';
import '../../domain/aggregates/channel_aggregate.dart';
import '../../domain/interfaces/channel_repository.dart';

/// In-memory implementation of [ChannelRepository] for testing.
///
/// This implementation stores channels in a simple [Map] with no persistence.
/// All data is lost when the application terminates.
///
/// **Use only for testing and prototyping.**
///
/// For production applications, implement [ChannelRepository] with persistent
/// storage:
/// - SQLite for mobile/desktop apps
/// - IndexedDB for web apps
/// - Serialize channels to JSON for storage
///
/// All operations complete synchronously but return [Future] to match the
/// repository interface contract.
class InMemoryChannelRepository implements ChannelRepository {
  final Map<ChannelId, ChannelAggregate> _channels = {};

  @override
  Future<ChannelAggregate?> findById(ChannelId id) async => _channels[id];

  @override
  Future<void> save(ChannelAggregate channel) async {
    _channels[channel.id] = channel;
  }

  @override
  Future<void> delete(ChannelId id) async {
    _channels.remove(id);
  }

  @override
  Future<List<ChannelId>> listIds() async => _channels.keys.toList();

  @override
  Future<bool> exists(ChannelId id) async => _channels.containsKey(id);

  @override
  Future<int> get count async => _channels.length;
}
