# X Layer Token Addresses

## Mainnet

| Token    | Address                                     | Decimals | Note |
|----------|---------------------------------------------|----------|------|
| **USDT0** | 0x779Ded0c9e1022225f8E0630b35a9b54bE713736 | 6        | Primary USDT — Stargate/LayerZero native |
| USDT     | 0x1E4a5963aBFD975d8c9021ce480b42188849D41d  | 6        | Legacy/bridged — prefer USDT0 for new integrations |
| WOKB   | 0xe538905cf8410324e03A5A23C1c177a474D59b2b  | 18       |
| WETH   | 0x5A77f1443D16ee5761d310e38b62f77f726bC71c  | 18       |
| USDC   | 0x74b7F16337b8972027F6196A17a631aC6dE26d22  | 6        |
| USDC.e | 0xA8CE8aee21bC2A48a5EF670afCc9274C7bbbC035  | 6        |
| WBTC   | 0xEA034fb02eB1808C2cc3adbC15f447B93CbE08e1  | 8        |
| DAI    | 0xC5015b9d9161Dca7e18e32f6f25C4aD850731Fd4  | 18       |

## Testnet

| Token  | Address                                     | Decimals |
|--------|---------------------------------------------|----------|
| WETH   | 0xBec7859BC3d0603BeC454F7194173E36BF2Aa5C8  | 18       |
| USDT   | Deploy via MockERC20.sol — no fixed address  |          |

## Utility Contracts

| Contract   | Address                                    | Note              |
|------------|---------------------------------------------|-------------------|
| Multicall3 | 0xcA11bde05977b3631167028862bE2a173976CA11  | Batch read calls  |

## OKB (Native Gas Token)
- OKB is X Layer's native gas token (like ETH on Ethereum)
- Decimals: 18 (as native token)
- Fixed supply: 21 million OKB (fully unlocked after August 2025)
- Gas can only be paid in OKB

## Testnet Faucet
- OKX testnet faucet: https://www.okx.com/xlayer/faucet
- Requires Sepolia ETH (bridge to get testnet OKB)

## Notes
- Common decimals mistake: use `parseUnits(amount, 6)` for USDT/USDC, NOT `parseEther`
- WBTC uses 8 decimals — different from most tokens, be careful!
