合约用途说明

# 生产合约

- `L2BlacklistMirror.sol` — 黑名单镜像（XLOP-1100 demo stub）。带 `panic()` test hook 用于 CX10 fail-open 测试；不设 panic 时跟原版 100% 一致。生产部署前需评估是否保留 panic 函数。

# 测试专用合约（CXn / Cn 测试使用，不进生产）

- `MirrorProxy.sol` — ERC-1967 minimal proxy。CX9 proxy upgrade 测试用，部署在 deterministic mirror 地址；委托给 `L2BlacklistMirror` 作为 V1 impl。
- `L2BlacklistMirrorV2.sol` — CX9 测试用的 V2 impl，无视存储固定返回 `[BANANA]`，用于验证 upgradeTo 后两端立刻读取新 impl。
- `FakeTransferEmitter.sol` — CX5/CX6 测试用，能够任意发射 ERC20-shaped `Transfer` 事件以触发 check②。
- `SimpleERC20.sol` — C10/C14 测试用的最小 ERC20（mint/transfer/approve/transferFrom + Approval event）。
- `SimpleERC721.sol` — C11 测试用的最小 ERC721（Transfer event topic0 与 ERC20 同）。

# 部署开关（in `.env`）

- `USE_PROXY_MIRROR=true` — `7-deploy-blacklist.sh` 将部署 `MirrorProxy + L2BlacklistMirror impl` 而不是裸 mirror。仅 CX9 使用。
- `XLAYER_BYPASS_BLACKLIST_GATE=1`（CX5）/ `=2`（CX6）— 需配合 op-geth 端 `core/blacklist_gate_xlayer.go` patch（见 `testplan-blacklist-demo-opgeth.md` 的 CX5/CX6 段），跑完务必 `git checkout` 还原。

默认（两个 env 都不设或留空）合约部署行为跟历史一致，不影响 C1-C34 / 多数 CXn case。
