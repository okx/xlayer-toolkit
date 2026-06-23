// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title L2BlacklistMirror (devnet demo stub)
/// @notice Minimal mirror of the emergency-freeze blacklist for the XLayer
///         devnet (chain_id 195).
///
/// @dev READ INTERFACE IS THE CROSS-CLIENT CONTRACT, NOT the storage layout.
///      The xlayer-reth and op-geth nodes read the list ONLY through the view
///      method `getBlacklist(start, limit)` (read once per block from the
///      block-head/parent state). They never read raw storage slots, so this
///      contract is free to use any internal representation — here a minimal
///      inline enumerable set (array + index map), equivalent to OpenZeppelin
///      EnumerableSet but dependency-free.
///
///      add/remove/contains are O(1); the set is deduped and rejects the zero
///      address, so the node-side zero-entry / duplicate edge cases cannot occur.
///
///      This is a devnet test stub only: there is intentionally NO access
///      control (anyone may add/remove), matching the PRD's "node trusts the
///      contract admin, no secondary auth" posture. NOT a production contract.
contract L2BlacklistMirror {
    // Enumerable set: `_values` for enumeration, `_index` maps an address to its
    // 1-based position in `_values` (0 == not present).
    address[] private _values;
    mapping(address => uint256) private _index;

    // CX10 fail-open test only: when true, getBlacklist reverts to simulate a
    // broken / mis-upgraded mirror impl. Nodes MUST treat revert as fail-open
    // (empty list + Error log) — anti-fork posture is that BOTH clients agree.
    bool private _panicked;

    event Added(address indexed account);
    event Removed(address indexed account);
    event Cleared();
    event Panicked(bool on);

    /// @notice Add `account` to the blacklist. Rejects the zero address; a
    ///         duplicate is a no-op (the set is deduped).
    function add(address account) external {
        require(account != address(0), "L2BlacklistMirror: zero address");
        if (_index[account] != 0) {
            return;
        }
        _values.push(account);
        _index[account] = _values.length; // 1-based
        emit Added(account);
    }

    /// @notice Remove `account` via swap-and-pop (O(1)). Reverts if not listed.
    function remove(address account) external {
        uint256 idx = _index[account];
        require(idx != 0, "L2BlacklistMirror: not listed");
        uint256 last = _values.length;
        if (idx != last) {
            address moved = _values[last - 1];
            _values[idx - 1] = moved;
            _index[moved] = idx;
        }
        _values.pop();
        delete _index[account];
        emit Removed(account);
    }

    /// @notice Drop the entire list.
    function clear() external {
        uint256 n = _values.length;
        for (uint256 i = 0; i < n; i++) {
            delete _index[_values[i]];
        }
        delete _values;
        emit Cleared();
    }

    /// @notice O(1) membership check (convenience; node uses getBlacklist).
    function contains(address account) external view returns (bool) {
        return _index[account] != 0;
    }

    /// @notice CX10 fail-open test only: switch getBlacklist into permanent
    ///         revert mode (or back). Devnet stub with no auth — anyone may toggle.
    function setPanic(bool on) external {
        _panicked = on;
        emit Panicked(on);
    }

    function isPanicked() external view returns (bool) {
        return _panicked;
    }

    /// @notice Node read interface. Returns the total number of
    ///         listed addresses and a bounded page `[start, start+limit)` of
    ///         them. A list within one page is fetched in a single call (total +
    ///         all addresses together); larger lists are paginated by the caller.
    /// @param start first index to return
    /// @param limit max addresses to return
    /// @return total full number of listed addresses (independent of start/limit)
    /// @return addresses the page; empty when start >= total
    function getBlacklist(uint256 start, uint256 limit)
        external
        view
        returns (uint256 total, address[] memory addresses)
    {
        require(!_panicked, "L2BlacklistMirror: panicked");
        total = _values.length;
        if (start >= total) {
            return (total, new address[](0));
        }
        uint256 end = start + limit;
        if (end > total) {
            end = total;
        }
        uint256 n = end - start;
        addresses = new address[](n);
        for (uint256 i = 0; i < n; i++) {
            addresses[i] = _values[start + i];
        }
    }
}
