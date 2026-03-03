// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {BuilderCodes, Initializable} from "../../../src/BuilderCodes.sol";

import {BuilderCodesTest} from "../../lib/BuilderCodesTest.sol";

/// @notice Unit tests for BuilderCodes.initialize
contract InitializeTest is BuilderCodesTest {
    /// @notice Test that initialize reverts when the contract is already initialized
    ///
    /// @param initialOwner The initial owner address
    /// @param initialRegistrar The initial registrar address
    /// @param uriPrefix The URI prefix
    function test_initialize_revert_initialized(address initialOwner, address initialRegistrar, string memory uriPrefix)
        public
    {
        initialOwner = _boundNonZeroAddress(initialOwner);

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        builderCodes.initialize(initialOwner, initialRegistrar, uriPrefix);
    }

    /// @notice Test that initialize reverts when a zero address is provided as the initial owner
    ///
    /// @param initialRegistrar The initial registrar address
    /// @param uriPrefix The URI prefix
    function test_initialize_revert_zeroInitialOwnerAddress(address initialRegistrar, string memory uriPrefix) public {
        BuilderCodes freshContract = _deployFreshBuilderCodes();

        vm.expectRevert(BuilderCodes.ZeroAddress.selector);
        freshContract.initialize(address(0), initialRegistrar, uriPrefix);
    }

    /// @notice Test that initialize sets the name to "Builder Codes"
    ///
    /// @param initialOwner The initial owner address
    /// @param initialRegistrar The initial registrar address
    /// @param uriPrefix The URI prefix
    function test_initialize_success_setName(address initialOwner, address initialRegistrar, string memory uriPrefix)
        public
    {
        initialOwner = _boundNonZeroAddress(initialOwner);
        BuilderCodes freshContract = _deployFreshBuilderCodes();

        freshContract.initialize(initialOwner, initialRegistrar, uriPrefix);

        assertEq(freshContract.name(), "Builder Codes");
    }

    /// @notice Test that initialize sets the symbol to "BUILDERCODE"
    ///
    /// @param initialOwner The initial owner address
    /// @param initialRegistrar The initial registrar address
    /// @param uriPrefix The URI prefix
    function test_initialize_success_setSymbol(address initialOwner, address initialRegistrar, string memory uriPrefix)
        public
    {
        initialOwner = _boundNonZeroAddress(initialOwner);
        BuilderCodes freshContract = _deployFreshBuilderCodes();

        freshContract.initialize(initialOwner, initialRegistrar, uriPrefix);

        assertEq(freshContract.symbol(), "BUILDERCODE");
    }

    /// @notice Test that initialize sets the initial owner
    ///
    /// @param initialOwner The initial owner address
    /// @param initialRegistrar The initial registrar address
    /// @param uriPrefix The URI prefix
    function test_initialize_success_setInitialOwner(
        address initialOwner,
        address initialRegistrar,
        string memory uriPrefix
    ) public {
        initialOwner = _boundNonZeroAddress(initialOwner);
        BuilderCodes freshContract = _deployFreshBuilderCodes();

        freshContract.initialize(initialOwner, initialRegistrar, uriPrefix);

        assertEq(freshContract.owner(), initialOwner);
    }

    /// @notice Test that initialize sets the initial registrar when a non-zero address is provided
    ///
    /// @param initialOwner The initial owner address
    /// @param initialRegistrar The initial registrar address
    /// @param uriPrefix The URI prefix
    function test_initialize_success_setNonZeroInitialRegistrar(
        address initialOwner,
        address initialRegistrar,
        string memory uriPrefix
    ) public {
        initialOwner = _boundNonZeroAddress(initialOwner);
        initialRegistrar = _boundNonZeroAddress(initialRegistrar);
        vm.assume(initialRegistrar != initialOwner);

        BuilderCodes freshContract = _deployFreshBuilderCodes();

        freshContract.initialize(initialOwner, initialRegistrar, uriPrefix);

        assertTrue(freshContract.hasRole(freshContract.REGISTER_ROLE(), initialRegistrar));
    }

    /// @notice Test that initialize ignores a zero initial registrar
    ///
    /// @param initialOwner The initial owner address
    /// @param uriPrefix The URI prefix
    function test_initialize_success_ignoresZeroInitialRegistrar(address initialOwner, string memory uriPrefix)
        public
    {
        initialOwner = _boundNonZeroAddress(initialOwner);
        BuilderCodes freshContract = _deployFreshBuilderCodes();

        freshContract.initialize(initialOwner, address(0), uriPrefix);

        assertFalse(freshContract.hasRole(freshContract.REGISTER_ROLE(), address(0)));
    }

    /// @notice Test that initialize sets the URI prefix
    ///
    /// @param initialOwner The initial owner address
    /// @param initialRegistrar The initial registrar address
    /// @param uriPrefix The URI prefix
    function test_initialize_success_setURIPrefix(
        address initialOwner,
        address initialRegistrar,
        string memory uriPrefix
    ) public {
        initialOwner = _boundNonZeroAddress(initialOwner);
        BuilderCodes freshContract = _deployFreshBuilderCodes();

        freshContract.initialize(initialOwner, initialRegistrar, uriPrefix);

        // Verify URI prefix by checking contractURI format
        string memory contractURI = freshContract.contractURI();
        if (bytes(uriPrefix).length > 0) assertEq(contractURI, string.concat(uriPrefix, "contractURI.json"));
        else assertEq(contractURI, "");
    }
}
