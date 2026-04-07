/**
 * Attempt to force include an OKB transfer on L2 via L1 deposit.
 *
 * This WILL FAIL on XLayer devnet because of CGT mode constraints:
 *   - Portal enforces msg.value == 0 (CGT mode)
 *   - Portal enforces msg.value == _value (InsufficientDeposit)
 *   - Therefore _value must be 0 — no native token transfers allowed
 *
 * The upstream OP Stack (ethereum-optimism) removed the msg.value == _value
 * check, which would allow _value > 0 with msg.value == 0 (spending existing
 * L2 balance). The okx fork re-added this check in commit d0cb1130d8.
 *
 * Run: npx tsx src/send-transfer.ts
 */
import "./env.js";
import { formatEther, parseEther } from "viem";
import { l1Account, l1PublicClient, l1WalletClient, l2PublicClient } from "./clients.js";
import { portalAddress } from "./config.js";
import { portalAbi } from "./deposit.js";

const RECIPIENT = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8";
const AMOUNT = parseEther("1"); // 1 OKB

async function main() {
  console.log("=== Force Inclusion: OKB Transfer (expected to fail) ===\n");

  const [l2BalanceBefore, l1Balance] = await Promise.all([
    l2PublicClient.getBalance({ address: RECIPIENT }),
    l1PublicClient.getBalance({ address: l1Account.address }),
  ]);
  console.log(`L1 account:  ${l1Account.address}`);
  console.log(`L1 balance:  ${formatEther(l1Balance)} ETH`);
  console.log(`Recipient:   ${RECIPIENT}`);
  console.log(`L2 balance:  ${formatEther(l2BalanceBefore)} OKB`);
  console.log(`Amount:      ${formatEther(AMOUNT)} OKB\n`);

  // Attempt 1: _value > 0, msg.value = 0
  // Expected: revert OptimismPortal_InsufficientDeposit (msg.value != _value)
  console.log("[Attempt 1] _value=1 OKB, msg.value=0 (CGT compliant, but fails InsufficientDeposit check)");
  try {
    await l1WalletClient.writeContract({
      address: portalAddress,
      abi: portalAbi,
      functionName: "depositTransaction",
      args: [RECIPIENT, AMOUNT, 21_000n, false, "0x"],
      value: 0n,
    });
    console.log("  Unexpected success!");
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    if (msg.includes("0xacb9c385")) {
      console.log("  Reverted: OptimismPortal_InsufficientDeposit (msg.value != _value)");
    } else {
      console.log(`  Reverted: ${msg.slice(0, 200)}`);
    }
  }

  // Attempt 2: _value > 0, msg.value > 0
  // Expected: revert OptimismPortal_NotAllowedOnCGTMode (msg.value > 0 in CGT)
  console.log("\n[Attempt 2] _value=1 OKB, msg.value=1 ETH (violates CGT mode)");
  try {
    await l1WalletClient.writeContract({
      address: portalAddress,
      abi: portalAbi,
      functionName: "depositTransaction",
      args: [RECIPIENT, AMOUNT, 21_000n, false, "0x"],
      value: AMOUNT,
    });
    console.log("  Unexpected success!");
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    if (msg.includes("0xbd58e0a2")) {
      console.log("  Reverted: OptimismPortal_NotAllowedOnCGTMode (msg.value > 0)");
    } else {
      console.log(`  Reverted: ${msg.slice(0, 200)}`);
    }
  }

  console.log("\n=== Conclusion ===");
  console.log("Native OKB transfers via depositTransaction are blocked in CGT mode.");
  console.log("The okx fork enforces msg.value == _value, making _value > 0 impossible");
  console.log("when msg.value must be 0. Upstream OP Stack removed this check.");
  console.log("To transfer OKB via force inclusion, use depositERC20Transaction instead");
  console.log("(requires L1 OKB tokens + approval to Portal).");
}

main().catch((err) => {
  console.error("\nFatal error:", err);
  process.exit(1);
});
