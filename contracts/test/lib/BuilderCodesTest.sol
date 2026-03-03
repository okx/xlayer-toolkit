// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Test} from "forge-std/Test.sol";

import {BuilderCodes} from "../../src/BuilderCodes.sol";

abstract contract BuilderCodesTest is Test {
    uint256 internal constant OWNER_PK = uint256(keccak256("owner"));
    uint256 internal constant REGISTRAR_PK = uint256(keccak256("registrar"));
    string public constant URI_PREFIX = "https://example.com/builder-codes/metadata";

    BuilderCodes public builderCodes;

    address public owner;
    address public registrar;

    bytes32 public constant REGISTER_ROLE = keccak256("REGISTER_ROLE");
    bytes32 public constant TRANSFER_ROLE = keccak256("TRANSFER_ROLE");
    bytes32 public constant METADATA_ROLE = keccak256("METADATA_ROLE");

    function setUp() public virtual {
        owner = vm.addr(OWNER_PK);
        registrar = vm.addr(REGISTRAR_PK);

        address implementation = address(new BuilderCodes());
        bytes memory initData = abi.encodeWithSelector(BuilderCodes.initialize.selector, owner, registrar, URI_PREFIX);
        builderCodes = BuilderCodes(address(new ERC1967Proxy(implementation, initData)));

        vm.label(owner, "Owner");
        vm.label(registrar, "Registrar");
        vm.label(address(builderCodes), "BuilderCodes");
    }

    /// @notice Generates valid code
    ///
    /// @param seed Random number to seed the valid code generation
    ///
    /// @return code Valid code
    function _generateValidCode(uint256 seed) internal view returns (string memory code) {
        uint256 length = seed % 32 + 1; // 1-32 characters
        string memory allowedCharacters = builderCodes.ALLOWED_CHARACTERS();
        return _generateCode(seed, length, allowedCharacters);
    }

    /// @notice Generates invalid code with disallowed characters
    ///
    /// @param seed Random number to seed the invalid code generation
    ///
    /// @return code Invalid code containing disallowed characters
    function _generateInvalidCode(uint256 seed) internal pure returns (string memory code) {
        uint256 length = seed % 32 + 1; // 1-32 characters
        string memory invalidCharacters = "!@#$%^&*()ABCDEFGHIJKLMNOPQRSTUVWXYZ";
        return _generateCode(seed, length, invalidCharacters);
    }

    /// @notice Generates code over 32 characters
    ///
    /// @param seed Random number to seed the long code generation
    ///
    /// @return code Code over 32 characters long
    function _generateLongCode(uint256 seed) internal view returns (string memory code) {
        uint256 length = seed % 32 + 33; // 33-64 characters
        string memory allowedCharacters = builderCodes.ALLOWED_CHARACTERS();
        return _generateCode(seed, length, allowedCharacters);
    }

    function _generateCode(uint256 seed, uint256 length, string memory characters)
        internal
        pure
        returns (string memory code)
    {
        bytes memory charactersBytes = bytes(characters);
        uint256 divisor = charactersBytes.length;
        bytes memory codeBytes = new bytes(length);

        uint256 tmpSeed = seed;
        for (uint256 i; i < length; i++) {
            codeBytes[i] = charactersBytes[tmpSeed % divisor];
            tmpSeed /= divisor;
            if (tmpSeed == 0) tmpSeed = seed;
        }

        return string(codeBytes);
    }

    /// @notice Bounds address to non-zero value for fuzz testing
    ///
    /// @param addr Address to bound
    ///
    /// @return boundedAddr Non-zero address
    function _boundNonZeroAddress(address addr) internal pure returns (address boundedAddr) {
        return address(uint160(bound(uint160(addr), 1, type(uint160).max)));
    }

    /// @notice Deploys fresh uninitialized BuilderCodes contract for initialization tests
    ///
    /// @return freshContract Uninitialized BuilderCodes contract
    function _deployFreshBuilderCodes() internal returns (BuilderCodes freshContract) {
        address implementation = address(new BuilderCodes());
        return BuilderCodes(address(new ERC1967Proxy(implementation, "")));
    }

    /// @notice Creates EIP-712 signature for BuilderCode registration using Foundry's native EIP-712 support
    ///
    /// @param signerPk Private key of the signer
    /// @param code The code to register
    /// @param initialOwner The initial owner of the code
    /// @param payoutAddress The payout address
    /// @param deadline The registration deadline
    ///
    /// @return signature The EIP-712 signature
    function _signRegistration(
        uint256 signerPk,
        string memory code,
        address initialOwner,
        address payoutAddress,
        uint48 deadline
    ) internal view returns (bytes memory signature) {
        bytes32 structHash = keccak256(
            abi.encode(
                builderCodes.REGISTRATION_TYPEHASH(), keccak256(bytes(code)), initialOwner, payoutAddress, deadline
            )
        );

        // Use the same approach as the contract - we need to compute the domain separator manually
        // since BuilderCodes doesn't expose it publicly. We'll use the EIP-712 standard format.
        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("Builder Codes")),
                keccak256(bytes("1")),
                block.chainid,
                address(builderCodes)
            )
        );

        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);
        return abi.encodePacked(r, s, v);
    }
}
