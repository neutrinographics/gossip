import 'package:gossip/src/domain/aggregates/channel_aggregate.dart';
import 'package:gossip/src/domain/interfaces/channel_repository.dart';
import 'package:gossip/src/domain/value_objects/channel_id.dart';
import 'package:gossip/src/domain/value_objects/node_id.dart';
import 'package:gossip/src/infrastructure/repositories/caching_channel_repository.dart';
import 'package:test/test.dart';

/// Models a persistent repository: findById deserializes a FRESH aggregate
/// per call (with I/O latency), and save can be told to fail.
class _PersistentishInner implements ChannelRepository {
  final Map<ChannelId, NodeId> _rows = {};
  bool failNextSave = false;

  @override
  Future<ChannelAggregate?> findById(ChannelId id) async {
    await Future<void>.delayed(Duration.zero);
    final localNode = _rows[id];
    if (localNode == null) return null;
    return ChannelAggregate.reconstitute(
      id: id,
      localNode: localNode,
      memberIds: {localNode},
      streams: const {},
    );
  }

  @override
  Future<void> save(ChannelAggregate channel) async {
    if (failNextSave) {
      failNextSave = false;
      throw StateError('disk full');
    }
    _rows[channel.id] = channel.localNode;
  }

  @override
  Future<void> delete(ChannelId id) async => _rows.remove(id);

  @override
  Future<List<ChannelId>> listIds() async => _rows.keys.toList();

  @override
  Future<bool> exists(ChannelId id) async => _rows.containsKey(id);

  @override
  Future<int> get count async => _rows.length;

  @override
  Future<void> clearAll() async => _rows.clear();
}

/// COR3-17: the identity map must stay consistent with the inner
/// repository and must actually be an identity map under concurrent
/// misses — the class exists so the engine's aggregate references stay
/// valid when the backing store deserializes fresh objects.
void main() {
  final channelId = ChannelId('ch1');
  final localNode = NodeId('local');

  test('a failed save does not leave the aggregate visible in the cache',
      () async {
    final inner = _PersistentishInner();
    final caching = CachingChannelRepository(inner);
    final channel = ChannelAggregate(id: channelId, localNode: localNode);

    inner.failNextSave = true;
    await expectLater(caching.save(channel), throwsStateError);

    expect(
      await caching.findById(channelId),
      isNull,
      reason: 'cache and store must agree: the save failed',
    );
    expect(await caching.exists(channelId), isFalse);
  });

  test('findById on a cache miss completes', () async {
    // Regression: whenComplete(() => _inFlight.remove(id)) returned the
    // removed value — the load future itself — so whenComplete waited on
    // its own result future and never completed (self-deadlock on every
    // cache miss).
    final caching = CachingChannelRepository(_PersistentishInner());

    final loaded = await caching
        .findById(channelId)
        .timeout(const Duration(seconds: 2));

    expect(loaded, isNull);
  });

  test('concurrent cache misses resolve to a single aggregate instance',
      () async {
    final inner = _PersistentishInner();
    final caching = CachingChannelRepository(inner);
    final channel = ChannelAggregate(id: channelId, localNode: localNode);
    await caching.save(channel);
    // A fresh caching layer (e.g. after restart) with a warm inner store.
    final cold = CachingChannelRepository(inner);

    final results = await Future.wait([
      cold.findById(channelId),
      cold.findById(channelId),
    ]);

    expect(results[0], isNotNull);
    expect(
      identical(results[0], results[1]),
      isTrue,
      reason:
          'two loaded instances break the in-place-mutation assumption '
          'the identity map exists to protect',
    );
  });
}
