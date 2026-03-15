# X Layer Contract Patterns

## Hardhat Config (TypeScript)

```typescript
import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";
import '@okxweb3/hardhat-explorer-verify';

const config: HardhatUserConfig = {
  solidity: "0.8.34",
  paths: { sources: "./contracts" },
  networks: {
    "xlayer-testnet": {
      url: process.env.XLAYER_TESTNET_RPC_URL || "https://testrpc.xlayer.tech/terigon",
      chainId: 1952,
      accounts: process.env.DEPLOYER_PRIVATE_KEY ? [process.env.DEPLOYER_PRIVATE_KEY] : [],
    },
    "xlayer-mainnet": {
      url: process.env.XLAYER_RPC_URL || "https://rpc.xlayer.tech",
      chainId: 196,
      accounts: process.env.DEPLOYER_PRIVATE_KEY ? [process.env.DEPLOYER_PRIVATE_KEY] : [],
    },
  },
  okxweb3explorer: {
    apiKey: process.env.OKLINK_API_KEY,
  },
};
export default config;
```

## Deploy
```bash
npx hardhat run scripts/deploy.ts --network xlayer-testnet
npx hardhat run scripts/deploy.ts --network xlayer-mainnet
```

## Contract Verification

Standard contract:
```bash
npm install @okxweb3/hardhat-explorer-verify
npx hardhat okverify --network xlayer-mainnet <CONTRACT_ADDRESS>
```

Proxy contract (UUPS/Transparent):
```bash
npx hardhat okverify --network xlayer-mainnet --contract contracts/File.sol:ContractName --proxy <PROXY_ADDRESS>
```

Note: Wait at least 1 minute after deploy. OKLink API key: https://www.oklink.com
Note: Command name is `okverify` (without proxy) and `okverify` + `--proxy` flag (with proxy). Older docs may show `okxverify` — same command.

Alternative etherscan plugin (chainId 196):
- apiURL: https://www.oklink.com/api/v5/explorer/contract/verify-source-code-plugin/XLAYER
- browserURL: https://www.oklink.com/xlayer

Testnet (chainId 1952 — see `network-config.md` for chainId notes):
- apiURL: https://www.oklink.com/api/v5/explorer/contract/verify-source-code-plugin/XLAYER_TESTNET
- browserURL: https://www.oklink.com/xlayer-test

---

## Foundry Config & Deploy

### foundry.toml
```toml
[profile.default]
src = "contracts"
out = "out"
libs = ["node_modules"]
solc_version = "0.8.34"
optimizer = true
optimizer_runs = 200
evm_version = "cancun"

[rpc_endpoints]
xlayer = "https://rpc.xlayer.tech"
xlayer_testnet = "https://testrpc.xlayer.tech/terigon"

[etherscan]
xlayer = { key = "${OKLINK_API_KEY}", url = "https://www.oklink.com/api/v5/explorer/contract/verify-source-code-plugin/XLAYER" }
```

### Foundry Deploy
```bash
forge script script/Deploy.s.sol --rpc-url xlayer --broadcast --verify
```

### Hardhat + Foundry Together
```bash
npm install --save-dev @nomicfoundation/hardhat-foundry
```
```typescript
// hardhat.config.ts
import "@nomicfoundation/hardhat-foundry";
```

---

## UUPS Proxy Pattern

### Deploy
```solidity
// contracts/MyContractV1.sol
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

contract MyContractV1 is UUPSUpgradeable, OwnableUpgradeable {
    uint256 public value;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() { _disableInitializers(); }

    function initialize(uint256 _value) public initializer {
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();
        value = _value;
    }

    function _authorizeUpgrade(address newImpl) internal override onlyOwner {}
}
```

### Upgrade
```solidity
// contracts/MyContractV2.sol
contract MyContractV2 is MyContractV1 {
    uint256 public newField;  // New field — existing storage layout must NOT be broken!

    function reinitialize(uint256 _newField) public reinitializer(2) {
        newField = _newField;
    }
}
```

### Storage Gap Pattern
Upgradeable contracts in an inheritance chain must reserve storage slots to prevent collisions:
```solidity
contract MyContractV1 is UUPSUpgradeable, OwnableUpgradeable {
    uint256 public value;

    // Reserve 49 storage slots for future variables (value uses 1 slot, total = 50)
    uint256[49] private __gap;
}
```
Without `__gap`, adding variables to a base contract shifts storage in child contracts, corrupting data.

### Solidity Compiler Warning
> **TSTORE Poison Bug:** Solidity 0.8.28–0.8.33 have a critical bug in the IR (Yul) pipeline that corrupts transient storage cleanup (`TSTORE`/`TLOAD`). **Use 0.8.34+** which fixes this bug. Do not use `via_ir = true` with any version in the 0.8.28–0.8.33 range.

### ERC-7201 Namespaced Storage (Recommended)
OpenZeppelin v5 best practice for proxy/upgrade safety. Replaces error-prone `__gap` arrays with deterministic storage locations:
```solidity
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

contract MyContractV1 is UUPSUpgradeable {
    /// @custom:storage-location erc7201:myproject.storage.MyContract
    struct MyContractStorage {
        uint256 value;
        mapping(address => uint256) balances;
    }

    // keccak256(abi.encode(uint256(keccak256("myproject.storage.MyContract")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant STORAGE_LOCATION =
        0x...; // Compute with: cast keccak "myproject.storage.MyContract"

    function _getStorage() private pure returns (MyContractStorage storage $) {
        assembly { $.slot := STORAGE_LOCATION }
    }

    function getValue() public view returns (uint256) {
        return _getStorage().value;
    }
}
```
**Why ERC-7201 over `__gap`:**
- No risk of miscounting gap size
- Storage slots are deterministic — no collision between contracts in inheritance chain
- OpenZeppelin `@custom:storage-location` annotation enables automated tooling verification
- Works alongside existing `__gap` patterns if migrating incrementally

### Import Path: `contracts` vs `contracts-upgradeable`
- **Non-proxy contracts:** Use `@openzeppelin/contracts/...` (standard library)
- **Proxy/upgradeable contracts:** Use `@openzeppelin/contracts-upgradeable/...` (initializable variants)
- Mixing them causes subtle bugs: standard contracts have constructors that don't run behind proxies
```solidity
// ❌ Wrong: standard Ownable in an upgradeable contract — constructor won't run
import "@openzeppelin/contracts/access/Ownable.sol";

// ✅ Correct: upgradeable variant with initializer
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
```

### Critical Rules
- `constructor` must always call `_disableInitializers()`
- `initialize` function must use `initializer` modifier
- During upgrade: NEVER delete or reorder existing storage variables
- Always append new variables at the end
- Use `uint256[N] private __gap` in every upgradeable base contract
- Before upgrade: check storage layout with `@openzeppelin/upgrades-core`
- Production: use timelock + multisig for `_authorizeUpgrade`, not a single EOA

### Contract Size
- EIP-170 limit: 24,576 bytes deployed bytecode
- Check with `forge build --sizes` or `npx hardhat compile`
- Details → `gas-optimization.md`

---

## ERC721 Deploy & Verify

### Contract
```solidity
// contracts/MyNFT.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";

contract MyNFT is ERC721, ERC721URIStorage, Ownable2Step {
    uint256 private _nextTokenId;
    uint256 public constant MAX_SUPPLY = 10_000;
    uint256 public mintPrice = 0.01 ether; // 0.01 OKB

    constructor() ERC721("MyNFT", "MNFT") Ownable(msg.sender) {}

    function mint(string calldata uri) external payable {
        require(msg.value >= mintPrice, "Insufficient OKB");
        require(_nextTokenId < MAX_SUPPLY, "Max supply reached");

        uint256 tokenId = _nextTokenId++;
        _safeMint(msg.sender, tokenId);
        _setTokenURI(tokenId, uri);
    }

    function withdraw() external onlyOwner {
        uint256 balance = address(this).balance;
        require(balance > 0, "No balance");
        (bool success,) = payable(owner()).call{value: balance}("");
        require(success, "Transfer failed");
    }

    // Required overrides
    function tokenURI(uint256 tokenId) public view override(ERC721, ERC721URIStorage) returns (string memory) {
        return super.tokenURI(tokenId);
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721, ERC721URIStorage) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
```

### Deploy Script (Hardhat)
```typescript
import { ethers } from "hardhat";

async function main() {
    if (!process.env.DEPLOYER_PRIVATE_KEY) {
        throw new Error("DEPLOYER_PRIVATE_KEY env variable required");
    }

    const MyNFT = await ethers.getContractFactory("MyNFT");
    const nft = await MyNFT.deploy();
    await nft.waitForDeployment();
    console.log("MyNFT deployed to:", await nft.getAddress());
}

main().catch(console.error);
```

### Verify
```bash
npx hardhat okverify --network xlayer-mainnet <NFT_CONTRACT_ADDRESS>
```

---

## Permit2 Approval Pattern

Uniswap's [Permit2](https://github.com/Uniswap/permit2) provides a unified, safer token approval mechanism:
```solidity
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";
import {ISignatureTransfer} from "permit2/src/interfaces/ISignatureTransfer.sol";

contract MyDEX {
    IPermit2 public immutable permit2;

    constructor(IPermit2 _permit2) {
        permit2 = _permit2;
    }

    function swapWithPermit(
        ISignatureTransfer.PermitTransferFrom calldata permit,
        ISignatureTransfer.SignatureTransferDetails calldata transferDetails,
        bytes calldata signature
    ) external {
        // Single approve to Permit2, then Permit2 handles per-tx transfers
        permit2.permitTransferFrom(permit, transferDetails, msg.sender, signature);
        // ... execute swap logic
    }
}
```
**Advantages over raw `approve()`:**
- Users approve Permit2 once; individual dApps get per-transaction, expiring, amount-bounded permissions via signatures
- Eliminates the approve race condition (ERC20 front-running)
- Built-in nonce and deadline enforcement
- Batch permits for multi-token operations

**Permit2 on X Layer:** Canonical Permit2 address is `0x000000000022D473030F116dDEE9F6B43aC78BA3` (deterministic CREATE2 — same on all EVM chains). Verify deployment: call `eth_getCode` at this address. If empty (not deployed), deploy from [github.com/Uniswap/permit2](https://github.com/Uniswap/permit2) using the canonical CREATE2 deployer.
