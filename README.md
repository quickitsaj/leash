# Leash Protocol

**Entropy-gated delegation for AI agents on Ethereum.**

Leash introduces authority that naturally decays without active renewal — doing nothing is safe. If every human participant disappears, all leashes decay to zero authority without requiring revocation or external intervention.

## Architecture

Three immutable, ownerless contracts with no admin keys, proxy patterns, or oracle dependencies.

| Contract | Purpose |
|----------|---------|
| **LeashCore** | Manages decaying authority scores between principals and agents. Authority decreases linearly: `effective = max(0, stored - elapsed * decayPerSecond)`. Decay is computed lazily at read-time. |
| **LeashPolicy** | Maps authority scores to tiered permission sets (up to 8 tiers). Content-addressed, immutable policies govern spending caps, whitelisted targets, and sub-delegation rights. Epoch-based spend tracking resets automatically. |
| **LeashLedger** | Append-only behavioral audit trail with rolling hash chain for tamper-evidence. Records actions at their corresponding authority levels for ERC-8004 reputation validators. |

## How It Works

```
Principal creates leash ──> Agent receives authority ──> Authority decays over time
       │                                                          │
       ├── heartbeat() resets decay clock                         │
       ├── boost() increases authority (capped at ceiling)        │
       ├── slash() permissionless reduction (rate-limited)        │
       └── kill() permanent destruction                           ▼
                                                          Authority → 0
```

### Lifecycle

1. **Create** — Human calls `create(agent, initialAuthority, ceiling, decayPerSecond)`
2. **Bind Policy** — Principal binds an immutable tiered policy to the leash
3. **Operate** — Agent checks `agentStatus()`, validates via `checkAction()`, executes, logs to ledger
4. **Maintain** — Principal sends periodic heartbeats; boosts authority over time as trust compounds
5. **Walkaway** — If principal stops heartbeating, authority decays to zero naturally

### Walkaway Safety

| Scenario | Behavior |
|----------|----------|
| Principal disappears | Authority decays to 0 over `timeToZero()` |
| Agent goes rogue | Principal or community can `slash()` / `kill()` |
| Both disappear | System quiesces to inert state |
| Deployer disappears | No effect — no admin functions |
| Chain halts temporarily | Decay catches up proportionally on resume |

## Build

```shell
forge build
```

## Test

```shell
forge test
```

82 tests across 4 suites: unit tests for each contract, integration tests covering full lifecycle scenarios, and fuzz tests for overflow/underflow safety.

## Key Functions

### LeashCore

| Function | Caller | Gas | Description |
|----------|--------|-----|-------------|
| `create()` | Anyone | ~120k | Create leash, caller becomes principal |
| `heartbeat()` | Principal | ~25k | Reset decay clock (does not recover lost authority) |
| `boost()` | Principal | ~28k | Increase authority, capped at ceiling |
| `slash()` | Anyone | ~30k | Reduce authority (rate-limited: 1 per hour per slasher) |
| `kill()` | Principal | ~15k | Permanently destroy leash |
| `effectiveAuthority()` | View | ~5k | Current authority with decay applied |
| `timeToZero()` | View | — | Seconds until authority reaches zero |
| `authorityAt()` | View | — | Projected authority at future timestamp |

### LeashPolicy

| Function | Caller | Description |
|----------|--------|-------------|
| `createPolicy()` | Anyone | Register immutable policy (content-addressed) |
| `bindPolicy()` | Principal | One-time irreversible policy binding |
| `checkAction()` | View | Verify action within policy bounds |
| `recordSpend()` | Middleware | Debit epoch budget after validated action |
| `agentStatus()` | View | Current tier, remaining budget, sub-deploy capability |

### LeashLedger

| Function | Caller | Description |
|----------|--------|-------------|
| `log()` | Anyone | Append action to audit trail |
| `verifyChain()` | View | Validate hash chain integrity |
| `summary()` | View | Aggregate stats (total actions, authority range, value) |

## Integration Points

Leash composes with emerging standards:

- **ERC-8004** — Reputation: LeashLedger provides per-relationship audit data
- **ERC-7710** — Capability delegation: Leash adds entropy-gating
- **x402** — Agent payments: LeashPolicy spending caps constrain payment flows
- **EIP-7702** — Smart EOAs: Agents operate via smart accounts

## License

MIT
