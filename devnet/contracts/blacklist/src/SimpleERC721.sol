// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice Minimal ERC721 for C11. ERC721 Transfer event topic0 is identical
///         to ERC20's (keccak256("Transfer(address,address,uint256)")), so the
///         blacklist check② hits this contract's Transfer the same way.
contract SimpleERC721 {
    mapping(uint256 => address) public ownerOf;

    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);

    function mint(address to, uint256 tokenId) external {
        require(ownerOf[tokenId] == address(0), "exists");
        ownerOf[tokenId] = to;
        emit Transfer(address(0), to, tokenId);
    }

    function transferFrom(address from, address to, uint256 tokenId) external {
        require(ownerOf[tokenId] == from, "not owner");
        ownerOf[tokenId] = to;
        emit Transfer(from, to, tokenId);
    }
}
