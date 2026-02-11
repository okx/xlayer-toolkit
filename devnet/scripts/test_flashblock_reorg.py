#!/usr/bin/env python3
"""
Test script to verify flashblock transactions are preserved across sequencer/builder changes.

This script monitors flashblocks via WebSocket and verifies that all flashblock transactions
(index > 0) eventually appear in canonical blocks, even after a sequencer/builder switch.

Usage:
    python test_flashblock_reorg_mitigation.py [--ws-url URL] [--rpc-url URL] [--duration SECONDS] [--verbose]

Example:
    python test_flashblock_reorg_mitigation.py --ws-url ws://localhost:11111 --rpc-url http://localhost:8124
"""

import argparse
import asyncio
import json
import signal
import sys
import time
from dataclasses import dataclass, field
from enum import Enum
from typing import Dict, List, Optional, Set
from urllib.error import URLError
from urllib.request import Request, urlopen

try:
    from websockets import connect
    from websockets.exceptions import ConnectionClosed, WebSocketException
except ImportError:
    print("Error: websockets library not installed. Run: pip install websockets")
    sys.exit(1)

try:
    import rlp
    HAS_RLP = True
except ImportError:
    HAS_RLP = False



def _get_keccak256_impl():
    """Find and return a keccak256 implementation."""
    # Try pycryptodome
    try:
        from Crypto.Hash import keccak
        def _keccak256(data: bytes) -> bytes:
            k = keccak.new(digest_bits=256)
            k.update(data)
            return k.digest()
        return _keccak256
    except ImportError:
        pass

    # Try eth-hash
    try:
        from eth_hash.auto import keccak as eth_keccak
        def _keccak256(data: bytes) -> bytes:
            return eth_keccak(data)
        return _keccak256
    except ImportError:
        pass

    # Try pysha3
    try:
        import sha3
        def _keccak256(data: bytes) -> bytes:
            k = sha3.keccak_256()
            k.update(data)
            return k.digest()
        return _keccak256
    except ImportError:
        pass

    # No implementation found
    return None


# Initialize keccak256 at module load time
_keccak256_impl = _get_keccak256_impl()

if _keccak256_impl is None:
    print("=" * 60)
    print("ERROR: No keccak256 implementation found!")
    print("=" * 60)
    print("Ethereum uses keccak256 (NOT sha3-256) to hash transactions.")
    print("Please install one of the following:")
    print()
    print("  pip install pycryptodome")
    print("  pip install eth-hash[pycryptodome]")
    print("  pip install pysha3")
    print()
    print("=" * 60)
    sys.exit(1)


def keccak256(data: bytes) -> bytes:
    """Compute keccak256 hash."""
    return _keccak256_impl(data)


_decode_error_logged = False

def decode_tx_hash(raw_tx_hex: str) -> Optional[str]:
    """Decode transaction hash from RLP-encoded hex string."""
    global _decode_error_logged
    try:
        # Remove 0x prefix if present
        if raw_tx_hex.startswith("0x"):
            raw_tx_hex = raw_tx_hex[2:]

        raw_bytes = bytes.fromhex(raw_tx_hex)

        # Transaction hash is keccak256 of the RLP-encoded transaction
        tx_hash = keccak256(raw_bytes)
        return "0x" + tx_hash.hex()
    except Exception as e:
        if not _decode_error_logged:
            print(f"\nWARNING: Transaction decode failed: {type(e).__name__}: {e}")
            print(f"  Raw tx (first 100 chars): {raw_tx_hex[:100]}...")
            print("  Make sure pycryptodome is installed: pip install pycryptodome\n")
            _decode_error_logged = True
        return None


class TxStatus(Enum):
    PENDING = "pending"
    CONFIRMED = "confirmed"
    MISSING = "missing"


@dataclass
class TrackedTransaction:
    tx_hash: str
    parent_hash: str
    flashblock_index: int
    block_number: int  # Expected block number
    first_seen_at: float
    status: TxStatus = TxStatus.PENDING

    def __hash__(self):
        return hash(self.tx_hash)


@dataclass
class BlockTracker:
    """Tracks flashblock transactions and canonical block confirmations."""

    # All tracked transactions: tx_hash -> TrackedTransaction
    transactions: Dict[str, TrackedTransaction] = field(default_factory=dict)

    # Transactions grouped by expected block number: block_number -> set of tx_hashes
    txs_by_block: Dict[int, Set[str]] = field(default_factory=dict)

    # Canonical blocks we've seen: block_number -> set of tx_hashes in that block
    canonical_blocks: Dict[int, Set[str]] = field(default_factory=dict)

    # Latest canonical block number
    latest_canonical_block: int = 0

    # Statistics
    total_flashblocks_received: int = 0
    total_txs_tracked: int = 0
    total_confirmed: int = 0
    total_missing: int = 0
    total_reorg_count: int = 0

    # Track reconnections
    reconnection_count: int = 0

    # Blocks to finalize after N confirmations
    blocks_to_confirm_after: int = 2


class ReorgDetectedException(Exception):
    """Raised when flashblock transactions are missing from canonical chain."""
    pass

class FlashblockReorgTester:
    def __init__(
        self,
        ws_urls: List[str],
        rpc_url: str,
        duration: Optional[int] = None,
        verbose: bool = False,
    ):
        self.ws_urls = ws_urls
        self.rpc_url = rpc_url
        self.duration = duration
        self.verbose = verbose
        self.tracker = BlockTracker()
        self.running = True
        self.start_time = None

        # Current pending block info from flashblocks
        self.current_parent_hash: Optional[str] = None
        self.current_block_number: Optional[int] = None
        self.current_payload_id: Optional[str] = None

    def log(self, message: str, force: bool = False):
        """Log message if verbose mode or forced."""
        if self.verbose or force:
            timestamp = time.strftime("%H:%M:%S")
            print(f"[{timestamp}] {message}")

    def log_always(self, message: str):
        """Always log this message."""
        self.log(message, force=True)

    def get_block_from_rpc(self, block_id: str = "latest") -> Optional[dict]:
        """Fetch block from RPC endpoint."""
        try:
            payload = {
                "jsonrpc": "2.0",
                "id": 1,
                "method": "eth_getBlockByNumber",
                "params": [block_id, True],  # True = include full tx objects
            }
            req = Request(
                self.rpc_url,
                data=json.dumps(payload).encode("utf-8"),
                headers={"Content-Type": "application/json"},
            )
            with urlopen(req, timeout=10) as response:
                data = json.loads(response.read().decode("utf-8"))
                return data.get("result")
        except (URLError, Exception) as e:
            self.log(f"RPC Error: {e}")
            return None

    def process_flashblock_payload(self, payload: dict, source_url: str = "unknown"):
        """Process a flashblock payload and track transactions."""
        try:
            payload_id = payload.get("payload_id")
            index = payload.get("index", 0)
            base = payload.get("base", {})
            diff = payload.get("diff", {})
            metadata = payload.get("metadata", {})

            # Get transactions from diff (RLP-encoded hex strings)
            raw_transactions = diff.get("transactions", [])

            self.tracker.total_flashblocks_received += 1

            # For index 0, extract parent_hash and block_number from base
            if index == 0 and base:
                self.current_parent_hash = base.get("parent_hash")
                block_number_hex = base.get("block_number", "0x0")
                self.current_block_number = int(block_number_hex, 16)
                self.current_payload_id = payload_id
                self.log(
                    f"[{source_url}] New pending block #{self.current_block_number} "
                    f"(parent: {self.current_parent_hash[:16]}..., payload_id: {payload_id})"
                )

            # Also check metadata for block_number (more reliable for index > 0)
            if metadata.get("block_number"):
                self.current_block_number = metadata["block_number"]

            # If we don't have block context yet, skip
            if self.current_block_number is None or self.current_parent_hash is None:
                self.log(f"Flashblock index={index} received but no block context yet")
                return

            block_number = self.current_block_number
            parent_hash = self.current_parent_hash

            # Skip index 0 (sequencer transactions - these are deterministic)
            if index == 0:
                self.log(
                    f"[{source_url}] Flashblock idx=0 for block #{block_number}: "
                    f"{len(raw_transactions)} sequencer txs (not tracking)"
                )
                return

            # Decode transaction hashes from RLP
            now = time.time()
            new_txs = 0
            decode_failures = 0

            for raw_tx in raw_transactions:
                tx_hash = decode_tx_hash(raw_tx)
                if not tx_hash:
                    decode_failures += 1
                    continue

                if tx_hash not in self.tracker.transactions:
                    tracked_tx = TrackedTransaction(
                        tx_hash=tx_hash,
                        parent_hash=parent_hash,
                        flashblock_index=index,
                        block_number=block_number,
                        first_seen_at=now,
                    )
                    self.tracker.transactions[tx_hash] = tracked_tx

                    if block_number not in self.tracker.txs_by_block:
                        self.tracker.txs_by_block[block_number] = set()
                    self.tracker.txs_by_block[block_number].add(tx_hash)

                    self.tracker.total_txs_tracked += 1
                    new_txs += 1

            msg = (
                f"[{source_url}] Flashblock idx={index} for block #{block_number}: "
                f"{len(raw_transactions)} txs ({new_txs} new tracked)"
            )
            if decode_failures:
                msg += f", {decode_failures} decode failures"
            self.log(msg)

            if new_txs > 0:
                self.log(
                    f"Block #{block_number} idx={index}: +{new_txs} txs tracked "
                    f"(total: {len(self.tracker.txs_by_block.get(block_number, set()))})"
                )

        except Exception as e:
            self.log(f"Error processing flashblock: {e}")
            import traceback
            self.log(traceback.format_exc())

    def check_canonical_block(self, block: dict):
        """Check a canonical block and update transaction statuses."""
        try:
            block_number = int(block.get("number", "0x0"), 16)
            block_hash = block.get("hash", "unknown")
            transactions = block.get("transactions", [])

            # Get tx hashes from canonical block
            canonical_tx_hashes = set()
            for tx in transactions:
                if isinstance(tx, str):
                    canonical_tx_hashes.add(tx)
                elif isinstance(tx, dict):
                    canonical_tx_hashes.add(tx.get("hash", ""))

            self.tracker.canonical_blocks[block_number] = canonical_tx_hashes

            if block_number > self.tracker.latest_canonical_block:
                self.tracker.latest_canonical_block = block_number
                tracked_for_block = len(self.tracker.txs_by_block.get(block_number, set()))

            # Check if we can finalize any older blocks
            self._finalize_old_blocks()

        except Exception as e:
            self.log(f"Error checking canonical block: {e}")

    def _finalize_old_blocks(self):
        """Mark transactions as confirmed or missing for blocks that are finalized."""
        finalization_threshold = (
            self.tracker.latest_canonical_block - self.tracker.blocks_to_confirm_after
        )

        blocks_to_check = [
            bn for bn in list(self.tracker.txs_by_block.keys())
            if bn <= finalization_threshold
        ]

        for block_number in blocks_to_check:
            if block_number not in self.tracker.canonical_blocks:
                # Canonical block not yet fetched, try to get it
                block = self.get_block_from_rpc(hex(block_number))
                if block:
                    self.check_canonical_block(block)
                else:
                    continue

            canonical_txs = self.tracker.canonical_blocks.get(block_number, set())
            flashblock_txs = self.tracker.txs_by_block.get(block_number, set())

            confirmed = 0
            missing = 0
            missing_hashes = []

            for tx_hash in flashblock_txs:
                tracked_tx = self.tracker.transactions.get(tx_hash)
                if not tracked_tx or tracked_tx.status != TxStatus.PENDING:
                    continue

                if tx_hash in canonical_txs:
                    tracked_tx.status = TxStatus.CONFIRMED
                    self.tracker.total_confirmed += 1
                    confirmed += 1
                else:
                    tracked_tx.status = TxStatus.MISSING
                    self.tracker.total_missing += 1
                    missing += 1
                    missing_hashes.append(tx_hash)

            if confirmed > 0 or missing > 0:
                self.log_always(
                    f"Block #{block_number}:"
                    f"{confirmed} CONFIRMED, {missing} MISSING"
                )

            if missing > 0:
                self.log_always(f"\n{'='*60}")
                self.log_always(f"!!! REORG DETECTED - Block #{block_number} !!!")
                self.log_always(f"{'='*60}")
                self.tracker.total_reorg_count += 1
                self.log_always(f"Reorg Count: {self.tracker.total_reorg_count}")

                # Print one confirmed transaction as example
                self.log_always(f"\nCONFIRMED TRANSACTION (example):")
                self.log_always("-" * 40)
                confirmed_example_printed = False
                for tx_hash in flashblock_txs:
                    if tx_hash in canonical_txs and not confirmed_example_printed:
                        tracked = self.tracker.transactions.get(tx_hash)
                        idx = tracked.flashblock_index if tracked else "unknown"
                        self.log_always(f"  [confirmed] {tx_hash}  (flashblock idx={idx})")
                        confirmed_example_printed = True
                        break

                if not confirmed_example_printed:
                    self.log_always(f"  (no confirmed transactions)")

                self.log_always(f"\nMISSING TRANSACTIONS ({len(missing_hashes)} total):")
                self.log_always("-" * 40)
                # Group by flashblock index
                missing_by_index = {}
                for tx_hash in missing_hashes:
                    tracked = self.tracker.transactions.get(tx_hash)
                    if tracked:
                        idx = tracked.flashblock_index
                        if idx not in missing_by_index:
                            missing_by_index[idx] = []
                        missing_by_index[idx].append(tx_hash)

                for idx in sorted(missing_by_index.keys()):
                    self.log_always(f"\n  Flashblock index {idx} ({len(missing_by_index[idx])} txs):")
                    for tx_hash in missing_by_index[idx]:
                        self.log_always(f"    [MISSING] {tx_hash}")
                        break

                # Summary
                self.log_always(f"\n{'='*60}")
                self.log_always(f"SUMMARY:")
                self.log_always(f"  Flashblock txs: {len(flashblock_txs)}")
                self.log_always(f"  Canonical txs:  {len(canonical_txs)}")
                self.log_always(f"  Confirmed:      {confirmed}")
                self.log_always(f"  MISSING:        {missing}")
                self.log_always(f"{'='*60}\n")

            # Clean up finalized block from tracking
            if block_number in self.tracker.txs_by_block:
                del self.tracker.txs_by_block[block_number]

    async def poll_canonical_blocks(self):
        """Periodically poll RPC for new canonical blocks."""
        last_block = 0

        while self.running:
            try:
                block = self.get_block_from_rpc("latest")
                if block:
                    block_number = int(block.get("number", "0x0"), 16)
                    if block_number > last_block:
                        self.check_canonical_block(block)
                        last_block = block_number
            except ReorgDetectedException:
                # Reorg detected, stop immediately
                raise
            except Exception as e:
                self.log(f"Error polling canonical blocks: {e}")

            await asyncio.sleep(1.5)

    async def subscribe_flashblocks_single(self, ws_url: str):
        """Subscribe to a single flashblocks WebSocket and process messages."""
        reconnect_delay = 1
        max_reconnect_delay = 30

        while self.running:
            try:
                self.log_always(f"Connecting to WebSocket: {ws_url}")

                async with connect(ws_url, ping_interval=20, ping_timeout=30, max_size=10 * 1024 * 1024) as ws:  # 10MB limit
                    self.log_always(f"Connected to flashblocks WebSocket: {ws_url}")
                    reconnect_delay = 1  # Reset on successful connection

                    async for message in ws:
                        if not self.running:
                            break

                        try:
                            data = json.loads(message)

                            # Direct flashblock payload format (not JSON-RPC wrapped)
                            # Has payload_id, index, base (for index 0), diff
                            if "payload_id" in data and "diff" in data:
                                self.process_flashblock_payload(data, source_url=ws_url)
                            # JSON-RPC subscription format (fallback)
                            elif "params" in data and "result" in data["params"]:
                                result = data["params"]["result"]
                                if isinstance(result, dict):
                                    self.process_flashblock_payload(result, source_url=ws_url)

                        except json.JSONDecodeError:
                            self.log(f"Failed to parse WebSocket message from {ws_url}")
                        except Exception as e:
                            self.log(f"Error processing message from {ws_url}: {e}")

            except ConnectionClosed as e:
                self.tracker.reconnection_count += 1
                self.log_always(
                    f"WebSocket {ws_url} closed: {e}. "
                    f"Reconnecting in {reconnect_delay}s... "
                    f"(reconnection #{self.tracker.reconnection_count})"
                )
            except WebSocketException as e:
                self.tracker.reconnection_count += 1
                self.log_always(
                    f"WebSocket {ws_url} error: {e}. "
                    f"Reconnecting in {reconnect_delay}s..."
                )
            except Exception as e:
                self.log_always(f"WebSocket {ws_url} unexpected error: {e}. Reconnecting in {reconnect_delay}s...")

            if self.running:
                await asyncio.sleep(reconnect_delay)
                reconnect_delay = min(reconnect_delay * 2, max_reconnect_delay)

    def print_summary(self):
        """Print final test summary."""
        duration = time.time() - self.start_time if self.start_time else 0

        print("\n" + "=" * 60)
        print("FLASHBLOCK REORG MITIGATION TEST SUMMARY")
        print("=" * 60)
        print(f"Duration: {duration:.1f} seconds")
        print(f"WebSocket URLs: {', '.join(self.ws_urls)}")
        print(f"RPC URL: {self.rpc_url}")
        print(f"Reconnections: {self.tracker.reconnection_count}")
        print()
        print("Transaction Statistics:")
        print(f"  Total flashblocks received: {self.tracker.total_flashblocks_received}")
        print(f"  Total transactions tracked (index > 0): {self.tracker.total_txs_tracked}")
        print(f"  Confirmed in canonical blocks: {self.tracker.total_confirmed}")
        print(f"  MISSING (reorged): {self.tracker.total_missing}")

        if self.tracker.total_txs_tracked > 0:
            confirmation_rate = (
                self.tracker.total_confirmed / self.tracker.total_txs_tracked * 100
            )
            print(f"  Confirmation rate: {confirmation_rate:.2f}%")

        # Count still pending
        pending = sum(
            1 for tx in self.tracker.transactions.values()
            if tx.status == TxStatus.PENDING
        )
        if pending > 0:
            print(f"  Still pending (not finalized): {pending}")

        print()
        if self.tracker.total_missing == 0 and self.tracker.total_txs_tracked > 0:
            print("RESULT: PASS - No flashblock reorgs detected")
        elif self.tracker.total_txs_tracked == 0:
            print("RESULT: INCONCLUSIVE - No transactions were tracked")
        else:
            print(f"RESULT: FAIL - {self.tracker.total_missing} transactions were reorged!")
            print(f"{self.tracker.total_reorg_count} reorgs detected!")
        print("=" * 60)

    async def run(self):
        """Run the test."""
        self.start_time = time.time()

        print("=" * 60)
        print("FLASHBLOCK REORG MITIGATION TEST")
        print("=" * 60)
        print(f"WebSocket URLs: {', '.join(self.ws_urls)}")
        print(f"RPC URL: {self.rpc_url}")
        print(f"Duration: {'unlimited' if self.duration is None else f'{self.duration}s'}")
        print(f"Verbose: {self.verbose}")
        print()
        print("Instructions:")
        print("1. Wait for flashblocks to start arriving")
        print("2. Manually trigger sequencer/builder switch")
        print("3. Observe if any transactions go missing")
        print("4. Press Ctrl+C to stop and see summary")
        print("=" * 60)
        print()

        # Create tasks - one subscriber per WebSocket URL
        tasks = [
            asyncio.create_task(self.subscribe_flashblocks_single(url))
            for url in self.ws_urls
        ]
        tasks.append(asyncio.create_task(self.poll_canonical_blocks()))

        # Add duration limit if specified
        if self.duration:
            async def duration_limit():
                await asyncio.sleep(self.duration)
                self.running = False
                self.log_always(f"Duration limit ({self.duration}s) reached, stopping...")
            tasks.append(asyncio.create_task(duration_limit()))

        try:
            await asyncio.gather(*tasks)
        except ReorgDetectedException as e:
            self.log_always(f"\nStopping due to reorg detection: {e}")
        except asyncio.CancelledError:
            pass
        finally:
            self.running = False
            self.print_summary()


def main():
    parser = argparse.ArgumentParser(
        description="Test flashblock reorg mitigation across sequencer/builder changes"
    )
    parser.add_argument(
        "--ws-url",
        nargs="+",
        default=["ws://localhost:11111", "ws://localhost:11112"],
        help="Flashblocks WebSocket URLs (default: ws://localhost:11111 ws://localhost:11112)",
    )
    parser.add_argument(
        "--rpc-url",
        default="http://localhost:8124",
        help="Ethereum RPC URL (default: http://localhost:8124)",
    )
    parser.add_argument(
        "--duration",
        type=int,
        default=None,
        help="Test duration in seconds (default: run until Ctrl+C)",
    )
    parser.add_argument(
        "--verbose",
        "-v",
        action="store_true",
        help="Enable verbose logging",
    )

    args = parser.parse_args()

    tester = FlashblockReorgTester(
        ws_urls=args.ws_url,
        rpc_url=args.rpc_url,
        duration=args.duration,
        verbose=args.verbose,
    )

    # Handle graceful shutdown
    def signal_handler(sig, frame):
        print("\n\nReceived interrupt signal, shutting down...")
        tester.running = False

    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)

    try:
        asyncio.run(tester.run())
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()