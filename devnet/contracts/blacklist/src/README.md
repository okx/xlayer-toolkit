Contract overview

# Production contract

- `L2BlacklistMirror.sol` — the blacklist mirror (devnet demo stub). Carries a `panic()` test hook used to exercise node fail-open behaviour; with panic unset it behaves identically to the plain mirror. Evaluate whether to keep the panic function before any production deployment.

# devnet mirror deploy address

On devnet (chain 195) the mirror is always deployed at the deterministic address `0x73511669fd4dE447feD18BB79bAFeAC93aB7F31f`:

- Deployed by a dedicated test-mnemonic account `m/44'/60'/0'/0/19` (standard `test … junk` mnemonic) whose only job is this one deploy, so its L2 nonce stays 0.
- A plain CREATE address = `keccak256(rlp(deployer, nonce))[12:]`, i.e. it depends only on (deployer, nonce); fixed deployer + nonce 0 ⇒ the address above.
- The same address is hardcoded in the node binaries (op-geth `params/config_xlayer.go`, xlayer-reth `crates/blacklist`); the nodes read the list via `getBlacklist`.
- `7-deploy-blacklist.sh` asserts the deployed address equals this constant and aborts on mismatch, so the deployed address can never diverge from the node-hardcoded one.
- The deployer index and this address are constants baked into `7-deploy-blacklist.sh`, not exposed in `.env` (only the `BLACKLIST_DEMO_ENABLED` toggle lives in `.env`).

# Test-only contracts (not for production)

- `MirrorProxy.sol` — ERC-1967 minimal proxy, deployed at the deterministic mirror address and delegating to `L2BlacklistMirror` as the V1 impl. Used by the proxy-upgrade test.
- `L2BlacklistMirrorV2.sol` — a V2 impl that ignores storage and always returns a fixed address list, used to verify both clients immediately read the new impl after an upgrade.
- `FakeTransferEmitter.sol` — emits an arbitrary ERC20-shaped `Transfer` event to trigger the blacklist's committed event-log scan.

Generic ERC20 / ERC721 / ERC1155 mocks live in `contracts/testkit/src/Mocks.sol` (`MockERC20` / `MockERC721` / `MockERC1155`); they are not maintained here.

# Test switches

Test-only env / switches (`USE_PROXY_MIRROR`, `XLAYER_BYPASS_BLACKLIST_GATE`, etc.) are set only during testing (including temporary docker-compose / op-geth patches). See `testplan-blacklist-demo-opgeth.md` for usage and revert steps. With them unset, contract deployment behaves as before and is unaffected.
