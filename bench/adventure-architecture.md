# adventure — Architecture & The reth Fix

> How the adventure Go tool works, what broke, and what was changed.

---

## 1. Overall component map

```mermaid
graph TD
    subgraph bench-adventure.sh
        SH[bench-adventure.sh]
    end

    subgraph adventure binary
        CLI[CLI entrypoint<br/>main.go]
        INIT[erc20-init<br/>bench/erc20.go]
        BENCH[erc20-bench<br/>bench/erc20.go]
        CFG[loadConfig<br/>reads JSON config]
        RUN[RunTxs<br/>utils/run.go<br/>N worker goroutines]
    end

    subgraph "Client interface (utils/eth_client.go)"
        IF[Client interface]
        QN[QueryNonce<br/>PendingNonceAt]
        QCN[QueryCommittedNonce ★NEW<br/>NonceAt — mined only]
        SEND[SendEthereumTx]
        MULTI[SendMultipleEthereumTx<br/>batch RPC]
        CREATE[CreateContract]
        CODE[CodeAt]
        SIGN[SignTx ★NEW]
    end

    subgraph xlayer devnet
        RETH[reth EL<br/>:8123 JSON-RPC<br/>:8553 Engine API]
    end

    SH -->|erc20-init 0.2ETH -f config| CLI
    SH -->|erc20-bench -f config| CLI
    CLI --> INIT
    CLI --> BENCH
    INIT --> CFG
    BENCH --> CFG
    BENCH --> RUN
    INIT --> IF
    RUN --> IF
    IF --> QN
    IF --> QCN
    IF --> SEND
    IF --> MULTI
    IF --> CREATE
    IF --> CODE
    IF --> SIGN
    QN -->|eth_getTransactionCount pending| RETH
    QCN -->|eth_getTransactionCount latest| RETH
    SEND -->|eth_sendRawTransaction| RETH
    MULTI -->|batch eth_sendRawTransaction| RETH
    CREATE -->|eth_sendRawTransaction to=nil| RETH
    CODE -->|eth_getCode| RETH

    style QCN fill:#d4edda,stroke:#28a745
    style SIGN fill:#d4edda,stroke:#28a745
```

★ = added in this change

---

## 2. erc20-init flow — BEFORE the fix

The bug: batch txs were submitted without waiting for the previous one to be mined.
reth saw nonce N+1 while N was still in pending → moved N+1 to "queued" → it was **never executed**.

```mermaid
sequenceDiagram
    participant SH as bench-adventure.sh
    participant ADV as adventure<br/>erc20-init
    participant RETH as reth mempool

    SH->>ADV: erc20-init 1ETH -f config

    Note over ADV: Deploy BatchTransfer (nonce 0)
    ADV->>RETH: eth_sendRawTransaction nonce=0
    ADV->>RETH: eth_getCode (poll until deployed)

    Note over ADV: transfersNative loop — 10 batches (500 accounts / 50)
    ADV->>RETH: QueryNonce → PendingNonceAt → returns 1
    ADV->>RETH: sendTx nonce=1 (batch 0: accounts 0-49, 50 ETH)
    Note over RETH: nonce=1 in PENDING ✅
    ADV->>RETH: sendTx nonce=2 immediately (batch 1: accounts 50-99)
    Note over RETH: committed nonce still = 0<br/>nonce=2 arrives before nonce=1 mined<br/>→ goes to QUEUED ⚠️
    ADV->>RETH: sendTx nonce=3 immediately
    Note over RETH: nonce=3 → QUEUED ⚠️
    Note over RETH: ...all subsequent batches queued...

    Note over RETH: Block mined: nonce=1 confirmed ✅<br/>committed nonce = 1
    Note over RETH: Should promote nonce=2 from queued→pending<br/>❌ BUG: promotion logic broken<br/>nonce=2 stays in queued FOREVER

    Note over ADV,RETH: ❌ Only batch 0 (50 accounts) funded<br/>Remaining 450 accounts never funded<br/>Bench runs with starved accounts
```

---

## 3. erc20-init flow — AFTER the fix

The fix: wait for `QueryCommittedNonce` to confirm the tx was mined before sending the next nonce.
This guarantees strictly sequential, gapless nonce delivery to reth.

```mermaid
sequenceDiagram
    participant SH as bench-adventure.sh
    participant ADV as adventure<br/>erc20-init
    participant RETH as reth mempool

    SH->>ADV: erc20-init 0.2ETH -f config (concurrency=1)

    Note over ADV: Deploy BatchTransfer (nonce 0)
    ADV->>RETH: eth_sendRawTransaction nonce=0
    ADV->>RETH: eth_getCode (poll until deployed)

    Note over ADV: transfersNative loop — 200 batches (10k accounts / 50)

    ADV->>RETH: sendTx nonce=1 (batch 0: accounts 0-49)
    Note over RETH: nonce=1 → PENDING ✅
    loop Wait for confirmation (up to 30s)
        ADV->>RETH: QueryCommittedNonce → NonceAt latest
        RETH-->>ADV: committed = 0  (not yet)
        Note over ADV: sleep 1s...
        ADV->>RETH: QueryCommittedNonce
        RETH-->>ADV: committed = 1  ✅ mined!
    end
    Note over ADV: committed > nonce → break

    ADV->>RETH: sendTx nonce=2 (batch 1: accounts 50-99)
    Note over RETH: committed=1, nonce=2 arrives in order<br/>→ PENDING ✅ (no gap)
    loop Wait for confirmation
        ADV->>RETH: QueryCommittedNonce
        RETH-->>ADV: committed = 2  ✅
    end

    Note over ADV: ...repeat for all 200 batches...

    Note over ADV,RETH: ✅ All 10k accounts funded<br/>Every tx went to PENDING → mined immediately<br/>No tx ever touched QUEUED
```

---

## 4. The reth queued-promotion bug — illustrated

```mermaid
graph TD
    subgraph "BEFORE fix — concurrent submission"
        TX1A[nonce=1 sent] -->|arrives first| PEND1[PENDING ✅]
        TX2A[nonce=2 sent immediately] -->|arrives while nonce=1 not mined| QUEUE1[QUEUED ⚠️]
        TX3A[nonce=3 sent immediately] --> QUEUE2[QUEUED ⚠️]
        PEND1 -->|mined in block| COMMIT1[committed=1]
        COMMIT1 -->|should promote| QUEUE1
        QUEUE1 -->|❌ promotion broken| STUCK[STUCK FOREVER<br/>never executed]
        QUEUE2 --> STUCK
    end

    subgraph "AFTER fix — sequential with confirmation wait"
        TX1B[nonce=1 sent] --> PEND2[PENDING ✅]
        PEND2 -->|mined| COMMIT2[committed=1 confirmed]
        COMMIT2 -->|NOW send nonce=2| TX2B[nonce=2 sent]
        TX2B --> PEND3[PENDING ✅]
        PEND3 -->|mined| COMMIT3[committed=2 confirmed]
        COMMIT3 -->|NOW send nonce=3| TX3B[nonce=3 sent]
        TX3B --> PEND4[PENDING ✅]
    end

    style STUCK fill:#f8d7da,stroke:#dc3545
    style QUEUE1 fill:#fff3cd,stroke:#ffc107
    style QUEUE2 fill:#fff3cd,stroke:#ffc107
    style PEND2 fill:#d4edda,stroke:#28a745
    style PEND3 fill:#d4edda,stroke:#28a745
    style PEND4 fill:#d4edda,stroke:#28a745
    style COMMIT2 fill:#d4edda,stroke:#28a745
    style COMMIT3 fill:#d4edda,stroke:#28a745
```

---

## 5. erc20-bench flow (unchanged — no fix needed here)

During bench, each **account** sends from its own key. Workers cycle through accounts so fast
that any given account has at most 1 tx in flight at a time naturally.

```mermaid
graph TD
    subgraph "adventure erc20-bench (2 instances in parallel)"
        CFG[Load config<br/>accountsFilePath: accounts-10k-A.txt<br/>concurrency: 20]
        CFG --> POOL[Account pool<br/>10,000 private keys]
        POOL --> W1[Worker 1<br/>accounts 0-499]
        POOL --> W2[Worker 2<br/>accounts 500-999]
        POOL --> W3[Worker 3<br/>accounts 1000-1499]
        POOL --> WN[Worker 20<br/>accounts 9500-9999]

        W1 -->|cycle through 500 accounts| TX1["sign + send ERC20.transfer(recipient, 1)"]
        W2 --> TX2[sign + send ERC20.transfer]
        W3 --> TX3[sign + send ERC20.transfer]
        WN --> TXN[sign + send ERC20.transfer]
    end

    subgraph reth
        TX1 -->|PendingNonceAt per account| MP[mempool<br/>~10k live txs per instance]
        TX2 --> MP
        TX3 --> MP
        TXN --> MP
        MP -->|1s block| BLK[block<br/>~5700 txs at 200M gas]
    end

    style MP fill:#cce5ff,stroke:#004085
    style BLK fill:#d4edda,stroke:#28a745
```

---

## 6. QueryNonce vs QueryCommittedNonce — when each is used

```mermaid
graph LR
    subgraph "QueryNonce — PendingNonceAt"
        QN_USE["Used by:<br/>• erc20-bench workers<br/>• contract deployments<br/>• anywhere you want next available nonce"]
        QN_VAL["Returns: confirmed + pending txs<br/>e.g. committed=5, 3 txs pending → returns 8<br/>Correct for sequencing new txs"]
    end

    subgraph "QueryCommittedNonce ★NEW — NonceAt latest"
        QCN_USE["Used by:<br/>• transfersNative wait loop<br/>• transferERC20 wait loop<br/>ONLY during erc20-init"]
        QCN_VAL["Returns: mined txs only<br/>e.g. committed=5 means nonce=5 is next to mine<br/>Correct for confirming a tx was included in a block"]
    end

    style QCN_USE fill:#d4edda,stroke:#28a745
    style QCN_VAL fill:#d4edda,stroke:#28a745
```

---

## 7. What changed — diff summary for new devs

```
tools/adventure/utils/eth_client.go
  Client interface:
    + QueryCommittedNonce(hexAddr string) (uint64, error)
    + SignTx(privateKey, tx) (*Transaction, error)

  EthClient implementation:
    + func QueryCommittedNonce → e.NonceAt(ctx, addr, nil)   ← "nil" = latest block
    + func SignTx → types.SignTx(tx, e.signer, key)

tools/adventure/bench/erc20.go
  transfersNative() — after each batch tx send:
    + deployerAddr := GetEthAddressFromPK(privateKey)
    + for j := 0; j < 30; j++ {
    +     sleep(1s)
    +     committed = QueryCommittedNonce(deployerAddr)
    +     if committed > nonce { break }
    + }

  transferERC20() — same wait loop added (identical pattern)
```

**Nothing in the bench path (`Erc20Bench` / `RunTxs`) was changed.**
The fix is scoped entirely to the one-time init funding path.

---
