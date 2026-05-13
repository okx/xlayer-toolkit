---
name: xlayer-expert
description: "Use when code targets chainId 196 or 1952, references rpc.xlayer.tech, mentions OKB/WOKB/flashblocks/xlayer-reth, or involves Solidity contracts for X Layer (OKX L2). Also trigger for Hardhat/Foundry config with X Layer networks, bridge contracts (L2CrossDomainMessenger, OptimismPortal), GasPriceOracle predeploy, re-genesis block 42810021, or proxy/upgrade patterns. Trigger for OKLink OnChain Data API: OK-ACCESS-KEY, OK-ACCESS-SIGN, oklink, /api/v5/xlayer/. Even if 'X Layer' is not mentioned, trigger for chainId 196 or OKB as native gas token."
---

# X Layer Expert Skill

## Security Golden Rules

These rules apply to ALL Solidity code written for X Layer. Violating any of these creates exploitable vulnerabilities:

1. **CEI Pattern** — All external calls AFTER state changes. Never send tokens/OKB before updating balances.
   ```solidity
   balances[msg.sender] -= amount;                    // Effect first
   (bool ok,) = msg.sender.call{value: amount}("");   // Then interact
   require(ok);
   ```

2. **ReentrancyGuard** — Add `nonReentrant` to any function that transfers value or makes external calls.

3. **No tx.origin auth** — ALWAYS `msg.sender`. The only acceptable `tx.origin` use is EOA check: `require(tx.origin == msg.sender)`.

4. **Private keys** — `.env` only, NEVER hardcoded. Always validate `process.env.DEPLOYER_PRIVATE_KEY` exists. Verify `.env` is in `.gitignore`.

5. **Token decimals** — USDT/USDC = **6**, WBTC = **8**, OKB/WETH/DAI = **18**. Use `parseUnits(amount, 6)` for USDT, NOT `parseEther()`.

6. **Slippage + deadline** — Every swap/DEX function MUST accept `minAmountOut` + `deadline` parameters.

7. **Ownable2Step** — Use 2-step ownership transfer to prevent accidental admin key loss. Never use basic `Ownable`.

8. **Check call return values** — Always `require(success)` after low-level `call`/`delegatecall`. Or use OpenZeppelin `Address.functionCall()`.

9. **Safe ERC20 approvals** — Use `forceApprove` or `safeIncreaseAllowance` (SafeERC20) instead of raw `approve()` to prevent the approval race condition.

10. **OKB is the gas token** — NOT ETH. `msg.value` is denominated in OKB. Users must hold OKB to pay gas. Set `nativeCurrency` to OKB in chain definitions.

11. **No unbounded loops** — Never iterate arrays that can grow without limit. Use pull patterns (users claim individually) instead of push patterns (contract distributes to all).

12. **Signature replay protection** — Include `block.chainid` (196), `nonce`, `deadline`, and `address(this)` in all EIP-712 domain separators.

13. **Never use transfer()/send()** — They forward only 2300 gas, which fails on contracts with logic in `receive()`. Always use `call{value: amount}("")` with return value check, or OpenZeppelin `Address.sendValue()`.

14. **Guard receive()/fallback()** — Never write empty `receive() external payable {}`. Either emit an event for tracking or `revert()` to reject unexpected OKB. Unguarded receive permanently locks OKB in the contract.

15. **Forced OKB sending** — `selfdestruct` (or `CREATE2` + `selfdestruct` in same tx post-EIP-6780) can force OKB into any contract, bypassing `receive()`. Never use `address(this).balance` for accounting — track deposits explicitly with a state variable.
   ```solidity
   // ❌ Vulnerable: attacker can inflate balance via selfdestruct
   require(address(this).balance >= totalDeposits);
   // ✅ Safe: track deposits explicitly
   uint256 public totalDeposited;
   function deposit() external payable { totalDeposited += msg.value; }
   ```

16. **No on-chain randomness** — On L2, the sequencer controls `block.timestamp`, `block.prevrandao`, and `blockhash`. Never use these for randomness. **Chainlink VRF is NOT available on X Layer** — use commit-reveal pattern instead. See `security.md` → Randomness.
   ```solidity
   // ❌ Vulnerable: sequencer can predict/manipulate
   uint256 random = uint256(keccak256(abi.encodePacked(block.timestamp, block.prevrandao)));
   // ✅ Safe: commit-reveal pattern (see security.md for full example)
   ```

17. **Private != secret** — `private` variables are readable via `eth_getStorageAt`. Never store passwords, secret keys, or hidden game state in contract storage. Use commit-reveal or off-chain computation for sensitive data.

18. **Signature malleability** — Raw `ecrecover` accepts both low-s and high-s values, allowing signature duplication. Always use OpenZeppelin `ECDSA.recover()` which rejects malleable signatures. Mark used signatures in a mapping to prevent replay.
   ```solidity
   // ❌ Vulnerable: accepts malleable signatures
   address signer = ecrecover(hash, v, r, s);
   // ✅ Safe: OpenZeppelin ECDSA rejects high-s values
   address signer = ECDSA.recover(hash, signature);
   ```

19. **Transient storage reentrancy** — EIP-1153 `TSTORE`/`TLOAD` costs only 100 gas — reentrancy is possible even within the 2300 gas stipend. Use `ReentrancyGuardTransient` (OZ v5.1+) for new contracts.

20. **Input validation** — Always validate: `address != address(0)`, `amount > 0`, array length bounds, and length parity for parallel arrays. Validate at system boundaries.

21. **Solidity ≥0.8.34** — Use 0.8.34+ as minimum compiler version. Versions 0.8.28–0.8.33 have the TSTORE Poison bug (IR pipeline corrupts transient storage cleanup). 0.8.34 fixes this.

22. **EIP-7702 awareness** — `tx.origin == msg.sender` is no longer a reliable EOA check post-Pectra. Validate nonce, gas, and value in all signature-verified operations. See `security.md` → EIP-7702.

## Post-Write Security Check

After writing any Solidity code, verify ALL Golden Rules before presenting it:
- [ ] CEI pattern followed? (Rule 1)
- [ ] `nonReentrant` on all value-transfer functions? (Rule 2)
- [ ] No `tx.origin` for auth? (Rule 3)
- [ ] No hardcoded private keys? (Rule 4)
- [ ] Correct token decimals used? (Rule 5)
- [ ] Slippage + deadline on swaps? (Rule 6)
- [ ] `Ownable2Step` instead of `Ownable`? (Rule 7)
- [ ] All low-level call return values checked? (Rule 8)
- [ ] `forceApprove`/`safeIncreaseAllowance` instead of raw `approve()`? (Rule 9)
- [ ] OKB as gas token, not ETH? (Rule 10)
- [ ] No unbounded loops? (Rule 11)
- [ ] Signature replay protection (chainid, nonce, deadline)? (Rule 12)
- [ ] No `payable(x).transfer()` or `.send()` calls? (Rule 13)
- [ ] `receive()`/`fallback()` guarded or absent? (Rule 14)
- [ ] No `address(this).balance` for accounting? (Rule 15)
- [ ] No on-chain randomness (`block.timestamp`, `prevrandao`)? (Rule 16)
- [ ] No secrets stored in `private` variables? (Rule 17)
- [ ] Using `ECDSA.recover()` instead of raw `ecrecover`? (Rule 18)
- [ ] Transient storage + reentrancy considered? (Rule 19)
- [ ] Input validation at boundaries? (Rule 20)
- [ ] Solidity version ≥0.8.34? (Rule 21)
- [ ] No `tx.origin == msg.sender` as sole EOA check? (Rule 22)

## Conditional Pattern Triggers

When you detect these patterns in user code, automatically apply the corresponding check:

| Pattern Detected | Auto-Check |
|-----------------|------------|
| `address(this).balance` | Warn about forced OKB sending (Rule 15) |
| `block.timestamp` or `block.prevrandao` used for randomness | Suggest commit-reveal pattern (Rule 16) — VRF not available |
| `private` variable storing password/secret/key | Warn about on-chain visibility (Rule 17) |
| `ecrecover(` | Suggest OpenZeppelin ECDSA (Rule 18) |
| `AggregatorV3Interface` or price feed | Check staleness + sequencer uptime |
| `selfdestruct` or `CREATE2` | Warn about forced send implications |
| `receive() external payable {}` (empty) | Reject — require event or revert (Rule 14) |
| `approve(` without SafeERC20 | Suggest forceApprove (Rule 9) |
| Unbounded `for` loop over storage array | Suggest pull pattern (Rule 11) |
| `tx.origin == msg.sender` as sole check | Warn about EIP-7702 bypass (Rule 22) |
| `TSTORE`/`TLOAD` without reentrancy guard | Warn about transient storage reentrancy (Rule 19) |

## When to Trigger

| Category | Triggers |
|----------|----------|
| **Contracts & Deploy** | `.sol` files, `hardhat.config.ts`, `foundry.toml`, `forge script/test/build`, deploy scripts |
| **Provider & Network** | `ethers.JsonRpcProvider`, `viem`, `createPublicClient`, `chainId 196/1952`, `rpc.xlayer.tech` |
| **Token & Address** | USDT/USDT0/WOKB/OKB/WETH/USDC/WBTC/DAI addresses, `Multicall3`, `aggregate3` |
| **Proxy & Upgrade** | `UUPSUpgradeable`, `TransparentUpgradeableProxy`, `initializer`, `reinitializer`, `upgradeTo` |
| **Bridge & Cross-Chain** | `L2CrossDomainMessenger`, `OptimismPortal`, `AggLayer`, bridge deposit/withdrawal |
| **Gas & Oracle** | `GasPriceOracle`, `maxFeePerGas`, `maxPriorityFeePerGas`, gas optimization |
| **OnChain Data API** | `OK-ACCESS-KEY`, `OK-ACCESS-SIGN`, `/api/v5/xlayer/`, OKLink API, block explorer queries |

## Reference Loading Guide

Read the reference files matching the current task.

**MANDATORY:** Always read `security.md` before writing ANY Solidity code. No exceptions.

| Task | Read These |
|------|-----------|
| Writing/auditing Solidity | **`security.md`** + `contract-patterns.md` |
| Deploy script or toolchain config | `contract-patterns.md` + `network-config.md` |
| Token addresses or decimals | `token-addresses.md` |
| Bridge or cross-chain code | **`security.md`** + `l2-predeploys.md` + `infrastructure.md` |
| Proxy/upgrade patterns | `contract-patterns.md` + **`security.md`** |
| Gas optimization | `gas-optimization.md` |
| Flashblocks integration | `flashblocks.md` |
| Testing or forking | `testing-patterns.md` |
| RPC setup or monitoring | `infrastructure.md` |
| On-chain data queries (REST API) | `onchain-data-api.md` |
| Pre-re-genesis / historical data | `zkevm-differences.md` |

## Reference Files

All under `references/`:

| File | Content |
|------|---------|
| `network-config.md` | RPC URLs, chainId, rate limits, re-genesis, architecture |
| `token-addresses.md` | Token addresses + Multicall3 |
| `contract-patterns.md` | Hardhat + Foundry config, deploy, verify, proxy |
| `flashblocks.md` | Flashblocks API, reorg risks |
| `l2-predeploys.md` | L2 predeploy + L1 bridge addresses |
| `security.md` | Solidity security, L2 risks, attack patterns |
| `zkevm-differences.md` | CDK->OP Stack migration, EVM differences |
| `gas-optimization.md` | OKB economics, fee structure, optimization |
| `testing-patterns.md` | Forking, security testing, stress testing |
| `onchain-data-api.md` | OKLink REST API — blocks, txs, tokens, logs, HMAC auth |
| `infrastructure.md` | RPC providers, xlayer-reth, monitoring, WebSocket |
