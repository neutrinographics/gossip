import 'package:gossip/src/shared/domain/value_objects/hlc.dart';
import 'package:gossip/src/shared/domain/value_objects/log_entry.dart';
import 'package:gossip/src/shared/domain/value_objects/log_entry_id.dart';
import 'package:gossip/src/shared/domain/value_objects/node_id.dart';

/// Strategy for determining which entries to keep during stream compaction.
///
/// [RetentionPolicy] defines the criteria for retaining or discarding entries
/// when streams are compacted to reclaim storage space. Applications choose
/// policies based on their data semantics and storage constraints.
///
/// The library provides four built-in policies:
/// - [KeepAllRetention]: Never discard entries (audit logs)
/// - [TimeBasedRetention]: Keep recent entries (ephemeral data)
/// - [CountBasedRetention]: Keep latest N per author (last-known-state)
/// - [CompositeRetention]: Combine multiple policies (union semantics)
///
/// Applications can implement custom policies for domain-specific requirements.
///
/// ## Contract
/// - [compact] must be deterministic: same inputs → same outputs
/// - [compact] must preserve entry order (by timestamp)
/// - Returned list must be a subset of input entries
/// - Must not modify the input list
abstract interface class RetentionPolicy {
  /// Returns the subset of entries to retain after compaction.
  ///
  /// Given all current entries and the current time, determines which entries
  /// should be kept. Entries not in the returned list will be deleted from
  /// storage.
  ///
  /// Parameters:
  /// - [entries]: All current entries in the stream (ordered by timestamp)
  /// - [now]: Current hybrid logical clock time
  List<LogEntry> compact(List<LogEntry> entries, Hlc now);

  /// Whether this policy never prunes anything (retains all entries).
  ///
  /// Lets auto-compaction skip loading and scanning streams that can never
  /// shrink (e.g. [KeepAllRetention]), avoiding needless work on large logs.
  bool get retainsAll;
}

/// Retains all entries indefinitely.
///
/// Never discards any entries during compaction. Use this policy when:
/// - Building audit logs that must preserve complete history
/// - Storage capacity is unlimited or managed externally
/// - Compliance requires full data retention
class KeepAllRetention implements RetentionPolicy {
  const KeepAllRetention();

  @override
  List<LogEntry> compact(List<LogEntry> entries, Hlc now) => entries;

  @override
  bool get retainsAll => true;
}

/// Retains entries newer than a specified age.
///
/// Discards entries whose timestamp is older than [maxAge] from the current
/// time. Use this policy for ephemeral data where only recent entries matter.
///
/// Examples:
/// - Presence indicators (keep last 5 minutes)
/// - Typing notifications (keep last 30 seconds)
/// - Recent activity feeds (keep last 24 hours)
class TimeBasedRetention implements RetentionPolicy {
  /// Maximum age of entries to retain.
  final Duration maxAge;

  // Not `const`: validating a parameter's *value* (not just its type)
  // makes const invocation impossible, full stop — a const constructor
  // can't have a body (so a factory-with-a-throw isn't an option
  // either), which leaves `assert(...)` in the initializer list as the
  // only place to put such a check, and Dart's constant-expression
  // evaluator rejects instance-getter/property access there regardless
  // of the parameter's type. Verified empirically for both this class
  // (`Duration.isNegative`) and [CompositeRetention] (`List.length`):
  // both fail to const-fold identically — there is no type for which
  // this guard and `const` coexist. No caller in this codebase
  // constructs this with the `const` keyword, so dropping it costs
  // nothing but gains a real guard.
  TimeBasedRetention(this.maxAge)
    : assert(
        !maxAge.isNegative,
        'maxAge must not be negative — compact subtracts it from the '
        'current HLC, and Hlc.subtract throws on the resulting negative '
        'time',
      );

  @override
  List<LogEntry> compact(List<LogEntry> entries, Hlc now) {
    // Clock younger than maxAge: the cutoff would precede the epoch
    // (Hlc.subtract throws on negative results). Nothing can be older
    // than maxAge yet — retain everything.
    if (now.physicalMs < maxAge.inMilliseconds) return entries;
    final cutoff = now.subtract(maxAge);
    return entries.where((e) => e.timestamp >= cutoff).toList();
  }

  @override
  bool get retainsAll => false;
}

/// Retains the most recent N entries per author.
///
/// For each author, keeps only their [maxEntriesPerAuthor] newest entries.
/// Use this policy for last-known-state patterns where only recent values
/// matter per author.
///
/// Examples:
/// - User profile updates (keep last 10 per user)
/// - Device configuration (keep last 5 per device)
/// - Status messages (keep last 3 per author)
class CountBasedRetention implements RetentionPolicy {
  /// Maximum entries to retain per author.
  final int maxEntriesPerAuthor;

  const CountBasedRetention(this.maxEntriesPerAuthor)
    : assert(
        maxEntriesPerAuthor >= 0,
        'maxEntriesPerAuthor must not be negative — zero is legal and '
        'deliberately prunes every entry; a negative count has no meaning '
        'for `take(n)` below',
      );

  @override
  List<LogEntry> compact(List<LogEntry> entries, Hlc now) {
    // Group by author, keep most recent N per author
    final byAuthor = <NodeId, List<LogEntry>>{};
    for (final entry in entries) {
      byAuthor.putIfAbsent(entry.author, () => []).add(entry);
    }

    final retained = <LogEntry>[];
    for (final authorEntries in byAuthor.values) {
      authorEntries.sort(
        (a, b) => b.sequence.compareTo(a.sequence),
      ); // Newest first
      retained.addAll(authorEntries.take(maxEntriesPerAuthor));
    }

    // Restore original order (by timestamp)
    retained.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return retained;
  }

  @override
  bool get retainsAll => false;
}

/// Combines multiple retention policies with union semantics.
///
/// An entry is retained if ANY of the constituent policies would retain it.
/// This allows expressing complex retention rules as combinations of simpler
/// policies.
///
/// Examples:
/// - Keep last 100 entries OR last 24 hours (whichever is larger)
/// - Keep last 10 per author OR entries from last hour
/// - Keep all entries with specific tags OR entries newer than 7 days
///
/// The composite policy evaluates all sub-policies and returns the union
/// of their results, preserving timestamp order.
class CompositeRetention implements RetentionPolicy {
  /// The policies to combine (union semantics).
  final List<RetentionPolicy> policies;

  // Not `const`, for the same reason as [TimeBasedRetention]'s
  // constructor: a value-dependent guard and const invocation cannot
  // coexist (verified empirically for both this class's `List.isNotEmpty`
  // and TimeBasedRetention's `Duration.isNegative` — no type escapes
  // this). No caller in this codebase constructs this with the `const`
  // keyword, so dropping it costs nothing but gains a real guard.
  CompositeRetention(this.policies)
    : assert(
        policies.isNotEmpty,
        'policies must not be empty — a composite with no sub-policies '
        'would retain nothing, silently discarding every entry on the '
        'next compaction',
      );

  @override
  List<LogEntry> compact(List<LogEntry> entries, Hlc now) {
    final retained = <LogEntryId>{};
    for (final policy in policies) {
      for (final entry in policy.compact(entries, now)) {
        retained.add(entry.id);
      }
    }
    return entries.where((e) => retained.contains(e.id)).toList();
  }

  /// Union semantics: if any sub-policy retains everything, the composite
  /// retains everything (nothing is ever pruned).
  @override
  bool get retainsAll => policies.any((p) => p.retainsAll);
}
