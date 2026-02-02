# UI Improvement Roadmap

This document tracks planned UI improvements for the nearby_chat example app. The goal is to make the app slick, fancy, intuitive, yet minimalistic.

## Completed

### Phase 1: Core Polish
- [x] Animated typing indicator (bouncing dots)
- [x] Message bubble grouping + delivery status
- [x] Dark mode support
- [x] Hero transitions (channel icon and name animate to chat screen)

### Phase 2: Animations & Micro-interactions
- [x] Connection status pulse animation (radar sweep, breathing glow)
- [x] Empty states with personality (floating icon animation)
- [x] New messages floating pill (shows count when scrolled up)
- [x] Input bar polish (animated send button, background color shift, haptic feedback)

### Phase 3: Visual Identity
- [x] Peer avatars (NodeId → gradient) - deterministic colors from identifier hash
- [x] Theme refinements (indigo-violet palette, semantic colors, refined surfaces)

### Phase 4: Status & Feedback
- [x] Message delivery status (sending spinner, sent checkmark, failed with retry)
- [x] Signal strength indicator (1-3 bars based on probe failures)

---

## Planned Improvements

### Animations & Micro-interactions

#### Connection Status Pulse
- Animated radar pulse when discovering
- Breathing glow effect when advertising  
- Smooth color transitions between states

**Implementation:** Create `AnimatedConnectionIndicator` widget with `AnimationController` for pulsing effects.

#### Hero Transitions
- Channel tile → Chat screen (channel name animates to AppBar)
- QR icon → QR dialog (icon morphs into the QR code)

**Implementation:** Wrap channel name and QR icon in `Hero` widgets with matching tags.

#### Empty States with Personality
- Subtle floating/bobbing animation on the icons
- More conversational copy

**Implementation:** Create `AnimatedEmptyState` widget with sine-wave vertical translation.

#### New Messages Floating Pill
When scrolled up, show a floating pill: "↓ 3 new messages" that scrolls to bottom on tap.

**Implementation:** Track scroll position with `ScrollController`, show/hide pill with `AnimatedOpacity`.

---

### List Interactions

#### Swipe Actions
- Swipe left on channel to leave (with red background reveal)
- Swipe right on peer to ping/connect

**Implementation:** Use `Dismissible` widget with custom backgrounds, or `flutter_slidable` package.

#### Pull to Refresh
Manual sync trigger for channels and peers lists.

**Implementation:** Wrap lists in `RefreshIndicator`.

---

### Input & Feedback

#### Input Bar Polish
- Send button grows/pulses when text is entered
- Subtle background color shift when typing
- Character count for long messages (optional, show at 200+ chars)

**Implementation:** Add `AnimatedScale` on send button, `AnimatedContainer` for background.

#### Haptic Feedback
- Light tap on send
- Medium impact on connect/disconnect
- Success pattern on channel join

**Implementation:** Use `HapticFeedback` class from Flutter services.

---

### Visual Identity

#### Peer Avatars
Generate unique gradient avatars from NodeId hash (like GitHub's identicons).

**Implementation:** Create `NodeAvatar` widget that generates deterministic colors from NodeId.

```dart
class NodeAvatar extends StatelessWidget {
  final NodeId nodeId;
  
  List<Color> get _gradientColors {
    final hash = nodeId.value.hashCode;
    return [
      Color((hash & 0xFFFFFF) | 0xFF000000),
      Color(((hash >> 8) & 0xFFFFFF) | 0xFF000000),
    ];
  }
}
```

#### Theme Refinements
- Primary: Deep indigo → violet gradient
- Success: Mint green (#10B981)
- Warning: Warm amber (#F59E0B)
- Error: Coral red (#EF4444)
- Surface: Off-white (#FAFAFA) / dark charcoal (#1F1F1F)

---

### Status & Feedback

#### Message Status Icons
- Sending: Small spinner
- Sent: Single checkmark
- Delivered: Double checkmark (if implementing delivery receipts)
- Failed: Red exclamation with retry

#### Connection Quality Indicator
Signal strength bars (1-3) based on ping latency or message success rate.

---

## Status & Feedback - Feasibility Analysis

### Message Status Icons

| Status | Currently Supported | Notes |
|--------|---------------------|-------|
| **Sending** (spinner) | ✅ Yes | `MessageDeliveryStatus.sending` exists, UI shows spinner |
| **Sent** (single check) | ✅ Yes | `MessageDeliveryStatus.sent` exists, UI shows checkmark |
| **Failed** (red exclamation) | ✅ Yes | `MessageDeliveryStatus.failed` exists, UI shows error icon |
| **Delivered** (double check) | ❌ No | **Requires new infrastructure** |

#### What's needed for "Delivered" status

The gossip library uses an anti-entropy gossip protocol that doesn't have explicit delivery receipts. Messages are synced via digest/delta exchange. To add "delivered" confirmation would require:

1. **New protocol message**: A `DeliveryReceipt` message type
2. **Entry tracking**: Track which peers have confirmed receipt of each entry
3. **New domain event**: `EntryDeliveredToPeer` event
4. **Storage**: Persist delivery state per entry per peer

**Complexity**: High - requires protocol changes in the core library.

**Alternative approach**: Consider "delivered" as "synced to at least one peer" - could detect this when a peer's version vector includes our entry. This would require:
- Tracking version vectors received from peers during sync
- Checking if our entry's HLC timestamp is covered

### Connection Quality Indicator

| Feature | Currently Supported | Notes |
|---------|---------------------|-------|
| **Peer status** (connected/suspected/unreachable) | ✅ Yes | `PeerStatus` enum in gossip library |
| **Ping latency/RTT** | ❌ No | Not tracked |
| **Message success rate** | ❌ No | Not tracked |

#### Implementation Options

**Option A: Ping latency-based** (complex)
- Modify `FailureDetector` to record RTT for each Ack
- Add `lastPingLatency` or `averageLatency` to `Peer` entity
- Expose via `PeerStatusChanged` event or new `PeerLatencyUpdated` event
- UI maps latency ranges to 1-3 bars

**Option B: Probe failure rate-based** (simpler)
- Already have `missedProbeCount` on `Peer` entity
- Could expose this count to the app layer
- UI maps failure count to signal strength (0 failures = 3 bars, 1 = 2 bars, 2+ = 1 bar)

**Current infrastructure available:**
```dart
// In Peer entity (packages/gossip/lib/src/domain/entities/peer.dart)
final int missedProbeCount; // Already exists but not exposed to app layer
```

### Summary

| Feature | Effort | Status |
|---------|--------|--------|
| Sending/Sent/Failed indicators | ✅ Done | Implemented |
| Delivered (double check) | 🔴 High | **Skipped** - not worth the complexity |
| Retry on failed | ✅ Done | Implemented |
| Signal bars (failure-based) | 🟢 Low | Planned |

**Decision on "Delivered" status**: After investigation, we decided to skip this feature. The complexity of tracking delivery across peers (version vector comparisons, lifecycle management for peer join/leave, memory overhead) outweighs the benefit. The "sent" status already indicates the message is in the gossip protocol and will sync to peers within sub-second latency. Users rarely need delivered vs sent distinction in local mesh chat apps.

---

### Responsive Design

#### Tablet Layout
Split view with channels list on left (300px fixed) and chat on right.

**Implementation:** Use `LayoutBuilder` to detect width > 720px, show `Row` with both screens.

#### Landscape Handling
Adjust input bar and message bubbles for wider screens.

---

### Accessibility

#### Screen Reader Support
- Semantic labels on all icons
- Announce new messages
- Describe connection status changes

#### Touch Targets
Ensure all interactive elements are minimum 48x48dp.

#### High Contrast Mode
Define high-contrast color scheme variant.

---

## Design Tokens

When implementing, extract these to a central location:

```dart
// lib/presentation/theme/spacing.dart
abstract class Spacing {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 16;
  static const double lg = 24;
  static const double xl = 32;
}

// lib/presentation/theme/durations.dart
abstract class Durations {
  static const fast = Duration(milliseconds: 150);
  static const normal = Duration(milliseconds: 300);
  static const slow = Duration(milliseconds: 500);
}
```

---

## Priority Order

1. ~~Animated typing indicator~~ ✓
2. ~~Message bubble grouping + delivery status~~ ✓
3. ~~Dark mode~~ ✓
4. ~~Hero transitions~~ ✓
5. ~~Connection status pulse animation~~ ✓
6. ~~Empty state animations~~ ✓
7. ~~New messages floating pill~~ ✓
8. ~~Input bar polish~~ ✓
9. ~~Peer avatars (NodeId → gradient)~~ ✓
10. ~~Theme refinements~~ ✓
11. Swipe actions on lists
12. Tablet responsive layout

---

## Resources

- [Material Design 3 Color System](https://m3.material.io/styles/color/overview)
- [Flutter Animations Guide](https://docs.flutter.dev/ui/animations)
- [Accessibility in Flutter](https://docs.flutter.dev/ui/accessibility-and-internationalization/accessibility)
