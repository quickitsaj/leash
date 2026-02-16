// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {LeashCore} from "./LeashCore.sol";

/// @title LeashPolicy — Maps authority scores to tiered permission sets
/// @notice Content-addressed, immutable policies that map authority tiers to
///         spending caps, whitelisted targets, and sub-delegation rights.
///         Epoch-based spend tracking resets automatically via block timestamps.
contract LeashPolicy {
    // ─── Types ──────────────────────────────────────────────────────────

    struct Tier {
        uint128 minAuthority; // Minimum authority to qualify for this tier
        uint128 spendCap; // Maximum spend per epoch (in policy denomination)
        bool canDeploySubAgents; // Whether agents at this tier can deploy sub-agents
        address[] whitelist; // Allowed target addresses (empty = any)
    }

    struct Policy {
        uint256 epochDuration; // Duration of each spend epoch in seconds
        uint8 tierCount; // Number of tiers (max 8)
        bool exists; // Whether this policy has been registered
    }

    struct SpendState {
        uint256 epochStart; // Timestamp of current epoch start
        uint128 spent; // Amount spent in current epoch
    }

    // ─── Constants ──────────────────────────────────────────────────────

    uint8 public constant MAX_TIERS = 8;

    // ─── Storage ────────────────────────────────────────────────────────

    LeashCore public immutable core;

    /// @notice policyId => Policy metadata
    mapping(bytes32 => Policy) internal _policies;

    /// @notice policyId => tier index => Tier data
    mapping(bytes32 => mapping(uint8 => Tier)) internal _tiers;

    /// @notice leashId => bound policyId (zero if unbound)
    mapping(bytes32 => bytes32) public boundPolicy;

    /// @notice leashId => spend tracking state
    mapping(bytes32 => SpendState) internal _spendStates;

    // ─── Events ─────────────────────────────────────────────────────────

    event PolicyCreated(bytes32 indexed policyId, uint256 epochDuration, uint8 tierCount);

    event PolicyBound(bytes32 indexed leashId, bytes32 indexed policyId);

    event SpendRecorded(bytes32 indexed leashId, uint128 amount, uint128 remainingBudget);

    // ─── Errors ─────────────────────────────────────────────────────────

    error PolicyAlreadyExists();
    error InvalidTierCount();
    error TierAuthoritiesNotAscending();
    error EpochDurationZero();
    error PolicyDoesNotExist();
    error LeashAlreadyBound();
    error OnlyPrincipal();
    error LeashNotAlive();
    error LeashNotBound();
    error ActionNotAllowed();
    error BudgetExceeded();

    // ─── Constructor ────────────────────────────────────────────────────

    constructor(address _core) {
        core = LeashCore(_core);
    }

    // ─── Policy Management ──────────────────────────────────────────────

    /// @notice Register an immutable policy. Returns content-addressed policyId.
    /// @param epochDuration Duration of each spend epoch in seconds
    /// @param minAuthorities Array of minimum authority thresholds per tier (ascending)
    /// @param spendCaps Array of spend caps per tier per epoch
    /// @param canDeploySubAgents Array of sub-agent deployment flags per tier
    /// @param whitelists Array of whitelisted target addresses per tier
    /// @return policyId Content-addressed identifier
    function createPolicy(
        uint256 epochDuration,
        uint128[] calldata minAuthorities,
        uint128[] calldata spendCaps,
        bool[] calldata canDeploySubAgents,
        address[][] calldata whitelists
    ) external returns (bytes32 policyId) {
        uint8 tierCount = uint8(minAuthorities.length);
        if (tierCount == 0 || tierCount > MAX_TIERS) revert InvalidTierCount();
        if (epochDuration == 0) revert EpochDurationZero();
        if (
            spendCaps.length != tierCount || canDeploySubAgents.length != tierCount
                || whitelists.length != tierCount
        ) {
            revert InvalidTierCount();
        }

        // Validate ascending authority thresholds
        for (uint8 i = 1; i < tierCount; i++) {
            if (minAuthorities[i] <= minAuthorities[i - 1]) {
                revert TierAuthoritiesNotAscending();
            }
        }

        // Content-addressed ID from all parameters
        policyId = keccak256(
            abi.encode(epochDuration, minAuthorities, spendCaps, canDeploySubAgents, whitelists)
        );

        if (_policies[policyId].exists) revert PolicyAlreadyExists();

        _policies[policyId] =
            Policy({epochDuration: epochDuration, tierCount: tierCount, exists: true});

        for (uint8 i = 0; i < tierCount; i++) {
            _tiers[policyId][i] = Tier({
                minAuthority: minAuthorities[i],
                spendCap: spendCaps[i],
                canDeploySubAgents: canDeploySubAgents[i],
                whitelist: whitelists[i]
            });
        }

        emit PolicyCreated(policyId, epochDuration, tierCount);
    }

    /// @notice Bind a policy to a leash. One-time, irreversible.
    /// @param leashId The leash to bind
    /// @param policyId The policy to bind
    function bindPolicy(bytes32 leashId, bytes32 policyId) external {
        LeashCore.Leash memory l = core.getLeash(leashId);
        if (msg.sender != l.principal) revert OnlyPrincipal();
        if (!l.alive) revert LeashNotAlive();
        if (!_policies[policyId].exists) revert PolicyDoesNotExist();
        if (boundPolicy[leashId] != bytes32(0)) revert LeashAlreadyBound();

        boundPolicy[leashId] = policyId;

        emit PolicyBound(leashId, policyId);
    }

    // ─── Action Checking ────────────────────────────────────────────────

    /// @notice Verify an action is within policy bounds.
    /// @param leashId The leash to check
    /// @param target Target address of the action
    /// @param amount Amount of the action (in policy denomination)
    /// @return allowed Whether the action is permitted
    /// @return tier The tier at which the action is allowed
    function checkAction(bytes32 leashId, address target, uint128 amount)
        external
        view
        returns (bool allowed, uint8 tier)
    {
        bytes32 policyId = boundPolicy[leashId];
        if (policyId == bytes32(0)) return (false, 0);

        Policy storage p = _policies[policyId];
        uint128 auth = core.effectiveAuthority(leashId);

        // Find highest qualifying tier
        tier = type(uint8).max;
        for (uint8 i = 0; i < p.tierCount; i++) {
            if (auth >= _tiers[policyId][i].minAuthority) {
                tier = i;
            }
        }

        if (tier == type(uint8).max) return (false, 0);

        Tier storage t = _tiers[policyId][tier];

        // Check whitelist (empty whitelist = any target allowed)
        if (t.whitelist.length > 0) {
            bool found = false;
            for (uint256 i = 0; i < t.whitelist.length; i++) {
                if (t.whitelist[i] == target) {
                    found = true;
                    break;
                }
            }
            if (!found) return (false, tier);
        }

        // Check spend cap
        uint128 remaining = _remainingBudget(leashId, policyId, tier);
        if (amount > remaining) return (false, tier);

        allowed = true;
    }

    /// @notice Record spend against epoch budget after a validated action.
    /// @param leashId The leash whose budget to debit
    /// @param amount Amount to debit
    function recordSpend(bytes32 leashId, uint128 amount) external {
        bytes32 policyId = boundPolicy[leashId];
        if (policyId == bytes32(0)) revert LeashNotBound();

        LeashCore.Leash memory l = core.getLeash(leashId);
        if (!l.alive) revert LeashNotAlive();

        Policy storage p = _policies[policyId];
        uint128 auth = core.effectiveAuthority(leashId);

        // Find current tier
        uint8 tier = type(uint8).max;
        for (uint8 i = 0; i < p.tierCount; i++) {
            if (auth >= _tiers[policyId][i].minAuthority) {
                tier = i;
            }
        }

        if (tier == type(uint8).max) revert ActionNotAllowed();

        SpendState storage ss = _spendStates[leashId];

        // Reset epoch if expired
        if (block.timestamp >= ss.epochStart + p.epochDuration || ss.epochStart == 0) {
            ss.epochStart = block.timestamp;
            ss.spent = 0;
        }

        Tier storage t = _tiers[policyId][tier];
        if (ss.spent + amount > t.spendCap) revert BudgetExceeded();

        ss.spent += amount;

        uint128 remaining = t.spendCap - ss.spent;
        emit SpendRecorded(leashId, amount, remaining);
    }

    // ─── View Functions ─────────────────────────────────────────────────

    /// @notice Get current status for an agent's leash.
    /// @param leashId The leash to query
    /// @return tier Current tier index
    /// @return remainingBudget Remaining spend budget in current epoch
    /// @return canDeploySubAgents Whether current tier allows sub-agent deployment
    function agentStatus(bytes32 leashId)
        external
        view
        returns (uint8 tier, uint128 remainingBudget, bool canDeploySubAgents)
    {
        bytes32 policyId = boundPolicy[leashId];
        if (policyId == bytes32(0)) return (type(uint8).max, 0, false);

        Policy storage p = _policies[policyId];
        uint128 auth = core.effectiveAuthority(leashId);

        tier = type(uint8).max;
        for (uint8 i = 0; i < p.tierCount; i++) {
            if (auth >= _tiers[policyId][i].minAuthority) {
                tier = i;
            }
        }

        if (tier == type(uint8).max) return (type(uint8).max, 0, false);

        remainingBudget = _remainingBudget(leashId, policyId, tier);
        canDeploySubAgents = _tiers[policyId][tier].canDeploySubAgents;
    }

    /// @notice Authority needed to reach the next tier.
    /// @param leashId The leash to query
    /// @return needed Authority delta needed (0 if at max tier or unbound)
    function authorityToNextTier(bytes32 leashId) external view returns (uint128 needed) {
        bytes32 policyId = boundPolicy[leashId];
        if (policyId == bytes32(0)) return 0;

        Policy storage p = _policies[policyId];
        uint128 auth = core.effectiveAuthority(leashId);

        // Find current tier
        uint8 currentTier = type(uint8).max;
        for (uint8 i = 0; i < p.tierCount; i++) {
            if (auth >= _tiers[policyId][i].minAuthority) {
                currentTier = i;
            }
        }

        // If at highest tier or no tier, return 0
        if (currentTier == type(uint8).max) {
            // Below all tiers — need to reach tier 0
            return _tiers[policyId][0].minAuthority - auth;
        }

        uint8 nextTier = currentTier + 1;
        if (nextTier >= p.tierCount) return 0; // Already at max tier

        uint128 nextMin = _tiers[policyId][nextTier].minAuthority;
        if (auth >= nextMin) return 0;
        return nextMin - auth;
    }

    /// @notice Get a policy's tier data.
    /// @param policyId The policy to query
    /// @param tierIndex The tier index
    /// @return tier The tier data
    function getTier(bytes32 policyId, uint8 tierIndex) external view returns (Tier memory tier) {
        return _tiers[policyId][tierIndex];
    }

    /// @notice Get policy metadata.
    /// @param policyId The policy to query
    /// @return policy The policy metadata
    function getPolicy(bytes32 policyId) external view returns (Policy memory policy) {
        return _policies[policyId];
    }

    // ─── Internal ───────────────────────────────────────────────────────

    function _remainingBudget(bytes32 leashId, bytes32 policyId, uint8 tier)
        internal
        view
        returns (uint128)
    {
        Policy storage p = _policies[policyId];
        SpendState storage ss = _spendStates[leashId];
        Tier storage t = _tiers[policyId][tier];

        // If epoch expired or never started, full budget available
        if (block.timestamp >= ss.epochStart + p.epochDuration || ss.epochStart == 0) {
            return t.spendCap;
        }

        if (ss.spent >= t.spendCap) return 0;
        return t.spendCap - ss.spent;
    }
}
