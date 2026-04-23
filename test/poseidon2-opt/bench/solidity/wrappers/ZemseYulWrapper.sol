// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {Poseidon2Yul} from "poseidon2-evm/Poseidon2Yul.sol";

/// @notice Wrapper that calls Poseidon2Yul with raw calldata (no ABI selector).
/// @dev Poseidon2Yul's fallback reads raw 32-byte words from calldataload(0).
///      It derives IV from calldatasize: iv = (calldatasize / 32) << 64.
///      We must NOT include a 4-byte selector in the calldata.
contract ZemseYulWrapper {
    Poseidon2Yul public immutable yul;

    constructor() {
        yul = new Poseidon2Yul();
    }

    function hash_1(uint256 x) external view returns (uint256) {
        return _rawCall(abi.encode(x));
    }

    function hash_2(uint256 x, uint256 y) external view returns (uint256) {
        return _rawCall(abi.encode(x, y));
    }

    function hash_3(uint256 x, uint256 y, uint256 z) external view returns (uint256) {
        return _rawCall(abi.encode(x, y, z));
    }

    function _rawCall(bytes memory data) internal view returns (uint256) {
        (bool ok, bytes memory ret) = address(yul).staticcall(data);
        require(ok, "Poseidon2Yul call failed");
        return abi.decode(ret, (uint256));
    }
}
