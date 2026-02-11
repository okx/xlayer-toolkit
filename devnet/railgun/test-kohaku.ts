import { ethers } from 'ethers';
import {
  createRailgunAccount,
  createRailgunIndexer,
  EthersProviderAdapter,
  EthersSignerAdapter,
  type RailgunNetworkConfig,
} from '@kohaku-eth/railgun';

const CONFIG = {
  chainId: parseInt(process.env.CHAIN_ID || '195'),
  chainName: process.env.CHAIN_NAME || 'XLayerDevNet',
  rpcUrl: process.env.RPC_URL || 'http://localhost:8123',
  railgunAddress: process.env.RAILGUN_ADDRESS || '',
  relayAdaptAddress: process.env.RAILGUN_RELAY_ADAPT_ADDRESS || '',
  poseidonAddress: process.env.POSEIDON_ADDRESS || '',
  
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

// ERC20 ABI
const TOKEN_ARTIFACT = {
  abi: [
    'function approve(address spender, uint256 amount) returns (bool)',
    'function balanceOf(address account) view returns (uint256)',
    'function decimals() view returns (uint8)',
    'function symbol() view returns (string)',
    'function transfer(address to, uint256 amount) returns (bool)',
  ]
};

// Global variables
let provider: ethers.JsonRpcProvider;
let signerA: ethers.Wallet;
let signerB: ethers.Wallet;
let tokenContract: ethers.Contract;
let tokenAddress: string;

// Kohaku objects
let devnetConfig: RailgunNetworkConfig;
let indexer: Awaited<ReturnType<typeof createRailgunIndexer>>;
let aliceAccount: Awaited<ReturnType<typeof createRailgunAccount>>;
let bobAccount: Awaited<ReturnType<typeof createRailgunAccount>>;

async function setupEnvironment() {
  console.log('📋 Step 1: Environment Setup');

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

  // 2. Get ERC20 token from environment
  console.log('📦 Loading ERC20 token...');
  
  tokenAddress = process.env.TOKEN_ADDRESS || '';
  if (!tokenAddress) {
    throw new Error('TOKEN_ADDRESS not set. Please run deploy-test-token.sh first.');
  }

  tokenContract = new ethers.Contract(tokenAddress, TOKEN_ARTIFACT.abi, signerA);
  
  try {
    const code = await provider.getCode(tokenAddress);
    if (code === '0x' || code === '0x0') {
      throw new Error(`Token contract not found at ${tokenAddress}`);
    }
    
    const symbol = await tokenContract.symbol();
    const balanceA = await tokenContract.balanceOf(signerA.address);
    console.log(`   ✓ Token loaded: ${tokenAddress}`);
    console.log(`   ✓ Symbol: ${symbol}`);
    console.log(`   ✓ Alice balance: ${ethers.formatEther(balanceA)} ${symbol}\n`);
  } catch (error: any) {
    console.error(`   ❌ Failed to load token: ${error.message}`);
    throw new Error(`Token contract at ${tokenAddress} is invalid or not deployed`);
  }
}

async function setupKohakuRailgun() {
  console.log('🔧 Step 2: Setup Kohaku RAILGUN SDK');

  // 1. Create custom devnet network configuration
  console.log('   📝 Creating devnet network configuration...');
  
  // Get deployment block from environment or use 0
  let startBlock = 0;
  if (process.env.RAILGUN_DEPLOY_BLOCK) {
    startBlock = parseInt(process.env.RAILGUN_DEPLOY_BLOCK);
    console.log(`   ✓ Using deployment block: ${startBlock}\n`);
  } else {
    // Fallback: estimate from current block
    try {
      const currentBlock = await provider.getBlockNumber();
      startBlock = Math.max(0, currentBlock - 1000);
      console.log(`   ⚠️  RAILGUN_DEPLOY_BLOCK not set, estimating: ${startBlock} (current: ${currentBlock})\n`);
    } catch (error: any) {
      console.log(`   ⚠️  Could not determine start block, using 0\n`);
    }
  }

  // Note: For devnet, we use a wrapped ETH address placeholder
  // You may need to deploy a WETH contract for native ETH shielding
  const WETH_PLACEHOLDER = '0x0000000000000000000000000000000000000001';
  
  devnetConfig = {
    NAME: CONFIG.chainName,
    RAILGUN_ADDRESS: CONFIG.railgunAddress as `0x${string}`,
    GLOBAL_START_BLOCK: startBlock,
    CHAIN_ID: BigInt(CONFIG.chainId),
    RELAY_ADAPT_ADDRESS: (CONFIG.relayAdaptAddress || CONFIG.railgunAddress) as `0x${string}`,
    WETH: WETH_PLACEHOLDER as `0x${string}`,
    FEE_BASIS_POINTS: 25n, // 0.25% fee
  };

  console.log('   ✓ Network configuration:');
  console.log(`      Chain ID: ${devnetConfig.CHAIN_ID}`);
  console.log(`      RAILGUN: ${devnetConfig.RAILGUN_ADDRESS}`);
  console.log(`      RelayAdapt: ${devnetConfig.RELAY_ADAPT_ADDRESS}`);
  console.log(`      Start Block: ${devnetConfig.GLOBAL_START_BLOCK}\n`);

  // 2. Create provider adapter
  console.log('   🔌 Creating provider adapter...');
  const providerAdapter = new EthersProviderAdapter(provider);
  console.log('   ✓ Ethers provider adapter created\n');

  // 3. Create indexer
  console.log('   📇 Creating RAILGUN indexer...');
  indexer = await createRailgunIndexer({
    network: devnetConfig,
    provider: providerAdapter,
    startBlock: devnetConfig.GLOBAL_START_BLOCK,
  });
  console.log('   ✓ Indexer created\n');

  // 4. Create Alice's account
  console.log('   👤 Creating Alice\'s RAILGUN account...');
  const aliceMnemonic = 'test test test test test test test test test test test junk';
  const aliceSigner = new EthersSignerAdapter(signerA);
  
  aliceAccount = await createRailgunAccount({
    credential: {
      type: 'mnemonic',
      mnemonic: aliceMnemonic,
      accountIndex: 0,
    },
    indexer,
  });
  
  // Set signer for shield operations
  (aliceAccount as any)._internal.signer = aliceSigner;
  
  const aliceRailgunAddress = await aliceAccount.getRailgunAddress();
  console.log(`   ✓ Alice RAILGUN address: ${aliceRailgunAddress}\n`);

  // 5. Create Bob's account
  console.log('   👤 Creating Bob\'s RAILGUN account...');
  const bobMnemonic = 'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
  const bobSigner = new EthersSignerAdapter(signerB);
  
  bobAccount = await createRailgunAccount({
    credential: {
      type: 'mnemonic',
      mnemonic: bobMnemonic,
      accountIndex: 0,
    },
    indexer,
  });
  
  // Set signer for operations
  (bobAccount as any)._internal.signer = bobSigner;
  
  const bobRailgunAddress = await bobAccount.getRailgunAddress();
  console.log(`   ✓ Bob RAILGUN address: ${bobRailgunAddress}\n`);

  console.log('🎉 Kohaku RAILGUN SDK Initialized');
}

async function handleShield() {
  console.log('🔒 Step 3: Shield - Alice deposits tokens into privacy pool');

  const symbol = await tokenContract.symbol();
  const balanceABefore = await tokenContract.balanceOf(signerA.address);
  
  console.log(`   Before Shield:`);
  console.log(`      Alice public balance:  ${ethers.formatEther(balanceABefore)} ${symbol}`);
  console.log(`      Alice private balance: 0 ${symbol}\n`);

  // 1. Approve RAILGUN to spend tokens
  console.log(`   📤 Approving RAILGUN to spend ${ethers.formatEther(CONFIG.testAmount)} ${symbol}...`);
  const approveTx = await tokenContract.connect(signerA).approve(CONFIG.railgunAddress, CONFIG.testAmount);
  await approveTx.wait();
  console.log(`   ✓ Approval confirmed\n`);

  // 2. Generate shield transaction using Kohaku
  console.log('   📝 Generating Shield transaction with Kohaku...');
  const shieldTxData = await aliceAccount.shield(
    tokenAddress as `0x${string}`,
    CONFIG.testAmount
  );
  
  console.log('   ✓ Shield transaction generated\n');

  // 3. Submit transaction
  console.log('   📤 Submitting Shield transaction...');
  const shieldTx = await signerA.sendTransaction({
    ...shieldTxData,  // Use spread operator like in Kohaku tests
    gasLimit: 6000000n,
  });
  
  console.log(`   ⏳ Waiting for confirmation (tx: ${shieldTx.hash})...`);
  const shieldReceipt = await shieldTx.wait();
  
  if (shieldReceipt!.status === 0) {
    throw new Error('Shield transaction reverted');
  }
  
  console.log(`   ✓ Shield confirmed (block: ${shieldReceipt!.blockNumber})\n`);

  // 4. Sync indexer to process the shield event
  console.log('   🔄 Syncing indexer to process Shield event...');
  const currentBlock = await provider.getBlockNumber();
  
  if (indexer.sync) {
    await indexer.sync({ toBlock: currentBlock, logProgress: false });
  } else {
    console.log('   ⚠️  No sync function available, events will be processed on demand\n');
  }
  
  console.log('   ✓ Indexer synced\n');

  // 5. Check balance
  console.log('   ⏳ Waiting for balance to update...');
  let privateBalance = 0n;
  let attempts = 0;
  const maxAttempts = 15;
  
  while (attempts < maxAttempts) {
    await new Promise(resolve => setTimeout(resolve, 2000));
    attempts++;
    
    try {
      privateBalance = await aliceAccount.getBalance(tokenAddress as `0x${string}`);
      if (privateBalance > 0n) {
        console.log(`   ✅ Balance synced in ${attempts * 2}s\n`);
        break;
      }
      console.log(`   🔍 Attempt ${attempts}: Balance = ${privateBalance}`);
    } catch (error: any) {
      console.log(`   ⚠️  Attempt ${attempts}: ${error.message}`);
    }
  }
  
  if (privateBalance === 0n) {
    throw new Error(`Failed to sync private balance after ${maxAttempts * 2}s`);
  }

  const balanceAAfter = await tokenContract.balanceOf(signerA.address);
  console.log(`   After Shield:`);
  console.log(`      Alice public balance:  ${ethers.formatEther(balanceAAfter)} ${symbol}`);
  console.log(`      Alice private balance: ${ethers.formatEther(privateBalance)} ${symbol} ✨\n`);
  
  console.log('   🔍 On-chain visible: "Someone deposited 500 tokens"');
  console.log('   🙈 Hidden: Who deposited (Alice)\n');
}

async function handleTransfer() {
  console.log('🔄 Step 4: Transfer - Alice sends tokens to Bob privately');

  // Sync indexer before transfer to ensure latest state
  console.log('   🔄 Pre-Transfer: Syncing indexer to latest block...');
  const latestBlock = await provider.getBlockNumber();
  if (indexer.sync) {
    await indexer.sync({ toBlock: latestBlock, logProgress: false });
  }
  console.log(`   ✓ Indexer synced to block ${latestBlock}\n`);

  const symbol = await tokenContract.symbol();
  const bobRailgunAddress = await bobAccount.getRailgunAddress();
  
  console.log(`   📝 Generating Transfer transaction...`);
  console.log(`      Amount: ${ethers.formatEther(CONFIG.transferAmount)} ${symbol}`);
  console.log(`      To: ${bobRailgunAddress}\n`);

  // Generate transfer transaction (includes ZK proof generation)
  console.log('   ⏳ Generating ZK proof ...\n');
  const transferTxData = await aliceAccount.transfer(
    tokenAddress as `0x${string}`,
    CONFIG.transferAmount,
    bobRailgunAddress as `0x${string}`
  );
  
  console.log('   ✓ Transfer transaction generated\n');

  // Submit transaction
  console.log('   📤 Submitting Transfer transaction...');
  const transferTx = await signerA.sendTransaction({
    ...transferTxData,  // Use spread operator like in Kohaku tests
    gasLimit: 6000000n,
  });
  
  console.log(`   ⏳ Waiting for confirmation (tx: ${transferTx.hash})...`);
  const transferReceipt = await transferTx.wait();
  
  if (transferReceipt!.status === 0) {
    console.error('   ❌ Transaction failed!');
    console.error('   📋 Receipt:', JSON.stringify(transferReceipt, null, 2));
    throw new Error('Transfer transaction reverted');
  }
  
  console.log(`   ✓ Transfer confirmed (block: ${transferReceipt!.blockNumber})\n`);

  // Sync indexer
  console.log('   🔄 Syncing indexer...');
  const currentBlock = await provider.getBlockNumber();
  
  if (indexer.sync) {
    await indexer.sync({ toBlock: currentBlock, logProgress: false });
  }
  
  console.log('   ✓ Indexer synced\n');

  // Check balances
  await new Promise(resolve => setTimeout(resolve, 3000));
  
  const aliceBalance = await aliceAccount.getBalance(tokenAddress as `0x${string}`);
  const bobBalance = await bobAccount.getBalance(tokenAddress as `0x${string}`);
  
  console.log(`   After Transfer:`);
  console.log(`      Alice private balance: ${ethers.formatEther(aliceBalance)} ${symbol}`);
  console.log(`      Bob private balance:   ${ethers.formatEther(bobBalance)} ${symbol} ✨\n`);
  
  console.log('   🔍 On-chain visible: "A transfer happened"');
  console.log('   🙈 Hidden: Sender (Alice), Receiver (Bob), Amount (100)\n');
}

// ============================================================================
// Step 5: Unshield (Privacy Withdrawal)
// ============================================================================

async function handleUnshield() {
  console.log('🔓 Step 5: Unshield - Bob withdraws to public address');

  const symbol = await tokenContract.symbol();
  
  console.log(`   📝 Generating Unshield transaction...`);
  console.log(`      Amount: ${ethers.formatEther(CONFIG.transferAmount)} ${symbol}`);
  console.log(`      To: ${signerB.address}\n`);

  // Generate unshield transaction (includes ZK proof generation)
  console.log('   ⏳ Generating ZK proof ..\n');
  const unshieldTxData = await bobAccount.unshield(
    tokenAddress as `0x${string}`,
    CONFIG.transferAmount,
    signerB.address as `0x${string}`
  );
  
  console.log('   ✓ Unshield transaction generated\n');

  // Submit transaction
  console.log('   📤 Submitting Unshield transaction...');
  const unshieldTx = await signerB.sendTransaction({
    ...unshieldTxData,  // Use spread operator like in Kohaku tests
    gasLimit: 6000000n,
  });
  
  console.log(`   ⏳ Waiting for confirmation (tx: ${unshieldTx.hash})...`);
  const unshieldReceipt = await unshieldTx.wait();
  
  if (unshieldReceipt!.status === 0) {
    throw new Error('Unshield transaction reverted');
  }
  
  console.log(`   ✓ Unshield confirmed (block: ${unshieldReceipt!.blockNumber})\n`);

  // Check final balances
  const balanceBAfter = await tokenContract.balanceOf(signerB.address);
  
  console.log(`   After Unshield:`);
  console.log(`      Bob private balance: 0 ${symbol}`);
  console.log(`      Bob public balance:  ${ethers.formatEther(balanceBAfter)} ${symbol} ✨\n`);
  
  console.log('   🔍 On-chain visible: "Someone withdrew 100 tokens to Bob\'s address"');
  console.log('   🙈 Hidden: Which private account belongs to Bob\n');
}

async function summary() {
  console.log('🙈 What is hidden:');
  console.log('   ✗ Alice deposited 500 tokens');
  console.log('   ✗ Alice sent 100 tokens to Bob');
  console.log('   ✗ Transfer amount was 100 tokens');
  console.log('   ✗ Alice still has 400 tokens in privacy pool');
  console.log('   ✗ Relationship between Alice and Bob\n');
  
  console.log('✅ RAILGUN Privacy Demo Complete (Kohaku SDK)!');
}

async function main() {
  console.log('🚀 RAILGUN Privacy Transaction Test (Kohaku SDK)');

  try {
    // Step 1: Setup environment (deploy ERC20, send gas fees)
    await setupEnvironment();

    // Step 2: Setup Kohaku RAILGUN SDK
    await setupKohakuRailgun();

    // Step 3: Shield - Alice deposits tokens
    await handleShield();

    // Step 4: Transfer - Alice sends to Bob
    await handleTransfer();

    // Step 5: Unshield - Bob withdraws to public address
    await handleUnshield();

    // Summary
    await summary();
    
    // Clean exit
    process.exit(0);
  } catch (error: any) {
    console.error('❌ Test Failed');
    console.error(`Error: ${error.message}`);
    console.error(`Stack: ${error.stack}`);
    process.exit(1);
  }
}

main().catch((error) => {
  console.error('\n❌ Unexpected Error:', error);
  process.exit(1);
});

