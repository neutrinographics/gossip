# ADR-005: Hybrid Logical Clocks for Ordering

## Status

Accepted

## Context

Event streams require a total ordering of entries. In a distributed system without a central authority, we need a clock mechanism that:
- Orders events causally (if A happened before B, A < B)
- Provides a total order (any two events can be compared)
- Works with clock skew (mobile devices have imperfect clocks)
- Is compact (fits in reasonable storage)

Options considered:
1. **Wall clock time**: Simple but fails with clock skew
2. **Lamport clocks**: Logical ordering but loses real-time correlation
3. **Vector clocks**: Full causality but O(n) size
4. **Hybrid Logical Clocks (HLC)**: Combines physical and logical time

## Decision

**Use Hybrid Logical Clocks (HLC) for entry timestamps.** HLC combines physical time with a logical counter to provide causally consistent ordering while maintaining correlation with real time.

```dart
class Hlc implements Comparable<Hlc> {
  final int millis;   // Physical time (milliseconds since epoch)
  final int counter;  // Logical counter for same-millisecond events
}
```

## Rationale

1. **Causal consistency**: HLC maintains happens-before relationships
2. **Clock skew tolerance**: Logical counter handles devices with different clocks
3. **Compact**: Only 12 bytes (8 for millis + 4 for counter)
4. **Real-time correlation**: Unlike pure logical clocks, HLC values are meaningful
5. **Deterministic**: Same inputs always produce same ordering

## How HLC Works

### Local Event

When creating a new entry:
```
hlc.millis = max(hlc.millis, now())
if hlc.millis == now():
  hlc.counter++
else:
  hlc.counter = 0
```

### Receiving Remote Event

When receiving an entry with timestamp `remote`:
```
hlc.millis = max(hlc.millis, remote.millis, now())
if hlc.millis == remote.millis == old_millis:
  hlc.counter = max(hlc.counter, remote.counter) + 1
elif hlc.millis == remote.millis:
  hlc.counter = remote.counter + 1
elif hlc.millis == old_millis:
  hlc.counter++
else:
  hlc.counter = 0
```

### Comparison

Two HLC values are compared by:
1. Physical time (millis)
2. Logical counter (if millis equal)
3. Author NodeId (if both equal, for deterministic tiebreaker)

## Consequences

### Positive

- Entries can be sorted deterministically across all nodes
- Clock skew up to several seconds is tolerated
- Real timestamps are preserved for debugging/display
- Efficient storage and comparison

### Negative

- More complex than simple timestamps
- Requires clock update on receive (must process entries in order)
- Large clock skew (hours) can cause issues

### Deterministic Tiebreaker

When two entries have identical HLC values (same millis and counter), we use the author's NodeId as a tiebreaker:

```dart
int compareTo(Hlc other) {
  if (millis != other.millis) return millis.compareTo(other.millis);
  if (counter != other.counter) return counter.compareTo(other.counter);
  return author.compareTo(other.author);  // Deterministic tiebreaker
}
```

This ensures all nodes produce the same total order.

## Alternatives Considered

### Wall Clock Only

Use system time directly:
- Simplest implementation
- But fails with clock skew
- Can have duplicate timestamps
- No causality guarantees

### Lamport Clocks

Pure logical counters:
- Strong causality
- But loses real-time meaning
- Counter can grow unbounded
- Hard to correlate with actual time

### Vector Clocks

Track causality per node:
- Full causality information
- But O(n) storage per entry
- Complex comparison
- Overkill for our use case

### Timestamp + Sequence

Combine wall time with per-author sequence:
- Simpler than HLC
- But doesn't handle clock skew
- Causality only within author
