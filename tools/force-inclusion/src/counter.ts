import type { Address } from "viem";
import { l2PublicClient } from "./clients.js";
import { loadArtifact } from "./artifacts.js";
import { submitDeposit, getCreationAddress } from "./deposit.js";

const { abi, bytecode } = loadArtifact("Counter");

export const counterAbi = abi;

export async function deployCounter(): Promise<Address> {
  console.log("[deploy] Deploying Counter to L2 via force inclusion...");

  const { l2Hash } = await submitDeposit({
    to: "0x0000000000000000000000000000000000000000",
    gasLimit: 500_000n,
    isCreation: true,
    data: bytecode,
  });

  const contractAddress = await getCreationAddress(l2Hash);
  console.log(`[deploy] Counter deployed at ${contractAddress}`);
  return contractAddress;
}

export async function readCount(address: Address): Promise<bigint> {
  const result = await l2PublicClient.readContract({
    address,
    abi,
    functionName: "count",
  });
  return result as bigint;
}
