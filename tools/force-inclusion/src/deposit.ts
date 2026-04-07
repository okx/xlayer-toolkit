import { type Address, getAddress } from "viem";
import { getL2TransactionHashes } from "viem/op-stack";
import { l1PublicClient, l1WalletClient, l2PublicClient } from "./clients.js";
import { portalAddress } from "./config.js";

// OptimismPortal.depositTransaction — subset needed for force inclusion
export const portalAbi = [
  {
    type: "function",
    name: "depositTransaction",
    inputs: [
      { name: "_to", type: "address" },
      { name: "_value", type: "uint256" },
      { name: "_gasLimit", type: "uint64" },
      { name: "_isCreation", type: "bool" },
      { name: "_data", type: "bytes" },
    ],
    outputs: [],
    stateMutability: "payable",
  },
] as const;

interface DepositParams {
  to: Address;
  gasLimit: bigint;
  isCreation: boolean;
  data: `0x${string}`;
}

/**
 * Submit a deposit transaction on L1 and wait for L2 confirmation.
 * Returns the L2 transaction receipt.
 *
 * Calls Portal.depositTransaction directly (method B) because viem's
 * buildDepositTransaction doesn't support isCreation=true.
 * Using the same approach for all deposits keeps the code consistent.
 */
export async function submitDeposit(params: DepositParams) {
  const l1Hash = await l1WalletClient.writeContract({
    address: portalAddress,
    abi: portalAbi,
    functionName: "depositTransaction",
    args: [
      params.to,
      0n,              // _value (must be 0 in CGT mode)
      params.gasLimit,
      params.isCreation,
      params.data,
    ],
    value: 0n, // msg.value must be 0 in CGT mode
  });
  console.log(`  L1 tx: ${l1Hash}`);

  console.log("  Waiting for L1 confirmation...");
  const l1Receipt = await l1PublicClient.waitForTransactionReceipt({ hash: l1Hash });
  console.log(`  L1 confirmed in block ${l1Receipt.blockNumber}`);

  if (l1Receipt.status !== "success") {
    throw new Error(`Deposit tx reverted on L1: ${l1Hash}`);
  }

  const [l2Hash] = getL2TransactionHashes(l1Receipt);
  if (!l2Hash) {
    throw new Error("Could not extract L2 tx hash from L1 receipt");
  }
  console.log(`  L2 tx: ${l2Hash}`);

  console.log("  Waiting for L2 confirmation...");
  const startTime = Date.now();
  const l2Receipt = await l2PublicClient.waitForTransactionReceipt({
    hash: l2Hash,
    timeout: 5 * 60_000,
  });
  const elapsed = ((Date.now() - startTime) / 1000).toFixed(1);
  console.log(`  L2 confirmed in block ${l2Receipt.blockNumber} (${elapsed}s)`);

  if (l2Receipt.status !== "success") {
    throw new Error(`Deposit tx reverted on L2: ${l2Hash}`);
  }

  return { l1Hash, l1Receipt, l2Hash, l2Receipt, elapsed };
}

/**
 * Get the actual contract address from a deposit tx creation.
 * receipt.contractAddress is unreliable for deposit txs (nonce differs).
 */
export async function getCreationAddress(l2Hash: `0x${string}`): Promise<Address> {
  const trace = await l2PublicClient.request({
    method: "debug_traceTransaction" as never,
    params: [l2Hash, { tracer: "callTracer" }] as never,
  }) as { to?: string };

  if (!trace.to || typeof trace.to !== "string") {
    throw new Error("Could not determine contract address from trace");
  }

  return getAddress(trace.to);
}
