// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IBridgeContractMock {
    function bridgeInternal(
        address targetToken,
        uint256 amount,
        address destinationAddr
    ) external;
}

/**
 * @title BridgeCallerMock
 * @notice Simulates "another contract calls the bridge" scenario.
 *
 * Case 2: The transaction is sent to THIS contract (BridgeCallerMock).
 * Internally it calls BridgeContractMock.bridgeInternal(), which emits
 * the BridgeEvent log from the bridge contract's address.
 * Because the interceptor filters logs by address (log.address ==
 * bridge_contract_address), the interception still triggers even
 * though the outer tx.to is this caller contract.
 */
contract BridgeCallerMock {
    IBridgeContractMock public immutable bridge;

    constructor(address bridgeAddress) {
        bridge = IBridgeContractMock(bridgeAddress);
    }

    /**
     * @notice Send this transaction to test indirect bridge interception.
     *         The interceptor should block this tx because the inner call
     *         causes BridgeContractMock to emit BridgeEvent.
     */
    function callBridge(
        address targetToken,
        uint256 amount,
        address destinationAddr
    ) external {
        bridge.bridgeInternal(targetToken, amount, destinationAddr);
    }

    // 调用 bridgeInternalNoEvent，不抛出事件
    function callBridgeNoEvent(
        address targetToken,
        uint256 amount,
        address destinationAddr
    ) external {
        // 需要 BridgeContractMock 新增 bridgeInternalNoEvent
        // 这里直接调用
        // solhint-disable-next-line avoid-low-level-calls
        (bool success, ) = address(bridge).call(
            abi.encodeWithSignature(
                "bridgeInternalNoEvent(address,uint256,address)",
                targetToken, amount, destinationAddr
            )
        );
        require(success, "bridgeInternalNoEvent call failed");
    }
}