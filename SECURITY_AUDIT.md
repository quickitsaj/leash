# Security Audit — Leash Protocol

**Date:** 2026-02-17
**Scope:** `LeashCore.sol`, `LeashPolicy.sol`, `LeashLedger.sol` (819 lines of Solidity)
**Compiler:** Solidity ^0.8.24 (checked arithmetic enabled)
**Framework:** Foundry

---

## Executive Summary

The Leash Protocol is a well-structured set of three immutable, ownerless smart contracts implementing entropy-gated delegation for AI agents. The codebase is compact, avoids external dependencies, and follows a clear separation of concerns. The design philosophy — no admin keys, no proxies, no oracles — eliminates several common attack vectors by default.

This audit identified **2 high-severity**, **3 medium-severity**, **3 low-severity**, and **4 informational** findings. The most critical issues relate to Sybil-exploitable permissionless slashing and unenforced whitelist constraints in spend recording.

---

## Findings

### [H-01] Sybil Vulnerability in Permissionless Slashing

**Severity:** High
**Contract:** `LeashCore.sol`
**Lines:** 162–182

**Description:**
The `slash()` function is permissionless with rate-limiting of 1 slash per hour **per slasher address** per leash. Since Ethereum addresses are free to create, an attacker can generate an arbitrary number of Sybil addresses and coordinate simultaneous slashes to drain authority in a single block.

With `N` Sybil addresses, an attacker can reduce authority by `N * amount` in a single transaction batch. The principal's only defense is `boost()` (one tx per boost) or `kill()`. A coordinated attack with thousands of addresses could overwhelm any principal's ability to respond.

```solidity
// LeashCore.sol:164-167
uint256 lastSlash = lastSlashTime[msg.sender][leashId];
if (lastSlash != 0 && block.timestamp - lastSlash < SLASH_COOLDOWN) {
    revert SlashCooldownActive();
}
```

**Impact:** An attacker can trivially bypass the rate-limiting design by using multiple addresses, reducing authority to zero in a single block regardless of the cooldown mechanism.

**Recommendation:**
Consider one or more of:
- Cap maximum slash amount per call (e.g., 10% of current effective authority)
- Implement a global slash rate limit per leash (across all slashers) per time window
- Require slashers to stake collateral that can be forfeited for malicious slashes
- Add a cumulative slash cap per epoch that limits total slashing across all addresses

---

### [H-02] Whitelist Not Enforced in `recordSpend()`

**Severity:** High
**Contract:** `LeashPolicy.sol`
**Lines:** 204–240

**Description:**
The `recordSpend()` function validates the spend amount against the tier's budget cap but does **not** validate the target address against the tier's whitelist. The whitelist check exists only in the view function `checkAction()`, which is purely advisory.

This means an agent can call `recordSpend()` to debit budget for actions against non-whitelisted targets. Since `recordSpend()` is the only function that actually mutates spend state, the whitelist provides no on-chain enforcement.

```solidity
// recordSpend() only checks: agent identity, alive, tier, and budget cap
// It does NOT accept or validate a `target` parameter
function recordSpend(bytes32 leashId, uint128 amount) external {
    // ... no target/whitelist validation
}
```

**Impact:** The whitelist enforcement is entirely advisory. A malicious or compromised agent can bypass whitelist restrictions by calling `recordSpend()` directly without consulting `checkAction()`.

**Recommendation:**
Add a `target` parameter to `recordSpend()` and enforce the whitelist check within it:

```solidity
function recordSpend(bytes32 leashId, address target, uint128 amount) external {
    // ... existing checks ...
    // Add whitelist enforcement
    Tier storage t = _tiers[policyId][tier];
    if (t.whitelist.length > 0) {
        bool found = false;
        for (uint256 i = 0; i < t.whitelist.length; i++) {
            if (t.whitelist[i] == target) { found = true; break; }
        }
        if (!found) revert ActionNotAllowed();
    }
    // ... rest of spend logic
}
```

---

### [M-01] Silent Overflow in `summary()` Truncates `totalValue`

**Severity:** Medium
**Contract:** `LeashLedger.sol`
**Lines:** 180–184

**Description:**
The `summary()` function accumulates `totalValue` across all log entries but silently skips entries when the addition would overflow `uint128`:

```solidity
if (s.totalValue + entry.value >= s.totalValue) {
    s.totalValue += entry.value;
}
```

This overflow guard silently drops values instead of reverting or signaling the inaccuracy. Consumers of the `summary()` function will receive an incorrect `totalValue` with no indication that overflow occurred. For a function designed as an audit/reputation data source (ERC-8004), silent data loss is particularly concerning.

**Impact:** `totalValue` in summaries can be silently incorrect, potentially misleading reputation validators and downstream consumers.

**Recommendation:**
Either:
- Use `uint256` for `totalValue` to effectively eliminate overflow risk, or
- Revert on overflow to signal the issue clearly, or
- Add a `bool overflowed` field to the Summary struct

---

### [M-02] Unbounded Iteration in `verifyChain()` and `summary()` — DoS Vector

**Severity:** Medium
**Contract:** `LeashLedger.sol`
**Lines:** 128–158 (`verifyChain`), 166–193 (`summary`)

**Description:**
Both `verifyChain()` and `summary()` iterate over the entire `_logs[leashId]` array. An agent can append an unbounded number of log entries (each `log()` call is relatively cheap ~50-80k gas), eventually making these view functions exceed the block gas limit.

For on-chain callers (other contracts relying on `verifyChain()` for reputation), this creates a permanent denial of service once enough entries are accumulated.

**Impact:** An agent (or an attacker through a compromised agent) can make chain verification and summary impossible to execute on-chain by flooding the log.

**Recommendation:**
- Add paginated verification: `verifyChain(leashId, startIndex, endIndex)`
- Add paginated summary: `summary(leashId, startIndex, endIndex)`
- Consider a maximum entries-per-leash cap

---

### [M-03] Spend State Not Reset on Tier Transitions

**Severity:** Medium
**Contract:** `LeashPolicy.sol`
**Lines:** 225–240

**Description:**
The `SpendState` tracks cumulative spend per epoch per leash, but does not account for tier transitions within an epoch. When authority decays and the agent drops to a lower tier, previously accumulated spend at a higher tier is compared against the lower tier's (smaller) spend cap.

Example scenario:
1. Agent is at Tier 3 (cap: 50,000). Spends 4,999.
2. Authority decays, agent drops to Tier 2 (cap: 5,000).
3. Agent can still spend 1 more unit (4,999 < 5,000).
4. But if the agent had spent 5,001 at Tier 3, they cannot spend anything at Tier 2.

This creates inconsistent behavior where the effective remaining budget depends on historical spending at a different tier.

**Impact:** Budget enforcement becomes unpredictable during tier transitions, potentially allowing agents to spend at lower tiers using budget headroom from higher tiers, or being unfairly locked out after dropping tiers.

**Recommendation:**
Either reset the spend state on tier changes, or track spend per-tier rather than per-leash. Alternatively, document this as intended behavior if the trade-off is acceptable.

---

### [L-01] `activeLeashId` Silently Overwritten on New Leash Creation

**Severity:** Low
**Contract:** `LeashCore.sol`
**Line:** 116

**Description:**
When a principal creates a new leash for the same agent, `activeLeashId[principal][agent]` is overwritten with the new leash ID. The previous leash remains alive and operational but is no longer discoverable via `getActiveLeash()`.

```solidity
activeLeashId[msg.sender][agent] = leashId; // Overwrites previous
```

**Impact:** External systems relying on `getActiveLeash()` will lose track of older (still-active) leashes for the same principal-agent pair. This could cause off-chain systems to miss valid active leashes.

**Recommendation:**
Either:
- Require the previous leash to be killed before creating a new one for the same pair, or
- Emit a warning event when overwriting, or
- Document this behavior clearly

---

### [L-02] Leash Creation Allows Zero Authority with Zero Ceiling

**Severity:** Low
**Contract:** `LeashCore.sol`
**Lines:** 91–119

**Description:**
A leash can be created with `initialAuthority = 0` and `ceiling = 0` (the check `initialAuthority > ceiling` passes when both are 0). Such a leash is alive but permanently at zero authority with no ability to boost (since boost is capped at ceiling). It also cannot be heartbeated meaningfully.

Additionally, a leash with `ceiling = 0` and any `initialAuthority = 0` effectively creates a dead-on-arrival leash that wastes gas and pollutes state.

**Impact:** Low — wastes gas and creates meaningless state. No security impact but could confuse integrators.

**Recommendation:**
Add `if (ceiling == 0) revert CeilingMustBeNonZero();` to prevent creation of zero-ceiling leashes.

---

### [L-03] `authorityAt()` Returns Stale Data for Past Timestamps

**Severity:** Low
**Contract:** `LeashCore.sol`
**Lines:** 220–230

**Description:**
The `authorityAt()` function is documented as "Projected authority at a future timestamp" but accepts any timestamp. For timestamps before `lastHeartbeat`, it returns the current stored `authority`, which may not reflect what the authority actually was at that past time (due to prior heartbeats, boosts, and slashes that modified stored values).

```solidity
if (timestamp <= l.lastHeartbeat) return l.authority;
```

**Impact:** Misleading return values for historical queries. Off-chain systems using this for historical analysis could receive incorrect data.

**Recommendation:**
Either revert for past timestamps (`require(timestamp > block.timestamp)`), or rename/document the function to clarify it only works for future projections from the current state.

---

### [I-01] No Reentrancy Guards

**Severity:** Informational
**Contracts:** All

**Description:**
None of the contracts use reentrancy guards (`nonReentrant` modifier). In the current design, there are no external calls to untrusted contracts — only cross-contract calls to the immutable `core` reference, which performs no callbacks. However, if the protocol is ever composed with contracts that have callback mechanisms (e.g., ERC-777 tokens, flash loans), reentrancy could become exploitable.

**Recommendation:**
Consider adding `nonReentrant` guards to state-changing functions as defense-in-depth, especially `slash()`, `recordSpend()`, and `log()`.

---

### [I-02] No ERC-165 Interface Support

**Severity:** Informational
**Contracts:** All

**Description:**
The contracts don't implement ERC-165 (`supportsInterface`). Given the protocol references ERC-8004 and ERC-7710 compatibility, implementing ERC-165 would allow on-chain interface discovery.

**Recommendation:**
Implement ERC-165 for each contract's external interface.

---

### [I-03] No Pausability / Circuit Breaker

**Severity:** Informational
**Contracts:** All

**Description:**
The contracts are fully immutable with no pause mechanism. This is by design (no admin keys), but means there is no way to stop exploitation if a critical vulnerability is discovered post-deployment.

**Recommendation:**
This is an acknowledged design trade-off. Consider whether a time-locked, multi-sig governed pause mechanism is acceptable, or document the risk acceptance.

---

### [I-04] Agent Can Log Fabricated Data to Ledger

**Severity:** Informational
**Contract:** `LeashLedger.sol`

**Description:**
The `log()` function records whatever `target` and `value` the agent provides. There is no validation that the logged action corresponds to an actual on-chain transaction. A dishonest agent can fabricate their audit trail.

The `authorityAtTime` is correctly fetched from `core.effectiveAuthority()`, but all other fields are agent-supplied.

**Recommendation:**
Document that the ledger is an agent-attested log, not a verified transaction record. Reputation validators should cross-reference logged actions against actual on-chain transactions.

---

## Architecture Review

### Positive Observations

1. **No admin keys or proxy patterns** — eliminates governance attack surface entirely.
2. **Lazy decay computation** — gas-efficient; no state updates needed between transactions.
3. **Checked arithmetic via Solidity 0.8.24** — overflow/underflow protection throughout (except the intentional summary overflow guard in [M-01]).
4. **Immutable cross-contract references** — `core` address cannot be changed post-deployment, preventing address manipulation.
5. **Content-addressed policies** — policies are deterministic and deduplicated by their parameters.
6. **Comprehensive test suite** — 82 tests covering unit, integration, fuzz, and edge cases.
7. **Clean separation of concerns** — Core (authority), Policy (permissions), Ledger (audit) are properly isolated.
8. **Events emitted for all state changes** — good for off-chain monitoring.

### Gas Considerations

- `createPolicy()` with large whitelists per tier could be expensive due to storage array writes. Consider documenting maximum practical whitelist sizes.
- `checkAction()` iterates the whitelist linearly — O(n) per check. For large whitelists, consider using a mapping-based approach.

---

## Summary Table

| ID | Severity | Title | Contract |
|----|----------|-------|----------|
| H-01 | High | Sybil vulnerability in permissionless slashing | LeashCore |
| H-02 | High | Whitelist not enforced in `recordSpend()` | LeashPolicy |
| M-01 | Medium | Silent overflow in `summary()` truncates `totalValue` | LeashLedger |
| M-02 | Medium | Unbounded iteration in `verifyChain()` and `summary()` — DoS vector | LeashLedger |
| M-03 | Medium | Spend state not reset on tier transitions | LeashPolicy |
| L-01 | Low | `activeLeashId` silently overwritten on new leash creation | LeashCore |
| L-02 | Low | Leash creation allows zero authority with zero ceiling | LeashCore |
| L-03 | Low | `authorityAt()` returns stale data for past timestamps | LeashCore |
| I-01 | Informational | No reentrancy guards | All |
| I-02 | Informational | No ERC-165 interface support | All |
| I-03 | Informational | No pausability / circuit breaker | All |
| I-04 | Informational | Agent can log fabricated data to ledger | LeashLedger |

---

## Disclaimer

This audit is a best-effort review based on static analysis of the source code. It does not guarantee the absence of vulnerabilities. A formal verification and additional fuzz testing are recommended before mainnet deployment.
