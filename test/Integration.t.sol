// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {LeashCore} from "../src/LeashCore.sol";
import {LeashPolicy} from "../src/LeashPolicy.sol";
import {LeashLedger} from "../src/LeashLedger.sol";

/// @notice Full lifecycle integration tests for the Leash Protocol
contract IntegrationTest is Test {
    LeashCore public core;
    LeashPolicy public policy;
    LeashLedger public ledger;

    address principal = address(0xA);
    address agent = address(0xB);
    address slasher = address(0xC);

    address constant UNISWAP = address(0x1111);
    address constant AAVE = address(0x2222);
    address constant CURVE = address(0x3333);

    function setUp() public {
        // Start at a realistic timestamp to avoid edge cases with timestamp=0
        vm.warp(1_700_000_000);

        core = new LeashCore();
        policy = new LeashPolicy(address(core));
        ledger = new LeashLedger(address(core));
    }

    // ─── Helpers ────────────────────────────────────────────────────────

    function _create4TierPolicy() internal returns (bytes32 policyId) {
        uint128[] memory minAuths = new uint128[](4);
        minAuths[0] = 1e18;
        minAuths[1] = 20e18;
        minAuths[2] = 60e18;
        minAuths[3] = 100e18;

        uint128[] memory caps = new uint128[](4);
        caps[0] = 0;
        caps[1] = 100e6;
        caps[2] = 5_000e6;
        caps[3] = 50_000e6;

        bool[] memory canDeploy = new bool[](4);
        canDeploy[3] = true;

        address[][] memory whitelists = new address[][](4);
        whitelists[0] = new address[](0);
        whitelists[1] = new address[](1);
        whitelists[1][0] = UNISWAP;
        whitelists[2] = new address[](3);
        whitelists[2][0] = UNISWAP;
        whitelists[2][1] = AAVE;
        whitelists[2][2] = CURVE;
        whitelists[3] = new address[](0);

        policyId = policy.createPolicy(1 days, minAuths, caps, canDeploy, whitelists);
    }

    // ─── Standard Lifecycle (from spec) ─────────────────────────────────

    function test_fullLifecycle() public {
        // 1. CREATE: Human creates leash for DeFi agent
        vm.prank(principal);
        bytes32 leashId = core.create(agent, 30e18, 200e18, 138_888_888_888_889); // ~0.5 units/hr decay

        // 2. BIND POLICY: Principal binds a 4-tier policy
        bytes32 policyId = _create4TierPolicy();
        vm.prank(principal);
        policy.bindPolicy(leashId, policyId);

        // 3. AGENT OPERATES: Agent checks status and executes
        (uint8 tier,,) = policy.agentStatus(leashId);
        assertEq(tier, 1); // 30e18 >= 20e18, < 60e18 → Tier 1

        // Agent swaps on Uniswap (whitelisted for tier 1)
        (bool allowed,) = policy.checkAction(leashId, UNISWAP, 50e6);
        assertTrue(allowed);

        // Record spend and log (must be called by agent)
        vm.startPrank(agent);
        policy.recordSpend(leashId, 50e6);
        ledger.log(leashId, LeashLedger.ActionType.SWAP, UNISWAP, 50e6);
        vm.stopPrank();

        // 4. PRINCIPAL MAINTAINS: Weekly heartbeats
        vm.warp(block.timestamp + 7 days);
        vm.prank(principal);
        core.heartbeat(leashId);

        // 5. TRUST COMPOUNDS: Good behavior → boost over time
        vm.prank(principal);
        core.boost(leashId, 40e18); // Boost toward tier 2

        (tier,,) = policy.agentStatus(leashId);
        // Authority is now: decayed from 30e18 over 7 days, then +40e18
        // At 0.5 units/hr, 7 days = 168 hours = 84 units lost
        // 30 - 84 = would be 0 (clamped), then heartbeat materializes to 0
        // But heartbeat was called first, then boost adds 40
        // So authority = 0 + 40 = 40e18 → Tier 1 still (need 60 for tier 2)
        assertEq(tier, 1);

        // Principal boosts more
        vm.prank(principal);
        core.boost(leashId, 80e18);
        (tier,,) = policy.agentStatus(leashId);
        assertEq(tier, 3); // 40 + 80 = 120e18 → Tier 3

        // 6. WALKAWAY: Principal stops heartbeats
        uint256 ttl = core.timeToZero(leashId);
        vm.warp(block.timestamp + ttl + 1);

        assertEq(core.effectiveAuthority(leashId), 0);
        (tier,,) = policy.agentStatus(leashId);
        // Below all tiers
        assertEq(tier, type(uint8).max);
    }

    // ─── DeFi Portfolio Agent Example (from spec) ───────────────────────

    function test_defiPortfolioAgent() public {
        // Initial: 30 units, ceiling 200, 0.5 units/hour decay
        vm.prank(principal);
        bytes32 leashId = core.create(agent, 30e18, 200e18, 138_888_888_888_889);

        bytes32 policyId = _create4TierPolicy();
        vm.prank(principal);
        policy.bindPolicy(leashId, policyId);

        // At 30 authority → Tier 1 (Micro: swap up to $100/day on Uniswap)
        (uint8 tier,,) = policy.agentStatus(leashId);
        assertEq(tier, 1);

        // Agent swaps on Uniswap
        (bool allowed,) = policy.checkAction(leashId, UNISWAP, 80e6);
        assertTrue(allowed);

        // Agent cannot use Aave (not in tier 1 whitelist)
        (allowed,) = policy.checkAction(leashId, AAVE, 80e6);
        assertFalse(allowed);

        // Agent cannot exceed tier 1 cap
        (allowed,) = policy.checkAction(leashId, UNISWAP, 101e6);
        assertFalse(allowed);

        // Over time, principal boosts. Daily heartbeat + weekly boost of 100 units
        // Decay is ~12 units/day, so weekly boost of 100 compensates ~84 decay + net gain
        for (uint256 i = 0; i < 30; i++) {
            vm.warp(block.timestamp + 1 days);
            vm.prank(principal);
            core.heartbeat(leashId);
            if (i % 7 == 0) {
                vm.prank(principal);
                core.boost(leashId, 100e18);
            }
        }

        // After 30 days with boosts, authority should have grown past tier 2
        uint128 auth = core.effectiveAuthority(leashId);
        assertTrue(auth > 60e18);

        // Agent can now use whitelisted DEXes
        (tier,,) = policy.agentStatus(leashId);
        assertTrue(tier >= 2);
    }

    // ─── Rogue Agent Scenario ───────────────────────────────────────────

    function test_rogueAgent_principalSlashAndKill() public {
        vm.prank(principal);
        bytes32 leashId = core.create(agent, 100e18, 200e18, 277_777_777_777_778);

        // Agent goes rogue — community notices
        vm.prank(slasher);
        core.slash(leashId, 30e18);

        uint128 auth = core.effectiveAuthority(leashId);
        assertEq(auth, 70e18);

        // Principal kills the leash
        vm.prank(principal);
        core.kill(leashId);

        assertEq(core.effectiveAuthority(leashId), 0);
        LeashCore.Leash memory l = core.getLeash(leashId);
        assertFalse(l.alive);
    }

    // ─── Slash Griefing Resistance ──────────────────────────────────────

    function test_slashGriefingResistance() public {
        vm.prank(principal);
        bytes32 leashId = core.create(agent, 100e18, 200e18, 277_777_777_777_778);

        // Slasher attacks
        vm.prank(slasher);
        core.slash(leashId, 20e18);

        // Cannot slash again within cooldown
        vm.prank(slasher);
        vm.expectRevert(LeashCore.SlashCooldownActive.selector);
        core.slash(leashId, 20e18);

        // Principal can outpace slasher by boosting
        vm.prank(principal);
        core.boost(leashId, 50e18);

        uint128 auth = core.effectiveAuthority(leashId);
        assertTrue(auth > 100e18); // Should be above original level
    }

    // ─── Both Disappear Scenario ────────────────────────────────────────

    function test_bothDisappear_systemQuiesces() public {
        vm.prank(principal);
        bytes32 leashId = core.create(agent, 100e18, 200e18, 277_777_777_777_778);

        bytes32 policyId = _create4TierPolicy();
        vm.prank(principal);
        policy.bindPolicy(leashId, policyId);

        // Log some actions (as agent)
        vm.prank(agent);
        ledger.log(leashId, LeashLedger.ActionType.TRANSFER, address(0x1111), 100e6);

        // Both disappear. Nobody heartbeats.
        uint256 ttl = core.timeToZero(leashId);
        vm.warp(block.timestamp + ttl + 1);

        // System quiesces to inert state
        assertEq(core.effectiveAuthority(leashId), 0);

        (uint8 tier,,) = policy.agentStatus(leashId);
        assertEq(tier, type(uint8).max); // Below all tiers

        // Audit trail remains intact
        bool valid = ledger.verifyChain(leashId);
        assertTrue(valid);

        LeashLedger.Summary memory s = ledger.summary(leashId);
        assertEq(s.totalActions, 1);
    }

    // ─── Chain Halt Scenario ────────────────────────────────────────────

    function test_chainHalt_decayCatchesUp() public {
        vm.prank(principal);
        bytes32 leashId = core.create(agent, 100e18, 200e18, 277_777_777_777_778);

        // Simulate chain halt for 12 hours
        vm.warp(block.timestamp + 12 hours);

        // Decay catches up proportionally: 12 * ~1 = ~12 units
        uint128 auth = core.effectiveAuthority(leashId);
        uint128 expectedDecay = uint128(uint256(277_777_777_777_778) * 12 hours);
        assertApproxEqAbs(auth, 100e18 - expectedDecay, 1e15);
    }

    // ─── Multiple Leashes ───────────────────────────────────────────────

    function test_multipleLeashesIndependent() public {
        vm.startPrank(principal);
        bytes32 leash1 = core.create(agent, 50e18, 200e18, 277_777_777_777_778);
        bytes32 leash2 = core.create(address(0xD), 80e18, 300e18, 138_888_888_888_889);
        vm.stopPrank();

        assertTrue(leash1 != leash2);

        // Kill one — other should be unaffected
        vm.prank(principal);
        core.kill(leash1);

        assertEq(core.effectiveAuthority(leash1), 0);
        assertEq(core.effectiveAuthority(leash2), 80e18);
    }

    // ─── Ledger Chain Integrity Across Full Lifecycle ────────────────────

    function test_ledgerIntegrity_throughFullLifecycle() public {
        vm.prank(principal);
        bytes32 leashId = core.create(agent, 100e18, 200e18, 277_777_777_777_778);

        // Multiple actions over time (all logged by agent)
        vm.prank(agent);
        ledger.log(leashId, LeashLedger.ActionType.TRANSFER, address(0x1), 100e6);

        vm.warp(block.timestamp + 1 hours);
        vm.prank(agent);
        ledger.log(leashId, LeashLedger.ActionType.SWAP, address(0x2), 200e6);

        vm.warp(block.timestamp + 2 hours);
        vm.prank(principal);
        core.heartbeat(leashId);
        vm.prank(agent);
        ledger.log(leashId, LeashLedger.ActionType.PROVIDE_LP, address(0x3), 500e6);

        vm.warp(block.timestamp + 1 hours);
        vm.prank(principal);
        core.boost(leashId, 30e18);
        vm.prank(agent);
        ledger.log(leashId, LeashLedger.ActionType.BORROW, address(0x4), 1000e6);

        // Verify chain integrity
        bool valid = ledger.verifyChain(leashId);
        assertTrue(valid);

        // Verify summary
        LeashLedger.Summary memory s = ledger.summary(leashId);
        assertEq(s.totalActions, 4);
        assertEq(s.totalValue, 1800e6);
        assertTrue(s.highestAuthority > s.lowestAuthority); // Authority varied
    }

    // ─── Access Control ─────────────────────────────────────────────────

    function test_recordSpend_onlyAgent() public {
        vm.prank(principal);
        bytes32 leashId = core.create(agent, 100e18, 200e18, 277_777_777_777_778);

        bytes32 policyId = _create4TierPolicy();
        vm.prank(principal);
        policy.bindPolicy(leashId, policyId);

        // Non-agent cannot recordSpend
        vm.prank(principal);
        vm.expectRevert(LeashPolicy.OnlyAgent.selector);
        policy.recordSpend(leashId, 100e6);

        // Agent can recordSpend
        vm.prank(agent);
        policy.recordSpend(leashId, 100e6);
    }

    function test_log_onlyAgent() public {
        vm.prank(principal);
        bytes32 leashId = core.create(agent, 100e18, 200e18, 277_777_777_777_778);

        // Non-agent cannot log
        vm.prank(principal);
        vm.expectRevert(LeashLedger.OnlyAgent.selector);
        ledger.log(leashId, LeashLedger.ActionType.TRANSFER, address(0x1), 100e6);

        // Agent can log
        vm.prank(agent);
        ledger.log(leashId, LeashLedger.ActionType.TRANSFER, address(0x1), 100e6);
    }

    function test_create_revertsOnZeroAgent() public {
        vm.prank(principal);
        vm.expectRevert(LeashCore.AgentCannotBeZero.selector);
        core.create(address(0), 100e18, 200e18, 277_777_777_777_778);
    }
}
