make build-op PROFILE=release

rm -rf ./op_reth_data

./target/release/op-reth init \
  --datadir ./op_reth_data \
  --chain ../optimism/build/genesis.json

./target/release/op-reth node \
  --datadir ./.op-reth \
  --chain ../optimism/build/genesis.json \
  --full \
  --http \
  --http.addr=0.0.0.0 \
  --http.port=7547 \
  --http.api web3,debug,eth,txpool,net \
  --http.corsdomain "*" \
  --ws \
  --ws.addr=0.0.0.0 \
  --ws.port=7546 \
  --ws.api debug,eth,txpool,net \
  --ws.origins "*" \
  --authrpc.addr 0.0.0.0 \
  --authrpc.port 8552 \
  --authrpc.jwtsecret /tmp/jwt.txt \
  --txpool.pending-max-count 800000 \
  --txpool.pending-max-size 4096 \
  --txpool.queued-max-count 800000 \
  --txpool.queued-max-size 4096 \
  --txpool.max-account-slots 1024 \
  --discovery.v5.port 9207 \
  --ipcpath /Users/yangweitao/meili/cliff.yang_dacs_at_okg.com/117/Documents/reth.ipc \
  --log.file.directory ./logs/reth > op-reth.log 2>&1



cast wallet derive-private-key \
  --mnemonic-path ./mnemonic.txt \
  --mnemonic-index 0

{
    "address": "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
    "privateKey": "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
},
{
    "address": "0x70997970C51812dc3A010C7d01b50e0d17dc79C8",
    "privateKey": "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"
}

export RPC_URL=localhost:8545
cast balance 0x70997970C51812dc3A010C7d01b50e0d17dc79C8 --rpc-url $RPC_URL

cast send 0x70997970C51812dc3A010C7d01b50e0d17dc79C8 \
  --value 0.02ether \
  --rpc-url $RPC_URL \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
  --priority-gas-price 2gwei \
  --gas-price 50gwei

  cast balance 