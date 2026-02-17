# Leash Protocol — Crypto VC Evaluation

**Date:** 2026-02-17
**Evaluator Lens:** Top-tier crypto VC
**Overall Rating:** 7.5 / 10

---

## Thesis

Entropy-gated delegation for AI agents on Ethereum. Authority decays passively over time unless actively renewed — "doing nothing is safe."

## Problem-Solution Fit — Strong

The problem is real: autonomous AI agents need on-chain authority, but existing mechanisms (multisigs, timelocks, ERC-20 allowances) are binary. Leash introduces a continuous trust gradient that degrades passively. If a principal disappears, authority decays to zero with no intervention.

## Market Timing — Excellent

AI agents on-chain are no longer hypothetical. With EIP-7702, ERC-7710, x402, and ERC-8004 all maturing, the infrastructure layer for autonomous agents is arriving. Leash positions itself as a composable safety primitive — complementing, not competing.

Target use cases: DeFi portfolio agents, trading automation, governance delegates, LP automation, bridge escrow.

## Technical Architecture — Strong

| Aspect | Assessment |
|--------|------------|
| Separation of concerns | Clean 3-contract split: Core (authority), Policy (permissions), Ledger (audit) |
| Lazy decay computation | Zero gas between heartbeats; decay calculated at read-time |
| Content-addressed policies | Deterministic, immutable. Good composability primitive |
| Rolling hash chains | Tamper-evident audit log enables downstream reputation systems |
| Gas efficiency | 15k–120k gas per operation — reasonable |
| Dependency surface | Minimal (forge-std only). No oracle risk |

**Note:** Linear-only decay is a deliberate simplification but limits expressiveness for complex trust dynamics.

## Code Quality & Security — Above Average

- 816 LOC across 3 contracts, 88 tests (1.76:1 test-to-code ratio)
- Completed security audit with critical fixes applied
- Fuzz tests for overflow/underflow
- No proxy patterns, no delegatecall, no upgradeable storage — immutable by design
- Proper use of unchecked blocks with uint256 intermediate math

**Remaining risk:** Permissionless slashing with 1hr cooldown. Coordinated slashing game theory under adversarial conditions warrants formal analysis.

## Tokenomics — N/A

No native token. Authority units are abstract permission scores, not transferable assets. No protocol fees. MIT-licensed.

- **Positive:** No regulatory surface, no mercenary capital dynamics. Pure infrastructure.
- **Negative:** No direct value capture mechanism. Monetization path unclear.

## Composability & Ecosystem Fit — Strong

Targets integration with ERC-8004 (reputation), ERC-7710 (capability delegation), x402 (agent payments), EIP-7702 (smart EOAs). Positioned as a composable primitive, not a monolithic system.

## Risk Matrix

| Risk | Severity | Notes |
|------|----------|-------|
| No value capture | High | MIT license, no fees, no token |
| Adoption chicken-and-egg | Medium | Needs both agent frameworks and principals |
| Linear decay limitation | Low | May need extension for complex trust models |
| Coordinated slashing | Medium | Game theory not formally proven |
| No upgrade path | Low–Medium | Immutability is a feature, but no patch mechanism |

## Verdict

Leash is a well-engineered, genuinely novel primitive solving a real problem at the right time. Code quality is high, architecture is clean, security posture is solid post-audit.

**What holds it back:** No clear value accrual, early adoption risk, linear-only decay may be too simplistic.

**What would move the needle:** Reference integration with a major agent framework, formal verification of slashing game theory, clear go-to-market strategy with SDKs or hosted service layer.

**Bottom line:** Solid primitive — the kind of bet you want on the AI agent economy. Path from "interesting primitive" to "investable protocol" requires clearer value capture and demonstrated adoption.
