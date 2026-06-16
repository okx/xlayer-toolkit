// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title MirrorProxy — minimal ERC-1967 proxy for CX9/CX10 testing.
/// @notice Delegates all calls to an upgradeable implementation. Devnet stub
///         with NO access control — anyone may call upgradeTo (matches the
///         L2BlacklistMirror "no auth" posture).
contract MirrorProxy {
    // ERC-1967 impl slot: keccak256("eip1967.proxy.implementation") - 1
    bytes32 internal constant _IMPL_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    event Upgraded(address indexed implementation);

    constructor(address initialImpl) {
        _setImpl(initialImpl);
    }

    function upgradeTo(address newImpl) external {
        require(newImpl.code.length > 0, "MirrorProxy: not a contract");
        _setImpl(newImpl);
        emit Upgraded(newImpl);
    }

    function implementation() external view returns (address impl) {
        assembly { impl := sload(_IMPL_SLOT) }
    }

    function _setImpl(address newImpl) internal {
        assembly { sstore(_IMPL_SLOT, newImpl) }
    }

    fallback() external payable {
        address impl;
        bytes32 slot = _IMPL_SLOT;
        assembly {
            impl := sload(slot)
            calldatacopy(0, 0, calldatasize())
            let ok := delegatecall(gas(), impl, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch ok
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }

    receive() external payable {}
}
