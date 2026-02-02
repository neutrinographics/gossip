# Integration Tests Index

This document catalogs all integration tests in the gossip_ble package for reference and organization.

---

## connection_lifecycle_test.dart

**Purpose:** Tests the basic connection lifecycle between devices.

| Test | Description |
|------|-------------|
| two devices complete handshake and become connected | Verifies bidirectional connection establishment and PeerConnected events |
| disconnection is detected by both sides | Verifies PeerDisconnected events and peer count updates |
| reconnection after disconnect works correctly | Tests connect-disconnect-reconnect cycle with correct event sequence |
| advertising and discovery state is tracked correctly | Verifies start/stop advertising and discovery state management |
| metrics are updated during connection lifecycle | Validates metric updates through connect/disconnect cycle |

---

## multi_peer_test.dart

**Purpose:** Tests scenarios involving multiple connected peers.

| Test | Description |
|------|-------------|
| single device connects to multiple peers simultaneously | Verifies one device connecting to 3 peers |
| mesh topology: all devices connect to each other | Tests full mesh where all 4 devices interconnect |
| one peer disconnecting does not affect others | Verifies isolation of disconnect events |
| metrics track multiple connections correctly | Validates metrics with multiple peers |
| rapid sequential connections are handled correctly | Tests fast sequential connection establishment |
| concurrent connect and disconnect operations | Tests simultaneous connect and disconnect operations |

---

## message_exchange_test.dart

**Purpose:** Tests message sending and receiving between peers.

| Test | Description |
|------|-------------|
| message sent via messagePort is received by peer | Basic message delivery verification |
| bidirectional message exchange works | Tests messages in both directions |
| multiple messages maintain order | Verifies ordering of 10 sequential messages |
| large messages are transmitted correctly | Tests 10KB payload transmission with content verification |
| messages to unknown peer are silently dropped | Verifies graceful handling of sends to unconnected peers |
| metrics track bytes sent and received | Validates message and byte metrics |
| rapid message exchange works correctly | Tests 3 rapid sequential sends |
| **multi-peer message routing** | |
| messages are routed to correct peer | Verifies correct routing to multiple peers |
| broadcast to all peers | Tests sending same message to all connected peers |

---

## error_handling_test.dart

**Purpose:** Tests error scenarios and recovery behavior.

| Test | Description |
|------|-------------|
| send failure emits error event | Verifies SendFailedError emission |
| send to unknown peer emits ConnectionNotFoundError | Tests error for send to unconnected peer |
| disconnection mid-handshake records failure in metrics | Validates handshake failure metrics |
| invalid handshake data is handled gracefully | Tests HandshakeInvalidError for malformed data |
| connection after transport dispose throws | Verifies StateError for operations after dispose |
| errors include timestamps | Validates error timestamp accuracy |
| peer disconnect during message send is handled | Tests SendFailedError when peer disconnects |
| **recovery scenarios** | |
| transport recovers from temporary send failures | Tests successful send after clearing failure state |
| connection errors dont prevent new connections | Tests that errors don't block future connections |
| new connection after failed handshake works | Tests successful connection after handshake failure |

---

## handshake_timeout_test.dart

**Purpose:** Tests handshake timeout behavior with deterministic time control.

| Test | Description |
|------|-------------|
| **timeout expiration** | |
| timeout does NOT fire before 30 seconds | Verifies no premature timeout at 29.999s |
| timeout fires at exactly 30 seconds | Verifies timeout at exact boundary |
| timeout emits correct error details | Validates HandshakeTimeoutError includes deviceId and message |
| device is disconnected after timeout | Verifies cleanup after timeout |
| **timeout cancellation** | |
| timeout is cancelled when handshake completes | Verifies no timeout after successful handshake |
| timeout cancelled at 25s when handshake completes does not fire at 30s | Tests late handshake completion cancels timeout |
| timeout cancelled on disconnect before expiration | Tests disconnect cancels pending timeout |
| **multiple concurrent handshakes** | |
| each device has independent timeout | Tests staggered timeout for devices started 5s apart |
| completing one handshake does not affect others timeout | Verifies timeout isolation |
| disconnecting one device does not cancel other timeouts | Tests timeout independence |
| **metrics with precise timing** | |
| handshake duration is recorded accurately | Validates handshake timing metrics |
| failed handshakes are counted correctly with timeouts | Tests failure metrics for 3 timed-out handshakes |
| **disposal** | |
| disposing service cancels all pending timeouts | Verifies timeout cancellation on dispose |
| no timeout callbacks fire after disposal | Tests no errors after disposal |
| **edge cases** | |
| timeout at exact boundary with millisecond precision | Tests 29999ms vs 30000ms boundary |
| rapid connect-disconnect cycles do not leak timeouts | Tests 10 rapid cycles with no leaked timeouts |
| timeout during message send does not crash | Tests concurrent timeout and message operations |

---

## timing_races_test.dart

**Purpose:** Tests timing-sensitive scenarios and race conditions.

| Test | Description |
|------|-------------|
| **handshake timing** | |
| handshake completes even with minimal delay | Tests fast handshake completion |
| multiple rapid connections complete correctly | Tests 3 simultaneous connections |
| disconnect during handshake is handled | Tests early disconnect during handshake |
| message arrives during handshake phase is buffered or dropped | Tests race between handshake and message |
| **concurrent operations** | |
| simultaneous sends to same peer are serialized | Tests 10 concurrent sends to one peer |
| simultaneous sends to different peers work correctly | Tests parallel sends to different peers |
| connect and disconnect interleaved operations | Tests simultaneous connect and disconnect |
| **reconnection scenarios** | |
| rapid reconnect to same peer works | Tests immediate reconnect after disconnect |
| multiple reconnect cycles maintain correct state | Tests 5 connect-disconnect cycles |
| message delivery works after reconnect | Tests message delivery after reconnection |
| **event ordering** | |
| PeerConnected event received before first message | Validates event ordering guarantee |
| PeerDisconnected event received after connection closes | Validates disconnect event timing |
| events from multiple peers arrive in correct order | Tests event ordering with multiple peers |
| **send during state transitions** | |
| send during disconnect is handled gracefully | Tests concurrent send and disconnect |
| send to recently disconnected peer fails gracefully | Tests send immediately after disconnect |
| **handshake edge cases** | |
| duplicate handshake message is handled | Tests duplicate handshake from same device |
| handshake from new device replaces pending handshake | Tests multiple pending handshakes |
| **concurrent handshakes from same peer** | |
| concurrent handshakes from same peer complete correctly | Tests duplicate connections from same NodeId |
| flaky connection with rapid reconnects during handshake | Tests handshake recovery with reconnects |
| **network latency simulation** | |
| messages are delivered after latency delay | Tests message delivery with 100ms delay |
| multiple messages with latency maintain order | Tests message ordering with latency |
| zero latency delivers immediately | Tests immediate delivery without latency |
| latency does not affect receiver | Tests latency affects sender only |

---

## disposal_test.dart

**Purpose:** Tests resource cleanup and disposal behavior.

| Test | Description |
|------|-------------|
| **basic disposal** | |
| dispose with no connections succeeds | Tests dispose on fresh transport |
| dispose with active connections cleans up | Verifies peer sees disconnect |
| double dispose is safe | Tests idempotent disposal |
| dispose cancels pending handshake timers | Tests timer cleanup on dispose |
| **operations after dispose** | |
| startAdvertising after dispose is safe | Tests safe failure after dispose |
| startDiscovery after dispose is safe | Tests safe failure after dispose |
| send after dispose fails gracefully | Tests send no-op after dispose |
| accessing connectedPeers after dispose is safe | Tests state access after dispose |
| **dispose during operations** | |
| dispose during send operation completes | Tests dispose during delayed send |
| dispose while connecting cleans up correctly | Tests dispose mid-connection |
| dispose with messages in flight | Tests dispose with 10 pending messages |
| **event streams after dispose** | |
| peerEvents stream closes on dispose | Verifies stream onDone called |
| errors stream closes on dispose | Verifies stream onDone called |
| incoming messages stream closes on dispose | Verifies stream onDone called |
| **peer disposal effects** | |
| peer disposing triggers local disconnect event | Tests remote peer disposal notification |
| multiple peers disposing in sequence | Tests sequential peer disposal |
| simultaneous disposal of multiple peers | Tests concurrent peer disposal |
| **resource leak prevention** | |
| timers are cancelled on dispose | Tests timer cleanup with 5 pending handshakes |
| stream subscriptions are cancelled on dispose | Tests subscription cleanup |

---

## metrics_test.dart

**Purpose:** Tests metrics tracking accuracy.

| Test | Description |
|------|-------------|
| **connection metrics** | |
| initial metrics are zero | Verifies all metrics start at 0 |
| connection establishment increments counters | Tests metric updates on connect |
| disconnection decrements connected count but not totals | Tests historical vs current metrics |
| multiple connections accumulate correctly | Tests metrics with 2 connections |
| **handshake timing metrics** | |
| handshake duration is recorded | Tests averageHandshakeDuration tracking |
| average duration calculated across multiple handshakes | Tests average calculation with 2 handshakes |
| **message metrics** | |
| sent messages are counted | Tests totalMessagesSent with 3 messages |
| received messages are counted | Tests totalMessagesReceived with 2 messages |
| bytes sent includes protocol overhead | Verifies totalBytesSent > payload size |
| bytes received tracks incoming data | Verifies totalBytesReceived > payload size |
| **failure metrics** | |
| failed handshake increments failure count | Tests totalHandshakesFailed on invalid data |
| disconnection during handshake counts as failure | Tests failure on incomplete handshake |
| relationship: established = completed + failed + pending | Validates metrics invariant |
| **metrics consistency** | |
| metrics remain consistent through complex scenarios | Tests metrics across connect/send/disconnect |
| metrics survive rapid connect/disconnect cycles | Tests 5 rapid cycles |

---

## malformed_data_test.dart

**Purpose:** Tests handling of invalid/malformed protocol data.

| Test | Description |
|------|-------------|
| **invalid handshake data** | |
| empty bytes are ignored | Tests empty byte handling |
| unknown message type is handled gracefully | Tests invalid message type byte |
| handshake with no payload triggers error | Tests truncated handshake |
| handshake with truncated data triggers error | Tests incomplete handshake payload |
| handshake with length overflow triggers error | Tests length field larger than data |
| handshake with invalid UTF-8 triggers error | Tests invalid UTF-8 in NodeId |
| handshake with empty NodeId triggers error | Tests zero-length NodeId |
| random garbage bytes are handled gracefully | Tests random byte sequence |
| **invalid gossip data** | |
| gossip with no payload delivers empty message | Tests empty gossip payload |
| gossip from unknown device is ignored | Tests gossip from unconnected device |
| **message type edge cases** | |
| type byte 0x00 is handled as unknown | Tests null type byte |
| type byte 0xFF is handled as unknown | Tests max type byte |
| **boundary conditions** | |
| very large handshake payload is handled | Tests 10KB NodeId payload |
| single byte messages are handled | Tests minimal payload |
| maximum reasonable payload is handled | Tests 64KB payload |
| **duplicate and repeated data** | |
| duplicate handshake from same device is handled | Tests replay of handshake |
| rapid repeated messages are all delivered | Tests 100 rapid messages |
| **interleaved and corrupted streams** | |
| valid message after invalid one is still processed | Tests recovery after invalid data |
| system recovers after malformed handshake attempt | Tests connection after failed handshake |

---

## state_consistency_test.dart

**Purpose:** Tests state consistency across complex multi-peer scenarios.

| Test | Description |
|------|-------------|
| **NodeId uniqueness** | |
| same NodeId from different DeviceIds replaces connection | Tests NodeId deduplication |
| message routes to newest DeviceId for NodeId | Tests routing after device change |
| three rapid reconnections with same NodeId | Tests 3 rapid reconnects |
| **metrics consistency** | |
| metrics match actual state after complex operations | Tests connect/disconnect/reconnect metrics |
| failed handshakes are counted correctly | Tests failure metrics with 3 invalid handshakes |
| message metrics accumulate correctly | Tests 5 message sends |
| **event stream consistency** | |
| PeerConnected count matches connectedPeerCount | Tests event/state consistency |
| connected minus disconnected equals current count | Tests event arithmetic |
| each connection produces exactly one PeerConnected event | Tests 5 devices, 1 event each |
| **registry state consistency** | |
| connectedPeers set matches actual connections | Tests set contents |
| bidirectional connection consistency | Tests both sides see connection |
| mesh network has consistent state | Tests full mesh of 3 devices |
| **error state consistency** | |
| errors dont corrupt connection state | Tests state after errors |
| failed connection doesnt affect existing connections | Tests existing connection preserved |
| **initial state** | |
| properties are accessible in initial state | Tests initial property values |
| state is consistent after rapid operations | Tests rapid state changes |
| **stress scenarios** | |
| rapid connect/disconnect maintains consistency | Tests 10 rapid cycles |
| many peers maintain individual state | Tests 10 peers with unique messages |

---

## lifecycle_edge_cases_test.dart

**Purpose:** Tests unusual API usage patterns and edge cases.

| Test | Description |
|------|-------------|
| **advertising and discovery** | |
| start advertising twice is idempotent | Tests double start |
| stop advertising without start is safe | Tests stop without start |
| start discovery twice is idempotent | Tests double start |
| stop discovery without start is safe | Tests stop without start |
| advertising and discovery can be active simultaneously | Tests both active together |
| connection works regardless of advertising state | Tests connect without advertising |
| **message port usage** | |
| messagePort is available immediately | Tests port exists before connections |
| send to unconnected peer fails gracefully | Tests ConnectionNotFoundError |
| incoming stream works across multiple connections | Tests messages from multiple peers |
| **concurrent access patterns** | |
| multiple listeners on peerEvents work correctly | Tests broadcast stream |
| multiple listeners on errors work correctly | Tests broadcast stream |
| multiple listeners on incoming messages work correctly | Tests broadcast stream |
| **empty and boundary inputs** | |
| empty message payload is delivered | Tests empty payload |
| single byte message is delivered | Tests minimal payload |
| **LocalNodeId handling** | |
| localNodeId is unique per transport | Tests NodeId uniqueness |
| localNodeId is consistent throughout lifecycle | Tests NodeId immutability |

---

## harness_test.dart

**Purpose:** Tests the test harness DSL itself.

| Test | Description |
|------|-------------|
| creates devices with unique identifiers | Validates createDevice uniqueness |
| connectTo establishes bidirectional connection | Tests connectTo helper |
| disconnectFrom removes connection | Tests disconnectFrom helper |
| sendTo delivers message | Tests sendTo helper |
| failAllSends causes send errors | Tests failAllSends helper |
| clearEvents removes collected events | Tests clearEvents helper |
| expectMetrics validates metric values | Tests expectMetrics assertion |
| MalformedData provides test byte sequences | Tests MalformedData constants |
| createDevices creates multiple devices at once | Tests batch device creation |
| connectToAll connects to multiple peers | Tests connectToAll helper |
| disconnectFromAll disconnects from multiple peers | Tests disconnectFromAll helper |
| connectToSilentPeer creates silent peer connection | Tests silent peer helper |
| expectAllConnectedTo checks multiple connections | Tests batch assertion |
| expectNoErrorsOnAll checks no errors on multiple devices | Tests batch assertion |
| clearAllEvents clears events on all devices | Tests batch clear |
| **harness disposal** | |
| harness dispose cleans up all devices | Tests BleTestHarness.dispose() |
| harness dispose after partial device disposal | Tests harness dispose with pre-disposed device |

---

## Summary Statistics

| File | Test Count |
|------|------------|
| connection_lifecycle_test.dart | 5 |
| multi_peer_test.dart | 6 |
| message_exchange_test.dart | 9 |
| error_handling_test.dart | 10 |
| handshake_timeout_test.dart | 16 |
| timing_races_test.dart | 22 |
| disposal_test.dart | 19 |
| metrics_test.dart | 14 |
| malformed_data_test.dart | 19 |
| state_consistency_test.dart | 16 |
| lifecycle_edge_cases_test.dart | 16 |
| harness_test.dart | 17 |
| **Total** | **169** |

---

## Test Organization

The tests are organized by concern:

| Category | Files |
|----------|-------|
| **Core Behavior** | connection_lifecycle_test, multi_peer_test, message_exchange_test |
| **Error Handling** | error_handling_test, malformed_data_test |
| **Timing & Concurrency** | handshake_timeout_test, timing_races_test |
| **State & Consistency** | state_consistency_test, metrics_test |
| **Resource Management** | disposal_test |
| **API Edge Cases** | lifecycle_edge_cases_test |
| **Test Infrastructure** | harness_test |

---

## Coverage Gaps to Consider

- Bluetooth-specific edge cases (MTU negotiation, etc.) - Note: These are handled at the BLE driver level, not at this transport layer
