// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {LeashCore} from "./LeashCore.sol";

/// @title LeashLedger — Append-only behavioral audit trail with rolling hash chain
/// @notice Records what an agent did, when, and at what authority level.
///         Per-relationship audit data for ERC-8004 reputation validators.
///         Tamper-evident via rolling hash chain — each entry includes hash of previous entry.
contract LeashLedger {
    // ─── Types ──────────────────────────────────────────────────────────

    enum ActionType {
        TRANSFER, // Token transfer, ERC-20, ETH
        SWAP, // DEX swap (Uniswap, Curve, 1inch)
        PROVIDE_LP, // Liquidity provision on AMMs
        BORROW, // Lending protocol actions (Aave, Compound)
        DEPLOY, // Contract deployment (CREATE/CREATE2)
        DELEGATE, // Sub-delegation, new sub-leash
        GOVERNANCE, // DAO actions, voting, proposals
        CUSTOM // Other categorizable actions

    }

    struct LogEntry {
        bytes32 leashId;
        ActionType actionType;
        address target;
        uint128 value;
        uint128 authorityAtTime; // Authority level when action was taken
        uint64 timestamp;
        bytes32 prevHash; // Rolling hash chain — hash of previous entry
    }

    struct Summary {
        uint256 totalActions;
        uint128 highestAuthority;
        uint128 lowestAuthority;
        uint128 totalValue;
        uint64 firstAction;
        uint64 lastAction;
    }

    // ─── Storage ────────────────────────────────────────────────────────

    LeashCore public immutable core;

    /// @notice leashId => array of log entries
    mapping(bytes32 => LogEntry[]) internal _logs;

    /// @notice leashId => hash of the most recent log entry (chain head)
    mapping(bytes32 => bytes32) public chainHead;

    // ─── Events ─────────────────────────────────────────────────────────

    event ActionLogged(
        bytes32 indexed leashId,
        ActionType indexed actionType,
        address target,
        uint128 value,
        uint128 authorityAtTime,
        uint256 entryIndex
    );

    // ─── Errors ─────────────────────────────────────────────────────────

    error LeashNotAlive();
    error ChainIntegrityBroken(uint256 entryIndex);

    // ─── Constructor ────────────────────────────────────────────────────

    constructor(address _core) {
        core = LeashCore(_core);
    }

    // ─── Logging ────────────────────────────────────────────────────────

    /// @notice Append a new action to the audit trail for a leash.
    /// @param leashId The leash this action belongs to
    /// @param actionType The type of action performed
    /// @param target The target address of the action
    /// @param value The value/amount of the action
    function log(bytes32 leashId, ActionType actionType, address target, uint128 value) external {
        LeashCore.Leash memory l = core.getLeash(leashId);
        if (!l.alive) revert LeashNotAlive();

        uint128 auth = core.effectiveAuthority(leashId);
        bytes32 prevHash = chainHead[leashId];

        LogEntry memory entry = LogEntry({
            leashId: leashId,
            actionType: actionType,
            target: target,
            value: value,
            authorityAtTime: auth,
            timestamp: uint64(block.timestamp),
            prevHash: prevHash
        });

        _logs[leashId].push(entry);

        // Update chain head
        bytes32 entryHash = keccak256(
            abi.encodePacked(
                entry.leashId,
                entry.actionType,
                entry.target,
                entry.value,
                entry.authorityAtTime,
                entry.timestamp,
                entry.prevHash
            )
        );
        chainHead[leashId] = entryHash;

        uint256 entryIndex = _logs[leashId].length - 1;
        emit ActionLogged(leashId, actionType, target, value, auth, entryIndex);
    }

    // ─── Verification ───────────────────────────────────────────────────

    /// @notice Verify the integrity of the rolling hash chain for a leash.
    /// @param leashId The leash whose chain to verify
    /// @return valid Whether the entire chain is intact
    function verifyChain(bytes32 leashId) external view returns (bool valid) {
        LogEntry[] storage entries = _logs[leashId];
        uint256 len = entries.length;
        if (len == 0) return true;

        bytes32 computedHash = bytes32(0);

        for (uint256 i = 0; i < len; i++) {
            LogEntry storage entry = entries[i];

            // Verify the stored prevHash matches our computed running hash
            if (entry.prevHash != computedHash) {
                revert ChainIntegrityBroken(i);
            }

            // Compute hash of this entry
            computedHash = keccak256(
                abi.encodePacked(
                    entry.leashId,
                    entry.actionType,
                    entry.target,
                    entry.value,
                    entry.authorityAtTime,
                    entry.timestamp,
                    entry.prevHash
                )
            );
        }

        // Final computed hash should match the stored chain head
        return computedHash == chainHead[leashId];
    }

    // ─── View Functions ─────────────────────────────────────────────────

    /// @notice Get a summary of all actions for a leash.
    /// @param leashId The leash to summarize
    /// @return s Summary struct with aggregate data
    function summary(bytes32 leashId) external view returns (Summary memory s) {
        LogEntry[] storage entries = _logs[leashId];
        uint256 len = entries.length;
        if (len == 0) return s;

        s.totalActions = len;
        s.highestAuthority = 0;
        s.lowestAuthority = type(uint128).max;
        s.firstAction = entries[0].timestamp;
        s.lastAction = entries[len - 1].timestamp;

        for (uint256 i = 0; i < len; i++) {
            LogEntry storage entry = entries[i];

            // Use unchecked to avoid overflow revert on totalValue accumulation
            // In practice, values won't overflow uint128 but we clamp for safety
            if (s.totalValue + entry.value >= s.totalValue) {
                s.totalValue += entry.value;
            }

            if (entry.authorityAtTime > s.highestAuthority) {
                s.highestAuthority = entry.authorityAtTime;
            }
            if (entry.authorityAtTime < s.lowestAuthority) {
                s.lowestAuthority = entry.authorityAtTime;
            }
        }
    }

    /// @notice Get the total number of log entries for a leash.
    /// @param leashId The leash to query
    /// @return count Number of log entries
    function entryCount(bytes32 leashId) external view returns (uint256 count) {
        return _logs[leashId].length;
    }

    /// @notice Get a specific log entry by index.
    /// @param leashId The leash to query
    /// @param index The entry index
    /// @return entry The log entry
    function getEntry(bytes32 leashId, uint256 index) external view returns (LogEntry memory entry) {
        return _logs[leashId][index];
    }
}
