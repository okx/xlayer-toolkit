// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {BuilderCodesTest, IERC721Errors} from "../../lib/BuilderCodesTest.sol";

/// @notice Unit tests for BuilderCodes.updateMetadata
contract UpdateMetadataTest is BuilderCodesTest {
    /// @notice ERC4906 MetadataUpdate event
    event MetadataUpdate(uint256 _tokenId);

    /// @notice Test that updateMetadata reverts when sender doesn't have required role
    function test_updateMetadata_revert_senderInvalidRole(uint256 codeSeed) public {
        string memory validCode = _generateValidCode(codeSeed);
        address unauthorizedUser = makeAddr("unauthorized");

        // Register a code first
        vm.prank(registrar);
        builderCodes.register(validCode, owner, owner);

        uint256 tokenId = builderCodes.toTokenId(validCode);

        vm.prank(unauthorizedUser);
        vm.expectRevert();
        builderCodes.updateMetadata(tokenId);
    }

    /// @notice Test that updateMetadata reverts when the code is not registered
    function test_updateMetadata_revert_codeNotRegistered(uint256 codeSeed) public {
        string memory validCode = _generateValidCode(codeSeed);
        uint256 tokenId = builderCodes.toTokenId(validCode);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, tokenId));
        builderCodes.updateMetadata(tokenId);
    }

    /// @notice Test that updateMetadata allows owner to update
    function test_updateMetadata_success_ownerCanUpdate(uint256 codeSeed) public {
        string memory validCode = _generateValidCode(codeSeed);

        // Register a code first
        vm.prank(registrar);
        builderCodes.register(validCode, owner, owner);

        uint256 tokenId = builderCodes.toTokenId(validCode);

        // Owner should be able to update metadata
        vm.prank(owner);
        builderCodes.updateMetadata(tokenId);
    }

    /// @notice Test that updateMetadata succeeds and token URI remains unchanged
    function test_updateMetadata_success_tokenURIUnchanged(uint256 codeSeed) public {
        string memory validCode = _generateValidCode(codeSeed);

        // Register a code first
        vm.prank(registrar);
        builderCodes.register(validCode, owner, owner);

        uint256 tokenId = builderCodes.toTokenId(validCode);
        string memory uriBefore = builderCodes.tokenURI(tokenId);

        vm.prank(owner);
        builderCodes.updateMetadata(tokenId);

        string memory uriAfter = builderCodes.tokenURI(tokenId);
        assertEq(uriBefore, uriAfter);
    }

    /// @notice Test that updateMetadata succeeds and code URI remains unchanged
    function test_updateMetadata_success_codeURIUnchanged(uint256 codeSeed) public {
        string memory validCode = _generateValidCode(codeSeed);

        // Register a code first
        vm.prank(registrar);
        builderCodes.register(validCode, owner, owner);

        string memory uriBefore = builderCodes.codeURI(validCode);
        uint256 tokenId = builderCodes.toTokenId(validCode);

        vm.prank(owner);
        builderCodes.updateMetadata(tokenId);

        string memory uriAfter = builderCodes.codeURI(validCode);
        assertEq(uriBefore, uriAfter);
    }

    /// @notice Test that updateMetadata emits the ERC4906 MetadataUpdate event
    function test_updateMetadata_success_emitsERC4906MetadataUpdate(uint256 codeSeed) public {
        string memory validCode = _generateValidCode(codeSeed);

        // Register a code first
        vm.prank(registrar);
        builderCodes.register(validCode, owner, owner);

        uint256 tokenId = builderCodes.toTokenId(validCode);

        vm.expectEmit(true, false, false, false);
        emit MetadataUpdate(tokenId);

        vm.prank(owner);
        builderCodes.updateMetadata(tokenId);
    }
}
