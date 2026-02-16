// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {LeashCore} from "../src/LeashCore.sol";
import {LeashLedger} from "../src/LeashLedger.sol";

contract LeashLedgerTest is Test {
    LeashCore public core;
    LeashLedger public ledger;

    address principal = address(0xA);
    address agent = address(0xB);

    uint128 constant INITIAL_AUTHORITY = 100e18;
    uint128 constant CEILING = 500e18;
    uint128 constant DECAY_PER_SECOND = 277_777_777_777_778;

    bytes32 leashId;

    function setUp() public {
        vm.warp(1_700_000_000);
        core = new LeashCore();
        ledger = new LeashLedger(address(core));

        vm.prank(principal);
        leashId = core.create(agent, INITIAL_AUTHORITY, CEILING, DECAY_PER_SECOND);
    }

    // ─── log() ──────────────────────────────────────────────────────────

    function test_log_appendsEntry() public {
        vm.prank(agent);
        ledger.log(leashId, LeashLedger.ActionType.TRANSFER, address(0x1111), 100e6);

        assertEq(ledger.entryCount(leashId), 1);

        LeashLedger.LogEntry memory entry = ledger.getEntry(leashId, 0);
        assertEq(entry.leashId, leashId);
        assertTrue(entry.actionType == LeashLedger.ActionType.TRANSFER);
        assertEq(entry.target, address(0x1111));
        assertEq(entry.value, 100e6);
        assertEq(entry.authorityAtTime, INITIAL_AUTHORITY);
        assertEq(entry.timestamp, block.timestamp);
        assertEq(entry.prevHash, bytes32(0)); // First entry has zero prevHash
    }

    function test_log_multipleEntries() public {
        vm.startPrank(agent);
        ledger.log(leashId, LeashLedger.ActionType.TRANSFER, address(0x1111), 100e6);
        ledger.log(leashId, LeashLedger.ActionType.SWAP, address(0x2222), 500e6);
        ledger.log(leashId, LeashLedger.ActionType.PROVIDE_LP, address(0x3333), 1000e6);
        vm.stopPrank();

        assertEq(ledger.entryCount(leashId), 3);
    }

    function test_log_chainsHashesCorrectly() public {
        vm.prank(agent);
        ledger.log(leashId, LeashLedger.ActionType.TRANSFER, address(0x1111), 100e6);

        // Get the chain head after first entry
        bytes32 head1 = ledger.chainHead(leashId);
        assertTrue(head1 != bytes32(0));

        // Second entry should reference first entry's hash
        vm.prank(agent);
        ledger.log(leashId, LeashLedger.ActionType.SWAP, address(0x2222), 200e6);

        LeashLedger.LogEntry memory entry2 = ledger.getEntry(leashId, 1);
        assertEq(entry2.prevHash, head1);
    }

    function test_log_capturesDecayedAuthority() public {
        // Log at full authority
        vm.prank(agent);
        ledger.log(leashId, LeashLedger.ActionType.TRANSFER, address(0x1111), 100e6);

        // Warp time to let authority decay
        vm.warp(block.timestamp + 10 hours);

        // Log again — should capture decayed authority
        vm.prank(agent);
        ledger.log(leashId, LeashLedger.ActionType.SWAP, address(0x2222), 200e6);

        LeashLedger.LogEntry memory entry1 = ledger.getEntry(leashId, 0);
        LeashLedger.LogEntry memory entry2 = ledger.getEntry(leashId, 1);

        assertTrue(entry2.authorityAtTime < entry1.authorityAtTime);
    }

    function test_log_revertsIfLeashDead() public {
        vm.prank(principal);
        core.kill(leashId);

        vm.prank(agent);
        vm.expectRevert(LeashLedger.LeashNotAlive.selector);
        ledger.log(leashId, LeashLedger.ActionType.TRANSFER, address(0x1111), 100e6);
    }

    function test_log_revertsIfNotAgent() public {
        // Principal cannot log
        vm.prank(principal);
        vm.expectRevert(LeashLedger.OnlyAgent.selector);
        ledger.log(leashId, LeashLedger.ActionType.TRANSFER, address(0x1111), 100e6);

        // Random address cannot log
        vm.prank(address(0xDEAD));
        vm.expectRevert(LeashLedger.OnlyAgent.selector);
        ledger.log(leashId, LeashLedger.ActionType.TRANSFER, address(0x1111), 100e6);
    }

    function test_log_emitsEvent() public {
        vm.prank(agent);
        vm.expectEmit(true, true, false, true);
        emit LeashLedger.ActionLogged(
            leashId, LeashLedger.ActionType.TRANSFER, address(0x1111), 100e6, INITIAL_AUTHORITY, 0
        );
        ledger.log(leashId, LeashLedger.ActionType.TRANSFER, address(0x1111), 100e6);
    }

    // ─── verifyChain() ──────────────────────────────────────────────────

    function test_verifyChain_emptyChainValid() public view {
        // Create a new leash with no logs
        bool valid = ledger.verifyChain(leashId);
        assertTrue(valid);
    }

    function test_verifyChain_singleEntryValid() public {
        vm.prank(agent);
        ledger.log(leashId, LeashLedger.ActionType.TRANSFER, address(0x1111), 100e6);

        bool valid = ledger.verifyChain(leashId);
        assertTrue(valid);
    }

    function test_verifyChain_multipleEntriesValid() public {
        vm.startPrank(agent);
        ledger.log(leashId, LeashLedger.ActionType.TRANSFER, address(0x1111), 100e6);
        ledger.log(leashId, LeashLedger.ActionType.SWAP, address(0x2222), 200e6);
        ledger.log(leashId, LeashLedger.ActionType.BORROW, address(0x3333), 300e6);
        ledger.log(leashId, LeashLedger.ActionType.GOVERNANCE, address(0x4444), 0);
        vm.stopPrank();

        bool valid = ledger.verifyChain(leashId);
        assertTrue(valid);
    }

    // ─── summary() ──────────────────────────────────────────────────────

    function test_summary_emptyReturnsDefaults() public view {
        LeashLedger.Summary memory s = ledger.summary(leashId);
        assertEq(s.totalActions, 0);
        assertEq(s.highestAuthority, 0);
        assertEq(s.lowestAuthority, 0);
        assertEq(s.totalValue, 0);
    }

    function test_summary_aggregatesCorrectly() public {
        vm.prank(agent);
        ledger.log(leashId, LeashLedger.ActionType.TRANSFER, address(0x1111), 100e6);

        vm.warp(block.timestamp + 5 hours);
        vm.prank(agent);
        ledger.log(leashId, LeashLedger.ActionType.SWAP, address(0x2222), 500e6);

        vm.warp(block.timestamp + 5 hours);
        vm.prank(agent);
        ledger.log(leashId, LeashLedger.ActionType.BORROW, address(0x3333), 1000e6);

        LeashLedger.Summary memory s = ledger.summary(leashId);
        assertEq(s.totalActions, 3);
        assertEq(s.totalValue, 1600e6);
        assertEq(s.highestAuthority, INITIAL_AUTHORITY); // First entry at full authority
        assertTrue(s.lowestAuthority < INITIAL_AUTHORITY); // Later entries at lower authority
    }

    function test_summary_tracksTimeRange() public {
        uint64 t1 = uint64(block.timestamp);
        vm.prank(agent);
        ledger.log(leashId, LeashLedger.ActionType.TRANSFER, address(0x1111), 100e6);

        vm.warp(block.timestamp + 1 days);
        uint64 t2 = uint64(block.timestamp);
        vm.prank(agent);
        ledger.log(leashId, LeashLedger.ActionType.SWAP, address(0x2222), 200e6);

        LeashLedger.Summary memory s = ledger.summary(leashId);
        assertEq(s.firstAction, t1);
        assertEq(s.lastAction, t2);
    }

    // ─── All action types ───────────────────────────────────────────────

    function test_allActionTypes() public {
        vm.startPrank(agent);
        ledger.log(leashId, LeashLedger.ActionType.TRANSFER, address(0x1), 1);
        ledger.log(leashId, LeashLedger.ActionType.SWAP, address(0x2), 2);
        ledger.log(leashId, LeashLedger.ActionType.PROVIDE_LP, address(0x3), 3);
        ledger.log(leashId, LeashLedger.ActionType.BORROW, address(0x4), 4);
        ledger.log(leashId, LeashLedger.ActionType.DEPLOY, address(0x5), 5);
        ledger.log(leashId, LeashLedger.ActionType.DELEGATE, address(0x6), 6);
        ledger.log(leashId, LeashLedger.ActionType.GOVERNANCE, address(0x7), 7);
        ledger.log(leashId, LeashLedger.ActionType.CUSTOM, address(0x8), 8);
        vm.stopPrank();

        assertEq(ledger.entryCount(leashId), 8);

        bool valid = ledger.verifyChain(leashId);
        assertTrue(valid);
    }

    // ─── Walkaway properties ────────────────────────────────────────────

    function test_walkaway_appendOnlyNoDeletion() public {
        vm.prank(agent);
        ledger.log(leashId, LeashLedger.ActionType.TRANSFER, address(0x1111), 100e6);
        uint256 count = ledger.entryCount(leashId);
        assertEq(count, 1);

        // There is no delete function — entries are permanent
        // Verify by checking entry still exists after time passes
        vm.warp(block.timestamp + 365 days);
        LeashLedger.LogEntry memory entry = ledger.getEntry(leashId, 0);
        assertEq(entry.value, 100e6);
    }

    function test_walkaway_summaryWorksWithoutDependencies() public {
        vm.startPrank(agent);
        ledger.log(leashId, LeashLedger.ActionType.TRANSFER, address(0x1111), 100e6);
        ledger.log(leashId, LeashLedger.ActionType.SWAP, address(0x2222), 200e6);
        vm.stopPrank();

        // Kill the leash
        vm.prank(principal);
        core.kill(leashId);

        // Summary and verify should still work
        LeashLedger.Summary memory s = ledger.summary(leashId);
        assertEq(s.totalActions, 2);

        bool valid = ledger.verifyChain(leashId);
        assertTrue(valid);
    }
}
