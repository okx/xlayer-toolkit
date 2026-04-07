import { createPublicClient, createWalletClient, http } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { xlayerDevnetL1, xlayerDevnetL2 } from "./config.js";

function requireHexEnv(name: string): `0x${string}` {
  const value = process.env[name];
  if (!value) throw new Error(`${name} not set in .env`);
  if (!value.startsWith("0x")) throw new Error(`${name} must start with 0x`);
  return value as `0x${string}`;
}

export const l1Account = privateKeyToAccount(requireHexEnv("PRIVATE_KEY"));

export const l1PublicClient = createPublicClient({
  chain: xlayerDevnetL1,
  transport: http(),
});

export const l1WalletClient = createWalletClient({
  account: l1Account,
  chain: xlayerDevnetL1,
  transport: http(),
});

export const l2PublicClient = createPublicClient({
  chain: xlayerDevnetL2,
  transport: http(),
});
