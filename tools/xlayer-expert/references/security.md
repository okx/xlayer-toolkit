# X Layer Security Reference

## Solidity Security Rules

### CEI (Checks-Effects-Interactions) Pattern
All external calls MUST happen AFTER state changes:
```solidity
// ✅ Correct: CEI pattern
function withdraw(uint256 amount) external {
    require(balances[msg.sender] >= amount, "Insufficient");  // Check
    balances[msg.sender] -= amount;                            // Effect
    (bool ok, ) = msg.sender.call{value: amount}("");          // Interaction
    require(ok, "Transfer failed");
}

// ❌ Wrong: Interaction before Effect — reentrancy vulnerability
function withdraw(uint256 amount) external {
    require(balances[msg.sender] >= amount, "Insufficient");
    (bool ok, ) = msg.sender.call{value: amount}("");  // External call BEFORE state update!
    balances[msg.sender] -= amount;
}
```

### ReentrancyGuard
Mandatory for bridge contracts and token transfer functions:
```solidity
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract Bridge is ReentrancyGuard {
    function bridgeToken(uint256 amount) external nonReentrant {
        // ...
    }
}
```

#### Transient Storage Reentrancy (EIP-1153)
> **Warning:** With EIP-1153 (transient storage), the 2300 gas stipend from `transfer()`/`send()` is NO longer a reentrancy barrier. `TSTORE`/`TLOAD` cost only 100 gas each, making reentrancy possible even within 2300 gas. (Source: ChainSecurity, 2025)

For new contracts, prefer `ReentrancyGuardTransient` (OpenZeppelin v5.1+) which uses transient storage for cheaper reentrancy protection:
```solidity
// Gas-efficient reentrancy guard using transient storage (EIP-1153)
import "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

contract MyContract is ReentrancyGuardTransient {
    function withdraw(uint256 amount) external nonReentrant {
        // TSTORE-based lock — cheaper than SSTORE, auto-clears at tx end
    }
}
```
**Key difference:** Classic `ReentrancyGuard` uses `SSTORE` (~5000 gas). `ReentrancyGuardTransient` uses `TSTORE` (~100 gas) and auto-resets at transaction end — no need to reset the lock manually.

### Authentication
- NEVER use `tx.origin` for authentication — always use `msg.sender`
- `tx.origin` is only acceptable for checking "is the caller an EOA?"
```solidity
// ❌ Dangerous: Vulnerable to phishing attacks
require(tx.origin == owner);

// ✅ Correct
require(msg.sender == owner);
```

#### EIP-7702 Delegated Execution Security
> **Critical (Pectra upgrade, 2025):** EIP-7702 allows EOAs to delegate execution to a contract via `SET_CODE_TX_TYPE (0x04)`. Phishing attacks using EIP-7702 are already occurring on Ethereum mainnet. X Layer cross-chain users are at risk.

**Threats:**
- Attacker tricks user into signing a delegation that transfers their assets
- Delegated code can bypass `tx.origin == msg.sender` EOA checks
- Nonce manipulation via delegated execution

**Protections:**
```solidity
// ❌ No longer safe as sole EOA check (EIP-7702 breaks this assumption)
require(tx.origin == msg.sender, "Not EOA");

// ✅ Additional validation for EIP-7702 awareness
function _validateCaller() internal view {
    require(msg.sender == tx.origin, "Not EOA");
    // If your contract handles delegated calls, also validate:
    require(msg.value == 0 || msg.value == expectedValue, "Unexpected value");
    // Check nonce consistency if implementing meta-tx
}
```
- Validate `nonce`, `gas`, and `value` in all signature-verified operations
- Never trust `tx.origin` alone — always combine with `msg.sender` checks and application-level authorization
- Warn users about blind-signing risks in your dApp UI

### Access Control
- Simple ownership: OpenZeppelin `Ownable2Step` (2-step transfer, prevents accidental loss)
- Role-based: OpenZeppelin `AccessControl` or `AccessControlEnumerable`
- Critical functions: `onlyOwner` + `timelock` combination

#### Role Separation Best Practices (OWASP 2025 #1)
Access control is the #1 vulnerability category (OWASP Smart Contract Top 10, 2025). Apply defense-in-depth:
```solidity
import "@openzeppelin/contracts/access/AccessControlEnumerable.sol";

contract Treasury is AccessControlEnumerable {
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    // Separate roles: operator can execute, guardian can pause/cancel
    function executeTransfer(address to, uint256 amount) external onlyRole(OPERATOR_ROLE) {
        // ...
    }

    function emergencyPause() external onlyRole(GUARDIAN_ROLE) {
        _pause();
    }
}
```
- **Enumerate roles:** Use `AccessControlEnumerable` to audit who has which role
- **Timelock critical operations:** Admin functions (upgrade, large transfers) should go through `TimelockController`
- **Multi-sig for admin:** Never use a single EOA for `DEFAULT_ADMIN_ROLE` in production
- **Revoke default admin:** After setup, consider renouncing `DEFAULT_ADMIN_ROLE` from deployer and transferring to a timelock/multisig

### Integer Overflow/Underflow
- Solidity 0.8+ has automatic checks
- Only use `unchecked` blocks for gas optimization when safety is guaranteed
```solidity
// Safe: i can never overflow (bounded loop)
for (uint256 i = 0; i < arr.length;) {
    // ...
    unchecked { ++i; }
}
```

#### Downcast Safety
Solidity 0.8+ checks arithmetic overflow/underflow, but **downcasting silently truncates** without reverting:
```solidity
// ❌ VULNERABLE: silently truncates — no revert on overflow
uint256 big = type(uint256).max;
uint128 small = uint128(big); // Silently truncated to type(uint128).max

// ✅ Safe: use OpenZeppelin SafeCast — reverts on overflow
import "@openzeppelin/contracts/utils/math/SafeCast.sol";
using SafeCast for uint256;
uint128 safe = big.toUint128(); // Reverts: "SafeCast: value doesn't fit in 128 bits"
```

### Front-running Protection
- Commit-reveal pattern: first commit hash, then reveal value
- Private mempool: via Flashblocks or dedicated RPC
- Time-based nonce or deadline parameters

#### MEV on X Layer
- **Single sequencer (OKX):** No public mempool MEV like Ethereum — users cannot run MEV bots targeting the mempool
- **Flashblocks:** Create a ~200ms visibility window before finalization — see `flashblocks.md` for reorg risks
- **Sequencer ordering:** The sequencer determines transaction ordering; no PBS (proposer-builder separation) yet
- **Always use slippage protection** (Rule 6) regardless of sequencer ordering guarantees — sequencer trust assumptions may change

### Slippage Protection
Mandatory parameters for DEX/swap operations:
```solidity
function swap(
    uint256 amountIn,
    uint256 minAmountOut,  // Slippage protection
    uint256 deadline       // Time protection
) external {
    require(block.timestamp <= deadline, "Expired");
    uint256 amountOut = _calculateSwap(amountIn);
    require(amountOut >= minAmountOut, "Slippage exceeded");
    // ...
}
```

### Flash Loan Attack Surfaces
- Oracle manipulation: use TWAP instead of spot price
- Price impact: large single-block trades manipulating price
- Protection: Chainlink price feed (if available for the pair) or multi-block TWAP, liquidity checks

### Oracle / Price Feed Guidance
- **Chainlink on X Layer:** Limited availability — only major pairs (OKB/USD, ETH/USD, BTC/USD, USDT/USD). Check [Chainlink X Layer feeds](https://docs.chain.link/data-feeds/price-feeds/addresses?network=xlayer) before depending on a feed.
- For pairs WITHOUT Chainlink feeds: use DEX TWAP (e.g., Uniswap V3 `observe()`) with multi-block averaging as fallback
- Always validate feed freshness: `require(block.timestamp - updatedAt < MAX_STALENESS)`
- Always check `answer > 0` and `answeredInRound >= roundId`

### ERC20 Approve Race Condition
The `approve()` function is vulnerable to front-running — an attacker can spend the old allowance before the new one takes effect:
```solidity
// ❌ Vulnerable: attacker front-runs and spends old + new allowance
token.approve(spender, newAmount);

// ✅ Recommended: use SafeERC20 (handles the race condition internally)
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
using SafeERC20 for IERC20;

token.forceApprove(spender, amount);          // OZ v5+ (best)
token.safeIncreaseAllowance(spender, amount); // OZ v4

// Legacy fallback (if SafeERC20 is unavailable): reset to 0 first
token.approve(spender, 0);
token.approve(spender, newAmount);
```
For new DEX/DeFi integrations, consider **Permit2** which eliminates the approve race entirely — see `contract-patterns.md` → Permit2 Approval Pattern.

### transfer() / send() 2300 Gas Limit
`transfer()` and `send()` forward only 2300 gas — not enough for contracts with logic in `receive()`:
```solidity
// ❌ Dangerous: 2300 gas limit — fails on contracts with receive() logic
payable(recipient).transfer(amount);
bool ok = payable(recipient).send(amount);

// ✅ Correct: call{value:} forwards all available gas
(bool success,) = payable(recipient).call{value: amount}("");
require(success, "Transfer failed");

// ✅ Better: OpenZeppelin Address
Address.sendValue(payable(recipient), amount);
```

### receive() / fallback() Protection
Unguarded receive functions permanently lock OKB in the contract:
```solidity
// ❌ Dangerous: OKB sent to this contract is locked forever
receive() external payable {}

// ✅ Option 1: emit event for tracking
receive() external payable {
    emit Received(msg.sender, msg.value);
}

// ✅ Option 2: reject unexpected OKB
receive() external payable {
    revert("Direct OKB transfers not accepted");
}
```

### Cross-Function Reentrancy
`nonReentrant` on one function does NOT protect other functions that share the same state:
```solidity
// ❌ Vulnerable: withdraw() has nonReentrant, but transfer() does not
function withdraw(uint256 amount) external nonReentrant {
    require(balances[msg.sender] >= amount);
    balances[msg.sender] -= amount;                          // Effect (CEI ✓)
    (bool ok,) = msg.sender.call{value: amount}("");         // Interaction
    require(ok);
    // During callback, attacker calls transfer() which has NO nonReentrant
}

function transfer(address to, uint256 amount) external {
    // No nonReentrant! Attacker re-enters here during withdraw callback
    require(balances[msg.sender] >= amount);
    balances[msg.sender] -= amount;
    balances[to] += amount;
}
```
Protection: use `nonReentrant` modifier on ALL public functions that read or write shared state, not just the one with the external call.

### Multicall Reentrancy
Batched calls via Multicall3 (`0xcA11bde05977b3631167028862bE2a173976CA11`) execute in a single transaction but bypass `nonReentrant` between calls in the batch:
- `nonReentrant` won't protect between calls within the same Multicall batch
- `msg.value` is shared across all calls in the batch — do NOT use `msg.value` in payable functions called via Multicall (double-spending risk)
- If inheriting OpenZeppelin `Multicall`: mark payable functions `nonReentrant` AND validate `msg.value` is consumed exactly once

### ERC-4626 Vault Inflation Attack
First depositor can manipulate share price by donating tokens directly to the vault:
```
Attack scenario:
1. Attacker deposits 1 wei → gets 1 share
2. Attacker donates 1,000,000 tokens directly to vault (transfer, not deposit)
3. Victim deposits 999,000 tokens: shares = 999,000 * 1 / 1,000,000 = 0 (rounded down)
4. Victim gets 0 shares — attacker redeems 1 share for all ~2M tokens
```
```solidity
// ✅ Protection: OpenZeppelin ERC4626 _decimalsOffset() adds virtual offset
// to prevent rounding manipulation. Use OZ implementation directly:
import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

contract MyVault is ERC4626 {
    constructor(IERC20 asset) ERC4626(asset) ERC20("Vault", "vTKN") {}

    // OZ default: _decimalsOffset() returns 0
    // Override to add protection (recommended):
    function _decimalsOffset() internal pure override returns (uint8) {
        return 3; // Adds 1000 virtual shares — prevents inflation attack
    }
}
```

### Unchecked Return Values
Low-level calls that ignore return values silently fail, potentially losing funds:
```solidity
// ❌ Dangerous: return value ignored — transfer may fail silently
payable(recipient).send(amount);
address(target).call(data);

// ✅ Correct: check return value
(bool success, ) = payable(recipient).call{value: amount}("");
require(success, "Transfer failed");

// ✅ Better: use OpenZeppelin Address library
import "@openzeppelin/contracts/utils/Address.sol";
Address.sendValue(payable(recipient), amount);
Address.functionCall(target, data);
```

### Delegatecall Risks
Especially relevant for proxy/upgrade patterns on X Layer:
- `delegatecall` executes code in the **caller's storage context** — a malicious implementation can overwrite proxy storage
- Never `delegatecall` to untrusted or unverified contracts
- Proxy and implementation storage layouts MUST be identical — adding/reordering variables in upgrades breaks storage
- Always call `_disableInitializers()` in implementation constructors to prevent direct initialization
- Use OpenZeppelin's `StorageSlot` for unstructured storage patterns
- For upgrade-safe storage, prefer **ERC-7201 namespaced storage** over `__gap` arrays — see `contract-patterns.md` → ERC-7201 Namespaced Storage

### Denial of Service (DoS) via Unbounded Loops
Iterating over arrays that can grow without bound will eventually exceed the block gas limit:
```solidity
// ❌ Dangerous: unbounded loop + .transfer() (see Rule 13)
function distributeRewards() external {
    for (uint256 i = 0; i < recipients.length; i++) {
        payable(recipients[i]).transfer(rewards[i]); // Bad: unbounded + 2300 gas limit
    }
}

// ✅ Safe: pull pattern — each recipient claims their own reward
mapping(address => uint256) public pendingRewards;

function claimReward() external nonReentrant {
    uint256 reward = pendingRewards[msg.sender];
    require(reward > 0, "No reward");
    pendingRewards[msg.sender] = 0;                        // Effect
    (bool success,) = payable(msg.sender).call{value: reward}("");  // Interaction
    require(success, "Transfer failed");
}
```
Also: a single failed `transfer` in a loop reverts the entire batch — another reason to prefer pull patterns.

### Signature Replay Protection
Off-chain signatures (EIP-712, permit) must include replay protection fields:
```solidity
// EIP-712 domain separator MUST include all of these:
bytes32 public DOMAIN_SEPARATOR = keccak256(abi.encode(
    keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
    keccak256(bytes("MyContract")),
    keccak256(bytes("1")),
    block.chainid,     // 196 for X Layer mainnet — prevents cross-chain replay
    address(this)      // prevents cross-contract replay
));

// Per-user nonce — prevents same-chain replay
mapping(address => uint256) public nonces;

// Deadline — prevents stale signatures from being used indefinitely
function executeWithSignature(
    bytes calldata sig,
    uint256 deadline,
    uint256 nonce
) external {
    require(block.timestamp <= deadline, "Signature expired");
    require(nonce == nonces[msg.sender]++, "Invalid nonce");
    // ... verify signature against DOMAIN_SEPARATOR
}
```
Note: `block.chainid` returns 196 on X Layer mainnet, 1952 on testnet.

### Input Validation Checklist
Apply these checks at all public/external function boundaries:
```solidity
// Address validation
require(recipient != address(0), "Zero address");
require(recipient != address(this), "Self-transfer");

// Amount validation
require(amount > 0, "Zero amount");
require(amount <= MAX_TRANSFER, "Exceeds limit");

// Array bounds
require(recipients.length > 0 && recipients.length <= MAX_BATCH, "Invalid batch size");
require(recipients.length == amounts.length, "Length mismatch");

// String/bytes length
require(bytes(name).length > 0 && bytes(name).length <= 32, "Invalid name");
```
Rule of thumb: validate at system boundaries (user input, external calls), trust internal functions.

### ERC-4337 Account Abstraction Security
> X Layer supports account abstraction (`isAaTransaction` field in OKLink API). Smart account wallets introduce unique attack surfaces.

**Key Threats:**
1. **UserOp gas field manipulation:** Attacker submits UserOp with inflated `preVerificationGas` or `callGasLimit` to drain paymaster funds
2. **Paymaster exploitation:** Malicious UserOp tricks paymaster into paying for operations it shouldn't sponsor
3. **Signature validation bypass:** `validateUserOp` must verify signature + nonce atomically
4. **Storage access rules:** `validateUserOp` can only access the account's own associated storage (ERC-7562 rules)

**Protection patterns:**
```solidity
// In your smart account's validateUserOp:
function validateUserOp(
    PackedUserOperation calldata userOp,
    bytes32 userOpHash,
    uint256 missingAccountFunds
) external returns (uint256 validationData) {
    // 1. Verify signature (MUST check — never skip)
    require(_validateSignature(userOp, userOpHash), "Invalid signature");

    // 2. Validate nonce (prevents replay)
    // EntryPoint manages nonces, but validate key-space if using 2D nonces

    // 3. Pay prefund if needed
    if (missingAccountFunds > 0) {
        (bool ok,) = payable(msg.sender).call{value: missingAccountFunds}("");
        // NOTE: Intentionally ignoring return value per ERC-4337 spec (exception to Rule 8).
        // EntryPoint will revert entire UserOp if underfunded — checking `ok` here is unnecessary.
        (ok); // Silence unused variable warning
    }

    return 0; // 0 = valid (no time restriction). Packed as (authorizer, validUntil, validAfter)
}
```
- **Paymaster validation:** Always cap `maxCost` and validate the `paymasterAndData` field. Set spending limits per user/timeframe.
- **Bundler trust:** Do not assume the bundler is honest — validate all UserOp fields on-chain.

---

## L2-Specific Security

### Sequencer Centralization
- X Layer sequencer is controlled by OKX (multi-sequencer cluster with failover)
- Sequencer can censor transactions (delay/skip)
- Consider L1 forced inclusion mechanism for critical functions
- Transactions cannot be sent during sequencer downtime

### block.timestamp Manipulation
- Sequencer determines `block.timestamp` (with ±drift)
- Time-sensitive operations (auction, vesting, deadline) must account for this drift
- `block.number` is less reliable on L2 — use L1 block reference (`L1Block` predeploy)

### L2→L1 Withdrawal Security
- Withdrawal period: ~7 days challenge period (PermissionedDisputeGame active on OP Stack), but AggLayer ZK proofs can provide faster finality
- Proof generation time is variable
- Withdrawal replay protection: each withdrawal has a unique nonce
- Sufficient balance check in bridge contract is mandatory

### Bridge Reentrancy Risks
- ERC-777 tokens can create reentrancy via `tokensReceived` hook
- Fee-on-transfer tokens (deflationary) transfer less than expected amount
- Rebase tokens create balance inconsistencies in bridge
- Protection: token whitelist + ReentrancyGuard + actual balance delta check

### Message Replay Protection
- Cross-chain messages must validate `nonce + sourceChainId + destinationChainId`
- Prevent same message from executing on multiple chains
- L2CrossDomainMessenger provides these protections built-in

### OP Stack Specific Security
- **PermissionedDisputeGame:** Only authorized participants can open disputes — not yet permissionless
- **Multi-sequencer:** OKX operates with backup failover for 99.9%+ uptime
- **Bridge security:** OP Stack standard bridge contracts, extensively audited
- **Security audit:** January 2026 xlayer-reth diff audit report available

---

## [LEGACY] zkEVM Circuit Risks (Pre-Re-genesis Only)

> **IMPORTANT:** The following risks apply ONLY to the old Polygon CDK/zkEVM era (block ≤42,810,020). Post-re-genesis X Layer runs on standard EVM-compatible OP Stack.

### Opcode Circuit Bugs (Historical)
- SHL/SHR opcodes previously caused circuit bugs (PSE/Scroll audits)
- Formal verification found 6 soundness + 1 completeness issues

### Precompile Circuit Capacity (Historical)
- In old zkEVM, each precompile had fixed capacity in the circuit
- Post-re-genesis: standard EVM precompile behavior — this limitation no longer applies

---

## Private Key Management

### Mandatory Rules
1. `DEPLOYER_PRIVATE_KEY` only in `.env` file
2. `.env` file MUST be in `.gitignore` (verify!)
3. Hardcoded private key = critical security vulnerability
4. `process.env` check mandatory in deploy scripts:

```typescript
// deploy.ts start
if (!process.env.DEPLOYER_PRIVATE_KEY) {
    throw new Error("DEPLOYER_PRIVATE_KEY env variable required");
}
```

### Production Environment
- Use hardware wallet (Ledger) or multi-sig (Safe)
- Gnosis Safe: https://safe.global — multi-sig wallet
- Deployer key and admin key should be separate
- Add timelock contract for admin operations

---

## Additional Security Patterns

### Forced OKB Sending (selfdestruct bypass)
> **Post-EIP-6780 (Dencun):** `selfdestruct` on pre-existing contracts only sends balance — it does NOT destroy code or storage. The only case where `selfdestruct` fully destroys a contract is when called in the **same transaction** as `CREATE2` deployment. This `CREATE2` + `selfdestruct` in same tx still works as a full forced-send vector.

`selfdestruct` (or `CREATE2` + `selfdestruct` in the same transaction) can force OKB into any contract, bypassing `receive()` guards:
```solidity
// ❌ VULNERABLE: attacker uses selfdestruct to inflate address(this).balance
contract Vault {
    uint256 public totalDeposits;

    function deposit() external payable {
        totalDeposits += msg.value;
    }

    function isBalanceCorrect() public view returns (bool) {
        return address(this).balance == totalDeposits; // Can be broken!
    }
}

// ✅ Safe: track deposits with state variable, ignore forced sends
contract SafeVault {
    uint256 public totalDeposited;

    function deposit() external payable {
        totalDeposited += msg.value;
    }

    function availableBalance() public view returns (uint256) {
        return totalDeposited; // Not address(this).balance
    }
}
```

### Randomness (VRF)
> **Chainlink VRF is NOT available on X Layer as of March 2026.** Do not use VRF code examples targeting X Layer — they will not work.

On L2, the sequencer controls `block.timestamp`, `block.prevrandao`, and `blockhash`. These MUST NOT be used for randomness:
```solidity
// ❌ VULNERABLE: sequencer can predict/manipulate all of these
uint256 bad1 = uint256(keccak256(abi.encodePacked(block.timestamp)));
uint256 bad2 = uint256(keccak256(abi.encodePacked(block.prevrandao)));
uint256 bad3 = uint256(keccak256(abi.encodePacked(blockhash(block.number - 1))));
```

Use **commit-reveal** as the primary on-chain randomness pattern:
```solidity
// Phase 1: Commit (user submits hash)
mapping(address => bytes32) public commitments;
mapping(address => uint256) public commitBlock;

function commit(bytes32 hash) external {
    commitments[msg.sender] = hash;
    commitBlock[msg.sender] = block.number;
}

// Phase 2: Reveal (after N blocks, user reveals secret)
function reveal(bytes32 secret) external {
    require(commitments[msg.sender] == keccak256(abi.encodePacked(secret)), "Invalid reveal");
    require(block.number > commitBlock[msg.sender] + REVEAL_DELAY, "Too early");
    require(block.number <= commitBlock[msg.sender] + REVEAL_DEADLINE, "Too late");

    // Combine user secret with future blockhash for randomness
    uint256 random = uint256(keccak256(abi.encodePacked(
        secret,
        blockhash(commitBlock[msg.sender] + REVEAL_DELAY)
    )));

    delete commitments[msg.sender];
    // Use `random` ...
}
```
**Limitations:** `blockhash()` only works for the last 256 blocks. Set `REVEAL_DELAY` and `REVEAL_DEADLINE` accordingly.

> **⚠ VRF Import Guidance — Future Reference Only.** VRF is NOT available on X Layer. Do NOT import these for X Layer deployments. When VRF becomes available, use stable import paths (NOT `/dev/`):
> ```solidity
> // Correct (stable):
> import {VRFConsumerBaseV2Plus} from "@chainlink/contracts/src/v0.8/vrf/VRFConsumerBaseV2Plus.sol";
> // Wrong (development — do NOT use):
> // import {VRFConsumerBaseV2Plus} from "@chainlink/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
> ```

### On-Chain Data Privacy
`private` variables are NOT hidden — anyone can read them via `eth_getStorageAt`:
```solidity
// ❌ VULNERABLE: "private" does not mean secret
contract BadGame {
    uint256 private secretNumber = 42; // Readable by anyone!
    bytes32 private password = keccak256("hunter2"); // Readable by anyone!
}

// Reading private storage (off-chain):
// slot 0: await provider.getStorage(contractAddr, 0) → secretNumber
// slot 1: await provider.getStorage(contractAddr, 1) → password hash

// ✅ Safe: use commit-reveal for hidden values
contract SafeGame {
    mapping(address => bytes32) public commitments;

    function commit(bytes32 hash) external {
        commitments[msg.sender] = hash; // hash = keccak256(abi.encodePacked(value, salt))
    }

    function reveal(uint256 value, bytes32 salt) external {
        require(commitments[msg.sender] == keccak256(abi.encodePacked(value, salt)), "Bad reveal");
        delete commitments[msg.sender];
        // ... use value
    }
}
```

### Signature Malleability (ECDSA s-value)
ECDSA signatures accept both low-s and high-s values for the same message. This means an attacker can compute a second valid signature from any existing one:
```solidity
// ❌ VULNERABLE: accepts malleable signatures — attacker can forge second valid sig
function verify(bytes32 hash, uint8 v, bytes32 r, bytes32 s) public pure returns (address) {
    return ecrecover(hash, v, r, s);
}

// ✅ Safe: OpenZeppelin ECDSA rejects high-s values automatically
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

function verify(bytes32 hash, bytes calldata signature) public pure returns (address) {
    return ECDSA.recover(MessageHashUtils.toEthSignedMessageHash(hash), signature);
}

// Also: always track used signatures to prevent replay
mapping(bytes32 => bool) public usedSignatures;

function executeWithSig(bytes32 hash, bytes calldata sig) external {
    bytes32 sigHash = keccak256(sig);
    require(!usedSignatures[sigHash], "Signature already used");
    usedSignatures[sigHash] = true;

    address signer = ECDSA.recover(MessageHashUtils.toEthSignedMessageHash(hash), sig);
    require(signer == authorizedSigner, "Invalid signer");
    // ... execute action
}
```

### Oracle Integration (Chainlink Price Feed)
When using price oracles, always check for staleness and L2 sequencer uptime:
```solidity
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

contract PriceConsumer {
    AggregatorV3Interface internal priceFeed;
    uint256 public constant STALENESS_THRESHOLD = 3600; // 1 hour

    constructor(address feedAddress) {
        priceFeed = AggregatorV3Interface(feedAddress);
    }

    function getLatestPrice() public view returns (int256 price, uint8 decimals) {
        (
            uint80 roundId,
            int256 answer,
            /* uint256 startedAt */,
            uint256 updatedAt,
            uint80 answeredInRound
        ) = priceFeed.latestRoundData();

        // Staleness check
        require(block.timestamp - updatedAt <= STALENESS_THRESHOLD, "Stale price data");
        // Round completeness check
        require(answeredInRound >= roundId, "Stale round");
        // Sanity check
        require(answer > 0, "Invalid price");

        return (answer, priceFeed.decimals());
    }
}

// L2 Sequencer Uptime Feed
// Chainlink L2 Sequencer Uptime Feed: NOT confirmed available on X Layer (March 2026).
// Check https://docs.chain.link/data-feeds/l2-sequencer-feeds for updates.
// When available, add this check before using any Chainlink price feed:
//
// AggregatorV3Interface sequencerUptimeFeed = AggregatorV3Interface(SEQUENCER_FEED_ADDR);
// (, int256 answer,, uint256 startedAt,) = sequencerUptimeFeed.latestRoundData();
// bool isSequencerUp = answer == 0;
// require(isSequencerUp, "Sequencer is down");
// uint256 timeSinceUp = block.timestamp - startedAt;
// require(timeSinceUp > GRACE_PERIOD, "Grace period not over");
```
> **Note:** Check Chainlink's official page for available price feeds on X Layer (chainId 196). If Chainlink feeds are not available for a specific pair, consider using TWAP from a DEX with sufficient liquidity.
