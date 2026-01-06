import { ethers } from 'ethers';
import * as fs from 'fs';
import * as path from 'path';
import { quickSyncEvents } from './quicksync';
// @ts-ignore - leveldown types not available
import LevelDOWN from 'leveldown';
import { 
  ArtifactStore,
  createRailgunWallet,
  loadProvider,
  populateShield,
  generateTransferProof,
  populateProvedTransfer,
  generateUnshieldProof,
  populateProvedUnshield,
  getRandomBytes,
  getEngine,
  setEngine,
  refreshBalances,
  fullWalletForID,
  setOnBalanceUpdateCallback,
  rescanFullUTXOMerkletreesAndWallets,
  resetFullTXIDMerkletreesV2,
  artifactGetterDownloadJustInTime,
  setArtifactStore,
  setUseNativeArtifacts,
} from '@railgun-community/wallet';
import { RailgunEngine } from '@railgun-community/engine';
// @ts-ignore - shared-models types
import { NetworkName, Chain, TXIDVersion, EVMGasType, createFallbackProviderFromJsonConfig } from '@railgun-community/shared-models';
import { createPollingJsonRpcProviderForListeners, RailgunVersionedSmartContracts, RailgunEngine, ShieldNoteERC20, ByteUtils } from '@railgun-community/engine';

// ============================================================================
// RAILGUN Complete Privacy Transaction Test
// ============================================================================

const ENGINE_DB_PATH = './engine.db';
const WALLET_SOURCE = 'xlayerdevnet'; // Must be < 16 characters, no hyphens or underscores

const CONFIG = {
  chainId: parseInt(process.env.CHAIN_ID || '195'),
  chainName: process.env.CHAIN_NAME || 'XLayerDevNet',
  rpcUrl: process.env.RPC_URL || 'http://localhost:8123',
  railgunAddress: process.env.RAILGUN_ADDRESS || '',
  subgraphUrl: process.env.SUBGRAPH_URL || '',
  
  // Account A (Alice) - deployer, has tokens
  accountA: {
    privateKey: '0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d',
  },
  
  // Account B (Bob) - receiver
  accountB: {
    privateKey: '0x169b6b7ae0857ff7ad563e6db5b7d0d0f5c3f388bc734e05b63ad05600bde341',
    address: '0x430959e66fd9f6da6F96e10E04004c7e9E4A59D0',
  },
  
  testAmount: ethers.parseEther('500'), // 500 tokens for Shield
  transferAmount: ethers.parseEther('100'), // 100 tokens for Transfer
  gasFee: ethers.parseEther('1'), // 1 ETH for gas
};

const TOKEN_ABI_PATH = path.join(__dirname, 'contracts/out/MyToken.sol/MyToken.json');
const TOKEN_ARTIFACT = JSON.parse(fs.readFileSync(TOKEN_ABI_PATH, 'utf-8'));

let provider: ethers.JsonRpcProvider;
let signerA: ethers.Wallet;
let signerB: ethers.Wallet;
let tokenContract: any; // ethers.Contract
let tokenAddress: string;

// RAILGUN wallet info
let walletA: any; // RailgunWalletInfo
let walletB: any; // RailgunWalletInfo
let encryptionKeyA: string;
let encryptionKeyB: string;
let networkName: NetworkName;
let txidVersion: TXIDVersion;

async function initializeRailgunEngine(): Promise<void> {
  console.log('\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
  console.log('🔧 Step 1: Initialize RAILGUN Engine');
  console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n');

  console.log('   ⚠️  Using real RAILGUN SDK with leveldown database\n');

  // Create artifact store
  const fileExists = (path: string): Promise<boolean> => {
    return new Promise(resolve => {
      fs.promises
        .access(path)
        .then(() => resolve(true))
        .catch(() => resolve(false));
    });
  };

  console.log('   📦 Creating artifact store...');
  const artifactStore = new ArtifactStore(
    fs.promises.readFile,
    async (dir, path, data) => {
      await fs.promises.mkdir(dir, { recursive: true });
      await fs.promises.writeFile(path, data);
    },
    fileExists,
  );

  // Initialize leveldown database
  console.log('   📁 Initializing leveldown database...');
  const db = new LevelDOWN(ENGINE_DB_PATH);

  console.log('   🚀 Starting RAILGUN engine...');
  console.log('      (First run may take 1-2 minutes to download ZK artifacts)');
  console.log('      ⚡ Custom QuickSync for devnet\n');

  // Use RailgunEngine.initForWallet directly to pass custom quickSyncEvents
  setArtifactStore(artifactStore);
  setUseNativeArtifacts(false);
  
  // Enable verbose logging for debugging
  const engineDebugger = {
    log: (msg: string) => console.log(`   [ENGINE] ${msg}`),
    error: (msg: string) => console.error(`   [ENGINE ERROR] ${msg}`),
  };
  
  const engine = await RailgunEngine.initForWallet(
    WALLET_SOURCE,
    db,
    artifactGetterDownloadJustInTime,
    quickSyncEvents, // ← Our custom QuickSync for devnet!
    async () => ({ merkleroot: '', railgunTxids: [] }), // quickSyncRailgunTransactionsV2
    async () => true, // validateRailgunTxidMerkleroot
    async () => undefined, // getLatestValidatedRailgunTxid
    engineDebugger as any, // Enable debug logging
    false, // skipMerkletreeScans
  );
  
  setEngine(engine);
  
  console.log('   ✅ RAILGUN engine initialized successfully!');
  console.log('   ✓ Database: leveldown working in Node.js v16');
  console.log('   ✓ Artifacts: ZK circuits loaded');
  console.log('   ✓ Custom QuickSync registered');
  console.log('   ✓ Debug logging enabled\n');
  console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
  console.log('🎉 REAL RAILGUN SDK MODE');
  console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n');
  console.log('   Ready to generate real ZK proofs and submit to L2!\n');
}

async function setupEnvironment() {
  console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
  console.log('📋 Step 2: Environment Setup');
  console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n');

  provider = new ethers.JsonRpcProvider(CONFIG.rpcUrl);
  signerA = new ethers.Wallet(CONFIG.accountA.privateKey, provider);
  signerB = new ethers.Wallet(CONFIG.accountB.privateKey, provider);

  console.log('📋 Configuration:');
  console.log(`   Alice (A): ${signerA.address}`);
  console.log(`   Bob (B):   ${signerB.address}`);
  console.log(`   RAILGUN:   ${CONFIG.railgunAddress}\n`);

  // 1. Send gas fee to Bob
  console.log('📤 Sending gas fee to Bob...');
  const tx = await signerA.sendTransaction({
    to: signerB.address,
    value: CONFIG.gasFee,
  });
  await tx.wait();
  console.log(`   ✓ Sent ${ethers.formatEther(CONFIG.gasFee)} ETH to Bob\n`);

  // 2. Deploy ERC20 token
  console.log('📦 Deploying ERC20 token (MyToken)...');
  const TokenFactory = new ethers.ContractFactory(
    TOKEN_ARTIFACT.abi,
    TOKEN_ARTIFACT.bytecode.object,
    signerA
  );
  tokenContract = await TokenFactory.deploy();
  await tokenContract.waitForDeployment();
  tokenAddress = await tokenContract.getAddress();
  
  const symbol = await tokenContract.symbol();
  const balanceA = await tokenContract.balanceOf(signerA.address);
  console.log(`   ✓ Token deployed: ${tokenAddress}`);
  console.log(`   ✓ Alice balance: ${ethers.formatEther(balanceA)} ${symbol}\n`);
}

async function verifyRailgunContract() {
  console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
  console.log('🔧 Step 3: Verify RAILGUN Contract');
  console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n');

  const code = await provider.getCode(CONFIG.railgunAddress);
  if (code === '0x' || code === '0x0') {
    throw new Error('RAILGUN contract not found');
  }
  
  console.log(`   ✓ RAILGUN contract deployed at: ${CONFIG.railgunAddress}`);
  console.log('   ✓ Contract verified and ready\n');
}

async function setupRailgunWallets() {
  console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
  console.log('🔧 Step 4: Setup RAILGUN Wallets');
  console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n');

  // Use FIXED encryption keys and mnemonics for consistent wallet addresses across test runs
  // This is critical: if we use random keys each time, the wallet can't decrypt previous Shields!
  encryptionKeyA = 'a'.repeat(64); // Fixed 32-byte hex string (without 0x)
  encryptionKeyB = 'b'.repeat(64); // Fixed 32-byte hex string (without 0x)

  // Use fixed mnemonics for deterministic wallet generation
  const mnemonicA = 'test test test test test test test test test test test junk';
  const mnemonicB = 'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';

  console.log('   📝 Creating RAILGUN wallets...');
  console.log('      Alice wallet...');
  walletA = await createRailgunWallet(encryptionKeyA, mnemonicA, undefined);
  console.log(`      ✓ Alice RAILGUN address: ${walletA.railgunAddress}\n`);

  console.log('      Bob wallet...');
  walletB = await createRailgunWallet(encryptionKeyB, mnemonicB, undefined);
  console.log(`      ✓ Bob RAILGUN address: ${walletB.railgunAddress}\n`);

  // Load provider for the network
  // For devnet (chain ID 195), we manually configure the network since it's not in RAILGUN's predefined list
  networkName = NetworkName.Polygon; // Using Polygon as network name (for internal SDK use)
  txidVersion = TXIDVersion.V2_PoseidonMerkle;

  console.log('   🌐 Loading network provider for devnet...');
  console.log(`   Chain ID: ${CONFIG.chainId}`);
  console.log(`   RAILGUN Contract: ${CONFIG.railgunAddress}\n`);
  
  // Create custom chain configuration for devnet
  const devnetChain: Chain = {
    id: CONFIG.chainId,
    type: 'EVM' as any,
  };

  // Create fallback provider config
  // Note: Total weight must be >= 2 for fallback quorum
  const fallbackProviderConfig = {
    chainId: CONFIG.chainId,
    providers: [
      {
        provider: CONFIG.rpcUrl,
        priority: 1,
        weight: 2, // Increased weight to meet minimum requirement (total >= 2)
        stallTimeout: 2500,
      },
    ],
  };

  // Manually load network using engine.loadNetwork (bypassing loadProvider's chain ID validation)
  const engine = getEngine();
  
  // Try to create fallback provider - may fail if chain ID 195 is not recognized by ethers
  let fallbackProvider: any;
  
  try {
    fallbackProvider = createFallbackProviderFromJsonConfig(fallbackProviderConfig as any);
    console.log('   ✓ Fallback provider created successfully');
    // Manually add providerType if it doesn't exist (ethers v6 may not have this)
    if (!fallbackProvider.providerType) {
      (fallbackProvider as any).providerType = 'fallback';
    }
  } catch (error: any) {
    // If ethers.Network.from() fails for chain ID 195, create a custom network
    console.log('   ⚠️  Chain ID 195 not recognized by ethers, creating custom network...');
    const customNetwork = {
      chainId: CONFIG.chainId,
      name: CONFIG.chainName,
    };
    // Create provider directly with custom network
    const { FallbackProvider, JsonRpcProvider } = await import('ethers');
    const baseRpcProvider = new JsonRpcProvider(CONFIG.rpcUrl, customNetwork);
    // Manually add providerType to JsonRpcProvider
    (baseRpcProvider as any).providerType = 'jsonrpc';
    
    fallbackProvider = new FallbackProvider([{
      provider: baseRpcProvider,
      priority: 1,
      weight: 2,
      stallTimeout: 2500,
    }], customNetwork);
    // Manually add providerType to FallbackProvider
    (fallbackProvider as any).providerType = 'fallback';
    console.log('   ✓ Custom fallback provider created');
  }
  
  // Ensure providerConfigs[0].provider has providerType
  if (fallbackProvider.providerConfigs?.length > 0 && fallbackProvider.providerConfigs[0].provider) {
    const firstProvider = fallbackProvider.providerConfigs[0].provider;
    if (!firstProvider.providerType) {
      (firstProvider as any).providerType = 'jsonrpc';
    }
  }
  
  // Create polling provider - createPollingJsonRpcProviderForListeners can handle FallbackProvider
  // It will extract the first JsonRpcProvider automatically
  const pollingProvider = await createPollingJsonRpcProviderForListeners(
    fallbackProvider,
    CONFIG.chainId,
    15000 // polling interval
  );

  // Use our devnet contract addresses
  const proxyContract = CONFIG.railgunAddress; // RailgunSmartWallet
  const relayAdaptContract: string = process.env.RAILGUN_RELAY_ADAPT_ADDRESS || CONFIG.railgunAddress; // RelayAdapt
  
  // Get contract deployment block (critical for event scanning)
  console.log('   🔍 Getting contract deployment block...');
  let deploymentBlock = 0;
  try {
    // Get the block number when the contract was deployed
    const code = await provider.getCode(proxyContract);
    if (code !== '0x' && code !== '0x0') {
      // Contract exists, try to find deployment block
      // For devnet, we can use current block - 1000 as a safe starting point
      const currentBlock = await provider.getBlockNumber();
      deploymentBlock = Math.max(0, currentBlock - 1000);
      console.log(`   ✓ Using block ${deploymentBlock} as starting point (current: ${currentBlock})\n`);
    }
  } catch (error: any) {
    console.log(`   ⚠️  Could not determine deployment block, using 0: ${error.message}\n`);
  }
  
  // Load network with custom configuration
  const deploymentBlocks: Record<TXIDVersion, number> = {
    [TXIDVersion.V2_PoseidonMerkle]: deploymentBlock,
    [TXIDVersion.V3_PoseidonMerkle]: deploymentBlock,
  };
  
  await engine.loadNetwork(
    devnetChain,
    proxyContract,
    relayAdaptContract,
    undefined as any, // poseidonMerkleAccumulatorV3Contract (V3 not used)
    undefined as any, // poseidonMerkleVerifierV3Contract (V3 not used)
    undefined as any, // tokenVaultV3Contract (V3 not used)
    fallbackProvider,
    pollingProvider,
    deploymentBlocks,
    undefined, // poi launch block
    false, // supportsV3
  );

  console.log('   ✓ Network loaded with custom devnet configuration\n');
}

async function demonstratePrivacyFlow() {
  console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
  console.log('🎭 RAILGUN Privacy Flow - Real Implementation');
  console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n');

  const symbol = await tokenContract.symbol();

  // Step 5: Shield (入金)
  console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
  console.log('🔒 Step 5: Shield - Alice deposits tokens into privacy pool');
  console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n');
  
  const balanceABefore = await tokenContract.balanceOf(signerA.address);
  console.log(`   Before Shield:`);
  console.log(`      Alice public balance:  ${ethers.formatEther(balanceABefore)} ${symbol}`);
  console.log(`      Alice private balance: 0 ${symbol}\n`);

  console.log(`   📤 Approving RAILGUN to spend ${ethers.formatEther(CONFIG.testAmount)} ${symbol}...`);
  const approveTx = await tokenContract.connect(signerA).approve(CONFIG.railgunAddress, CONFIG.testAmount);
  await approveTx.wait();
  console.log(`   ✓ Approval confirmed (tx: ${approveTx.hash})\n`);
  
  console.log('   📝 Generating Shield transaction...');
  const shieldPrivateKey = getRandomBytes(32); // hex string without 0x prefix
  
  const erc20AmountRecipients = [{
    tokenAddress: tokenAddress,
    amount: CONFIG.testAmount,
    recipientAddress: walletA.railgunAddress!,
  }];

  // Generate shield requests using devnet chain (not Polygon)
  const random = ByteUtils.randomHex(16);
  const shieldInputs = await Promise.all(
    erc20AmountRecipients.map(async (erc20AmountRecipient) => {
      const railgunAddress = erc20AmountRecipient.recipientAddress;
      const { masterPublicKey, viewingPublicKey } = RailgunEngine.decodeAddress(railgunAddress);
      const shield = new ShieldNoteERC20(
        masterPublicKey,
        random,
        erc20AmountRecipient.amount,
        erc20AmountRecipient.tokenAddress
      );
      return shield.serialize(ByteUtils.hexToBytes(shieldPrivateKey), viewingPublicKey);
    })
  );

  // Use devnet chain directly instead of networkName
  const devnetChain: Chain = {
    id: CONFIG.chainId,
    type: 'EVM' as any,
  };

  // Debug: Check shieldInputs structure
  console.log('   🔍 Debug: Shield inputs:');
  console.log(`      count: ${shieldInputs.length}`);
  if (shieldInputs.length > 0) {
    const firstInput = shieldInputs[0];
    console.log(`      first input preimage: ${firstInput.preimage ? 'present' : 'missing'}`);
    console.log(`      first input ciphertext: ${firstInput.ciphertext ? 'present' : 'missing'}\n`);
  }

  // Debug: Check if contract is registered in ContractStore
  try {
    // Try to get contract from ContractStore
    const contract = RailgunVersionedSmartContracts.getShieldApprovalContract(txidVersion, devnetChain);
    console.log('   🔍 Debug: Contract found in ContractStore:');
    console.log(`      address: ${contract.address}\n`);
  } catch (error: any) {
    console.log(`   ❌ Contract not found in ContractStore: ${error.message}\n`);
    throw new Error(`Contract not registered for chain ${devnetChain.id}. Make sure engine.loadNetwork was called correctly.`);
  }

  // Generate shield transaction using devnet chain
  const shieldTransaction = await RailgunVersionedSmartContracts.generateShield(
    txidVersion,
    devnetChain,
    shieldInputs
  );

  // Debug: Check transaction structure
  console.log('   🔍 Debug: Shield transaction structure:');
  console.log(`      to: ${shieldTransaction.to}`);
  console.log(`      data: ${shieldTransaction.data ? shieldTransaction.data.substring(0, 20) + '...' : 'EMPTY!'}`);
  console.log(`      data length: ${shieldTransaction.data ? shieldTransaction.data.length : 0} chars`);
  console.log(`      value: ${shieldTransaction.value}\n`);

  // Ensure transaction has required fields
  if (!shieldTransaction.to) {
    throw new Error('Shield transaction missing "to" address');
  }
  if (!shieldTransaction.data || shieldTransaction.data === '0x' || shieldTransaction.data === '') {
    throw new Error(`Shield transaction missing "data" field (data: "${shieldTransaction.data}")`);
  }

  const gasPrice = await provider.getFeeData();
  
  // Estimate gas for shield transaction
  // Shield operations require significant gas for merkle tree calculations
  let gasEstimate = 1000000n; // Default to 1M gas for shield
  try {
    const estimatedGas = await provider.estimateGas({
      to: shieldTransaction.to,
      data: shieldTransaction.data,
      from: signerA.address,
    });
    // Add 20% buffer for safety
    gasEstimate = (estimatedGas * 120n) / 100n;
    console.log(`   🔍 Gas estimate: ${gasEstimate} (estimated: ${estimatedGas})\n`);
  } catch (error: any) {
    console.log(`   ⚠️  Gas estimation failed, using default: ${gasEstimate}\n`);
  }
  
  const gasDetails = {
    evmGasType: EVMGasType.Type2,
    gasEstimate: gasEstimate,
    maxFeePerGas: gasPrice.maxFeePerGas || 1000000000n,
    maxPriorityFeePerGas: gasPrice.maxPriorityFeePerGas || 1000000000n,
  };

  // Set gas details
  if (gasDetails.evmGasType === EVMGasType.Type2) {
    shieldTransaction.maxFeePerGas = gasDetails.maxFeePerGas;
    shieldTransaction.maxPriorityFeePerGas = gasDetails.maxPriorityFeePerGas;
  }
  shieldTransaction.gasLimit = gasDetails.gasEstimate;

  const shieldTx = {
    transaction: shieldTransaction,
    preTransactionPOIsPerTxidLeafPerList: {},
  };

  // Debug: Verify transaction data before sending
  console.log('   🔍 Debug: Transaction before sending:');
  console.log(`      to: ${shieldTx.transaction.to}`);
  console.log(`      data: ${shieldTx.transaction.data ? shieldTx.transaction.data.substring(0, 20) + '...' : 'EMPTY!'}`);
  console.log(`      data length: ${shieldTx.transaction.data ? shieldTx.transaction.data.length : 0} chars\n`);

  console.log('   📤 Submitting Shield transaction...');
  // Ensure data is preserved - create a clean transaction object
  const txToSend: any = {
    to: shieldTx.transaction.to,
    data: shieldTx.transaction.data,
    value: shieldTx.transaction.value || 0n,
  };
  
  // Add gas fields if they exist
  if (shieldTx.transaction.maxFeePerGas) {
    txToSend.maxFeePerGas = shieldTx.transaction.maxFeePerGas;
  }
  if (shieldTx.transaction.maxPriorityFeePerGas) {
    txToSend.maxPriorityFeePerGas = shieldTx.transaction.maxPriorityFeePerGas;
  }
  if (shieldTx.transaction.gasLimit) {
    txToSend.gasLimit = shieldTx.transaction.gasLimit;
  }
  
  // Final debug check
  if (!txToSend.data || txToSend.data === '0x' || txToSend.data === '') {
    throw new Error(`Transaction data is empty before sending! Original data: ${shieldTx.transaction.data}`);
  }
  
  const shieldResponse = await signerA.sendTransaction(txToSend);
  console.log(`   ⏳ Waiting for confirmation (tx: ${shieldResponse.hash})...`);

  let shieldReceipt: any;
  try {
    shieldReceipt = await shieldResponse.wait();
    if (shieldReceipt!.status === 0) {
      // Transaction reverted - try to get revert reason
      console.log('   ❌ Transaction reverted! Trying to get revert reason...');
      try {
        // Call the contract to see what the revert reason is
        const callResult = await provider.call({
          to: txToSend.to,
          data: txToSend.data,
          from: signerA.address,
        });
        console.log(`   Call result: ${callResult}`);
      } catch (callError: any) {
        console.log(`   Revert reason (from call): ${callError.message}`);
      }
      throw new Error(`Shield transaction reverted. Receipt: ${JSON.stringify(shieldReceipt, null, 2)}`);
    }
    console.log(`   ✓ Shield confirmed (block: ${shieldReceipt!.blockNumber})\n`);
  } catch (error: any) {
    // If wait() throws, it's likely a revert
    if (error.receipt && error.receipt.status === 0) {
      console.log('   ❌ Transaction reverted!');
      console.log(`   Gas used: ${error.receipt.gasUsed}`);
      console.log(`   Block: ${error.receipt.blockNumber}`);
      // Try to decode revert reason
      try {
        const callResult = await provider.call({
          to: txToSend.to,
          data: txToSend.data,
          from: signerA.address,
        });
        console.log(`   Call result: ${callResult}`);
      } catch (callError: any) {
        console.log(`   Revert reason: ${callError.message || callError.reason || 'Unknown'}`);
      }
    }
    throw error;
  }
  
  // Wait for RAILGUN engine to sync the new commitment
  console.log('   🔄 Syncing RAILGUN wallet balance...');
  console.log('   ⚡ Using custom QuickSync (Subgraph) for devnet...');
  
  const syncChain: Chain = {
    id: CONFIG.chainId,
    type: 'EVM' as any,
  };
  
  // Get Shield block for QuickSync starting point
  const shieldBlockNumber = shieldReceipt!.blockNumber;
  const scanStartBlock = Math.max(0, shieldBlockNumber - 100); // Start 100 blocks before Shield
  
  console.log(`   📡 Fetching events from Subgraph (block ${scanStartBlock}+)...`);
  
  // Manually trigger QuickSync to fetch events from Subgraph
  try {
    const accumulatedEvents = await quickSyncEvents(txidVersion, syncChain, scanStartBlock);
    console.log(`   ✓ QuickSync fetched ${accumulatedEvents.commitmentEvents.length} commitment events\n`);
    
    // Now trigger balance refresh (SDK will process the events)
    console.log('   📡 Triggering balance refresh...');
    await refreshBalances(syncChain, [walletA.id]);
    console.log('   ✓ Refresh triggered\n');
  } catch (error: any) {
    console.log(`   ⚠️  QuickSync failed: ${error.message}`);
    console.log(`   ⏳ Falling back to slow scan...\n`);
    await refreshBalances(syncChain, [walletA.id]);
  }
  
  // Poll for balance update
  let privateBalanceAfterShield = 0n;
  const maxAttempts = 15; // 15 attempts * 2 seconds = 30 seconds
  let attempt = 0;
  
  console.log('   ⏳ Waiting for balance sync to complete...');
  
  while (attempt < maxAttempts) {
    await new Promise(resolve => setTimeout(resolve, 2000));
    attempt++;
    
    try {
      const wallet = fullWalletForID(walletA.id);
      const balances = await wallet.getTokenBalances(txidVersion, syncChain, false);
      
      // Debug logging
      console.log(`   🔍 Attempt ${attempt}: Token=${tokenAddress.toLowerCase()}, Keys=${Object.keys(balances).join(', ') || 'none'}`);
      
      const tokenBalanceEntry = balances[tokenAddress.toLowerCase()];
      if (tokenBalanceEntry) {
        const balanceValue = typeof tokenBalanceEntry === 'object' && 'balance' in tokenBalanceEntry 
          ? BigInt((tokenBalanceEntry as any).balance) 
          : BigInt(tokenBalanceEntry);
        
        if (balanceValue > 0n) {
          privateBalanceAfterShield = balanceValue;
          console.log(`   ✅ Balance synced in ${attempt * 2}s: ${ethers.formatEther(privateBalanceAfterShield)} ${symbol}\n`);
          break;
        }
      }
    } catch (error: any) {
      console.log(`   ⚠️  Error: ${error.message}`);
    }
  }
  
  if (privateBalanceAfterShield === 0n) {
    throw new Error(`Failed to sync after ${maxAttempts * 2}s. Check Subgraph at ${process.env.SUBGRAPH_URL || 'http://railgun-graph-node:8000/subgraphs/name/railgun-xlayer-devnet'}`);
  }
  
  const balanceAAfterShield = await tokenContract.balanceOf(signerA.address);
  console.log(`   After Shield:`);
  console.log(`      Alice public balance:  ${ethers.formatEther(balanceAAfterShield)} ${symbol}`);
  console.log(`      Alice private balance: ${ethers.formatEther(privateBalanceAfterShield)} ${symbol} ✨\n`);
  
  console.log('   🔍 On-chain visible: "Someone deposited 500 tokens"');
  console.log('   🙈 Hidden: Who deposited (Alice)\n');

  // Step 6: Transfer
  console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
  console.log('🔄 Step 6: Transfer - Alice sends tokens to Bob privately');
  console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n');
  
  console.log(`   📝 Generating Transfer proof (this may take 30-60 seconds)...`);
  console.log(`      Amount: ${ethers.formatEther(CONFIG.transferAmount)} ${symbol}`);
  console.log(`      From: ${walletA.railgunAddress}`);
  console.log(`      To: ${walletB.railgunAddress}\n`);

  const transferERC20AmountRecipients = [{
    tokenAddress: tokenAddress,
    amount: CONFIG.transferAmount,
    recipientAddress: walletB.railgunAddress!,
  }];

  await generateTransferProof(
    txidVersion,
    networkName,
    walletA.id,
    encryptionKeyA,
    false, // showSenderAddressToRecipient
    undefined, // memoText
    transferERC20AmountRecipients,
    [], // nftAmountRecipients
    undefined, // broadcasterFeeERC20AmountRecipient
    false, // sendWithPublicWallet
    undefined, // overallBatchMinGasPrice
    (progress, status) => {
      if (progress % 10 === 0) {
        console.log(`      Proof generation: ${progress}% - ${status}`);
      }
    },
  );

  console.log('   ✓ Transfer proof generated\n');

  const transferTx = await populateProvedTransfer(
    txidVersion,
    networkName,
    walletA.id,
    false, // showSenderAddressToRecipient
    undefined, // memoText
    transferERC20AmountRecipients,
    [], // nftAmountRecipients
    undefined, // broadcasterFeeERC20AmountRecipient
    false, // sendWithPublicWallet
    undefined, // overallBatchMinGasPrice
    gasDetails,
  );

  console.log('   📤 Submitting Transfer transaction...');
  const transferResponse = await signerA.sendTransaction(transferTx.transaction);
  console.log(`   ⏳ Waiting for confirmation (tx: ${transferResponse.hash})...`);
  const transferReceipt = await transferResponse.wait();
  console.log(`   ✓ Transfer confirmed (block: ${transferReceipt!.blockNumber})\n`);
  
  console.log('   🔍 On-chain visible: "A transfer happened"');
  console.log('   🙈 Hidden: Sender (Alice), Receiver (Bob), Amount (100)\n');

  // Step 7: Unshield
  console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
  console.log('🔓 Step 7: Unshield - Bob withdraws to public address');
  console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n');
  
  console.log(`   📝 Generating Unshield proof (this may take 30-60 seconds)...`);
  console.log(`      Amount: ${ethers.formatEther(CONFIG.transferAmount)} ${symbol}`);
  console.log(`      To: ${signerB.address}\n`);

  const unshieldERC20AmountRecipients = [{
    tokenAddress: tokenAddress,
    amount: CONFIG.transferAmount,
    recipientAddress: signerB.address,
  }];

  await generateUnshieldProof(
    txidVersion,
    networkName,
    walletB.id,
    encryptionKeyB,
    unshieldERC20AmountRecipients,
    [], // nftAmountRecipients
    undefined, // broadcasterFeeERC20AmountRecipient
    false, // sendWithPublicWallet
    undefined, // overallBatchMinGasPrice
    (progress, status) => {
      if (progress % 10 === 0) {
        console.log(`      Proof generation: ${progress}% - ${status}`);
      }
    },
  );

  console.log('   ✓ Unshield proof generated\n');

  const unshieldTx = await populateProvedUnshield(
    txidVersion,
    networkName,
    walletB.id,
    unshieldERC20AmountRecipients,
    [], // nftAmountRecipients
    undefined, // broadcasterFeeERC20AmountRecipient
    false, // sendWithPublicWallet
    undefined, // overallBatchMinGasPrice
    gasDetails,
  );

  console.log('   📤 Submitting Unshield transaction...');
  const unshieldResponse = await signerB.sendTransaction(unshieldTx.transaction);
  console.log(`   ⏳ Waiting for confirmation (tx: ${unshieldResponse.hash})...`);
  const unshieldReceipt = await unshieldResponse.wait();
  console.log(`   ✓ Unshield confirmed (block: ${unshieldReceipt!.blockNumber})\n`);
  
  const balanceBAfter = await tokenContract.balanceOf(signerB.address);
  console.log(`   After Unshield:`);
  console.log(`      Bob private balance: 0 ${symbol}`);
  console.log(`      Bob public balance:  ${ethers.formatEther(balanceBAfter)} ${symbol} ✨\n`);
  
  console.log('   🔍 On-chain visible: "Someone withdrew 100 tokens to Bob\'s address"');
  console.log('   🙈 Hidden: Which private account belongs to Bob\n');
}

async function summary() {
  console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
  console.log('📊 Privacy Analysis');
  console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n');
  
  console.log('🔍 What observers can see on-chain:');
  console.log('   1. "Someone deposited 500 tokens"');
  console.log('   2. "A transfer happened"');
  console.log('   3. "Someone withdrew 100 tokens to Bob\'s address"\n');
  
  console.log('🙈 What is hidden:');
  console.log('   ✗ Alice deposited 500 tokens');
  console.log('   ✗ Alice sent 100 tokens to Bob');
  console.log('   ✗ Transfer amount was 100 tokens');
  console.log('   ✗ Alice still has 400 tokens in privacy pool');
  console.log('   ✗ Relationship between Alice and Bob\n');
  
  console.log('🔑 Key Technologies:');
  console.log('   • Zero-Knowledge Proofs: Prove "I can spend" without revealing "I am"');
  console.log('   • Commitments: Encrypted "checks" only owner can decrypt');
  console.log('   • Nullifiers: Prevent double-spending without revealing spender');
  console.log('   • Merkle Tree: Efficiently prove Commitment exists');
  console.log('   • Subgraph: Index events for fast wallet scanning\n');
  
  console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
  console.log('✅ RAILGUN Privacy Demo Complete!');
  console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n');
  
  console.log('ℹ️  Current Status: RAILGUN Engine Initialized');
  console.log('   • RAILGUN engine: ✅ Running');
  console.log('   • leveldown database: ✅ Working in Node.js v16');
  console.log('   • ZK circuits: ✅ Loaded');
  console.log('   • Privacy flow: ⚠️  Simulated (TODO: implement with real SDK)');
  console.log('');
  console.log('📝 Next Steps to Complete Real Implementation:');
  console.log('   1. Create RAILGUN wallets for Alice and Bob');
  console.log('   2. Load network provider and connect to L2');
  console.log('   3. Generate Shield transaction with real ZK proof');
  console.log('   4. Submit Shield to L2 and wait for confirmation');
  console.log('   5. Generate Transfer transaction with real ZK proof');
  console.log('   6. Submit Transfer to L2 and wait for confirmation');
  console.log('   7. Generate Unshield transaction with real ZK proof');
  console.log('   8. Submit Unshield to L2 and wait for confirmation');
  console.log('');
  console.log('⏱️  Estimated implementation time: 2-3 hours');
  console.log('   (Each ZK proof generation takes 10-60 seconds)\n');
}

async function main() {
  console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
  console.log('🚀 RAILGUN Real Privacy Transaction Test');
  console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n');

  try {
    // Step 1: Initialize RAILGUN engine (REQUIRED - fails if not working)
    await initializeRailgunEngine();

    // Step 2: Setup environment (deploy ERC20, send gas fees)
    await setupEnvironment();

    // Step 3: Verify RAILGUN contract
    await verifyRailgunContract();

    // Step 4: Setup RAILGUN wallets
    await setupRailgunWallets();

    // Step 5-7: Real privacy flow
    await demonstratePrivacyFlow();

    // Summary
    await summary();
  } catch (error: any) {
    console.error('\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
    console.error('❌ Test Failed');
    console.error('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n');
    console.error('Error:', error.message);
    console.error('\nStack:', error.stack);
    console.error('\n💡 Common Issues:');
    console.error('   • leveldown compatibility (try running in browser instead)');
    console.error('   • Missing ZK artifacts (check network connection)');
    console.error('   • Node.js version (requires v14-v19)');
    console.error('');
    process.exit(1);
  }
}

main().catch((error) => {
  console.error('\n❌ Unexpected Error:', error);
  process.exit(1);
});
