import "dotenv/config";
import { encodeFunctionData, formatEther } from "viem";
import {
  l1Account,
  l1PublicClient,
  l2PublicClient,
} from "./clients.js";
import { rollup, portalAddress } from "./config.js";
import { counterAbi, deployCounter, readCount } from "./counter.js";
import { submitDeposit } from "./deposit.js";

async function preflight() {
  const [l1Block, l2Block, l1Balance] = await Promise.all([
    l1PublicClient.getBlockNumber(),
    l2PublicClient.getBlockNumber(),
    l1PublicClient.getBalance({ address: l1Account.address }),
  ]);

  console.log(`L1=${rollup.l1_chain_id} L2=${rollup.l2_chain_id} portal=${portalAddress}`);
  console.log(`L1 account: ${l1Account.address}`);
  console.log(`L1 block:   ${l1Block}  L2 block: ${l2Block}`);
  console.log(`L1 balance: ${formatEther(l1Balance)} ETH`);

  if (l1Balance === 0n) {
    throw new Error("L1 account has no ETH — cannot pay for deposit tx gas");
  }
}

// CGT mode constraints:
//   depositTransaction() requires msg.value == 0 and _value == 0.
//   Deposit txs execute on L2 as system txs (zero gas price) — no OKB needed.
//   EOA callers: L2 msg.sender == L1 address (no aliasing).
async function forceIncludeIncrement(counterAddress: `0x${string}`) {
  const calldata = encodeFunctionData({
    abi: counterAbi,
    functionName: "increment",
  });

  console.log("\n=== Force Inclusion: Counter.increment() ===");
  console.log(`Counter:  ${counterAddress}`);

  const countBefore = await readCount(counterAddress);
  console.log(`Count before: ${countBefore}`);

  await submitDeposit({
    to: counterAddress,
    gasLimit: 100_000n,
    isCreation: false,
    data: calldata,
  });

  const countAfter = await readCount(counterAddress);
  console.log(`\nCount: ${countBefore} → ${countAfter}`);
  console.log("\n=== Force Inclusion Complete ===");
}

async function main() {
  await preflight();
  const counterAddress = await deployCounter();
  await forceIncludeIncrement(counterAddress);
}

main().catch((err) => {
  console.error("\nFatal error:", err);
  process.exit(1);
});
