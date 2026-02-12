import '../../domain/aggregates/channel_aggregate.dart';
import '../../domain/interfaces/channel_repository.dart';
import '../../domain/value_objects/channel_id.dart';

/// A [ChannelRepository] decorator that maintains an in-memory identity map
/// over a persistent backing repository.
///
/// The gossip engine holds references to [ChannelAggregate] objects and expects
/// mutations (e.g. stream creation via [ChannelService]) to be visible on those
/// same references. Persistent repositories that deserialize new objects on
/// each [findById] call break this assumption.
///
/// [CachingChannelRepository] solves this by caching aggregates in memory:
/// - [findById] returns the cached reference if available, otherwise loads
///   from the inner repository and caches it.
/// - [save] updates the cache and writes through to the inner repository.
/// - [delete] removes from both cache and inner repository.
///
/// This is wired up automatically by [Coordinator.create], so consuming
/// applications don't need to use this class directly.
class CachingChannelRepository implements ChannelRepository {
  final ChannelRepository _inner;
  final Map<ChannelId, ChannelAggregate> _cache = {};

  CachingChannelRepository(this._inner);

  @override
  Future<ChannelAggregate?> findById(ChannelId id) async {
    final cached = _cache[id];
    if (cached != null) return cached;

    final loaded = await _inner.findById(id);
    if (loaded != null) {
      _cache[id] = loaded;
    }
    return loaded;
  }

  @override
  Future<void> save(ChannelAggregate channel) async {
    _cache[channel.id] = channel;
    await _inner.save(channel);
  }

  @override
  Future<void> delete(ChannelId id) async {
    _cache.remove(id);
    await _inner.delete(id);
  }

  @override
  Future<List<ChannelId>> listIds() => _inner.listIds();

  @override
  Future<bool> exists(ChannelId id) async {
    if (_cache.containsKey(id)) return true;
    return _inner.exists(id);
  }

  @override
  Future<int> get count => _inner.count;
}
