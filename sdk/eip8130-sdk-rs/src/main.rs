//! EIP-8130 (X Layer Native AA) transaction sender CLI.
//!
//! Covers the spec surface a tester needs:
//!
//! | Feature                       | CLI flag                                |
//! |-------------------------------|-----------------------------------------|
//! | EOA self-pay (`from` empty)   | default                                 |
//! | Configured-owner mode         | `--from <addr>`                         |
//! | Single call                   | `--to <addr> --data <hex>`              |
//! | Multi-call / multi-phase      | repeated `--phase "to,data;to,data;…"`  |
//! | 2D nonce (any channel)        | `--nonce-key`, `--nonce-sequence`       |
//! | Auto-detect nonce sequence    | `--auto-nonce`                          |
//! | Nonce-free mode (`MAX`)       | `--nonce-free`                          |
//! | Expiry                        | `--expiry <unix-secs>`                  |
//! | Sponsored payer               | `--payer <addr> --payer-key <hex>`      |
//! | Delegation entry              | `--delegation-target <addr>`            |
//! | Revoke implicit EOA owner     | `--revoke-eoa-owner`                    |
//! | Encode-only                   | `--dry-run`                             |
//!
//! Refer to <https://github.com/ethereum/EIPs/blob/master/EIPS/eip-8130.md>
//! for the field-level semantics.

use std::str::FromStr;

use alloy_eips::eip2718::Encodable2718;
use alloy_primitives::{Address, B256, Bytes, U256, hex};
use alloy_provider::{Provider, ProviderBuilder};
use clap::Parser;
use eyre::{Context, Result, bail};
use op_alloy_consensus::transaction::eip8130::{
    AA_TX_TYPE_ID, AccountChangeEntry, Call, ConfigChangeEntry, CreateEntry, DelegationEntry,
    NONCE_KEY_MAX, Owner, OwnerChange, TxEip8130, config_change_digest, derive_account_address,
    payer_signature_hash, sender_signature_hash,
};
use op_alloy_network::Optimism;
use op_alloy_rpc_types::OpTransactionReceipt;
use p256::ecdsa::{
    Signature as P256Signature, SigningKey as P256SigningKey,
    VerifyingKey as P256VerifyingKey, signature::hazmat::PrehashSigner,
};
use secp256k1::{Message, SECP256K1, SecretKey};
use sha2::{Digest, Sha256};

// ── Spec-fixed addresses (op-alloy fork) ─────────────────────────────────────
//
// Mirrored from `op_alloy_consensus::transaction::eip8130::predeploys`. We
// don't import the module to keep the SDK's public-API surface small.
const ECRECOVER_VERIFIER: Address =
    alloy_primitives::address!("0x0000000000000000000000000000000000000001");
const REVOKED_VERIFIER: Address =
    alloy_primitives::address!("0xffffffffffffffffffffffffffffffffffffffff");
/// `create(NativeAAP256VerifierDeployer @ 0x4210…0009, 0)` — must match
/// `op_alloy_consensus::P256_RAW_VERIFIER_ADDRESS`.
const P256_RAW_VERIFIER: Address =
    alloy_primitives::address!("0x6751c7ED0C58319e75437f8E6Dafa2d7F6b8306F");
/// `create(NativeAAWebAuthnVerifierDeployer @ 0x4210…000a, 0)` — must match
/// `op_alloy_consensus::P256_WEBAUTHN_VERIFIER_ADDRESS`.
const P256_WEBAUTHN_VERIFIER: Address =
    alloy_primitives::address!("0x3572bb3F611a40DDcA70e5b55Cc797D58357AD44");
/// `create(NativeAADelegateVerifierDeployer @ 0x4210…000c, 0)` — must match
/// `op_alloy_consensus::DELEGATE_VERIFIER_ADDRESS`.
const DELEGATE_VERIFIER: Address =
    alloy_primitives::address!("0xc758A89C53542164aaB7f6439e8c8cAcf628fF62");
/// AccountConfiguration contract — also the CREATE2 deployer for new
/// accounts via `createAccount(salt, bytecode, owners)`.
const ACCOUNT_CONFIG: Address =
    alloy_primitives::address!("0xf946601D5424118A4e4054BB0B13133f216b4FeE");

const OP_AUTHORIZE_OWNER: u8 = 0x01;
const OP_REVOKE_OWNER: u8 = 0x02;
const SCOPE_UNRESTRICTED: u8 = 0x00;

#[derive(Debug, Parser)]
#[command(version, about = "EIP-8130 (Native AA) transaction sender")]
struct Args {
    /// JSON-RPC endpoint of the L2 node (e.g. http://localhost:8123).
    #[arg(long)]
    rpc_url: url::Url,

    /// L2 chain ID.
    #[arg(long)]
    chain_id: u64,

    /// Sender private key (hex, 0x-prefix optional).
    #[arg(long)]
    private_key: String,

    /// Configured-owner mode: explicit `from` address. Omit for EOA mode
    /// (the sender is recovered from `sender_auth` via ecrecover).
    #[arg(long)]
    from: Option<Address>,

    // ── calls ────────────────────────────────────────────────────────────
    /// Single-call shorthand: equivalent to `--phase "<to>,<data>"`.
    /// Mutually exclusive with `--phase`.
    #[arg(long, conflicts_with = "phase")]
    to: Option<Address>,

    /// Calldata for `--to`. Defaults to empty bytes.
    #[arg(long, default_value = "0x", requires = "to")]
    data: String,

    /// One phase, repeatable. Format: `"to,data[;to,data;…]"`. Each phase
    /// is atomic; if any call inside reverts, all calls in that phase
    /// revert and later phases are skipped.
    #[arg(long, value_name = "to,data[;to,data]")]
    phase: Vec<String>,

    // ── gas / fees ───────────────────────────────────────────────────────
    /// Total tx gas budget reserved for the call phases. The protocol adds
    /// intrinsic + auth costs on top automatically.
    #[arg(long, default_value_t = 100_000_u64)]
    gas_limit: u64,

    /// Max fee per gas, gwei.
    #[arg(long)]
    max_fee_gwei: u128,

    /// Priority fee per gas, gwei.
    #[arg(long)]
    priority_fee_gwei: u128,

    // ── nonce ────────────────────────────────────────────────────────────
    /// 2D nonce channel (uint256 decimal or 0x-hex). Default 0.
    #[arg(long, default_value = "0", conflicts_with = "nonce_free")]
    nonce_key: String,

    /// Sequence number within the channel. Mutually exclusive with
    /// `--auto-nonce`.
    #[arg(long, conflicts_with = "auto_nonce", conflicts_with = "nonce_free")]
    nonce_sequence: Option<u64>,

    /// Read the next sequence from `NONCE_MANAGER_ADDRESS.getNonce()`.
    #[arg(long, conflicts_with = "nonce_sequence")]
    auto_nonce: bool,

    /// Shortcut for `nonce_key = NONCE_KEY_MAX` (nonce-free mode).
    /// Requires `--expiry` non-zero. `nonce_sequence` is forced to 0.
    #[arg(long)]
    nonce_free: bool,

    // ── expiry ───────────────────────────────────────────────────────────
    /// Unix timestamp in seconds. 0 = no expiry. Required (>0) for
    /// `--nonce-free`.
    #[arg(long, default_value_t = 0_u64)]
    expiry: u64,

    // ── payer ────────────────────────────────────────────────────────────
    /// Sponsor address. Pair with either `--payer-key` (sign fresh) or
    /// `--payer-auth-hex` (inject pre-built bytes — used by cross-sender
    /// replay tests).
    #[arg(long)]
    payer: Option<Address>,

    /// Sponsor private key, used to sign `payer_auth` against the payer
    /// signature hash (which substitutes the resolved sender into `from`).
    #[arg(long, requires = "payer", conflicts_with = "payer_auth_hex")]
    payer_key: Option<String>,

    /// Pre-built `payer_auth` bytes (hex). When set, the SDK uses these
    /// verbatim as `tx.payer_auth` instead of signing a fresh one. The
    /// expected shape is `verifier(20) || data`. Useful for replay
    /// regression tests that need to reuse a payer signature originally
    /// produced for a different sender.
    #[arg(long, requires = "payer", conflicts_with = "payer_key")]
    payer_auth_hex: Option<String>,

    /// Pre-built `sender_auth` bytes (hex). When set, the SDK skips
    /// signing and uses these verbatim. Used by negative tests that need
    /// to inject malformed or replayed sender signatures.
    #[arg(long)]
    sender_auth_hex: Option<String>,

    // ── account changes ──────────────────────────────────────────────────
    /// Add a delegation entry to `account_changes`. Repeatable; use
    /// `0x000…000` to clear an existing delegation. The protocol limits
    /// at most one delegation entry per tx — passing multiple is useful
    /// for negative tests.
    #[arg(long)]
    delegation_target: Vec<Address>,

    /// Add a config-change entry that revokes the implicit EOA owner
    /// (writes `REVOKED_VERIFIER` for `ownerId == bytes20(account)`).
    #[arg(long)]
    revoke_eoa_owner: bool,

    /// Authorize a new owner via config change. Format:
    /// `<verifier>:<ownerId>:<scope>` where scope is hex (e.g. 0x02).
    /// Repeatable to authorize multiple owners in one entry.
    #[arg(long, value_name = "verifier:ownerId:scope")]
    config_authorize: Vec<String>,

    /// Revoke a non-implicit owner via config change. Pass the ownerId
    /// (32-byte hex). Repeatable.
    #[arg(long, value_name = "ownerId")]
    config_revoke: Vec<String>,

    /// Sequence number for the config-change entry. Default 0 (first
    /// change ever made for this account).
    #[arg(long, default_value_t = 0_u64)]
    config_sequence: u64,

    /// `chain_id` field in the config-change entry. 0 = multi-chain
    /// (uses the account's multichain sequence channel). Defaults to the
    /// tx chain_id (chain-specific channel).
    #[arg(long)]
    config_chain_id: Option<u64>,

    /// Authorizer private key for signing the SignedOwnerChanges
    /// EIP-712 digest. Defaults to `--private-key` (the implicit EOA
    /// owner has CONFIG scope by default).
    #[arg(long)]
    authorizer_key: Option<String>,

    /// Authorize a P256-raw owner via config change. Format: `<p256_priv_hex32>:<scope_hex>`.
    /// SDK derives `pubkey(64)` from the private key and sets
    /// `ownerId = keccak256(pubkey)`, `verifier = P256_RAW_VERIFIER`. Repeatable.
    #[arg(long, value_name = "p256_priv:scope")]
    config_authorize_p256: Vec<String>,

    /// Authorize a P256-WebAuthn owner. Format: `<p256_priv_hex32>:<scope_hex>`.
    /// SDK derives `pubkey(64)` and sets `ownerId = keccak256(pubkey)`,
    /// `verifier = P256_WEBAUTHN_VERIFIER`. ownerId matches raw P256 — only
    /// the verifier address differs.
    #[arg(long, value_name = "p256_priv:scope")]
    config_authorize_webauthn: Vec<String>,

    /// Authorize a Delegate owner. Format: `<k1_priv_hex32>:<scope_hex>`.
    /// SDK derives the delegate's K1 address and sets
    /// `ownerId = bytes32(bytes20(delegate_addr))`, `verifier = DELEGATE_VERIFIER`.
    /// The delegate's K1 EOA can later sign `sender_auth` via the implicit-EOA
    /// nested path (`--sender-delegate-key`).
    #[arg(long, value_name = "delegate_k1_priv:scope")]
    config_authorize_delegate: Vec<String>,

    // ── P256 sender ──────────────────────────────────────────────────────
    /// Sign `sender_auth` with a P256 raw key instead of K1. When set, the
    /// envelope becomes `P256_RAW_VERIFIER || pubkey(64) || sig(64)` and the
    /// resolved owner is `keccak256(pubkey)`. Requires `--from` (configured-
    /// owner mode) — P256 doesn't recover an address, so EOA mode is N/A.
    #[arg(long, requires = "from")]
    sender_p256_key: Option<String>,

    /// Sign `sender_auth` with a P256 WebAuthn envelope. Same key format as
    /// `--sender-p256-key`. Builds:
    /// `P256_WEBAUTHN_VERIFIER(20) || pubkey(64) || authData(37) ||
    ///   cdLen(4 BE) || clientDataJSON || sig(64)` where the JSON challenge
    /// is `base64url(sender_signature_hash)` and the signed message is
    /// `sha256(authData || sha256(clientDataJSON))`.
    #[arg(long, requires = "from")]
    sender_webauthn_key: Option<String>,

    /// Sign `sender_auth` via Delegate (1-hop) — implicit-EOA inner path.
    /// Pass the K1 secret key of the delegate's EOA. SDK derives delegate
    /// address, signs `sender_signature_hash` with K1, and builds:
    /// `DELEGATE_VERIFIER(20) || delegate_addr(20) || 0x000…00(20) || sig(65)`.
    /// Requires `--from` (the account address whose owner registered this
    /// delegate via `--config-authorize-delegate`).
    #[arg(long, requires = "from")]
    sender_delegate_key: Option<String>,

    // ── Account creation (account_changes type 0x00) ───────────────────
    /// Append a CREATE2 account-creation entry. Format:
    /// `<salt_hex32>:<owner_spec>[,<owner_spec>...]` where each owner_spec
    /// is one of:
    ///   - `k1:<addr>:<scope>`           (implicit EOA owner — ownerId = bytes20(addr))
    ///   - `p256:<priv_hex32>:<scope>`   (P256 raw — ownerId = keccak256(pubkey))
    ///   - `webauthn:<priv_hex32>:<scope>` (WebAuthn — same ownerId as p256)
    ///   - `delegate:<k1_priv_hex32>:<scope>` (Delegate)
    /// SDK uses empty bytecode by default (writes the registrations only).
    /// Repeatable for multi-account creates. Prints the predicted CREATE2
    /// address per spec `derive_account_address`.
    #[arg(long, value_name = "salt:owner_spec[,owner_spec]")]
    account_create: Vec<String>,

    // ── output ───────────────────────────────────────────────────────────
    /// Don't broadcast — just print the encoded tx hex and exit.
    #[arg(long)]
    dry_run: bool,
}

#[tokio::main]
async fn main() -> Result<()> {
    let args = Args::parse();

    // ---- 1. Decode keys + fees + nonce key ------------------------------
    let secret_key = parse_secret_key(&args.private_key)?;
    let sender_addr = derive_address(&secret_key);
    let resolved_sender = args.from.unwrap_or(sender_addr);
    println!("Sender (resolved): {resolved_sender}");

    let max_fee = args.max_fee_gwei.saturating_mul(1_000_000_000);
    let priority_fee = args.priority_fee_gwei.saturating_mul(1_000_000_000);
    if priority_fee > max_fee {
        bail!("--priority-fee-gwei must not exceed --max-fee-gwei");
    }

    let nonce_key = if args.nonce_free { NONCE_KEY_MAX } else { parse_u256(&args.nonce_key)? };
    if args.nonce_free && args.expiry == 0 {
        bail!("--nonce-free requires --expiry > 0 (replay protection)");
    }

    // ---- 2. Build provider (Optimism network) for both nonce queries
    //         and broadcast. ---------------------------------------------
    let provider =
        ProviderBuilder::new().network::<Optimism>().connect_http(args.rpc_url.clone());

    // ---- 3. Resolve nonce sequence --------------------------------------
    let nonce_sequence = if args.nonce_free {
        0
    } else if args.auto_nonce {
        let seq = read_nonce(&provider, resolved_sender, nonce_key).await?;
        println!("auto-nonce: getNonce({resolved_sender}, {nonce_key}) = {seq}");
        seq
    } else {
        args.nonce_sequence.ok_or_else(|| {
            eyre::eyre!("provide --nonce-sequence, --auto-nonce, or --nonce-free")
        })?
    };

    // ---- 4. Build calls --------------------------------------------------
    let calls = build_calls(&args)?;

    // ---- 5. Build account_changes ----------------------------------------
    let account_changes = build_account_changes(&args, resolved_sender, &secret_key)?;

    // ---- 6. Assemble unsigned tx -----------------------------------------
    let mut tx = TxEip8130 {
        chain_id: args.chain_id,
        from: args.from,
        nonce_key,
        nonce_sequence,
        expiry: args.expiry,
        max_priority_fee_per_gas: priority_fee,
        max_fee_per_gas: max_fee,
        gas_limit: args.gas_limit,
        account_changes,
        calls,
        payer: args.payer,
        sender_auth: Bytes::new(),
        payer_auth: Bytes::new(),
    };

    // ---- 7. Sign sender_auth --------------------------------------------
    let sender_hash = sender_signature_hash(&tx);
    if let Some(raw_hex) = args.sender_auth_hex.as_ref() {
        // Negative-test path: inject pre-built sender_auth verbatim.
        tx.sender_auth = parse_hex_bytes(raw_hex)?;
    } else if let Some(p256_hex) = args.sender_p256_key.as_ref() {
        // P256 raw: envelope is `P256_RAW_VERIFIER || pubkey(64) || sig(64)`.
        let p256_sk = parse_p256_secret_key(p256_hex)?;
        let pubkey = p256_pubkey_raw(&p256_sk);
        let sig = sign_p256_prehash(&p256_sk, sender_hash)?;
        let mut buf = Vec::with_capacity(20 + 64 + 64);
        buf.extend_from_slice(P256_RAW_VERIFIER.as_slice());
        buf.extend_from_slice(&pubkey);
        buf.extend_from_slice(&sig);
        tx.sender_auth = Bytes::from(buf);
        println!("p256 ownerId (expected registered): {}", p256_owner_id(&p256_sk));
    } else if let Some(p256_hex) = args.sender_webauthn_key.as_ref() {
        // WebAuthn: P256_WEBAUTHN_VERIFIER || (pubkey || authData || cdLen || cd || sig).
        let p256_sk = parse_p256_secret_key(p256_hex)?;
        let data = build_webauthn_data(&p256_sk, sender_hash)?;
        let mut buf = Vec::with_capacity(20 + data.len());
        buf.extend_from_slice(P256_WEBAUTHN_VERIFIER.as_slice());
        buf.extend_from_slice(&data);
        tx.sender_auth = Bytes::from(buf);
        println!("webauthn ownerId (expected registered): {}", p256_owner_id(&p256_sk));
    } else if let Some(k1_hex) = args.sender_delegate_key.as_ref() {
        // Delegate (1-hop, implicit-EOA inner): DELEGATE_VERIFIER || delegate_addr || 0x0 || sig65.
        let delegate_sk = parse_secret_key(k1_hex)?;
        let data = build_delegate_data(&delegate_sk, sender_hash)?;
        let mut buf = Vec::with_capacity(20 + data.len());
        buf.extend_from_slice(DELEGATE_VERIFIER.as_slice());
        buf.extend_from_slice(&data);
        tx.sender_auth = Bytes::from(buf);
        println!("delegate ownerId (expected registered): {}", delegate_owner_id(&delegate_sk));
    } else {
        let sender_sig = sign_hash(&secret_key, sender_hash)?;
        tx.sender_auth = match tx.from {
            // EOA mode: raw 65-byte ECDSA.
            None => Bytes::from(sender_sig.to_vec()),
            // Configured-owner mode: verifier(20) || data. We default to
            // ECRECOVER_VERIFIER which interprets `data` as r||s||v.
            Some(_) => {
                let mut buf = Vec::with_capacity(20 + 65);
                buf.extend_from_slice(ECRECOVER_VERIFIER.as_slice());
                buf.extend_from_slice(&sender_sig);
                Bytes::from(buf)
            }
        };
    }
    println!("sender_signature_hash: {sender_hash}");

    // ---- 8. Optional sponsored payer_auth -------------------------------
    if let Some(payer_addr) = args.payer {
        if let Some(raw_hex) = args.payer_auth_hex.as_ref() {
            // Replay path: inject pre-built payer_auth bytes verbatim.
            let raw = parse_hex_bytes(raw_hex)?;
            tx.payer_auth = raw;
            println!("payer_auth: <injected {} bytes>", tx.payer_auth.len());
        } else {
            let payer_sk = parse_secret_key(
                args.payer_key
                    .as_ref()
                    .ok_or_else(|| eyre::eyre!("--payer requires --payer-key or --payer-auth-hex"))?,
            )?;

            // Per EIP-8130 §"Signature Payload" + §"Cross-sender Payer Replay",
            // the payer hash binds to the resolved sender. The fork's
            // `payer_signature_hash(&tx, resolved_sender)` performs the
            // substitution internally — pass the recovered EOA addr (or
            // the explicit configured owner addr) so the hash on signing
            // side matches what the validator computes.
            let resolved_sender = tx.from.unwrap_or(sender_addr);
            let payer_hash = payer_signature_hash(&tx, resolved_sender);
            let payer_sig = sign_hash(&payer_sk, payer_hash)?;
            // Same envelope shape as configured-owner sender_auth: the
            // payer is always treated as a configured owner of
            // `payer_addr` (even when sponsoring an EOA-mode tx).
            let mut buf = Vec::with_capacity(20 + 65);
            buf.extend_from_slice(ECRECOVER_VERIFIER.as_slice());
            buf.extend_from_slice(&payer_sig);
            tx.payer_auth = Bytes::from(buf);

            let payer_derived = derive_address(&payer_sk);
            if payer_derived != payer_addr {
                println!(
                    "warning: --payer ({payer_addr}) != address derived from --payer-key ({payer_derived})"
                );
            }
            println!("payer_signature_hash: {payer_hash}");
        }
    }

    // ---- 9. RLP-encode --------------------------------------------------
    let mut encoded = Vec::with_capacity(tx.encode_2718_len());
    tx.encode_2718(&mut encoded);

    if args.dry_run {
        // Dry-run is the "build mode" — emit a single-line JSON record so
        // automation (replay tests, fixture builders, etc.) can pipe the
        // output through `jq`/Python without screen-scraping debug lines.
        let record = serde_json::json!({
            "tx_type": format!("0x{:02x}", AA_TX_TYPE_ID),
            "encoded": format!("0x{}", hex::encode(&encoded)),
            "encoded_len": encoded.len(),
            "sender_auth": format!("0x{}", hex::encode(&tx.sender_auth)),
            "payer_auth": format!("0x{}", hex::encode(&tx.payer_auth)),
            "sender_signature_hash": format!("{sender_hash}"),
            "resolved_sender": format!("{resolved_sender}"),
        });
        println!("{record}");
        return Ok(());
    }

    println!(
        "encoded tx ({} bytes, type 0x{:02x}): 0x{}",
        encoded.len(),
        AA_TX_TYPE_ID,
        hex::encode(&encoded)
    );

    // ---- 10. Broadcast + receipt ----------------------------------------
    let pending = provider
        .send_raw_transaction(&encoded)
        .await
        .context("eth_sendRawTransaction failed")?;
    let tx_hash = *pending.tx_hash();
    println!("submitted: {tx_hash}");

    let receipt: OpTransactionReceipt =
        pending.get_receipt().await.context("waiting for tx receipt")?;
    print_receipt_summary(&receipt);

    Ok(())
}

// ── building blocks ─────────────────────────────────────────────────────────

fn build_calls(args: &Args) -> Result<Vec<Vec<Call>>> {
    if let Some(to) = args.to {
        let data = parse_hex_bytes(&args.data)?;
        return Ok(vec![vec![Call { to, data }]]);
    }
    if args.phase.is_empty() {
        // Empty calls is legal — useful for nonce bumps or pure
        // account-changes transactions.
        return Ok(vec![]);
    }
    let mut phases = Vec::with_capacity(args.phase.len());
    for (idx, raw_phase) in args.phase.iter().enumerate() {
        let mut calls_in_phase = Vec::new();
        for (call_idx, raw_call) in raw_phase.split(';').enumerate() {
            let raw_call = raw_call.trim();
            if raw_call.is_empty() {
                continue;
            }
            let (to_str, data_str) = raw_call
                .split_once(',')
                .ok_or_else(|| eyre::eyre!("phase {idx} call {call_idx}: expected `to,data`"))?;
            let to = Address::from_str(to_str.trim()).context("phase: invalid `to`")?;
            let data = parse_hex_bytes(data_str.trim())?;
            calls_in_phase.push(Call { to, data });
        }
        phases.push(calls_in_phase);
    }
    Ok(phases)
}

fn build_account_changes(
    args: &Args,
    resolved_sender: Address,
    sender_secret: &SecretKey,
) -> Result<Vec<AccountChangeEntry>> {
    let mut entries = Vec::new();

    // Collect owner-change operations from CLI flags.
    let mut owner_changes: Vec<OwnerChange> = Vec::new();

    if args.revoke_eoa_owner {
        let mut self_owner_id_bytes = [0u8; 32];
        self_owner_id_bytes[..20].copy_from_slice(resolved_sender.as_slice());
        owner_changes.push(OwnerChange {
            change_type: OP_REVOKE_OWNER,
            verifier: REVOKED_VERIFIER,
            owner_id: B256::from(self_owner_id_bytes),
            scope: SCOPE_UNRESTRICTED,
        });
    }

    for raw in &args.config_authorize {
        // Format: <verifier>:<ownerId>:<scope>
        let parts: Vec<&str> = raw.splitn(3, ':').collect();
        if parts.len() != 3 {
            bail!("--config-authorize expects `verifier:ownerId:scope`, got `{raw}`");
        }
        let verifier = Address::from_str(parts[0].trim()).context("config-authorize verifier")?;
        let owner_id = parse_b256(parts[1].trim()).context("config-authorize ownerId")?;
        let scope_bytes = parse_hex_bytes(parts[2].trim())?;
        if scope_bytes.len() != 1 {
            bail!("--config-authorize scope must be a single hex byte (e.g. 0x02)");
        }
        owner_changes.push(OwnerChange {
            change_type: OP_AUTHORIZE_OWNER,
            verifier,
            owner_id,
            scope: scope_bytes[0],
        });
    }

    for raw in &args.config_revoke {
        let owner_id = parse_b256(raw.trim()).context("config-revoke ownerId")?;
        owner_changes.push(OwnerChange {
            change_type: OP_REVOKE_OWNER,
            verifier: REVOKED_VERIFIER,
            owner_id,
            scope: SCOPE_UNRESTRICTED,
        });
    }

    // P256-raw shortcut: `<p256_priv_hex32>:<scope_hex>` → derive pubkey, set
    // `ownerId = keccak256(pubkey)`, verifier = `P256_RAW_VERIFIER`.
    for raw in &args.config_authorize_p256 {
        let parts: Vec<&str> = raw.splitn(2, ':').collect();
        if parts.len() != 2 {
            bail!("--config-authorize-p256 expects `p256_priv:scope`, got `{raw}`");
        }
        let p256_sk = parse_p256_secret_key(parts[0].trim())?;
        let scope_bytes = parse_hex_bytes(parts[1].trim())?;
        if scope_bytes.len() != 1 {
            bail!("--config-authorize-p256 scope must be a single hex byte (e.g. 0x02)");
        }
        owner_changes.push(OwnerChange {
            change_type: OP_AUTHORIZE_OWNER,
            verifier: P256_RAW_VERIFIER,
            owner_id: p256_owner_id(&p256_sk),
            scope: scope_bytes[0],
        });
    }

    // WebAuthn shortcut: same key/ownerId as raw but verifier differs.
    for raw in &args.config_authorize_webauthn {
        let parts: Vec<&str> = raw.splitn(2, ':').collect();
        if parts.len() != 2 {
            bail!("--config-authorize-webauthn expects `p256_priv:scope`, got `{raw}`");
        }
        let p256_sk = parse_p256_secret_key(parts[0].trim())?;
        let scope_bytes = parse_hex_bytes(parts[1].trim())?;
        if scope_bytes.len() != 1 {
            bail!("--config-authorize-webauthn scope must be a single hex byte");
        }
        owner_changes.push(OwnerChange {
            change_type: OP_AUTHORIZE_OWNER,
            verifier: P256_WEBAUTHN_VERIFIER,
            owner_id: p256_owner_id(&p256_sk),
            scope: scope_bytes[0],
        });
    }

    // Delegate shortcut: derive K1 addr from the delegate's secret; ownerId =
    // bytes32(bytes20(delegate_addr)); verifier = DELEGATE_VERIFIER.
    for raw in &args.config_authorize_delegate {
        let parts: Vec<&str> = raw.splitn(2, ':').collect();
        if parts.len() != 2 {
            bail!("--config-authorize-delegate expects `delegate_k1_priv:scope`, got `{raw}`");
        }
        let delegate_sk = parse_secret_key(parts[0].trim())?;
        let scope_bytes = parse_hex_bytes(parts[1].trim())?;
        if scope_bytes.len() != 1 {
            bail!("--config-authorize-delegate scope must be a single hex byte");
        }
        owner_changes.push(OwnerChange {
            change_type: OP_AUTHORIZE_OWNER,
            verifier: DELEGATE_VERIFIER,
            owner_id: delegate_owner_id(&delegate_sk),
            scope: scope_bytes[0],
        });
    }

    if !owner_changes.is_empty() {
        let chain_id = args.config_chain_id.unwrap_or(args.chain_id);
        let mut entry = ConfigChangeEntry {
            chain_id,
            sequence: args.config_sequence,
            owner_changes,
            // Signed below — placeholder for digest computation.
            authorizer_auth: Bytes::new(),
        };

        // Sign the EIP-712 SignedOwnerChanges digest with the authorizer
        // key (defaults to --private-key). The default authorizer is the
        // implicit EOA owner, which has unrestricted (CONFIG-included)
        // scope. Pack auth as `K1_VERIFIER || sig(65)` per the spec
        // signature format.
        let authorizer_sk = match args.authorizer_key.as_ref() {
            Some(s) => parse_secret_key(s)?,
            None => *sender_secret,
        };
        let digest = config_change_digest(resolved_sender, &entry);
        let sig = sign_hash(&authorizer_sk, digest)?;
        let mut auth = Vec::with_capacity(20 + 65);
        auth.extend_from_slice(ECRECOVER_VERIFIER.as_slice());
        auth.extend_from_slice(&sig);
        entry.authorizer_auth = Bytes::from(auth);

        entries.push(AccountChangeEntry::ConfigChange(entry));
    }

    for target in &args.delegation_target {
        entries.push(AccountChangeEntry::Delegation(DelegationEntry { target: *target }));
    }

    for raw in &args.account_create {
        let (salt_str, owners_str) = raw.split_once(':').ok_or_else(|| {
            eyre::eyre!("--account-create expects `salt:owner_spec[,owner_spec]`, got `{raw}`")
        })?;
        let user_salt = parse_b256(salt_str.trim())?;
        let mut initial_owners = Vec::new();
        for spec in owners_str.split(',') {
            initial_owners.push(parse_owner_spec(spec.trim())?);
        }
        let bytecode = Bytes::new();
        let predicted = derive_account_address(ACCOUNT_CONFIG, user_salt, &bytecode, &initial_owners);
        println!("account-create predicted addr: {predicted} (salt={user_salt}, owners={})", initial_owners.len());
        entries.push(AccountChangeEntry::Create(CreateEntry {
            user_salt,
            bytecode,
            initial_owners,
        }));
    }

    Ok(entries)
}

/// Parse a single `--account-create` owner spec.
fn parse_owner_spec(spec: &str) -> Result<Owner> {
    let parts: Vec<&str> = spec.split(':').collect();
    let kind = parts.first().copied().unwrap_or("");
    match kind {
        "k1" => {
            if parts.len() != 3 {
                bail!("k1 spec expects `k1:<addr>:<scope>`, got `{spec}`");
            }
            let addr = Address::from_str(parts[1].trim()).context("k1 addr")?;
            let scope = parse_scope_byte(parts[2])?;
            let mut owner_id = [0u8; 32];
            owner_id[..20].copy_from_slice(addr.as_slice());
            Ok(Owner {
                verifier: ECRECOVER_VERIFIER,
                owner_id: B256::from(owner_id),
                scope,
            })
        }
        "p256" => {
            if parts.len() != 3 {
                bail!("p256 spec expects `p256:<priv>:<scope>`, got `{spec}`");
            }
            let sk = parse_p256_secret_key(parts[1].trim())?;
            let scope = parse_scope_byte(parts[2])?;
            Ok(Owner {
                verifier: P256_RAW_VERIFIER,
                owner_id: p256_owner_id(&sk),
                scope,
            })
        }
        "webauthn" => {
            if parts.len() != 3 {
                bail!("webauthn spec expects `webauthn:<priv>:<scope>`, got `{spec}`");
            }
            let sk = parse_p256_secret_key(parts[1].trim())?;
            let scope = parse_scope_byte(parts[2])?;
            Ok(Owner {
                verifier: P256_WEBAUTHN_VERIFIER,
                owner_id: p256_owner_id(&sk),
                scope,
            })
        }
        "delegate" => {
            if parts.len() != 3 {
                bail!("delegate spec expects `delegate:<k1_priv>:<scope>`, got `{spec}`");
            }
            let sk = parse_secret_key(parts[1].trim())?;
            let scope = parse_scope_byte(parts[2])?;
            Ok(Owner {
                verifier: DELEGATE_VERIFIER,
                owner_id: delegate_owner_id(&sk),
                scope,
            })
        }
        _ => bail!("unknown owner kind `{kind}` in spec `{spec}` (expected k1|p256|webauthn|delegate)"),
    }
}

fn parse_scope_byte(s: &str) -> Result<u8> {
    let bytes = parse_hex_bytes(s.trim())?;
    if bytes.len() != 1 {
        bail!("scope must be a single hex byte (e.g. 0x02), got `{s}`");
    }
    Ok(bytes[0])
}

// ── nonce + receipt ─────────────────────────────────────────────────────────

/// Read the next nonce sequence for `(account, nonce_key)`.
///
/// Uses the EIP-8130 extension to `eth_getTransactionCount`: when called
/// with a third positional `nonceKey` (hex U256), the node returns the
/// 2D nonce read from `NONCE_MANAGER_ADDRESS`. The precompile itself
/// only has a 0xfe stub byte exposed to the EVM (to avoid EIP-161
/// pruning), so direct `eth_call` is not supported.
async fn read_nonce<P: Provider<Optimism>>(
    provider: &P,
    account: Address,
    nonce_key: U256,
) -> Result<u64> {
    let req = serde_json::json!([
        account,
        "latest",
        format!("0x{:x}", nonce_key),
    ]);
    let raw_hex: String = provider
        .raw_request("eth_getTransactionCount".into(), req)
        .await
        .context("eth_getTransactionCount(account, latest, nonceKey) failed")?;
    let stripped = raw_hex.trim_start_matches("0x");
    let parsed = u64::from_str_radix(if stripped.is_empty() { "0" } else { stripped }, 16)
        .context("invalid hex nonce")?;
    Ok(parsed)
}

fn print_receipt_summary(r: &OpTransactionReceipt) {
    use alloy_consensus::TxReceipt;

    let block = r.inner.block_number.unwrap_or_default();
    let tx_type: u8 = r.inner.inner.receipt.tx_type().into();
    let status = r.inner.inner.status();
    let gas_used = r.inner.gas_used;
    let logs = r.inner.inner.logs().len();
    let (payer, phases) = match &r.eip8130_fields {
        Some(f) => (
            format!("{}", f.payer),
            format!("{:?}", f.phase_statuses.as_deref().unwrap_or(&[])),
        ),
        None => ("(none)".into(), "(none)".into()),
    };
    println!(
        "mined in block {block} (type=0x{tx_type:02x}, status={}, gasUsed={gas_used}, logs={logs}, payer={payer}, phaseStatuses={phases})",
        if status { "success" } else { "reverted" },
    );
}

// ── parsing helpers ─────────────────────────────────────────────────────────

fn parse_secret_key(s: &str) -> Result<SecretKey> {
    let trimmed = s.strip_prefix("0x").unwrap_or(s);
    let bytes = hex::decode(trimmed).context("invalid hex private key")?;
    if bytes.len() != 32 {
        bail!("private key must be 32 bytes, got {}", bytes.len());
    }
    SecretKey::from_byte_array(bytes.as_slice().try_into().unwrap())
        .context("invalid secp256k1 secret key")
}

fn parse_hex_bytes(s: &str) -> Result<Bytes> {
    let trimmed = s.strip_prefix("0x").unwrap_or(s);
    if trimmed.is_empty() {
        return Ok(Bytes::new());
    }
    let bytes = hex::decode(trimmed).context("invalid hex bytes")?;
    Ok(Bytes::from(bytes))
}

fn parse_b256(s: &str) -> Result<B256> {
    let trimmed = s.strip_prefix("0x").unwrap_or(s);
    let bytes = hex::decode(trimmed).context("invalid hex bytes")?;
    if bytes.len() != 32 {
        bail!("expected 32-byte hex (got {} bytes)", bytes.len());
    }
    Ok(B256::from_slice(&bytes))
}

fn parse_u256(s: &str) -> Result<U256> {
    let s = s.trim();
    if let Some(stripped) = s.strip_prefix("0x").or_else(|| s.strip_prefix("0X")) {
        U256::from_str_radix(stripped, 16).context("invalid hex U256")
    } else {
        U256::from_str(s).context("invalid decimal U256")
    }
}

fn derive_address(sk: &SecretKey) -> Address {
    let pk = secp256k1::PublicKey::from_secret_key(SECP256K1, sk);
    let uncompressed = pk.serialize_uncompressed();
    let hash = alloy_primitives::keccak256(&uncompressed[1..]);
    Address::from_slice(&hash[12..])
}

/// Sign `hash` with `sk` and return 65 bytes `r||s||v` where `v = 27 + recid`.
fn sign_hash(sk: &SecretKey, hash: B256) -> Result<[u8; 65]> {
    let msg = Message::from_digest(hash.0);
    let recoverable = SECP256K1.sign_ecdsa_recoverable(msg, sk);
    let (recid, compact) = recoverable.serialize_compact();
    let mut out = [0u8; 65];
    out[..64].copy_from_slice(&compact);
    out[64] = 27_u8 + i32::from(recid) as u8;
    Ok(out)
}

// ── P256 helpers ────────────────────────────────────────────────────────────

/// Parse a 32-byte hex-encoded P256 private key into a `SigningKey`.
fn parse_p256_secret_key(s: &str) -> Result<P256SigningKey> {
    let trimmed = s.strip_prefix("0x").unwrap_or(s);
    let bytes = hex::decode(trimmed).context("invalid hex P256 private key")?;
    if bytes.len() != 32 {
        bail!("P256 private key must be 32 bytes, got {}", bytes.len());
    }
    let arr: [u8; 32] = bytes.as_slice().try_into().unwrap();
    P256SigningKey::from_bytes(&arr.into()).context("invalid P256 secret key")
}

/// Returns the 64-byte uncompressed public key (`x||y`, the 0x04 prefix dropped),
/// matching the `data` layout `pubkey(64) || sig(64)` that
/// `P256_RAW_VERIFIER` expects.
fn p256_pubkey_raw(sk: &P256SigningKey) -> [u8; 64] {
    let pk = P256VerifyingKey::from(sk).to_encoded_point(false);
    let raw = &pk.as_bytes()[1..];
    let mut out = [0u8; 64];
    out.copy_from_slice(raw);
    out
}

/// Sign `hash` with a P256 raw key. Returns the 64-byte `r||s` IEEE-P1363 form
/// that the verifier parses.
fn sign_p256_prehash(sk: &P256SigningKey, hash: B256) -> Result<[u8; 64]> {
    let (sig, _recid): (P256Signature, _) =
        sk.sign_prehash(hash.as_slice()).context("P256 prehash sign failed")?;
    let bytes = sig.to_bytes();
    let mut out = [0u8; 64];
    out.copy_from_slice(&bytes);
    Ok(out)
}

/// `ownerId = keccak256(pubkey(64))` — matches `P256_RAW_VERIFIER`'s return.
fn p256_owner_id(sk: &P256SigningKey) -> B256 {
    alloy_primitives::keccak256(p256_pubkey_raw(sk))
}

// ── WebAuthn helpers ────────────────────────────────────────────────────────

/// Base64url (no padding) — RFC 4648 §5. WebAuthn `clientDataJSON.challenge`
/// uses this encoding.
fn base64_url_encode(bytes: &[u8]) -> String {
    const TABLE: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let b0 = chunk[0] as u32;
        let b1 = if chunk.len() > 1 { chunk[1] as u32 } else { 0 };
        let b2 = if chunk.len() > 2 { chunk[2] as u32 } else { 0 };
        let triple = (b0 << 16) | (b1 << 8) | b2;
        out.push(TABLE[((triple >> 18) & 0x3F) as usize] as char);
        out.push(TABLE[((triple >> 12) & 0x3F) as usize] as char);
        if chunk.len() > 1 {
            out.push(TABLE[((triple >> 6) & 0x3F) as usize] as char);
        }
        if chunk.len() > 2 {
            out.push(TABLE[(triple & 0x3F) as usize] as char);
        }
    }
    out
}

/// Build a P256 WebAuthn `data` payload that the verifier will accept.
///
/// Layout: `pubkey(64) || authData(37) || cdLen(4 BE) || clientDataJSON || sig(64)`.
/// The `sender_signature_hash` (`hash`) is encoded into `clientDataJSON.challenge`
/// as base64url; the signed message is `sha256(authData || sha256(clientDataJSON))`.
fn build_webauthn_data(sk: &P256SigningKey, hash: B256) -> Result<Vec<u8>> {
    let pubkey = p256_pubkey_raw(sk);
    // Minimum-viable authenticatorData: 32-byte rpIdHash (any) + flags (UP=0x01)
    // + 4-byte signCount = 37 bytes. Verifier doesn't enforce specific bits.
    let mut auth_data = [0u8; 37];
    auth_data[32] = 0x01; // UP (User Present) flag set
    let challenge_b64 = base64_url_encode(hash.as_slice());
    let client_data_json = format!(
        r#"{{"type":"webauthn.get","challenge":"{}","origin":"https://example.com"}}"#,
        challenge_b64,
    );
    let cd_bytes = client_data_json.as_bytes();
    // Signed message = sha256(authData || sha256(clientDataJSON))
    let cd_hash = Sha256::digest(cd_bytes);
    let mut hasher = Sha256::new();
    hasher.update(auth_data);
    hasher.update(cd_hash);
    let message = hasher.finalize();
    let (sig, _recid): (P256Signature, _) = sk
        .sign_prehash(&message)
        .context("P256 WebAuthn prehash sign failed")?;
    let sig_bytes = sig.to_bytes();

    let cd_len = (cd_bytes.len() as u32).to_be_bytes();
    let mut out = Vec::with_capacity(64 + 37 + 4 + cd_bytes.len() + 64);
    out.extend_from_slice(&pubkey);
    out.extend_from_slice(&auth_data);
    out.extend_from_slice(&cd_len);
    out.extend_from_slice(cd_bytes);
    out.extend_from_slice(&sig_bytes);
    Ok(out)
}

// ── Delegate helpers ────────────────────────────────────────────────────────

/// Build a Delegate (1-hop, implicit-EOA inner) `data` payload.
///
/// Layout: `delegate_addr(20) || inner_verifier(20=0x0…0) || sig(65)`.
/// The chain's `verify_delegate` recovers a K1 owner from the inner sig,
/// asserts it equals `delegate_addr` (implicit EOA mismatch check), then
/// returns `bytes20(delegate_addr)` as the ownerId.
fn build_delegate_data(delegate_sk: &SecretKey, hash: B256) -> Result<Vec<u8>> {
    let delegate_addr = derive_address(delegate_sk);
    let sig = sign_hash(delegate_sk, hash)?;
    let mut out = Vec::with_capacity(20 + 20 + 65);
    out.extend_from_slice(delegate_addr.as_slice());
    out.extend_from_slice(Address::ZERO.as_slice()); // implicit-EOA inner verifier
    out.extend_from_slice(&sig);
    Ok(out)
}

/// `ownerId = bytes32(bytes20(delegate_addr))` — matches Delegate verifier's return.
fn delegate_owner_id(delegate_sk: &SecretKey) -> B256 {
    let addr = derive_address(delegate_sk);
    let mut out = [0u8; 32];
    out[..20].copy_from_slice(addr.as_slice());
    B256::from(out)
}
