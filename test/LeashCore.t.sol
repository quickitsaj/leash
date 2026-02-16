// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {LeashCore} from "../src/LeashCore.sol";

contract LeashCoreTest is Test {
    LeashCore public core;

    address principal = address(0xA);
    address agent = address(0xB);
    address slasher = address(0xC);

    uint128 constant INITIAL_AUTHORITY = 50e18; // 50 units
    uint128 constant CEILING = 500e18; // 500 units
    uint128 constant DECAY_PER_SECOND = 277_777_777_777_778; // ~1 unit/hour

    function setUp() public {
        vm.warp(1_700_000_000);
        core = new LeashCore();
    }

    // ─── create() ───────────────────────────────────────────────────────

    function test_create_success() public {
        vm.prank(principal);
        bytes32 leashId = core.create(agent, INITIAL_AUTHORITY, CEILING, DECAY_PER_SECOND);

        LeashCore.Leash memory l = core.getLeash(leashId);
        assertEq(l.principal, principal);
        assertEq(l.agent, agent);
        assertEq(l.authority, INITIAL_AUTHORITY);
        assertEq(l.ceiling, CEILING);
        assertEq(l.decayPerSecond, DECAY_PER_SECOND);
        assertTrue(l.alive);
        assertEq(l.createdAt, block.timestamp);
        assertEq(l.lastHeartbeat, block.timestamp);
    }

    function test_create_emitsEvent() public {
        vm.prank(principal);
        vm.expectEmit(false, true, true, true);
        emit LeashCore.LeashCreated(bytes32(0), principal, agent, INITIAL_AUTHORITY, CEILING, DECAY_PER_SECOND);
        core.create(agent, INITIAL_AUTHORITY, CEILING, DECAY_PER_SECOND);
    }

    function test_create_deterministicId() public {
        vm.prank(principal);
        bytes32 leashId = core.create(agent, INITIAL_AUTHORITY, CEILING, DECAY_PER_SECOND);

        bytes32 expected = keccak256(abi.encodePacked(principal, agent, uint256(0)));
        assertEq(leashId, expected);
    }

    function test_create_updatesActiveLeash() public {
        vm.prank(principal);
        bytes32 leashId = core.create(agent, INITIAL_AUTHORITY, CEILING, DECAY_PER_SECOND);

        assertEq(core.activeLeashId(principal, agent), leashId);
    }

    function test_create_incrementsLeashCount() public {
        vm.startPrank(principal);
        core.create(agent, INITIAL_AUTHORITY, CEILING, DECAY_PER_SECOND);
        assertEq(core.leashCount(principal), 1);

        core.create(address(0xD), INITIAL_AUTHORITY, CEILING, DECAY_PER_SECOND);
        assertEq(core.leashCount(principal), 2);
        vm.stopPrank();
    }

    function test_create_revertsIfAgentIsPrincipal() public {
        vm.prank(principal);
        vm.expectRevert(LeashCore.AgentCannotBePrincipal.selector);
        core.create(principal, INITIAL_AUTHORITY, CEILING, DECAY_PER_SECOND);
    }

    function test_create_revertsIfAgentIsZero() public {
        vm.prank(principal);
        vm.expectRevert(LeashCore.AgentCannotBeZero.selector);
        core.create(address(0), INITIAL_AUTHORITY, CEILING, DECAY_PER_SECOND);
    }

    function test_create_revertsIfAuthorityExceedsCeiling() public {
        vm.prank(principal);
        vm.expectRevert(LeashCore.InitialAuthorityExceedsCeiling.selector);
        core.create(agent, CEILING + 1, CEILING, DECAY_PER_SECOND);
    }

    function test_create_revertsIfDecayZero() public {
        vm.prank(principal);
        vm.expectRevert(LeashCore.DecayMustBeNonZero.selector);
        core.create(agent, INITIAL_AUTHORITY, CEILING, 0);
    }

    // ─── Decay mechanics ────────────────────────────────────────────────

    function test_decay_linearOverTime() public {
        vm.prank(principal);
        bytes32 leashId = core.create(agent, INITIAL_AUTHORITY, CEILING, DECAY_PER_SECOND);

        // After 1 hour, should have decayed ~1 unit
        vm.warp(block.timestamp + 1 hours);
        uint128 eff = core.effectiveAuthority(leashId);

        // 1 hour * 277_777_777_777_778 per second = ~1e18 decay
        uint128 expectedDecay = uint128(uint256(DECAY_PER_SECOND) * 3600);
        assertApproxEqAbs(eff, INITIAL_AUTHORITY - expectedDecay, 1e15); // within 0.001 unit tolerance
    }

    function test_decay_floorsAtZero() public {
        vm.prank(principal);
        bytes32 leashId = core.create(agent, INITIAL_AUTHORITY, CEILING, DECAY_PER_SECOND);

        // Warp far into the future
        vm.warp(block.timestamp + 365 days);
        assertEq(core.effectiveAuthority(leashId), 0);
    }

    function test_timeToZero_calculatesCorrectly() public {
        vm.prank(principal);
        bytes32 leashId = core.create(agent, INITIAL_AUTHORITY, CEILING, DECAY_PER_SECOND);

        uint256 ttl = core.timeToZero(leashId);
        // 50e18 / 277_777_777_777_778 ≈ 180,000 seconds ≈ 50 hours
        assertApproxEqAbs(ttl, 180_000, 1);
    }

    function test_authorityAt_futureProjection() public {
        vm.prank(principal);
        bytes32 leashId = core.create(agent, INITIAL_AUTHORITY, CEILING, DECAY_PER_SECOND);

        uint256 futureTime = block.timestamp + 1 hours;
        uint128 projected = core.authorityAt(leashId, futureTime);

        uint128 expectedDecay = uint128(uint256(DECAY_PER_SECOND) * 3600);
        assertApproxEqAbs(projected, INITIAL_AUTHORITY - expectedDecay, 1e15);
    }

    // ─── heartbeat() ────────────────────────────────────────────────────

    function test_heartbeat_resetsDecayClock() public {
        vm.prank(principal);
        bytes32 leashId = core.create(agent, INITIAL_AUTHORITY, CEILING, DECAY_PER_SECOND);

        // Let some authority decay
        vm.warp(block.timestamp + 1 hours);
        uint128 decayedAuth = core.effectiveAuthority(leashId);

        // Heartbeat
        vm.prank(principal);
        core.heartbeat(leashId);

        // Authority should be materialized at decayed value
        assertEq(core.effectiveAuthority(leashId), decayedAuth);

        // After another hour from heartbeat, should have decayed from the materialized value
        vm.warp(block.timestamp + 1 hours);
        uint128 afterSecondDecay = core.effectiveAuthority(leashId);
        assertTrue(afterSecondDecay < decayedAuth);
    }

    function test_heartbeat_doesNotRecoverAuthority() public {
        vm.prank(principal);
        bytes32 leashId = core.create(agent, INITIAL_AUTHORITY, CEILING, DECAY_PER_SECOND);

        vm.warp(block.timestamp + 2 hours);
        uint128 beforeHeartbeat = core.effectiveAuthority(leashId);

        vm.prank(principal);
        core.heartbeat(leashId);

        // Authority should NOT increase, just freeze at current level
        assertEq(core.effectiveAuthority(leashId), beforeHeartbeat);
    }

    function test_heartbeat_revertsIfNotPrincipal() public {
        vm.prank(principal);
        bytes32 leashId = core.create(agent, INITIAL_AUTHORITY, CEILING, DECAY_PER_SECOND);

        vm.prank(agent);
        vm.expectRevert(LeashCore.OnlyPrincipal.selector);
        core.heartbeat(leashId);
    }

    function test_heartbeat_revertsIfDead() public {
        vm.prank(principal);
        bytes32 leashId = core.create(agent, INITIAL_AUTHORITY, CEILING, DECAY_PER_SECOND);

        vm.prank(principal);
        core.kill(leashId);

        vm.prank(principal);
        vm.expectRevert(LeashCore.LeashNotAlive.selector);
        core.heartbeat(leashId);
    }

    // ─── boost() ────────────────────────────────────────────────────────

    function test_boost_increasesAuthority() public {
        vm.prank(principal);
        bytes32 leashId = core.create(agent, INITIAL_AUTHORITY, CEILING, DECAY_PER_SECOND);

        vm.warp(block.timestamp + 1 hours);

        vm.prank(principal);
        core.boost(leashId, 20e18);

        // Should be decayed value + 20
        uint128 expectedDecay = uint128(uint256(DECAY_PER_SECOND) * 3600);
        uint128 expected = INITIAL_AUTHORITY - expectedDecay + 20e18;
        assertApproxEqAbs(core.effectiveAuthority(leashId), expected, 1e15);
    }

    function test_boost_cappedAtCeiling() public {
        vm.prank(principal);
        bytes32 leashId = core.create(agent, INITIAL_AUTHORITY, CEILING, DECAY_PER_SECOND);

        vm.prank(principal);
        core.boost(leashId, CEILING); // Try to boost way beyond ceiling

        assertEq(core.effectiveAuthority(leashId), CEILING);
    }

    function test_boost_resetsDecayClock() public {
        vm.prank(principal);
        bytes32 leashId = core.create(agent, INITIAL_AUTHORITY, CEILING, DECAY_PER_SECOND);

        vm.warp(block.timestamp + 1 hours);

        vm.prank(principal);
        core.boost(leashId, 10e18);

        uint128 afterBoost = core.effectiveAuthority(leashId);

        // No time has passed since boost — authority shouldn't have decayed
        LeashCore.Leash memory l = core.getLeash(leashId);
        assertEq(l.lastHeartbeat, block.timestamp);
        assertEq(l.authority, afterBoost);
    }

    function test_boost_revertsIfNotPrincipal() public {
        vm.prank(principal);
        bytes32 leashId = core.create(agent, INITIAL_AUTHORITY, CEILING, DECAY_PER_SECOND);

        vm.prank(agent);
        vm.expectRevert(LeashCore.OnlyPrincipal.selector);
        core.boost(leashId, 10e18);
    }

    function test_boost_revertsIfAmountZero() public {
        vm.prank(principal);
        bytes32 leashId = core.create(agent, INITIAL_AUTHORITY, CEILING, DECAY_PER_SECOND);

        vm.prank(principal);
        vm.expectRevert(LeashCore.BoostAmountZero.selector);
        core.boost(leashId, 0);
    }

    // ─── slash() ────────────────────────────────────────────────────────

    function test_slash_reducesAuthority() public {
        vm.prank(principal);
        bytes32 leashId = core.create(agent, INITIAL_AUTHORITY, CEILING, DECAY_PER_SECOND);

        vm.prank(slasher);
        core.slash(leashId, 10e18);

        uint128 eff = core.effectiveAuthority(leashId);
        assertEq(eff, INITIAL_AUTHORITY - 10e18);
    }

    function test_slash_permissionless() public {
        vm.prank(principal);
        bytes32 leashId = core.create(agent, INITIAL_AUTHORITY, CEILING, DECAY_PER_SECOND);

        // Anyone can slash
        address randomAddr = address(0xDEAD);
        vm.prank(randomAddr);
        core.slash(leashId, 5e18);

        assertEq(core.effectiveAuthority(leashId), INITIAL_AUTHORITY - 5e18);
    }

    function test_slash_floorsAtZero() public {
        vm.prank(principal);
        bytes32 leashId = core.create(agent, INITIAL_AUTHORITY, CEILING, DECAY_PER_SECOND);

        vm.prank(slasher);
        core.slash(leashId, INITIAL_AUTHORITY + 100e18); // Slash way more than available

        assertEq(core.effectiveAuthority(leashId), 0);
    }

    function test_slash_rateLimited() public {
        vm.prank(principal);
        bytes32 leashId = core.create(agent, INITIAL_AUTHORITY, CEILING, DECAY_PER_SECOND);

        vm.prank(slasher);
        core.slash(leashId, 5e18);

        // Second slash by same slasher should fail
        vm.prank(slasher);
        vm.expectRevert(LeashCore.SlashCooldownActive.selector);
        core.slash(leashId, 5e18);
    }

    function test_slash_cooldownExpires() public {
        vm.prank(principal);
        bytes32 leashId = core.create(agent, INITIAL_AUTHORITY, CEILING, DECAY_PER_SECOND);

        vm.prank(slasher);
        core.slash(leashId, 5e18);

        // After cooldown expires, same slasher can slash again
        vm.warp(block.timestamp + 1 hours);
        vm.prank(slasher);
        core.slash(leashId, 5e18); // Should succeed
    }

    function test_slash_differentSlashersNotRateLimited() public {
        vm.prank(principal);
        bytes32 leashId = core.create(agent, INITIAL_AUTHORITY, CEILING, DECAY_PER_SECOND);

        vm.prank(slasher);
        core.slash(leashId, 5e18);

        // Different slasher can slash immediately
        address slasher2 = address(0xD);
        vm.prank(slasher2);
        core.slash(leashId, 5e18); // Should succeed
    }

    function test_slash_revertsIfAmountZero() public {
        vm.prank(principal);
        bytes32 leashId = core.create(agent, INITIAL_AUTHORITY, CEILING, DECAY_PER_SECOND);

        vm.prank(slasher);
        vm.expectRevert(LeashCore.SlashAmountZero.selector);
        core.slash(leashId, 0);
    }

    function test_slash_cannotKillLeash() public {
        vm.prank(principal);
        bytes32 leashId = core.create(agent, INITIAL_AUTHORITY, CEILING, DECAY_PER_SECOND);

        vm.prank(slasher);
        core.slash(leashId, INITIAL_AUTHORITY + 1);

        // Leash should still be alive, just at zero authority
        LeashCore.Leash memory l = core.getLeash(leashId);
        assertTrue(l.alive);
        assertEq(core.effectiveAuthority(leashId), 0);
    }

    // ─── kill() ─────────────────────────────────────────────────────────

    function test_kill_permanent() public {
        vm.prank(principal);
        bytes32 leashId = core.create(agent, INITIAL_AUTHORITY, CEILING, DECAY_PER_SECOND);

        vm.prank(principal);
        core.kill(leashId);

        LeashCore.Leash memory l = core.getLeash(leashId);
        assertFalse(l.alive);
        assertEq(l.authority, 0);
        assertEq(core.effectiveAuthority(leashId), 0);
    }

    function test_kill_cannotReactivate() public {
        vm.prank(principal);
        bytes32 leashId = core.create(agent, INITIAL_AUTHORITY, CEILING, DECAY_PER_SECOND);

        vm.prank(principal);
        core.kill(leashId);

        // Cannot heartbeat a dead leash
        vm.prank(principal);
        vm.expectRevert(LeashCore.LeashNotAlive.selector);
        core.heartbeat(leashId);

        // Cannot boost a dead leash
        vm.prank(principal);
        vm.expectRevert(LeashCore.LeashNotAlive.selector);
        core.boost(leashId, 10e18);
    }

    function test_kill_revertsIfNotPrincipal() public {
        vm.prank(principal);
        bytes32 leashId = core.create(agent, INITIAL_AUTHORITY, CEILING, DECAY_PER_SECOND);

        vm.prank(agent);
        vm.expectRevert(LeashCore.OnlyPrincipal.selector);
        core.kill(leashId);
    }

    // ─── getActiveLeash() ───────────────────────────────────────────────

    function test_getActiveLeash_returnsCorrectData() public {
        vm.prank(principal);
        bytes32 leashId = core.create(agent, INITIAL_AUTHORITY, CEILING, DECAY_PER_SECOND);

        (bytes32 id, uint128 auth, bool alive) = core.getActiveLeash(principal, agent);
        assertEq(id, leashId);
        assertEq(auth, INITIAL_AUTHORITY);
        assertTrue(alive);
    }

    // ─── Walkaway safety ────────────────────────────────────────────────

    function test_walkaway_authorityDecaysToZero() public {
        vm.prank(principal);
        bytes32 leashId = core.create(agent, 100e18, CEILING, DECAY_PER_SECOND);

        // Simulate principal disappearing — no more heartbeats
        uint256 ttl = core.timeToZero(leashId);
        vm.warp(block.timestamp + ttl + 1);

        assertEq(core.effectiveAuthority(leashId), 0);
    }

    function test_walkaway_noAdminCanPreventDecay() public {
        vm.prank(principal);
        bytes32 leashId = core.create(agent, 100e18, CEILING, DECAY_PER_SECOND);

        // Nobody else can heartbeat
        vm.prank(agent);
        vm.expectRevert(LeashCore.OnlyPrincipal.selector);
        core.heartbeat(leashId);

        vm.prank(slasher);
        vm.expectRevert(LeashCore.OnlyPrincipal.selector);
        core.heartbeat(leashId);
    }

    // ─── Fuzz tests ─────────────────────────────────────────────────────

    function testFuzz_decay_neverUnderflows(uint128 authority, uint128 decayRate, uint32 elapsed) public {
        vm.assume(authority > 0 && authority <= 1000e18);
        vm.assume(decayRate > 0 && decayRate <= 1e18);

        vm.prank(principal);
        bytes32 leashId = core.create(agent, authority, 1000e18, decayRate);

        vm.warp(block.timestamp + uint256(elapsed));
        // Should never revert
        uint128 eff = core.effectiveAuthority(leashId);
        assertTrue(eff <= authority);
    }

    function testFuzz_boost_neverExceedsCeiling(uint128 boostAmount) public {
        vm.assume(boostAmount > 0);

        vm.prank(principal);
        bytes32 leashId = core.create(agent, INITIAL_AUTHORITY, CEILING, DECAY_PER_SECOND);

        vm.prank(principal);
        core.boost(leashId, boostAmount);

        assertTrue(core.effectiveAuthority(leashId) <= CEILING);
    }
}
