# Quality-of-life additions to the adverse-network harness

**Track:** Testing   **Depends on:** [Simulate adverse network conditions in the test harness](testing-network-condition-simulation.md)

## What this is

Small gaps surfaced while writing the first adverse-scenario suites — each
was worked around, but first-class support would make future tests simpler
and clearer:

- **Message-type-selective faults.** Drop/duplicate today are positional
  ("the next N messages") or probabilistic; there's no "drop the next
  delta-response". Isolating one message type required careful staging
  (holding a link to control the release cascade) or blanket duplication. A
  predicate hook (`dropWhere`, `duplicateWhere`) — perhaps dispatching on the
  wire type byte — would make such tests one-liners.
- **Per-node time advancement in the test-network DSL.** `runRounds` advances
  every node's virtual clock uniformly, so clock-*rate* skew needs a
  hand-rolled loop over the per-node time ports. A `runRounds` variant taking
  per-node step sizes would make rate skew first-class.
- **A DSL wrapper for probabilistic duplication.** The bus supports a
  duplicate *rate*, but the test-network helper only wraps the counted form.
- **BLE facade test knobs.** The BLE transport's test constructor doesn't
  expose the send timeout or reconnect-backoff durations, so the adverse
  end-to-end harness re-wires the stack manually, bypassing the facade's thin
  event relay. Exposing those knobs would let those suites run through the
  facade itself.

## Why it matters

Each workaround is a place where the next test author has to rediscover a
trick instead of expressing intent directly. Cheap to add, and the scenario
suites that would use them already exist as consumers.

## Related

- Built on: [testing-network-condition-simulation.md](testing-network-condition-simulation.md).
- Consumers: the suites under `packages/gossip/test/integration/adverse/`
  and `packages/gossip_bluey/test/integration/`.
