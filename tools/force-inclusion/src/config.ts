import { readFileSync } from "node:fs";
import { join } from "node:path";
import { defineChain, getAddress } from "viem";

// Default: relative to this file's location within xlayer-toolkit
const ROLLUP_JSON_PATH =
  process.env.ROLLUP_JSON_PATH ??
  join(import.meta.dirname, "../../../devnet/config-op/rollup.json");

interface RollupConfig {
  l1_chain_id: number;
  l2_chain_id: number;
  deposit_contract_address: string;
}

function loadRollupConfig(): RollupConfig {
  let raw: string;
  try {
    raw = readFileSync(ROLLUP_JSON_PATH, "utf-8");
  } catch (err) {
    throw new Error(`Failed to read rollup config at ${ROLLUP_JSON_PATH}: ${err}`);
  }

  const parsed: unknown = JSON.parse(raw);
  if (
    typeof parsed !== "object" ||
    parsed === null ||
    typeof (parsed as Record<string, unknown>).l1_chain_id !== "number" ||
    typeof (parsed as Record<string, unknown>).l2_chain_id !== "number" ||
    typeof (parsed as Record<string, unknown>).deposit_contract_address !== "string"
  ) {
    throw new Error(`Invalid rollup config: missing required fields in ${ROLLUP_JSON_PATH}`);
  }

  return parsed as RollupConfig;
}

const rollup = loadRollupConfig();
// getAddress validates and checksums — will throw on malformed addresses
const portalAddress = getAddress(rollup.deposit_contract_address);

export const xlayerDevnetL1 = defineChain({
  id: rollup.l1_chain_id,
  name: "XLayer Devnet L1",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: {
    default: { http: [process.env.L1_RPC_URL ?? "http://localhost:8545"] },
  },
});

export const xlayerDevnetL2 = defineChain({
  id: rollup.l2_chain_id,
  name: "XLayer Devnet L2",
  nativeCurrency: { name: "OKB", symbol: "OKB", decimals: 18 },
  rpcUrls: {
    default: { http: [process.env.L2_RPC_URL ?? "http://localhost:8123"] },
  },
  sourceId: rollup.l1_chain_id,
  contracts: {
    portal: {
      [rollup.l1_chain_id]: {
        address: portalAddress,
      },
    },
  },
});

export { portalAddress, rollup };
