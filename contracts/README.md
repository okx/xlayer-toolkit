# Builder Codes

An ERC-721 NFT contract that enables builders to register unique codes (e.g., `"myapp"`) with an associated payout addresses for revenue attribution and distribution. Implements the [ERC-8021](https://eip.tools/eip/8021) `ICodesRegistry` interface.

## Features

- **Unique Code Registration**: Mint ERC-721 tokens representing alphanumeric codes (1-32 characters)
- **Flexible Registration Methods**: Direct registration via authorized registrars or gasless signature-based registration
- **Revenue Attribution**: Each code has a configurable payout address for tracking and distributing revenue
- **Role-Based Access Control**: Granular permissions for registration, transfers, and metadata updates
- **Upgradeable Design**: UUPS proxy pattern enables future enhancements while preserving state
- **Gas-Optimized**: Efficient storage layout using ERC-7201 and Solady libraries

## Architecture

### ERC-721 NFT

BuilderCodes implements the ERC-721 standard where each token represents a unique builder code. The token ID is deterministically derived from the code string itself, ensuring a 1:1 mapping between codes and token IDs. The contract uses OpenZeppelin's upgradeable ERC-721 implementation as the base.

### Access Control

The contract employs a **central registry with periphery registrars** architecture:

- **Central Registry**: The BuilderCodes contract serves as the authoritative registry, storing all code ownership and payout mappings
- **Periphery Registrars**: External contracts or EOAs granted `REGISTER_ROLE` can register codes on behalf of users
- **Restricted Transfers**: Only addresses with `TRANSFER_ROLE` can initiate transfers, preventing unauthorized code transfers

**Roles:**
- `REGISTER_ROLE`: Authorize code registration (direct calls or signatures)
- `TRANSFER_ROLE`: Authorize token transfers
- `METADATA_ROLE`: Update token metadata URIs
- **Owner**: Automatically has all roles via `hasRole()` override and can manage role grants

### Upgradeability

The contract uses the **UUPS (Universal Upgradeable Proxy Standard)** pattern:

- **Proxy Pattern**: ERC-1967 transparent proxy separates logic (implementation) from state (proxy)
- **Storage Safety**: ERC-7201 namespaced storage prevents collisions during upgrades
- **Owner-Only Upgrades**: Only the contract owner can authorize implementation upgrades via `_authorizeUpgrade()`

## Code System

### Valid Code Format

Builder codes must adhere to strict formatting rules:

- **Length**: 1-32 characters
- **Allowed Characters**: Lowercase letters (`a-z`), digits (`0-9`), and underscore (`_`)

### Token ID Conversion

The contract provides `toCode()` and `toTokenId()` as pure functions that bidirectionally map between builder codes and token IDs. This deterministic 1:1 mapping is enabled by 7-bit ASCII encoding of the allowed character set.

## Registration

### Direct Registration

The `register()` function allows authorized registrars to mint codes:

```solidity
function register(
    string memory code,
    address initialOwner,
    address initialPayoutAddress
) external onlyRole(REGISTER_ROLE)
```

**Flow:**
1. Caller must have `REGISTER_ROLE` (or be owner)
2. Code is validated for format compliance
3. Token is minted to `initialOwner`
4. Payout address is set to `initialPayoutAddress`
5. Events emitted: `Transfer`, `CodeRegistered`, `PayoutAddressUpdated`

### Signature-Based Registration

The `registerWithSignature()` function enables gasless registration via EIP-712 signatures:

```solidity
function registerWithSignature(
    string memory code,
    address initialOwner,
    address initialPayoutAddress,
    uint48 deadline,
    address signer,
    bytes memory signature
) external
```

**Flow:**
1. Verify deadline has not passed
2. Verify `signer` has `REGISTER_ROLE`
3. Compute EIP-712 typed data hash for registration parameters
4. Validate signature against signer's address
5. Execute registration (same as direct registration)

**EIP-712 Typed Data:**
```
BuilderCodeRegistration(
    string code,
    address initialOwner,
    address payoutAddress,
    uint48 deadline
)
```

This pattern allows users to obtain off-chain signatures from authorized registrars and submit registrations without the registrar paying gas.

## Transfer Restrictions

BuilderCodes implements a permission-gated transfer system to control how codes can be transferred between addresses.

**How it works:**
1. Transfers are only allowed if initiated by an address with `TRANSFER_ROLE`
2. Holders of `TRANSFER_ROLE` cannot move tokens unilaterally—they still need approval from each owner to transfer tokens

This design enables intentional rollout of specific transfer patterns, such as controlled marketplaces or recovery mechanisms.

