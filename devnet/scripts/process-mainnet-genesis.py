#!/usr/bin/env python3
"""
Process mainnet genesis.json for OP Stack deployment
- Updates block number, parentHash, and config fields
- Optionally injects test account balance
- Optimized for large files (6.6GB+)
"""

import json
import sys
import os
import time
from typing import Optional

def process_genesis(
    input_file: str,
    output_file: str,
    next_block: int,
    parent_hash: str,
    test_account: Optional[str] = None,
    test_balance: Optional[str] = None
) -> bool:
    """
    Process mainnet genesis file with minimal memory footprint
    
    Args:
        input_file: Path to source genesis.json
        output_file: Path to output genesis.json
        next_block: Next block number (FORK_BLOCK + 1)
        parent_hash: Parent block hash
        test_account: Optional test account address to inject
        test_balance: Optional balance for test account (hex)
    
    Returns:
        True if successful
    """
    print(f"📖 Loading genesis from {input_file}...")
    print(f"   File size: {os.path.getsize(input_file) / (1024**3):.2f} GB")
    
    try:
        with open(input_file, 'r') as f:
            genesis = json.load(f)
        
        print(f"✅ Loaded genesis with {len(genesis.get('alloc', {}))} accounts")
        
        # Update config fields
        print(f"🔧 Updating genesis configuration...")
        if 'config' not in genesis:
            genesis['config'] = {}
        
        genesis['config']['legacyXLayerBlock'] = next_block
        genesis['parentHash'] = parent_hash
        # NOTE: Keep number as 0 for geth init (geth doesn't support number > 0)
        # Reth version will have hex number, rollup.json will have the actual number
        genesis['number'] = 0
        
        # CRITICAL: Update timestamp to current time to avoid conductor "unsafe head falling behind" error
        current_timestamp = int(time.time())
        old_timestamp = genesis.get('timestamp', 0)
        genesis['timestamp'] = hex(current_timestamp)
        
        print(f"   ✓ legacyXLayerBlock: {next_block}")
        print(f"   ✓ number: 0 (required for geth init)")
        print(f"   ✓ parentHash: {parent_hash}")
        print(f"   ✓ timestamp: {hex(current_timestamp)} (updated from {hex(old_timestamp) if isinstance(old_timestamp, int) else old_timestamp})")
        
        # Inject test account if requested
        if test_account and test_balance:
            if 'alloc' not in genesis:
                genesis['alloc'] = {}
            
            account_key = test_account.lower()
            if account_key.startswith('0x'):
                account_key = account_key[2:]
            
            if account_key in genesis['alloc']:
                print(f"⚠️  Account {test_account} already exists, updating balance...")
                genesis['alloc'][account_key]['balance'] = test_balance
            else:
                print(f"💰 Injecting test account {test_account}...")
                genesis['alloc'][account_key] = {"balance": test_balance}
            
            # Convert balance to decimal for display
            balance_wei = int(test_balance, 16)
            balance_eth = balance_wei / (10**18)
            print(f"   ✓ Balance: {balance_eth:,.0f} ETH")
        
        # Write output
        print(f"💾 Writing to {output_file}...")
        with open(output_file, 'w') as f:
            # Use separators to minimize file size
            json.dump(genesis, f, separators=(',', ':'))
        
        output_size = os.path.getsize(output_file)
        print(f"✅ Successfully processed genesis ({output_size / (1024**3):.2f} GB)")
        
        return True
        
    except Exception as e:
        print(f"❌ ERROR: {e}", file=sys.stderr)
        return False

def create_reth_version(genesis_file: str, reth_file: str, next_block_hex: str) -> bool:
    """
    Create Reth-compatible genesis (number as hex string "0x0")
    
    Args:
        genesis_file: Source genesis.json
        reth_file: Output genesis-reth.json
        next_block_hex: Block number in hex format (should be "0x0" for init)
    
    Returns:
        True if successful
    """
    print(f"🔧 Creating Reth-compatible genesis...")
    
    try:
        with open(genesis_file, 'r') as f:
            genesis = json.load(f)
        
        # Reth expects number as hex string "0x0" for init
        genesis['number'] = "0x0"
        
        with open(reth_file, 'w') as f:
            json.dump(genesis, f, separators=(',', ':'))
        
        print(f"✅ Created {reth_file} (number: 0x0 for reth init)")
        return True
        
    except Exception as e:
        print(f"❌ ERROR creating Reth genesis: {e}", file=sys.stderr)
        return False

def main():
    if len(sys.argv) < 5:
        print("Usage: process-mainnet-genesis.py <input> <output> <next_block> <parent_hash> [test_account] [test_balance]")
        print("")
        print("Example:")
        print("  process-mainnet-genesis.py mainnet.genesis.json genesis.json 8593921 0x6912... 0x7099... 0x52B7...")
        sys.exit(1)
    
    input_file = sys.argv[1]
    output_file = sys.argv[2]
    next_block = int(sys.argv[3])
    parent_hash = sys.argv[4]
    test_account = sys.argv[5] if len(sys.argv) > 5 else None
    test_balance = sys.argv[6] if len(sys.argv) > 6 else None
    
    # Process main genesis
    success = process_genesis(
        input_file,
        output_file,
        next_block,
        parent_hash,
        test_account,
        test_balance
    )
    
    if not success:
        sys.exit(1)
    
    # Create Reth version (number must be "0x0" for init)
    reth_file = output_file.replace('.json', '-reth.json')
    
    if not create_reth_version(output_file, reth_file, "0x0"):
        sys.exit(1)
    
    print("")
    print("🎉 Genesis processing complete!")
    sys.exit(0)

if __name__ == '__main__':
    main()

