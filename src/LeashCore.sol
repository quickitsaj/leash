// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title LeashCore — Entropy-gated delegation with decaying authority
/// @notice Manages decaying authority scores between principals and agents.
///         Authority decreases linearly via: effective = max(0, stored - elapsed * decayPerSecond).
///         Decay is computed lazily at read-time with no gas cost between transactions.
contract LeashCore {
    // ─── Types ──────────────────────────────────────────────────────────

    struct Leash {
        address principal;
        address agent;
        uint128 authority;
        uint128 ceiling;
        uint128 decayPerSecond;
        uint64 lastHeartbeat;
        uint64 createdAt;
        bool alive;
    }

    // ─── Constants ──────────────────────────────────────────────────────

    uint256 public constant SLASH_COOLDOWN = 1 hours;

    // ─── Storage ────────────────────────────────────────────────────────

    /// @notice leashId => Leash struct
    mapping(bytes32 => Leash) internal _leashes;

    /// @notice principal => sequential leash counter for deterministic IDs
    mapping(address => uint256) public leashCount;

    /// @notice principal => agent => most recently created leashId
    mapping(address => mapping(address => bytes32)) public activeLeashId;

    /// @notice slasher => leashId => last slash timestamp (rate-limiting)
    mapping(address => mapping(bytes32 => uint256)) public lastSlashTime;

    // ─── Events ─────────────────────────────────────────────────────────

    event LeashCreated(
        bytes32 indexed leashId,
        address indexed principal,
        address indexed agent,
        uint128 initialAuthority,
        uint128 ceiling,
        uint128 decayPerSecond
    );

    event Heartbeat(bytes32 indexed leashId, uint128 authorityAfterDecay);

    event Boosted(bytes32 indexed leashId, uint128 newAuthority);

    event Slashed(bytes32 indexed leashId, address indexed slasher, uint128 amount, uint128 newAuthority);

    event Killed(bytes32 indexed leashId);

    // ─── Errors ─────────────────────────────────────────────────────────

    error AgentCannotBePrincipal();
    error AgentCannotBeZero();
    error InitialAuthorityExceedsCeiling();
    error DecayMustBeNonZero();
    error OnlyPrincipal();
    error LeashNotAlive();
    error SlashCooldownActive();
    error SlashAmountZero();
    error BoostAmountZero();

    // ─── Modifiers ──────────────────────────────────────────────────────

    modifier onlyPrincipal(bytes32 leashId) {
        if (msg.sender != _leashes[leashId].principal) revert OnlyPrincipal();
        _;
    }

    modifier onlyAlive(bytes32 leashId) {
        if (!_leashes[leashId].alive) revert LeashNotAlive();
        _;
    }

    // ─── Core Functions ─────────────────────────────────────────────────

    /// @notice Create a new leash. Caller becomes the principal.
    /// @param agent Address of the agent receiving authority
    /// @param initialAuthority Starting authority score (scaled 1e18 = 1 unit)
    /// @param ceiling Maximum authority this leash can ever reach
    /// @param decayPerSecond Authority units lost per second without heartbeat
    /// @return leashId Deterministic identifier for this leash
    function create(
        address agent,
        uint128 initialAuthority,
        uint128 ceiling,
        uint128 decayPerSecond
    ) external returns (bytes32 leashId) {
        if (agent == address(0)) revert AgentCannotBeZero();
        if (agent == msg.sender) revert AgentCannotBePrincipal();
        if (initialAuthority > ceiling) revert InitialAuthorityExceedsCeiling();
        if (decayPerSecond == 0) revert DecayMustBeNonZero();

        uint256 count = leashCount[msg.sender]++;
        leashId = keccak256(abi.encodePacked(msg.sender, agent, count));

        _leashes[leashId] = Leash({
            principal: msg.sender,
            agent: agent,
            authority: initialAuthority,
            ceiling: ceiling,
            decayPerSecond: decayPerSecond,
            lastHeartbeat: uint64(block.timestamp),
            createdAt: uint64(block.timestamp),
            alive: true
        });

        activeLeashId[msg.sender][agent] = leashId;

        emit LeashCreated(leashId, msg.sender, agent, initialAuthority, ceiling, decayPerSecond);
    }

    /// @notice Reset decay clock. Does NOT recover lost authority.
    /// @param leashId The leash to heartbeat
    function heartbeat(bytes32 leashId) external onlyPrincipal(leashId) onlyAlive(leashId) {
        Leash storage l = _leashes[leashId];

        // Materialize decay before resetting clock
        uint128 eff = _effectiveAuthority(l);
        l.authority = eff;
        l.lastHeartbeat = uint64(block.timestamp);

        emit Heartbeat(leashId, eff);
    }

    /// @notice Increase agent authority (capped at ceiling) and reset decay clock.
    /// @param leashId The leash to boost
    /// @param amount Amount to add to authority
    function boost(bytes32 leashId, uint128 amount) external onlyPrincipal(leashId) onlyAlive(leashId) {
        if (amount == 0) revert BoostAmountZero();

        Leash storage l = _leashes[leashId];

        // Materialize decay
        uint128 eff = _effectiveAuthority(l);

        // Boost capped at ceiling (use uint256 to prevent overflow)
        uint256 sum = uint256(eff) + uint256(amount);
        uint128 newAuth = sum > l.ceiling ? l.ceiling : uint128(sum);

        l.authority = newAuth;
        l.lastHeartbeat = uint64(block.timestamp);

        emit Boosted(leashId, newAuth);
    }

    /// @notice Permissionless authority reduction. Rate-limited per slasher per leash.
    /// @dev Materializes accrued decay first, then subtracts slash amount.
    ///      lastHeartbeat is reset to avoid double-counting decay on the
    ///      already-materialized value. This does NOT extend the leash's
    ///      lifetime because all accrued decay was already applied.
    /// @param leashId The leash to slash
    /// @param amount Amount to reduce authority by
    function slash(bytes32 leashId, uint128 amount) external onlyAlive(leashId) {
        if (amount == 0) revert SlashAmountZero();
        uint256 lastSlash = lastSlashTime[msg.sender][leashId];
        if (lastSlash != 0 && block.timestamp - lastSlash < SLASH_COOLDOWN) {
            revert SlashCooldownActive();
        }

        Leash storage l = _leashes[leashId];

        // Materialize decay — all accrued decay is applied to stored authority
        uint128 eff = _effectiveAuthority(l);

        // Reduce authority, floor at zero
        uint128 newAuth = amount >= eff ? 0 : eff - amount;

        l.authority = newAuth;
        l.lastHeartbeat = uint64(block.timestamp); // Reset to avoid double-counting materialized decay
        lastSlashTime[msg.sender][leashId] = block.timestamp;

        emit Slashed(leashId, msg.sender, amount, newAuth);
    }

    /// @notice Permanently and irreversibly destroy a leash.
    /// @param leashId The leash to kill
    function kill(bytes32 leashId) external onlyPrincipal(leashId) onlyAlive(leashId) {
        Leash storage l = _leashes[leashId];
        l.alive = false;
        l.authority = 0;

        emit Killed(leashId);
    }

    // ─── View Functions ─────────────────────────────────────────────────

    /// @notice Get real authority right now with decay applied.
    /// @param leashId The leash to query
    /// @return The effective authority after applying decay
    function effectiveAuthority(bytes32 leashId) external view returns (uint128) {
        return _effectiveAuthority(_leashes[leashId]);
    }

    /// @notice Seconds until authority reaches zero without heartbeat.
    /// @param leashId The leash to query
    /// @return Seconds remaining until zero authority
    function timeToZero(bytes32 leashId) external view returns (uint256) {
        Leash storage l = _leashes[leashId];
        if (!l.alive) return 0;

        uint128 eff = _effectiveAuthority(l);
        if (eff == 0) return 0;

        return uint256(eff) / uint256(l.decayPerSecond);
    }

    /// @notice Projected authority at a future timestamp.
    /// @param leashId The leash to query
    /// @param timestamp Future timestamp to project to
    /// @return Projected authority at the given timestamp
    function authorityAt(bytes32 leashId, uint256 timestamp) external view returns (uint128) {
        Leash storage l = _leashes[leashId];
        if (!l.alive) return 0;
        if (timestamp <= l.lastHeartbeat) return l.authority;

        uint256 elapsed = timestamp - uint256(l.lastHeartbeat);
        uint256 totalDecay = elapsed * uint256(l.decayPerSecond);

        if (totalDecay >= l.authority) return 0;
        return l.authority - uint128(totalDecay);
    }

    /// @notice Get active leash info for a principal-agent pair.
    /// @param principal The principal address
    /// @param agent The agent address
    /// @return leashId The active leash ID
    /// @return authority Current effective authority
    /// @return alive Whether the leash is alive
    function getActiveLeash(address principal, address agent)
        external
        view
        returns (bytes32 leashId, uint128 authority, bool alive)
    {
        leashId = activeLeashId[principal][agent];
        Leash storage l = _leashes[leashId];
        authority = _effectiveAuthority(l);
        alive = l.alive;
    }

    /// @notice Get the full leash struct (stored values, not decayed).
    /// @param leashId The leash to query
    /// @return The Leash struct
    function getLeash(bytes32 leashId) external view returns (Leash memory) {
        return _leashes[leashId];
    }

    // ─── Internal ───────────────────────────────────────────────────────

    /// @dev Compute effective authority after applying linear decay.
    function _effectiveAuthority(Leash storage l) internal view returns (uint128) {
        if (!l.alive) return 0;

        uint256 elapsed = block.timestamp - uint256(l.lastHeartbeat);
        uint256 totalDecay = elapsed * uint256(l.decayPerSecond);

        if (totalDecay >= l.authority) return 0;
        return l.authority - uint128(totalDecay);
    }
}
