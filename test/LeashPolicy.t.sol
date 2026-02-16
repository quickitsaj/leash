// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {LeashCore} from "../src/LeashCore.sol";
import {LeashPolicy} from "../src/LeashPolicy.sol";

contract LeashPolicyTest is Test {
    LeashCore public core;
    LeashPolicy public policy;

    address principal = address(0xA);
    address agent = address(0xB);

    uint128 constant INITIAL_AUTHORITY = 100e18;
    uint128 constant CEILING = 500e18;
    uint128 constant DECAY_PER_SECOND = 277_777_777_777_778; // ~1 unit/hour

    bytes32 leashId;

    function setUp() public {
        vm.warp(1_700_000_000);
        core = new LeashCore();
        policy = new LeashPolicy(address(core));

        vm.prank(principal);
        leashId = core.create(agent, INITIAL_AUTHORITY, CEILING, DECAY_PER_SECOND);
    }

    // ─── Helpers ────────────────────────────────────────────────────────

    function _createStandardPolicy() internal returns (bytes32 policyId) {
        uint128[] memory minAuths = new uint128[](4);
        minAuths[0] = 1e18; // Tier 0: Observer
        minAuths[1] = 20e18; // Tier 1: Micro
        minAuths[2] = 60e18; // Tier 2: Standard
        minAuths[3] = 100e18; // Tier 3: Full

        uint128[] memory caps = new uint128[](4);
        caps[0] = 0; // Observer: no spend
        caps[1] = 100e6; // Micro: 100 USDC
        caps[2] = 5_000e6; // Standard: 5,000 USDC
        caps[3] = 50_000e6; // Full: 50,000 USDC

        bool[] memory canDeploy = new bool[](4);
        canDeploy[0] = false;
        canDeploy[1] = false;
        canDeploy[2] = false;
        canDeploy[3] = true;

        address[][] memory whitelists = new address[][](4);
        whitelists[0] = new address[](0); // Observer: view-only
        whitelists[1] = new address[](1);
        whitelists[1][0] = address(0x1111); // Uniswap Router
        whitelists[2] = new address[](3);
        whitelists[2][0] = address(0x1111); // Uniswap
        whitelists[2][1] = address(0x2222); // Aave
        whitelists[2][2] = address(0x3333); // Curve
        whitelists[3] = new address[](0); // Full: any target

        policyId = policy.createPolicy(1 days, minAuths, caps, canDeploy, whitelists);
    }

    // ─── createPolicy() ─────────────────────────────────────────────────

    function test_createPolicy_success() public {
        bytes32 policyId = _createStandardPolicy();

        LeashPolicy.Policy memory p = policy.getPolicy(policyId);
        assertTrue(p.exists);
        assertEq(p.epochDuration, 1 days);
        assertEq(p.tierCount, 4);
    }

    function test_createPolicy_contentAddressed() public {
        bytes32 policyId1 = _createStandardPolicy();

        // Creating same policy again should revert (same content hash)
        vm.expectRevert(LeashPolicy.PolicyAlreadyExists.selector);
        _createStandardPolicy();

        // Verify it's deterministic
        assertTrue(policyId1 != bytes32(0));
    }

    function test_createPolicy_revertsIfTierCountZero() public {
        uint128[] memory minAuths = new uint128[](0);
        uint128[] memory caps = new uint128[](0);
        bool[] memory canDeploy = new bool[](0);
        address[][] memory whitelists = new address[][](0);

        vm.expectRevert(LeashPolicy.InvalidTierCount.selector);
        policy.createPolicy(1 days, minAuths, caps, canDeploy, whitelists);
    }

    function test_createPolicy_revertsIfTierCountExceedsMax() public {
        uint128[] memory minAuths = new uint128[](9);
        uint128[] memory caps = new uint128[](9);
        bool[] memory canDeploy = new bool[](9);
        address[][] memory whitelists = new address[][](9);

        for (uint8 i = 0; i < 9; i++) {
            minAuths[i] = uint128(i + 1) * 1e18;
        }

        vm.expectRevert(LeashPolicy.InvalidTierCount.selector);
        policy.createPolicy(1 days, minAuths, caps, canDeploy, whitelists);
    }

    function test_createPolicy_revertsIfEpochZero() public {
        uint128[] memory minAuths = new uint128[](1);
        minAuths[0] = 1e18;
        uint128[] memory caps = new uint128[](1);
        caps[0] = 100e6;
        bool[] memory canDeploy = new bool[](1);
        address[][] memory whitelists = new address[][](1);
        whitelists[0] = new address[](0);

        vm.expectRevert(LeashPolicy.EpochDurationZero.selector);
        policy.createPolicy(0, minAuths, caps, canDeploy, whitelists);
    }

    function test_createPolicy_revertsIfNotAscending() public {
        uint128[] memory minAuths = new uint128[](2);
        minAuths[0] = 50e18;
        minAuths[1] = 20e18; // Not ascending

        uint128[] memory caps = new uint128[](2);
        caps[0] = 100e6;
        caps[1] = 500e6;

        bool[] memory canDeploy = new bool[](2);
        address[][] memory whitelists = new address[][](2);
        whitelists[0] = new address[](0);
        whitelists[1] = new address[](0);

        vm.expectRevert(LeashPolicy.TierAuthoritiesNotAscending.selector);
        policy.createPolicy(1 days, minAuths, caps, canDeploy, whitelists);
    }

    // ─── bindPolicy() ───────────────────────────────────────────────────

    function test_bindPolicy_success() public {
        bytes32 policyId = _createStandardPolicy();

        vm.prank(principal);
        policy.bindPolicy(leashId, policyId);

        assertEq(policy.boundPolicy(leashId), policyId);
    }

    function test_bindPolicy_irreversible() public {
        bytes32 policyId = _createStandardPolicy();

        vm.prank(principal);
        policy.bindPolicy(leashId, policyId);

        // Try to bind another policy — different content to get different ID
        uint128[] memory minAuths = new uint128[](1);
        minAuths[0] = 5e18;
        uint128[] memory caps = new uint128[](1);
        caps[0] = 200e6;
        bool[] memory canDeploy = new bool[](1);
        address[][] memory whitelists = new address[][](1);
        whitelists[0] = new address[](0);

        bytes32 policyId2 = policy.createPolicy(2 days, minAuths, caps, canDeploy, whitelists);

        vm.prank(principal);
        vm.expectRevert(LeashPolicy.LeashAlreadyBound.selector);
        policy.bindPolicy(leashId, policyId2);
    }

    function test_bindPolicy_revertsIfNotPrincipal() public {
        bytes32 policyId = _createStandardPolicy();

        vm.prank(agent);
        vm.expectRevert(LeashPolicy.OnlyPrincipal.selector);
        policy.bindPolicy(leashId, policyId);
    }

    function test_bindPolicy_revertsIfPolicyDoesNotExist() public {
        vm.prank(principal);
        vm.expectRevert(LeashPolicy.PolicyDoesNotExist.selector);
        policy.bindPolicy(leashId, bytes32(uint256(0xDEAD)));
    }

    // ─── checkAction() ──────────────────────────────────────────────────

    function test_checkAction_allowedAtCorrectTier() public {
        bytes32 policyId = _createStandardPolicy();
        vm.prank(principal);
        policy.bindPolicy(leashId, policyId);

        // Agent has 100e18 authority → qualifies for Tier 3 (Full)
        // Tier 3 has empty whitelist = any target allowed
        (bool allowed, uint8 tier) = policy.checkAction(leashId, address(0x9999), 1000e6);
        assertTrue(allowed);
        assertEq(tier, 3);
    }

    function test_checkAction_respectsWhitelist() public {
        bytes32 policyId = _createStandardPolicy();
        vm.prank(principal);
        policy.bindPolicy(leashId, policyId);

        // Decay authority to Tier 1 range (20-60)
        // At 30e18, should be Tier 1 (minAuth=20e18, whitelist=[0x1111])
        vm.prank(principal);
        core.kill(leashId);

        // Create new leash at tier 1 authority
        vm.prank(principal);
        bytes32 leashId2 = core.create(agent, 30e18, CEILING, DECAY_PER_SECOND);
        vm.prank(principal);
        policy.bindPolicy(leashId2, policyId);

        // Whitelisted target should work
        (bool allowed,) = policy.checkAction(leashId2, address(0x1111), 50e6);
        assertTrue(allowed);

        // Non-whitelisted target should fail
        (bool allowed2,) = policy.checkAction(leashId2, address(0x9999), 50e6);
        assertFalse(allowed2);
    }

    function test_checkAction_respectsSpendCap() public {
        bytes32 policyId = _createStandardPolicy();
        vm.prank(principal);
        policy.bindPolicy(leashId, policyId);

        // Tier 3 has 50,000 USDC cap
        (bool allowed,) = policy.checkAction(leashId, address(0x9999), 50_000e6);
        assertTrue(allowed);

        // Over cap should fail
        (bool allowed2,) = policy.checkAction(leashId, address(0x9999), 50_001e6);
        assertFalse(allowed2);
    }

    function test_checkAction_unboundReturnsNotAllowed() public {
        (bool allowed, uint8 tier) = policy.checkAction(leashId, address(0x1111), 100e6);
        assertFalse(allowed);
        assertEq(tier, 0);
    }

    // ─── recordSpend() ──────────────────────────────────────────────────

    function test_recordSpend_debitsBudget() public {
        bytes32 policyId = _createStandardPolicy();
        vm.prank(principal);
        policy.bindPolicy(leashId, policyId);

        // Spend 10,000 USDC
        policy.recordSpend(leashId, 10_000e6);

        // Check remaining budget (Tier 3: 50,000 cap - 10,000 spent = 40,000)
        (uint8 tier, uint128 remaining, bool canDeploy) = policy.agentStatus(leashId);
        assertEq(tier, 3);
        assertEq(remaining, 40_000e6);
        assertTrue(canDeploy);
    }

    function test_recordSpend_revertsIfOverBudget() public {
        bytes32 policyId = _createStandardPolicy();
        vm.prank(principal);
        policy.bindPolicy(leashId, policyId);

        // Spend full budget
        policy.recordSpend(leashId, 50_000e6);

        // Next spend should fail
        vm.expectRevert(LeashPolicy.BudgetExceeded.selector);
        policy.recordSpend(leashId, 1);
    }

    function test_recordSpend_epochResetsAutomatically() public {
        bytes32 policyId = _createStandardPolicy();
        vm.prank(principal);
        policy.bindPolicy(leashId, policyId);

        // Spend full tier 3 budget
        policy.recordSpend(leashId, 50_000e6);

        // Warp past epoch (1 day)
        vm.warp(block.timestamp + 1 days);

        // Boost to keep authority at tier 3 level (compensate for decay)
        vm.prank(principal);
        core.boost(leashId, 50e18);

        // Should be able to spend again (new epoch)
        policy.recordSpend(leashId, 10_000e6);
        (, uint128 remaining,) = policy.agentStatus(leashId);
        assertEq(remaining, 40_000e6);
    }

    function test_recordSpend_revertsIfUnbound() public {
        vm.expectRevert(LeashPolicy.LeashNotBound.selector);
        policy.recordSpend(leashId, 100e6);
    }

    // ─── agentStatus() ──────────────────────────────────────────────────

    function test_agentStatus_returnsCorrectTier() public {
        bytes32 policyId = _createStandardPolicy();
        vm.prank(principal);
        policy.bindPolicy(leashId, policyId);

        (uint8 tier,, bool canDeploy) = policy.agentStatus(leashId);
        assertEq(tier, 3); // 100e18 >= Tier 3 threshold
        assertTrue(canDeploy);
    }

    function test_agentStatus_changesWithDecay() public {
        bytes32 policyId = _createStandardPolicy();
        vm.prank(principal);
        policy.bindPolicy(leashId, policyId);

        // Let authority decay from 100 to between 20-60 (Tier 1 range)
        // Need to lose >40 units but <80. At ~1 unit/hr, 50 hours = ~50 units lost → 50e18 auth
        vm.warp(block.timestamp + 50 hours);

        (uint8 tier,, bool canDeploy) = policy.agentStatus(leashId);
        assertEq(tier, 1); // Should have dropped to Tier 1
        assertFalse(canDeploy);
    }

    // ─── authorityToNextTier() ──────────────────────────────────────────

    function test_authorityToNextTier_returnsCorrectDelta() public {
        // Create leash at tier 1 (30 units)
        vm.prank(principal);
        bytes32 leashId2 = core.create(address(0xD), 30e18, CEILING, DECAY_PER_SECOND);

        bytes32 policyId = _createStandardPolicy();
        vm.prank(principal);
        policy.bindPolicy(leashId2, policyId);

        uint128 needed = policy.authorityToNextTier(leashId2);
        assertEq(needed, 30e18); // Need 60e18 for Tier 2, have 30e18
    }

    function test_authorityToNextTier_zeroAtMaxTier() public {
        bytes32 policyId = _createStandardPolicy();
        vm.prank(principal);
        policy.bindPolicy(leashId, policyId);

        uint128 needed = policy.authorityToNextTier(leashId);
        assertEq(needed, 0); // Already at Tier 3 (max)
    }
}
