// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC1967} from "@openzeppelin/contracts/interfaces/IERC1967.sol";

import {BuilderCodes} from "../../../src/BuilderCodes.sol";
import {BuilderCodesTest} from "../../lib/BuilderCodesTest.sol";
import {MockBuilderCodesV2} from "../../lib/mocks/MockBuilderCodesV2.sol";

/// @notice Unit tests for BuilderCodes.upgradeToAndCall
contract UpgradeToAndCallTest is BuilderCodesTest {
    /// @notice Creates EIP-712 signature for BuilderCode registration with specific domain version
    ///
    /// @param signerPk Private key of the signer
    /// @param code The code to register
    /// @param initialOwner The initial owner of the code
    /// @param payoutAddress The payout address
    /// @param deadline The registration deadline
    /// @param domainVersion The EIP-712 domain version to use
    ///
    /// @return signature The EIP-712 signature
    function _signRegistrationWithVersion(
        uint256 signerPk,
        string memory code,
        address initialOwner,
        address payoutAddress,
        uint48 deadline,
        string memory domainVersion
    ) internal view returns (bytes memory signature) {
        bytes32 structHash = keccak256(
            abi.encode(
                builderCodes.REGISTRATION_TYPEHASH(), keccak256(bytes(code)), initialOwner, payoutAddress, deadline
            )
        );

        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("Builder Codes")),
                keccak256(bytes(domainVersion)),
                block.chainid,
                address(builderCodes)
            )
        );

        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);
        return abi.encodePacked(r, s, v);
    }
    /// @notice Test that upgradeToAndCall reverts when caller is not the owner

    function test_upgradeToAndCall_revert_notOwner() public {
        address nonOwner = address(0x123);
        address newImplementation = address(new MockBuilderCodesV2());

        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
        builderCodes.upgradeToAndCall(newImplementation, "");
    }

    /// @notice Test that upgradeToAndCall successfully updates the implementation
    function test_upgradeToAndCall_success_updatesImplementation() public {
        address newImplementation = address(new MockBuilderCodesV2());

        vm.prank(owner);
        builderCodes.upgradeToAndCall(newImplementation, "");

        // Verify the upgrade worked by testing storage preservation
        assertEq(builderCodes.owner(), owner);
        assertTrue(builderCodes.hasRole(builderCodes.REGISTER_ROLE(), registrar));
    }

    /// @notice Test that upgradeToAndCall succeeds without default slot ordering collision
    function test_upgradeToAndCall_success_noDefaultSlotOrderingCollision() public {
        // Register a code before upgrade to test storage preservation
        string memory testCode = "testcode";
        address testPayoutAddress = address(0x456);

        vm.prank(registrar);
        builderCodes.register(testCode, owner, testPayoutAddress);

        // Store original data
        address originalOwnerOfCode = builderCodes.ownerOf(builderCodes.toTokenId(testCode));
        address originalPayoutAddress = builderCodes.payoutAddress(testCode);

        // Perform upgrade
        address newImplementation = address(new MockBuilderCodesV2());
        vm.prank(owner);
        builderCodes.upgradeToAndCall(newImplementation, "");

        // Verify storage is preserved (no collision)
        assertEq(builderCodes.ownerOf(builderCodes.toTokenId(testCode)), originalOwnerOfCode);
        assertEq(builderCodes.payoutAddress(testCode), originalPayoutAddress);
        assertTrue(builderCodes.isRegistered(testCode));
    }

    /// @notice Test that upgradeToAndCall can change the EIP712 domain version
    function test_upgradeToAndCall_success_canChangeEIP712DomainVersion() public {
        string memory testCode = "testcode";
        address testOwner = address(0x789);
        address testPayoutAddress = address(0x456);
        uint48 deadline = uint48(block.timestamp + 1000);

        // Create signature with original domain version ("1")
        bytes memory v1Signature =
            _signRegistrationWithVersion(REGISTRAR_PK, testCode, testOwner, testPayoutAddress, deadline, "1");

        // This should work with original version
        builderCodes.registerWithSignature(testCode, testOwner, testPayoutAddress, deadline, registrar, v1Signature);

        // Perform upgrade to version 2
        address newImplementation = address(new MockBuilderCodesV2());
        vm.prank(owner);
        builderCodes.upgradeToAndCall(newImplementation, "");

        // Test with a new code to verify domain version change
        string memory newTestCode = "newtestcode";

        // Old signature (domain version "1") should NOT work anymore
        bytes memory oldV1Signature =
            _signRegistrationWithVersion(REGISTRAR_PK, newTestCode, testOwner, testPayoutAddress, deadline, "1");
        vm.expectRevert(BuilderCodes.Unauthorized.selector);
        builderCodes.registerWithSignature(
            newTestCode, testOwner, testPayoutAddress, deadline, registrar, oldV1Signature
        );

        // New signature (domain version "2") should work
        bytes memory v2Signature =
            _signRegistrationWithVersion(REGISTRAR_PK, newTestCode, testOwner, testPayoutAddress, deadline, "2");
        builderCodes.registerWithSignature(newTestCode, testOwner, testPayoutAddress, deadline, registrar, v2Signature);

        // Verify the new code was registered
        assertTrue(builderCodes.isRegistered(newTestCode));
        assertEq(builderCodes.ownerOf(builderCodes.toTokenId(newTestCode)), testOwner);
    }

    /// @notice Test that upgradeToAndCall emits the ERC1967 Upgraded event
    function test_upgradeToAndCall_success_emitsERC1967Upgraded() public {
        address newImplementation = address(new MockBuilderCodesV2());

        vm.expectEmit(true, false, false, false);
        emit IERC1967.Upgraded(newImplementation);

        vm.prank(owner);
        builderCodes.upgradeToAndCall(newImplementation, "");
    }
}
