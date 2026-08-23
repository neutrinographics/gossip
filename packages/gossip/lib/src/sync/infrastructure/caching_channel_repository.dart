import 'package:gossip/src/sync/domain/aggregates/channel_aggregate.dart';
import 'package:gossip/src/sync/domain/interfaces/channel_repository.dart';
import 'package:gossip/src/shared/domain/value_objects/channel_id.dart';
import 'package:gossip/src/sync/application/channel_service.dart';

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
/// This is wired up automatically by `Coordinator.create`, so consuming
/// applications don't need to use this class directly.
class CachingChannelRepository implements ChannelRepository {
  final ChannelRepository _inner;
  final Map<ChannelId, ChannelAggregate> _cache = {};

  CachingChannelRepository(this._inner);

  /// In-flight loads, so concurrent cache misses share one deserialized
  /// instance — two instances would break the in-place-mutation assumption
  /// this identity map exists to protect.
  final Map<ChannelId, Future<ChannelAggregate?>> _inFlight = {};

  @override
  Future<ChannelAggregate?> findById(ChannelId id) {
    final cached = _cache[id];
    if (cached != null) return Future.value(cached);

    final pending = _inFlight[id];
    if (pending != null) return pending;

    final load = _inner
        .findById(id)
        .then((loaded) {
          final existing = _cache[id];
          if (existing != null) return existing;
          if (loaded != null) _cache[id] = loaded;
          return loaded;
        })
        // Block body, deliberately: `() => _inFlight.remove(id)` returns the
        // removed value — this very future — and whenComplete awaits a
        // Future-returning callback, deadlocking findById on itself.
        .whenComplete(() {
          _inFlight.remove(id);
        });
    _inFlight[id] = load;
    return load;
  }

  @override
  Future<void> save(ChannelAggregate channel) async {
    // Write through FIRST: caching before a failed persistent write leaves
    // the aggregate visible in memory but absent from storage — gone on
    // restart, present until then.
    await _inner.save(channel);
    _cache[channel.id] = channel;
  }

  @override
  Future<void> delete(ChannelId id) async {
    await _inner.delete(id);
    _cache.remove(id);
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

  @override
  Future<void> clearAll() async {
    await _inner.clearAll();
    _cache.clear();
  }
}
