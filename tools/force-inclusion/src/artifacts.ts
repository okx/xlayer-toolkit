import { readFileSync } from "node:fs";
import { join } from "node:path";

const ARTIFACTS_DIR = join(import.meta.dirname, "../contracts/out");

interface ForgeArtifact {
  abi: readonly Record<string, unknown>[];
  bytecode: { object: string };
}

/**
 * Load a forge compilation artifact by contract name.
 * E.g. loadArtifact("Counter") reads contracts/out/Counter.sol/Counter.json
 */
export function loadArtifact(contractName: string): {
  abi: ForgeArtifact["abi"];
  bytecode: `0x${string}`;
} {
  const path = join(ARTIFACTS_DIR, `${contractName}.sol`, `${contractName}.json`);

  let raw: string;
  try {
    raw = readFileSync(path, "utf-8");
  } catch {
    throw new Error(
      `Artifact not found: ${path}. Run "cd contracts && forge build" first.`
    );
  }

  const artifact: ForgeArtifact = JSON.parse(raw);
  const hex = artifact.bytecode.object;

  if (!hex || hex === "0x") {
    throw new Error(`Empty bytecode in artifact for ${contractName}`);
  }

  return {
    abi: artifact.abi,
    bytecode: (hex.startsWith("0x") ? hex : `0x${hex}`) as `0x${string}`,
  };
}
