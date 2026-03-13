fn main() {
    // Declare `inline` as a valid cfg to suppress check-cfg warnings.
    println!("cargo::rustc-check-cfg=cfg(inline)");

    // Set `--cfg inline` when JOLT_INLINE env var is present.
    // This is needed because `jolt build` overrides --features and RUSTFLAGS,
    // but env vars are inherited by child processes.
    if std::env::var("JOLT_INLINE").is_ok() {
        println!("cargo:rustc-cfg=inline");
    }
    // Re-run if the env var changes
    println!("cargo:rerun-if-env-changed=JOLT_INLINE");
}
