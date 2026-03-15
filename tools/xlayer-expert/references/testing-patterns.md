# X Layer Testing Patterns

## Hardhat Mainnet Forking

Test against real mainnet state:
```bash
npx hardhat node --fork https://rpc.xlayer.tech --fork-block-number <BLOCK>
```

### Hardhat Config
```typescript
// hardhat.config.ts
networks: {
    hardhat: {
        forking: {
            url: "https://rpc.xlayer.tech",
            blockNumber: 50_000_000,  // Fixed block — deterministic tests
        },
        chainId: 196,
    },
}
```

### Test Helpers
```typescript
import { ethers } from "hardhat";
import { loadFixture, time, mine } from "@nomicfoundation/hardhat-network-helpers";

// Impersonate a wealthy account
await ethers.provider.send("hardhat_impersonateAccount", [richAddress]);
const signer = await ethers.getSigner(richAddress);

// Set balance
await ethers.provider.send("hardhat_setBalance", [
    address,
    ethers.toQuantity(ethers.parseEther("100"))
]);

// Advance time
await time.increase(3600);  // 1 hour

// Mine blocks
await mine(10);  // 10 blocks
```

### Testing with Real Contracts
```typescript
it("should swap on DEX", async () => {
    const router = await ethers.getContractAt("IUniswapV2Router", DEX_ROUTER_ADDRESS);
    const usdt = await ethers.getContractAt("IERC20", "0x1E4a5963aBFD975d8c9021ce480b42188849D41d");

    // Impersonate a USDT holder
    await ethers.provider.send("hardhat_impersonateAccount", [usdtWhale]);
    const whale = await ethers.getSigner(usdtWhale);

    // Approve & swap
    await usdt.connect(whale).approve(router.target, amount);
    // ... test swap logic
});
```

---

## Foundry Forking

```bash
forge test --fork-url https://rpc.xlayer.tech --fork-block-number 50000000 -vvv
```

For `foundry.toml` config, see `contract-patterns.md` → Foundry Config section.

### Foundry Test Cheatcodes
```solidity
// test/MyContract.t.sol
pragma solidity ^0.8.34;
import "forge-std/Test.sol";
import "../contracts/MyContract.sol";

contract MyContractTest is Test {
    MyContract public target;

    function setUp() public {
        target = new MyContract();
    }

    function testWithFork() public {
        // Impersonate
        vm.prank(someAddress);

        // Set balance (OKB — native)
        vm.deal(someAddress, 100 ether);

        // Warp time
        vm.warp(block.timestamp + 1 hours);

        // Roll block number
        vm.roll(block.number + 100);

        // Expect revert
        vm.expectRevert("Insufficient balance");
        target.withdraw(1000);

        // Expect event
        vm.expectEmit(true, true, false, true);
        emit Transfer(from, to, amount);
        target.transfer(to, amount);
    }

    // Fuzz testing
    function testFuzz_deposit(uint256 amount) public {
        vm.assume(amount > 0 && amount < 1e24);
        target.deposit{value: amount}();
        assertEq(target.balanceOf(address(this)), amount);
    }
}
```

### Foundry Deploy Script
```solidity
// script/Deploy.s.sol
pragma solidity ^0.8.34;
import "forge-std/Script.sol";
import "../contracts/MyContract.sol";

contract DeployScript is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        vm.startBroadcast(deployerKey);

        MyContract c = new MyContract();
        console.log("Deployed:", address(c));

        vm.stopBroadcast();
    }
}
```
```bash
forge script script/Deploy.s.sol --rpc-url xlayer --broadcast --verify
```

---

## Hardhat + Foundry Together

```bash
npm install --save-dev @nomicfoundation/hardhat-foundry
```
```typescript
// hardhat.config.ts
import "@nomicfoundation/hardhat-foundry";
```
- Use Hardhat for deploy + verify
- Use Foundry for fast testing + fuzzing
- They share the same `contracts/` directory

---

## Stress Testing (xlayer-toolkit)

### Adventure Tool
20,000 concurrent accounts with ERC20 + native transfers:
```bash
git clone https://github.com/okx/xlayer-toolkit
cd xlayer-toolkit/adventure
# Edit config file
# Strategy: "erc20", "native", "mixed"
go run . --strategy erc20 --accounts 20000 --rpc https://rpc.xlayer.tech
```

### Transaction Replayor
Replay existing transactions for stress testing:
```bash
cd xlayer-toolkit/replayor
# Replay transactions from a specific block range
go run . --from-block 50000000 --to-block 50001000 --rpc https://rpc.xlayer.tech
```

---

## Security Testing Patterns

### Reentrancy Attack Simulation
```solidity
// test/ReentrancyTest.t.sol
contract MaliciousReceiver {
    IVault public target;
    uint256 public attackCount;

    constructor(address _target) {
        target = IVault(_target);
    }

    function attack() external payable {
        target.deposit{value: msg.value}();
        target.withdraw(msg.value);
    }

    receive() external payable {
        if (address(target).balance >= msg.value && attackCount < 5) {
            attackCount++;
            target.withdraw(msg.value);
        }
    }
}

contract ReentrancyTest is Test {
    function testReentrancyBlocked() public {
        MaliciousReceiver attacker = new MaliciousReceiver(address(vault));
        vm.deal(address(attacker), 1 ether);
        vm.expectRevert();  // Must revert if nonReentrant is applied
        attacker.attack();
    }
}
```

### Access Control Bypass Testing
```solidity
function testUnauthorizedAccessReverts() public {
    address unauthorized = makeAddr("hacker");

    vm.startPrank(unauthorized);
    vm.expectRevert();  // or vm.expectRevert(abi.encodeWithSelector(OwnableUnauthorizedAccount.selector, unauthorized))
    target.adminOnlyFunction();
    vm.stopPrank();
}

function testOwnershipTransfer() public {
    address newOwner = makeAddr("newOwner");
    // Step 1: current owner initiates transfer
    target.transferOwnership(newOwner);
    // Step 2: new owner must accept (Ownable2Step)
    vm.prank(newOwner);
    target.acceptOwnership();
    assertEq(target.owner(), newOwner);
}
```

### Invariant Testing (Foundry)
Invariant tests run random sequences of function calls and assert properties that must always hold:
```solidity
// test/invariants/TokenInvariant.t.sol
contract TokenInvariantTest is Test {
    MyToken public token;
    Handler public handler;

    function setUp() public {
        token = new MyToken();
        handler = new Handler(token);
        targetContract(address(handler));
    }

    // This invariant is checked after every random call sequence
    function invariant_totalSupplyMatchesBalances() public view {
        assertEq(
            token.totalSupply(),
            token.balanceOf(address(handler)) + token.balanceOf(address(this))
        );
    }

    function invariant_noUnauthorizedMints() public view {
        assertLe(token.totalSupply(), MAX_SUPPLY);
    }
}

// Handler: defines which functions the fuzzer can call
contract Handler is Test {
    MyToken public token;
    constructor(MyToken _token) { token = _token; }

    function deposit(uint256 amount) external {
        amount = bound(amount, 1, 100 ether);
        deal(address(this), amount);
        token.deposit{value: amount}();
    }

    function withdraw(uint256 amount) external {
        amount = bound(amount, 0, token.balanceOf(address(this)));
        token.withdraw(amount);
    }
}
```
Run invariant tests: `forge test --mt invariant -vvv`

### Flash Loan Attack Simulation
```solidity
function testFlashLoanPriceManipulation() public {
    // 1. Record price before attack
    uint256 priceBefore = oracle.getPrice(tokenA);

    // 2. Simulate a large swap (flash loan style)
    vm.deal(address(this), 10000 ether);
    router.swapExactTokensForTokens(largeAmount, 0, path, address(this), block.timestamp);

    // 3. Verify oracle is NOT manipulated (if using TWAP)
    uint256 priceAfter = oracle.getPrice(tokenA);
    assertApproxEqRel(priceBefore, priceAfter, 0.05e18); // Within 5%
}
```

### Security Analysis Tools
- **Slither** (static analysis): `slither . --solc-remaps '@openzeppelin=node_modules/@openzeppelin'`
- **Mythril** (symbolic execution): `myth analyze contracts/MyContract.sol`
- **Halmos** (formal verification for Foundry): `halmos --contract MyContract`
- **HEVM** (symbolic EVM): `hevm test --match testSymbolic`
- Run Slither in CI pipeline — catches most common vulnerability patterns automatically

---

## Pre-Deploy Test Checklist

Verify before every deployment:

- [ ] **Unit tests** — All functions tested (Hardhat or Foundry)
- [ ] **Integration tests** — Tested with real contracts via mainnet fork
- [ ] **Gas benchmarks** — `hardhat-gas-reporter` or `forge test --gas-report`
- [ ] **Decimals validation** — USDT/USDC: 6, OKB/WETH/DAI: 18, WBTC: 8
- [ ] **Upgrade path** — Proxy contracts: initialize + upgrade tested
- [ ] **Re-genesis boundary** — Block 42,810,021 edge case handled
- [ ] **Fuzz testing** — Critical functions tested with fuzzer
- [ ] **Slippage/deadline** — DEX operations have protection parameters
- [ ] **Access control** — Authorized functions have correct modifiers
- [ ] **Event emission** — All state changes emit events
