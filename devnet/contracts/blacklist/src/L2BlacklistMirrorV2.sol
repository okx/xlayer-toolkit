// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title L2BlacklistMirrorV2 — proxy upgrade test impl (CX9).
/// @notice Same storage layout as L2BlacklistMirror (V1), but getBlacklist
///         IGNORES storage and ALWAYS returns a single hard-coded address.
///         Used to prove that after upgradeTo(V2) at block M, both op-geth and
///         xlayer-reth pick up the new impl by block M+1 (anti-fork parity).
contract L2BlacklistMirrorV2 {
    // Match V1 storage so existing data is non-corrupting; we just ignore it.
    address[] private _values;
    mapping(address => uint256) private _index;
    bool private _panicked;

    // Hard-coded "banana" account — Anvil test #15.
    // Address: 0xcd3B766CCDd6AE721141F452C550Ca635964ce71
    address internal constant V2_BANANA =
        0xcd3B766CCDd6AE721141F452C550Ca635964ce71;

    event Added(address indexed account);
    event Removed(address indexed account);

    function add(address[] calldata) external {
        revert("L2BlacklistMirrorV2: read-only test impl");
    }

    function remove(address[] calldata) external {
        revert("L2BlacklistMirrorV2: read-only test impl");
    }

    function clear() external {
        revert("L2BlacklistMirrorV2: read-only test impl");
    }

    function setPanic(bool on) external {
        _panicked = on;
    }

    function isPanicked() external view returns (bool) {
        return _panicked;
    }

    function contains(address account) external pure returns (bool) {
        return account == V2_BANANA;
    }

    function getBlacklist(uint256 start, uint256 limit)
        external
        view
        returns (uint256 total, address[] memory addresses)
    {
        require(!_panicked, "L2BlacklistMirrorV2: panicked");
        total = 1;
        if (start >= 1 || limit == 0) {
            return (1, new address[](0));
        }
        addresses = new address[](1);
        addresses[0] = V2_BANANA;
    }
}
