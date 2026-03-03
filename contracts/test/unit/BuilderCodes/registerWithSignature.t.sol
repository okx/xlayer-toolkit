// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {BuilderCodes} from "../../../src/BuilderCodes.sol";

import {BuilderCodesTest, IERC721Errors} from "../../lib/BuilderCodesTest.sol";
import {MockAccount} from "../../lib/mocks/MockAccount.sol";

/// @notice Unit tests for BuilderCodes.registerWithSignature
contract RegisterWithSignatureTest is BuilderCodesTest {
    /// @notice Test that registerWithSignature reverts when the deadline has passed
    ///
    /// @param codeSeed The seed for generating the code
    /// @param initialOwner The initial owner address
    /// @param payoutAddress The payout address
    /// @param deadline The registration deadline
    function test_registerWithSignature_revert_afterRegistrationDeadline(
        uint256 codeSeed,
        address initialOwner,
        address payoutAddress,
        uint48 deadline
    ) public {
        initialOwner = _boundNonZeroAddress(initialOwner);
        payoutAddress = _boundNonZeroAddress(payoutAddress);
        deadline = uint48(bound(deadline, 0, uint48(block.timestamp - 1)));

        string memory code = _generateValidCode(codeSeed);
        bytes memory signature = _signRegistration(REGISTRAR_PK, code, initialOwner, payoutAddress, deadline);

        vm.expectRevert(abi.encodeWithSelector(BuilderCodes.AfterRegistrationDeadline.selector, deadline));
        builderCodes.registerWithSignature(code, initialOwner, payoutAddress, deadline, registrar, signature);
    }

    /// @notice Test that registerWithSignature reverts when the registrar doesn't have the required role
    ///
    /// @param codeSeed The seed for generating the code
    /// @param initialOwner The initial owner address
    /// @param payoutAddress The payout address
    /// @param deadline The registration deadline
    /// @param invalidRegistrarPk The invalid registrar private key
    function test_registerWithSignature_revert_registrarInvalidRole(
        uint256 codeSeed,
        address initialOwner,
        address payoutAddress,
        uint48 deadline,
        uint256 invalidRegistrarPk
    ) public {
        initialOwner = _boundNonZeroAddress(initialOwner);
        payoutAddress = _boundNonZeroAddress(payoutAddress);
        invalidRegistrarPk =
            bound(invalidRegistrarPk, 1, 115792089237316195423570985008687907852837564279074904382605163141518161494336);
        vm.assume(invalidRegistrarPk != OWNER_PK && invalidRegistrarPk != REGISTRAR_PK);
        address invalidRegistrar = vm.addr(invalidRegistrarPk);
        deadline = uint48(bound(deadline, uint48(block.timestamp), type(uint48).max));

        string memory code = _generateValidCode(codeSeed);
        bytes memory signature = _signRegistration(invalidRegistrarPk, code, initialOwner, payoutAddress, deadline);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, invalidRegistrar, builderCodes.REGISTER_ROLE()
            )
        );
        builderCodes.registerWithSignature(code, initialOwner, payoutAddress, deadline, invalidRegistrar, signature);
    }

    /// @notice Test that registerWithSignature reverts when provided with an invalid signature
    ///
    /// @param codeSeed The seed for generating the code
    /// @param initialOwner The initial owner address
    /// @param payoutAddress The payout address
    /// @param deadline The registration deadline
    function test_registerWithSignature_revert_invalidSignature(
        uint256 codeSeed,
        address initialOwner,
        address payoutAddress,
        uint48 deadline
    ) public {
        initialOwner = _boundNonZeroAddress(initialOwner);
        payoutAddress = _boundNonZeroAddress(payoutAddress);
        deadline = uint48(bound(deadline, uint48(block.timestamp), type(uint48).max));

        string memory code = _generateValidCode(codeSeed);
        bytes memory invalidSignature = "invalid signature";

        vm.expectRevert(BuilderCodes.Unauthorized.selector);
        builderCodes.registerWithSignature(code, initialOwner, payoutAddress, deadline, registrar, invalidSignature);
    }

    /// @notice Test that registerWithSignature reverts when attempting to register an empty code
    ///
    /// @param initialOwner The initial owner address
    /// @param payoutAddress The payout address
    /// @param deadline The registration deadline
    function test_registerWithSignature_revert_emptyCode(address initialOwner, address payoutAddress, uint48 deadline)
        public
    {
        initialOwner = _boundNonZeroAddress(initialOwner);
        payoutAddress = _boundNonZeroAddress(payoutAddress);
        deadline = uint48(bound(deadline, uint48(block.timestamp), type(uint48).max));

        bytes memory signature = _signRegistration(REGISTRAR_PK, "", initialOwner, payoutAddress, deadline);

        vm.expectRevert(abi.encodeWithSelector(BuilderCodes.InvalidCode.selector, ""));
        builderCodes.registerWithSignature("", initialOwner, payoutAddress, deadline, registrar, signature);
    }

    /// @notice Test that registerWithSignature reverts when the code is over 32 characters
    ///
    /// @param codeSeed The seed for generating the code
    /// @param initialOwner The initial owner address
    /// @param payoutAddress The payout address
    /// @param deadline The registration deadline
    function test_registerWithSignature_revert_codeOver32Characters(
        uint256 codeSeed,
        address initialOwner,
        address payoutAddress,
        uint48 deadline
    ) public {
        initialOwner = _boundNonZeroAddress(initialOwner);
        payoutAddress = _boundNonZeroAddress(payoutAddress);
        deadline = uint48(bound(deadline, uint48(block.timestamp), type(uint48).max));

        string memory longCode = _generateLongCode(codeSeed);
        bytes memory signature = _signRegistration(REGISTRAR_PK, longCode, initialOwner, payoutAddress, deadline);

        vm.expectRevert(abi.encodeWithSelector(BuilderCodes.InvalidCode.selector, longCode));
        builderCodes.registerWithSignature(longCode, initialOwner, payoutAddress, deadline, registrar, signature);
    }

    /// @notice Test that registerWithSignature reverts when the code contains invalid characters
    ///
    /// @param codeSeed The seed for generating the code
    /// @param initialOwner The initial owner address
    /// @param payoutAddress The payout address
    /// @param deadline The registration deadline
    function test_registerWithSignature_revert_codeContainsInvalidCharacters(
        uint256 codeSeed,
        address initialOwner,
        address payoutAddress,
        uint48 deadline
    ) public {
        initialOwner = _boundNonZeroAddress(initialOwner);
        payoutAddress = _boundNonZeroAddress(payoutAddress);
        deadline = uint48(bound(deadline, uint48(block.timestamp), type(uint48).max));

        string memory invalidCode = _generateInvalidCode(codeSeed);
        bytes memory signature = _signRegistration(REGISTRAR_PK, invalidCode, initialOwner, payoutAddress, deadline);

        vm.expectRevert(abi.encodeWithSelector(BuilderCodes.InvalidCode.selector, invalidCode));
        builderCodes.registerWithSignature(invalidCode, initialOwner, payoutAddress, deadline, registrar, signature);
    }

    /// @notice Test that registerWithSignature reverts when the initial owner is zero address
    ///
    /// @param codeSeed The seed for generating the code
    /// @param payoutAddress The payout address
    /// @param deadline The registration deadline
    function test_registerWithSignature_revert_zeroInitialOwner(
        uint256 codeSeed,
        address payoutAddress,
        uint48 deadline
    ) public {
        payoutAddress = _boundNonZeroAddress(payoutAddress);
        deadline = uint48(bound(deadline, uint48(block.timestamp), type(uint48).max));

        string memory code = _generateValidCode(codeSeed);
        bytes memory signature = _signRegistration(REGISTRAR_PK, code, address(0), payoutAddress, deadline);

        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(0)));
        builderCodes.registerWithSignature(code, address(0), payoutAddress, deadline, registrar, signature);
    }

    /// @notice Test that registerWithSignature reverts when the payout address is zero address
    ///
    /// @param codeSeed The seed for generating the code
    /// @param initialOwner The initial owner address
    /// @param deadline The registration deadline
    function test_registerWithSignature_revert_zeroPayoutAddress(
        uint256 codeSeed,
        address initialOwner,
        uint48 deadline
    ) public {
        initialOwner = _boundNonZeroAddress(initialOwner);
        deadline = uint48(bound(deadline, uint48(block.timestamp), type(uint48).max));

        string memory code = _generateValidCode(codeSeed);
        bytes memory signature = _signRegistration(REGISTRAR_PK, code, initialOwner, address(0), deadline);

        vm.expectRevert(BuilderCodes.ZeroAddress.selector);
        builderCodes.registerWithSignature(code, initialOwner, address(0), deadline, registrar, signature);
    }

    /// @notice Test that registerWithSignature reverts when the code is already registered
    ///
    /// @param codeSeed The seed for generating the code
    /// @param initialOwner The initial owner address
    /// @param payoutAddress The payout address
    /// @param deadline The registration deadline
    function test_registerWithSignature_revert_alreadyRegistered(
        uint256 codeSeed,
        address initialOwner,
        address payoutAddress,
        uint48 deadline
    ) public {
        initialOwner = _boundNonZeroAddress(initialOwner);
        payoutAddress = _boundNonZeroAddress(payoutAddress);
        deadline = uint48(bound(deadline, uint48(block.timestamp), type(uint48).max));

        string memory code = _generateValidCode(codeSeed);

        // Register the code first
        vm.prank(registrar);
        builderCodes.register(code, initialOwner, payoutAddress);

        // Try to register the same code again with signature
        bytes memory signature = _signRegistration(REGISTRAR_PK, code, initialOwner, payoutAddress, deadline);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidSender.selector, address(0)));
        builderCodes.registerWithSignature(code, initialOwner, payoutAddress, deadline, registrar, signature);
    }

    /// @notice Test that registerWithSignature supports signature from owner
    ///
    /// @param codeSeed The seed for generating the code
    /// @param initialOwner The initial owner address
    /// @param payoutAddress The payout address
    /// @param deadline The registration deadline
    function test_registerWithSignature_success_ownerCanSign(
        uint256 codeSeed,
        address initialOwner,
        address payoutAddress,
        uint48 deadline
    ) public {
        initialOwner = _boundNonZeroAddress(initialOwner);
        payoutAddress = _boundNonZeroAddress(payoutAddress);
        deadline = uint48(bound(deadline, uint48(block.timestamp), type(uint48).max));

        string memory code = _generateValidCode(codeSeed);
        bytes memory signature = _signRegistration(OWNER_PK, code, initialOwner, payoutAddress, deadline);

        builderCodes.registerWithSignature(code, initialOwner, payoutAddress, deadline, owner, signature);

        assertTrue(builderCodes.isRegistered(code));
        assertEq(builderCodes.ownerOf(builderCodes.toTokenId(code)), initialOwner);
    }

    /// @notice Test that registerWithSignature supports signature from EOA
    ///
    /// @param codeSeed The seed for generating the code
    /// @param initialOwner The initial owner address
    /// @param payoutAddress The payout address
    /// @param deadline The registration deadline
    function test_registerWithSignature_success_eoaSignatureSupport(
        uint256 codeSeed,
        address initialOwner,
        address payoutAddress,
        uint48 deadline
    ) public {
        initialOwner = _boundNonZeroAddress(initialOwner);
        payoutAddress = _boundNonZeroAddress(payoutAddress);
        deadline = uint48(bound(deadline, uint48(block.timestamp), type(uint48).max));

        string memory code = _generateValidCode(codeSeed);
        bytes memory signature = _signRegistration(REGISTRAR_PK, code, initialOwner, payoutAddress, deadline);

        builderCodes.registerWithSignature(code, initialOwner, payoutAddress, deadline, registrar, signature);

        assertTrue(builderCodes.isRegistered(code));
        assertEq(builderCodes.ownerOf(builderCodes.toTokenId(code)), initialOwner);
    }

    /// @notice Test that registerWithSignature supports signature from contract
    ///
    /// @param codeSeed The seed for generating the code
    /// @param initialOwner The initial owner address
    /// @param payoutAddress The payout address
    /// @param deadline The registration deadline
    function test_registerWithSignature_success_contractSignatureSupport(
        uint256 codeSeed,
        address initialOwner,
        address payoutAddress,
        uint48 deadline,
        uint256 mockAccountOwnerPk
    ) public {
        initialOwner = _boundNonZeroAddress(initialOwner);
        payoutAddress = _boundNonZeroAddress(payoutAddress);
        deadline = uint48(bound(deadline, uint48(block.timestamp), type(uint48).max));
        mockAccountOwnerPk =
            bound(mockAccountOwnerPk, 1, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364140);
        vm.assume(mockAccountOwnerPk != OWNER_PK && mockAccountOwnerPk != REGISTRAR_PK);

        address mockAccountOwner = vm.addr(mockAccountOwnerPk);

        // Deploy mock account controlled by the fuzzed EOA
        MockAccount mockAccount = new MockAccount(mockAccountOwner, true);

        // Grant REGISTER_ROLE to the mock account
        vm.startPrank(owner);
        builderCodes.grantRole(builderCodes.REGISTER_ROLE(), address(mockAccount));
        vm.stopPrank();

        string memory code = _generateValidCode(codeSeed);
        bytes memory signature = _signRegistration(mockAccountOwnerPk, code, initialOwner, payoutAddress, deadline);

        builderCodes.registerWithSignature(code, initialOwner, payoutAddress, deadline, address(mockAccount), signature);

        assertTrue(builderCodes.isRegistered(code));
        assertEq(builderCodes.ownerOf(builderCodes.toTokenId(code)), initialOwner);
    }

    /// @notice Test that registerWithSignature complies with EIP-712 standard
    ///
    /// @param codeSeed The seed for generating the code
    /// @param initialOwner The initial owner address
    /// @param payoutAddress The payout address
    /// @param deadline The registration deadline
    function test_registerWithSignature_success_eip712Compliance(
        uint256 codeSeed,
        address initialOwner,
        address payoutAddress,
        uint48 deadline
    ) public {
        initialOwner = _boundNonZeroAddress(initialOwner);
        payoutAddress = _boundNonZeroAddress(payoutAddress);
        deadline = uint48(bound(deadline, uint48(block.timestamp), type(uint48).max));

        string memory code = _generateValidCode(codeSeed);

        // Verify the typehash matches what the contract expects
        bytes32 expectedTypehash = builderCodes.REGISTRATION_TYPEHASH();
        bytes32 actualTypehash =
            keccak256("BuilderCodeRegistration(string code,address initialOwner,address payoutAddress,uint48 deadline)");
        assertEq(actualTypehash, expectedTypehash, "Typehash mismatch");

        bytes memory signature = _signRegistration(REGISTRAR_PK, code, initialOwner, payoutAddress, deadline);

        // This should succeed if EIP-712 is implemented correctly
        builderCodes.registerWithSignature(code, initialOwner, payoutAddress, deadline, registrar, signature);

        assertTrue(builderCodes.isRegistered(code));

        // Verify domain separator can be computed (since it's not exposed publicly)
        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("Builder Codes")),
                keccak256(bytes("1")),
                block.chainid,
                address(builderCodes)
            )
        );
        assertTrue(domainSeparator != bytes32(0));
    }

    /// @notice Test that registerWithSignature successfully mints a token
    ///
    /// @param codeSeed The seed for generating the code
    /// @param initialOwner The initial owner address
    /// @param payoutAddress The payout address
    /// @param deadline The registration deadline
    function test_registerWithSignature_success_mintsToken(
        uint256 codeSeed,
        address initialOwner,
        address payoutAddress,
        uint48 deadline
    ) public {
        initialOwner = _boundNonZeroAddress(initialOwner);
        payoutAddress = _boundNonZeroAddress(payoutAddress);
        deadline = uint48(bound(deadline, uint48(block.timestamp), type(uint48).max));

        string memory code = _generateValidCode(codeSeed);
        uint256 tokenId = builderCodes.toTokenId(code);
        bytes memory signature = _signRegistration(REGISTRAR_PK, code, initialOwner, payoutAddress, deadline);

        builderCodes.registerWithSignature(code, initialOwner, payoutAddress, deadline, registrar, signature);

        assertEq(builderCodes.ownerOf(tokenId), initialOwner);
        assertTrue(builderCodes.isRegistered(code));
    }

    /// @notice Test that registerWithSignature successfully sets the payout address
    ///
    /// @param codeSeed The seed for generating the code
    /// @param initialOwner The initial owner address
    /// @param payoutAddress The payout address
    /// @param deadline The registration deadline
    function test_registerWithSignature_success_setsPayoutAddress(
        uint256 codeSeed,
        address initialOwner,
        address payoutAddress,
        uint48 deadline
    ) public {
        initialOwner = _boundNonZeroAddress(initialOwner);
        payoutAddress = _boundNonZeroAddress(payoutAddress);
        deadline = uint48(bound(deadline, uint48(block.timestamp), type(uint48).max));

        string memory code = _generateValidCode(codeSeed);
        bytes memory signature = _signRegistration(REGISTRAR_PK, code, initialOwner, payoutAddress, deadline);

        builderCodes.registerWithSignature(code, initialOwner, payoutAddress, deadline, registrar, signature);

        assertEq(builderCodes.payoutAddress(code), payoutAddress);
    }

    /// @notice Test that registerWithSignature emits the ERC721 Transfer event
    ///
    /// @param codeSeed The seed for generating the code
    /// @param initialOwner The initial owner address
    /// @param payoutAddress The payout address
    /// @param deadline The registration deadline
    function test_registerWithSignature_success_emitsERC721Transfer(
        uint256 codeSeed,
        address initialOwner,
        address payoutAddress,
        uint48 deadline
    ) public {
        initialOwner = _boundNonZeroAddress(initialOwner);
        payoutAddress = _boundNonZeroAddress(payoutAddress);
        deadline = uint48(bound(deadline, uint48(block.timestamp), type(uint48).max));

        string memory code = _generateValidCode(codeSeed);
        uint256 tokenId = builderCodes.toTokenId(code);
        bytes memory signature = _signRegistration(REGISTRAR_PK, code, initialOwner, payoutAddress, deadline);

        vm.expectEmit(true, true, true, true);
        emit IERC721.Transfer(address(0), initialOwner, tokenId);

        builderCodes.registerWithSignature(code, initialOwner, payoutAddress, deadline, registrar, signature);
    }

    /// @notice Test that registerWithSignature emits the CodeRegistered event
    ///
    /// @param codeSeed The seed for generating the code
    /// @param initialOwner The initial owner address
    /// @param payoutAddress The payout address
    /// @param deadline The registration deadline
    function test_registerWithSignature_success_emitsCodeRegistered(
        uint256 codeSeed,
        address initialOwner,
        address payoutAddress,
        uint48 deadline
    ) public {
        initialOwner = _boundNonZeroAddress(initialOwner);
        payoutAddress = _boundNonZeroAddress(payoutAddress);
        deadline = uint48(bound(deadline, uint48(block.timestamp), type(uint48).max));

        string memory code = _generateValidCode(codeSeed);
        uint256 tokenId = builderCodes.toTokenId(code);
        bytes memory signature = _signRegistration(REGISTRAR_PK, code, initialOwner, payoutAddress, deadline);

        vm.expectEmit(true, true, true, true);
        emit BuilderCodes.CodeRegistered(tokenId, code);

        builderCodes.registerWithSignature(code, initialOwner, payoutAddress, deadline, registrar, signature);
    }

    /// @notice Test that registerWithSignature emits the PayoutAddressUpdated event
    ///
    /// @param codeSeed The seed for generating the code
    /// @param initialOwner The initial owner address
    /// @param payoutAddress The payout address
    /// @param deadline The registration deadline
    function test_registerWithSignature_success_emitsPayoutAddressUpdated(
        uint256 codeSeed,
        address initialOwner,
        address payoutAddress,
        uint48 deadline
    ) public {
        initialOwner = _boundNonZeroAddress(initialOwner);
        payoutAddress = _boundNonZeroAddress(payoutAddress);
        deadline = uint48(bound(deadline, uint48(block.timestamp), type(uint48).max));

        string memory code = _generateValidCode(codeSeed);
        uint256 tokenId = builderCodes.toTokenId(code);
        bytes memory signature = _signRegistration(REGISTRAR_PK, code, initialOwner, payoutAddress, deadline);

        vm.expectEmit(true, true, true, true);
        emit BuilderCodes.PayoutAddressUpdated(tokenId, payoutAddress);

        builderCodes.registerWithSignature(code, initialOwner, payoutAddress, deadline, registrar, signature);
    }
}
