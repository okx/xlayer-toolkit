# X Layer OnChain Data API (OKLink)

REST API for querying X Layer blockchain data — blocks, transactions, addresses, tokens, event logs, and contract verification. Alternative to subgraph/indexer for most data queries.

## Base URL & Authentication

**Base URL:** `https://web3.okx.com`

**API Key Portal:** https://web3.okx.com/xlayer/dev-portal (connect wallet → create API key with passphrase)

### Required Headers (every request)

| Header | Value |
|--------|-------|
| `OK-ACCESS-KEY` | Your API key |
| `OK-ACCESS-SIGN` | HMAC SHA256 signature (Base64) |
| `OK-ACCESS-TIMESTAMP` | UTC timestamp (ISO format) |
| `OK-ACCESS-PASSPHRASE` | Passphrase from key creation |
| `Content-Type` | `application/json` (POST only) |

### HMAC Signing

```
sign = Base64( HmacSHA256( timestamp + METHOD + requestPath + body, SecretKey ) )
```

- `timestamp` must match `OK-ACCESS-TIMESTAMP` header exactly
- `METHOD` is uppercase (`GET`, `POST`)
- For GET: query params are part of `requestPath`; body is empty string
- For POST: body is raw JSON string
- Server time difference must not exceed **30 seconds**

### TypeScript Example

```typescript
import crypto from "crypto";

function createOKXHeaders(
  method: "GET" | "POST",
  requestPath: string,
  body: string = "",
  apiKey: string,
  secretKey: string,
  passphrase: string
) {
  const timestamp = new Date().toISOString().slice(0, -5) + "Z";
  const message = timestamp + method + requestPath + body;
  const sign = crypto
    .createHmac("sha256", secretKey)
    .update(message)
    .digest("base64");

  return {
    "OK-ACCESS-KEY": apiKey,
    "OK-ACCESS-SIGN": sign,
    "OK-ACCESS-TIMESTAMP": timestamp,
    "OK-ACCESS-PASSPHRASE": passphrase,
    "Content-Type": "application/json",
  };
}

// Usage
const path = "/api/v5/xlayer/block/block-fills?chainShortName=XLAYER&height=50000000";
const headers = createOKXHeaders("GET", path, "", API_KEY, SECRET_KEY, PASSPHRASE);
const res = await fetch(`https://web3.okx.com${path}`, { headers });
const data = await res.json(); // { code: "0", msg: "", data: [...] }
```

### Response Format

```json
{
  "code": "0",
  "msg": "",
  "data": [{ /* result objects */ }]
}
```
`"code": "0"` = success. Any other code = error.

### Error Handling

Always check both HTTP status and API response code:
```typescript
async function fetchOKX<T>(method: "GET" | "POST", path: string, body?: string): Promise<T[]> {
    const headers = createOKXHeaders(method, path, body ?? "", API_KEY, SECRET_KEY, PASSPHRASE);
    const res = await fetch(`https://web3.okx.com${path}`, {
        method,
        headers,
        ...(body ? { body } : {}),
    });

    if (!res.ok) {
        throw new Error(`OKLink HTTP error: ${res.status} ${res.statusText}`);
    }

    const json = await res.json();

    if (json.code !== "0") {
        throw new Error(`OKLink API error ${json.code}: ${json.msg}`);
    }

    if (!json.data || json.data.length === 0) {
        return []; // No results — not an error
    }

    return json.data as T[];
}
```

Common error codes:
| Code | Meaning |
|------|---------|
| `"50000"` | Body required / invalid parameters |
| `"50001"` | Service temporarily unavailable |
| `"50005"` | API key / signature invalid |
| `"50011"` | Rate limit exceeded |
| `"50014"` | Timestamp expired (>30s drift) |

---

## Limits & Constraints

| Constraint | Value |
|------------|-------|
| Pagination default | 20 per page |
| Pagination max | 50-100 (varies by endpoint) |
| Max results per query | ~10,000 (list endpoints) |
| Max results (logs) | ~1,000 |
| Block range (multi queries) | Max 10,000 block difference |
| Batch queries | Max 20 addresses or tx hashes |
| Time filter range | Max 1 year |
| `chainShortName` value | `XLAYER` (required on all endpoints) |

---

## Endpoint Reference

### Block Data (4 endpoints)

| Endpoint | Description |
|----------|-------------|
| `GET /api/v5/xlayer/block/block-fills` | Block details by height (`height` param) |
| `GET /api/v5/xlayer/block/block-list` | Paginated block list (max 100/page) |
| `GET /api/v5/xlayer/block/transaction-list` | Transactions in a block; filter by `protocolType` (`transaction`, `internal`, `token_20`, `token_721`, `token_1155`) |
| `GET /api/v5/xlayer/block/transaction-list-multi` | Batch transactions across block range (`startBlockHeight` → `endBlockHeight`) |

### Address Data (9 endpoints)

| Endpoint | Description |
|----------|-------------|
| `GET .../address/information-evm` | Balance, tx count, contract status, first/last tx time |
| `GET .../address/token-balance` | Token holdings by `protocolType` (`token_20`, `token_721`, `token_1155`); includes USD value |
| `GET .../address/transaction-list` | All tx types; **L2 fields: `challengeStatus`, `l1OriginHash`** |
| `GET .../address/normal-transaction-list` | Standard txs only; has `gasPrice`, `gasUsed`, `transactionType` fields |
| `GET .../address/internal-transaction-list` | Internal txs; has `operation` field (`call`, `staticcall`, etc.) |
| `GET .../address/token-transaction-list` | Token transfers by `protocolType`; filter by `tokenContractAddress` |
| `GET .../address/normal-transaction-list-multi` | Batch: up to 20 addresses, max 10k block range |
| `GET .../address/internal-transaction-list-multi` | Batch internal txs: up to 20 addresses |
| `GET .../address/native-token-position-list` | OKB rich list — top 10,000 holders with rank |

### Transaction Data (9 endpoints)

| Endpoint | Description |
|----------|-------------|
| `GET .../transaction/transaction-list` | Chain tx list; filter by `blockHash` or `height` |
| `GET .../transaction/large-transaction-list` | High-value txs (min 100 OKB threshold via `type` param) |
| `GET .../transaction/unconfirmed-transaction-list` | Pending/mempool transactions |
| `GET .../transaction/internal-transaction-detail` | Internal txs for single `txId` |
| `GET .../transaction/token-transaction-detail` | Token transfers within single `txId` |
| `GET .../transaction/transaction-fills` | Full tx details; batch up to 20 `txid`s (comma-separated) |
| `GET .../transaction/transaction-multi` | Same as fills; batch up to 20 |
| `GET .../transaction/internal-transaction-multi` | Internal txs for up to 20 hashes |
| `GET .../transaction/token-transfer-multi` | Token transfers for up to 20 hashes |

**Transaction types:** `"0"` (legacy), `"1"` (EIP-2930), `"2"` (EIP-1559)
**States:** `"success"`, `"fail"`, `"pending"`

### Token Data (3 endpoints)

| Endpoint | Description |
|----------|-------------|
| `GET .../token/token-list` | Token info + market data; sort by `totalMarketCap` or `transactionAmount24h` |
| `GET .../token/position-list` | Token holder ranking (top 10k); includes `positionChange24h` |
| `GET .../token/transaction-list` | Token transfers; filter by `minAmount`/`maxAmount` |

**Protocol types:** `token_20` (ERC20), `token_721` (ERC721), `token_1155` (ERC1155), `token_10` (ERC10)

### Event Log Data (4 endpoints)

| Endpoint | Description |
|----------|-------------|
| `GET .../log/by-block-and-address` | Logs by block range + contract address |
| `GET .../log/by-address-and-topic` | Logs by address + `topic0` filter |
| `GET .../log/by-address` | All logs for contract address |
| `GET .../log/by-transaction` | Logs emitted in single tx |

Log response: `height`, `address`, `topics[]`, `data`, `methodId`, `blockHash`, `txId`, `logIndex`
Max ~1,000 results per query.

### Event Log Limitations

- Only `topic0` filtering is supported — no `topic1`/`topic2`/`topic3` filters
- To filter by specific sender/receiver in Transfer events, fetch by `topic0` and filter client-side
- Max ~1,000 results per query; use block range pagination for larger datasets

### Contract Verification (5 endpoints)

| Endpoint | Method | Description |
|----------|--------|-------------|
| `.../contract/verify` | POST | Submit source code for verification |
| `.../contract/verify-result` | GET | Check verification status (`0`=pending, `1`=success, `2`=failed) |
| `.../contract/verify-proxy` | POST | Verify proxy contract — `proxyType`: `1`=Transparent, `2`=UUPS, `3`=Beacon |
| `.../contract/verify-proxy-result` | GET | Check proxy verification status |
| `.../contract/get-verified-contract` | GET | Get verified ABI + source code |

**Verify POST params:** `sourceCode`, `contractAddress`, `compilerVersion`, `runs`, `constructorArguments`, `licenseType`, `evmVersion`

---

## L2-Specific Response Fields

The address transaction list endpoint returns OP Stack-specific fields:

| Field | Description |
|-------|-------------|
| `challengeStatus` | Challenge period status for optimistic rollup transactions |
| `l1OriginHash` | Corresponding L1 transaction hash |
| `isAaTransaction` | Whether tx uses account abstraction (ERC-4337) |

---

## Common Patterns

### Get address balance + token holdings
```typescript
// 1. Native OKB balance
const info = await fetchOKX("GET", "/api/v5/xlayer/address/information-evm?chainShortName=XLAYER&address=0x...");
console.log(info.data[0].balance); // OKB balance

// 2. ERC20 token balances
const tokens = await fetchOKX("GET", "/api/v5/xlayer/address/token-balance?chainShortName=XLAYER&address=0x...&protocolType=token_20");
tokens.data[0].tokenList.forEach(t => console.log(t.symbol, t.holdingAmount, t.valueUsd));
```

### Monitor large transactions
```typescript
const large = await fetchOKX("GET", "/api/v5/xlayer/transaction/large-transaction-list?chainShortName=XLAYER&type=1000");
// Returns txs with amount >= 1000 OKB
```

### Query event logs by topic
```typescript
// Find all Transfer events for a token
const transferTopic = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef";
const logs = await fetchOKX("GET",
  `/api/v5/xlayer/log/by-address-and-topic?chainShortName=XLAYER&address=${tokenAddr}&topic0=${transferTopic}`
);
```

### Get token holder ranking
```typescript
const holders = await fetchOKX("GET",
  `/api/v5/xlayer/token/position-list?chainShortName=XLAYER&tokenContractAddress=${usdtAddr}&limit=50`
);
holders.data[0].positionList.forEach(h => console.log(h.rank, h.holderAddress, h.amount));
```
