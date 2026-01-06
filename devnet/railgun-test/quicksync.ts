/**
 * RAILGUN QuickSync Implementation for Subgraph
 * 
 * This module provides QuickSync functionality to rapidly fetch
 * commitment and nullifier events from the RAILGUN Subgraph.
 */

import { 
  TXIDVersion, 
  Chain, 
  AccumulatedEvents, 
  CommitmentEvent, 
  Nullifier, 
  UnshieldStoredEvent,
  ByteUtils,
  ByteLength,
  serializePreImage,
  serializeTokenData,
  TokenType,
  CommitmentType,
} from '@railgun-community/engine';
import fetch from 'node-fetch';

const SUBGRAPH_URL = process.env.SUBGRAPH_URL || 'http://railgun-graph-node:8000/subgraphs/name/railgun-xlayer-devnet';

interface SubgraphCommitment {
  id: string;
  blockNumber: string;
  blockTimestamp: string;
  transactionHash: string;
  treeNumber: number;
  commitmentType: string;
  hashes: string[];
}

interface SubgraphNullifier {
  id: string;
  blockNumber: string;
  treeNumber: number;
  nullifier: string;
}

interface SubgraphUnshield {
  id: string;
  blockNumber: string;
  blockTimestamp: string;
  transactionHash: string;
  to: string;
  token: {
    tokenType: string;
    tokenAddress: string;
    tokenSubID: string;
  };
  value: string;
  fee: string;
  transactIndex: number;
}

/**
 * Query RAILGUN Subgraph for events since a starting block
 * Note: V2 and V3 have different schemas
 */
async function querySubgraphEvents(startingBlock: number): Promise<{
  commitments: SubgraphCommitment[];
  nullifiers: SubgraphNullifier[];
  unshields: SubgraphUnshield[];
}> {
  // V2 Subgraph query (uses ShieldCommitment, TransactCommitment, etc.)
  // IMPORTANT: Must include preimage, encryptedBundle, and shieldKey for SDK to decrypt
  const query = `
    query GetEvents($startBlock: BigInt!) {
      shieldCommitments(
        where: { blockNumber_gte: $startBlock }
        orderBy: blockNumber
        orderDirection: asc
        first: 1000
      ) {
        id
        blockNumber
        blockTimestamp
        transactionHash
        treeNumber
        treePosition
        commitmentType
        hash
        preimage {
          npk
          token {
            tokenType
            tokenAddress
            tokenSubID
          }
          value
        }
        encryptedBundle
        shieldKey
      }
      
      nullifiers(
        where: { blockNumber_gte: $startBlock }
        orderBy: blockNumber
        orderDirection: asc
        first: 1000
      ) {
        id
        blockNumber
        treeNumber
        nullifier
      }
      
      unshields(
        where: { blockNumber_gte: $startBlock }
        orderBy: blockNumber
        orderDirection: asc
        first: 1000
      ) {
        id
        blockNumber
        blockTimestamp
        transactionHash
        to
        token {
          tokenType
          tokenAddress
          tokenSubID
        }
        amount
        fee
      }
    }
  `;

  console.log(`   📡 Querying Subgraph from block ${startingBlock}...`);
  console.log(`   URL: ${SUBGRAPH_URL}`);

  const response = await fetch(SUBGRAPH_URL, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      query,
      variables: {
        startBlock: startingBlock.toString(),
      },
    }),
  });

  if (!response.ok) {
    throw new Error(`Subgraph query failed: ${response.status} ${response.statusText}`);
  }

  const result = await response.json();

  if (result.errors) {
    console.error('   ❌ Subgraph errors:', JSON.stringify(result.errors, null, 2));
    throw new Error(`Subgraph query errors: ${JSON.stringify(result.errors)}`);
  }

  const data = result.data;
  
  // V2 returns shieldCommitments and transactCommitments separately
  // For now, only use shieldCommitments (simpler schema)
  const allCommitments = [
    ...(data.shieldCommitments || []),
    // TODO: Add transactCommitments support when needed
  ];
  
  console.log(`   ✓ Received: ${allCommitments.length} shield commitments, ${data.nullifiers?.length || 0} nullifiers, ${data.unshields?.length || 0} unshields`);

  return {
    commitments: allCommitments,
    nullifiers: data.nullifiers || [],
    unshields: data.unshields || [],
  };
}

/**
 * Convert Subgraph data to RAILGUN SDK format
 */
function convertToAccumulatedEvents(
  txidVersion: TXIDVersion,
  subgraphData: {
    commitments: SubgraphCommitment[];
    nullifiers: SubgraphNullifier[];
    unshields: SubgraphUnshield[];
  }
): AccumulatedEvents {
  // Group commitments by transaction
  const commitmentsByTx = new Map<string, SubgraphCommitment[]>();
  for (const commitment of subgraphData.commitments) {
    const key = `${commitment.transactionHash}-${commitment.treeNumber}`;
    if (!commitmentsByTx.has(key)) {
      commitmentsByTx.set(key, []);
    }
    commitmentsByTx.get(key)!.push(commitment);
  }

  // Convert to CommitmentEvent format
  const commitmentEvents: CommitmentEvent[] = [];
  for (const [key, commitments] of commitmentsByTx) {
    if (commitments.length === 0) continue;

    const first = commitments[0];
    
    // Sort by position (implicit from array order)
    commitments.sort((a, b) => a.id.localeCompare(b.id));

    // V2: Format Shield commitments using SDK's official formatters
    const sdkCommitments = commitments.map(c => {
      const cAny = c as any;
      
      // Use SDK's serializePreImage function (same as formatPreImage)
      const tokenData = serializeTokenData(
        cAny.preimage.token.tokenAddress,
        TokenType.ERC20, // Assuming ERC20 for now
        cAny.preimage.token.tokenSubID
      );
      const preImage = serializePreImage(
        cAny.preimage.npk,
        tokenData,
        BigInt(cAny.preimage.value)
      );
      
      // Use SDK's formatTo32Bytes function
      const formatTo32Bytes = (value: string) => {
        return ByteUtils.formatToByteLength(value, ByteLength.UINT_256, false);
      };
      const bigIntStringToHex = (bigintString: string): string => {
        return `0x${BigInt(bigintString).toString(16)}`;
      };
      
      return {
        txid: formatTo32Bytes(c.transactionHash),
        timestamp: Number(c.blockTimestamp),
        commitmentType: CommitmentType.ShieldCommitment,
        hash: formatTo32Bytes(bigIntStringToHex(cAny.hash)),
        preImage,
        encryptedBundle: cAny.encryptedBundle as [string, string, string],
        shieldKey: cAny.shieldKey,
        fee: cAny.fee ? cAny.fee.toString() : undefined,
        blockNumber: Number(c.blockNumber),
        utxoTree: c.treeNumber,
        utxoIndex: Number(cAny.treePosition),
        from: undefined,
      };
    });

    // Sort commitments by utxoIndex (treePosition) within each batch - CRITICAL!
    sdkCommitments.sort((a: any, b: any) => a.utxoIndex - b.utxoIndex);
    
    // Use batchStartTreePosition as startPosition (critical for SDK!)
    const firstAny = first as any;
    commitmentEvents.push({
      txid: first.transactionHash,
      treeNumber: first.treeNumber,
      startPosition: Number(firstAny.batchStartTreePosition || 0), // ← 修复：使用正确的 startPosition
      commitments: sdkCommitments as any[],
      blockNumber: Number(first.blockNumber),
    });
  }

  // Convert nullifiers
  const nullifierEvents: Nullifier[] = subgraphData.nullifiers.map(n => ({
    txid: '', // Not available from Subgraph
    nullifier: n.nullifier,
    blockNumber: Number(n.blockNumber),
    utxoTree: n.treeNumber,
    utxoIndex: 0, // Not available from Subgraph
  }));

  // Convert unshields (V2 uses 'amount' instead of 'value')
  const unshieldEvents: UnshieldStoredEvent[] = subgraphData.unshields.map(u => ({
    txid: u.transactionHash,
    timestamp: Number(u.blockTimestamp),
    toAddress: u.to,
    tokenType: Number(u.token.tokenType),
    tokenAddress: u.token.tokenAddress,
    tokenSubID: u.token.tokenSubID,
    amount: (u as any).amount || (u as any).value, // V2 uses 'amount', V3 uses 'value'
    fee: u.fee,
    blockNumber: Number(u.blockNumber),
    eventLogIndex: 0, // V2 doesn't have transactIndex
    railgunTxid: undefined,
    poisPerList: undefined,
  }));

  console.log(`   ✓ Converted to SDK format: ${commitmentEvents.length} commitment events, ${nullifierEvents.length} nullifiers, ${unshieldEvents.length} unshields`);

  return {
    commitmentEvents,
    nullifierEvents: nullifierEvents,
    unshieldEvents: unshieldEvents,
  };
}

/**
 * QuickSync implementation for RAILGUN SDK
 */
export async function quickSyncEvents(
  txidVersion: TXIDVersion,
  chain: Chain,
  startingBlock: number
): Promise<AccumulatedEvents> {
  console.log(`\n   🚀 QuickSync: Fetching events from block ${startingBlock} (chain ${chain.id})...`);

  try {
    // Query Subgraph
    const subgraphData = await querySubgraphEvents(startingBlock);

    // Convert to SDK format
    const accumulatedEvents = convertToAccumulatedEvents(txidVersion, subgraphData);

    console.log(`   ✅ QuickSync completed successfully\n`);

    return accumulatedEvents;
  } catch (error: any) {
    console.error(`   ❌ QuickSync failed: ${error.message}`);
    console.error(`   Stack: ${error.stack}`);
    
    // Return empty events on failure (SDK will fall back to slow scan)
    console.log(`   ⚠️  Falling back to slow scan...`);
    return {
      commitmentEvents: [],
      nullifierEvents: [],
      unshieldEvents: [],
    };
  }
}

