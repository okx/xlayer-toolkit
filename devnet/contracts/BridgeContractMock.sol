// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title BridgeContractMock
 * @notice Mock of the XLayer bridge contract used to test bridge transaction interception.
 *
 * Deploy this contract at the address configured via --xlayer.intercept.bridge-contract.
 *
 * The interception logic in crates/intercept/src/lib.rs listens for:
 *   BridgeEvent(uint8,uint32,address,uint32,address,uint256,bytes,uint32)
 *   topic0 = 0x501781209a1f889932...  (keccak256 of the signature above)
 *
 * Two interception modes are tested:
 *   1. Wildcard mode  (--xlayer.intercept.target-token not set):
 *      Any log emitted by this contract triggers interception.
 *   2. Specific-token mode (--xlayer.intercept.target-token <token>):
 *      Only BridgeEvents where targetToken == target token trigger interception.
 */
contract BridgeContractMock {

    event BridgeEvent(
        uint8   leafType,
        uint32  originNetwork,
        address targetToken,       // ← matched against --xlayer.intercept.target-token
        uint32  destinationNetwork,
        address destinationAddress,
        uint256 amount,
        bytes   metadata,
        uint32  depositCount
    );

    uint32 public depositCount;

    /**
     * @notice Case 1 – direct call: msg.sender calls this function directly.
     *         The transaction itself is "to" this contract, so the interception
     *         check fires immediately on the resulting logs.
     *
     * @param targetToken   Set to the token address you want to match
     *                        (use --xlayer.intercept.target-token <targetToken>).
     * @param amount          Token amount being bridged.
     * @param destinationAddr Recipient on the destination chain.
     */
    function bridgeDirect(
        address targetToken,
        uint256 amount,
        address destinationAddr
    ) external {
        emit BridgeEvent(
            0,               // leafType  (ERC-20)
            0,               // originNetwork (source chain id index)
            targetToken,   // the token being bridged
            1,               // destinationNetwork
            destinationAddr,
            amount,
            "",              // metadata (empty for native tokens)
            depositCount++
        );
    }

    // Direct call that emits no event
    function bridgeDirectNoEvent(
        address,
        uint256,
        address
    ) external {
        depositCount++;
    }

    /**
     * @notice Entry-point called by BridgeCallerMock (case 2 – indirect call).
     *         The transaction is "to" BridgeCallerMock, which then calls this
     *         function internally.  The log is still emitted by *this* contract,
     *         so the interception check still fires because the interceptor
     *         filters on log.address == bridge_contract_address.
     */
    function bridgeInternal(
        address targetToken,
        uint256 amount,
        address destinationAddr
    ) external {
        emit BridgeEvent(
            0,
            0,
            targetToken,
            1,
            destinationAddr,
            amount,
            "",
            depositCount++
        );
    }
    // Internal call that emits no event
    function bridgeInternalNoEvent(
        address,
        uint256,
        address
    ) external {
        depositCount++;
    }
}