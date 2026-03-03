// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {BuilderCodesTest} from "../../lib/BuilderCodesTest.sol";

/// @notice Unit tests for BuilderCodes.updateBaseURI
contract UpdateBaseURITest is BuilderCodesTest {
    /// @notice ERC4906 BatchMetadataUpdate event
    event BatchMetadataUpdate(uint256 _fromTokenId, uint256 _toTokenId);

    /// @notice ERC7572 ContractURIUpdated event
    event ContractURIUpdated();
    /// @notice Test that updateBaseURI reverts when sender doesn't have required role
    ///
    /// @param uriPrefix The URI prefix to test

    function test_updateBaseURI_revert_senderInvalidRole(address sender, string memory uriPrefix) public {
        vm.assume(!builderCodes.hasRole(builderCodes.METADATA_ROLE(), sender));
        vm.startPrank(sender);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, sender, builderCodes.METADATA_ROLE()
            )
        );
        builderCodes.updateBaseURI(uriPrefix);
    }

    /// @notice Test that updateBaseURI allows owner to update
    function test_updateBaseURI_success_ownerCanUpdate() public {
        string memory newURI = "https://new-uri.com/";

        vm.prank(owner);
        builderCodes.updateBaseURI(newURI);

        // Verify update worked by checking contractURI
        assertEq(builderCodes.contractURI(), string.concat(newURI, "contractURI.json"));
    }

    /// @notice Test that updateBaseURI successfully updates the token URI
    ///
    /// @param uriPrefix The URI prefix to test
    function test_updateBaseURI_success_tokenURIUpdated(string memory uriPrefix) public {
        string memory validCode = _generateValidCode(12345);

        // Register a code first
        vm.prank(registrar);
        builderCodes.register(validCode, owner, owner);

        uint256 tokenId = builderCodes.toTokenId(validCode);

        vm.prank(owner);
        builderCodes.updateBaseURI(uriPrefix);

        string memory tokenURI = builderCodes.tokenURI(tokenId);
        if (bytes(uriPrefix).length > 0) assertEq(tokenURI, string.concat(uriPrefix, validCode));
        else assertEq(tokenURI, "");
    }

    /// @notice Test that updateBaseURI successfully updates the code URI
    ///
    /// @param uriPrefix The URI prefix to test
    function test_updateBaseURI_success_codeURIUpdated(string memory uriPrefix) public {
        string memory validCode = _generateValidCode(67890);

        // Register a code first
        vm.prank(registrar);
        builderCodes.register(validCode, owner, owner);

        vm.prank(owner);
        builderCodes.updateBaseURI(uriPrefix);

        string memory codeURI = builderCodes.codeURI(validCode);
        if (bytes(uriPrefix).length > 0) assertEq(codeURI, string.concat(uriPrefix, validCode));
        else assertEq(codeURI, "");
    }

    /// @notice Test that updateBaseURI successfully updates the contract URI
    ///
    /// @param uriPrefix The URI prefix to test
    function test_updateBaseURI_success_contractURIUpdated(string memory uriPrefix) public {
        vm.prank(owner);
        builderCodes.updateBaseURI(uriPrefix);

        string memory contractURI = builderCodes.contractURI();
        if (bytes(uriPrefix).length > 0) assertEq(contractURI, string.concat(uriPrefix, "contractURI.json"));
        else assertEq(contractURI, "");
    }

    /// @notice Test that updateBaseURI emits the ERC4906 BatchMetadataUpdate event
    ///
    /// @param uriPrefix The URI prefix to test
    function test_updateBaseURI_success_emitsERC4906BatchMetadataUpdate(string memory uriPrefix) public {
        vm.expectEmit(true, true, false, false);
        emit BatchMetadataUpdate(0, type(uint256).max);

        vm.prank(owner);
        builderCodes.updateBaseURI(uriPrefix);
    }

    /// @notice Test that updateBaseURI emits the ERC7572 ContractURIUpdated event
    ///
    /// @param uriPrefix The URI prefix to test
    function test_updateBaseURI_success_emitsERC7572ContractURIUpdated(string memory uriPrefix) public {
        vm.expectEmit(false, false, false, false);
        emit ContractURIUpdated();

        vm.prank(owner);
        builderCodes.updateBaseURI(uriPrefix);
    }
}
