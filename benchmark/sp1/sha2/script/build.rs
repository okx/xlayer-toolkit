use std::path::PathBuf;

use sp1_build::{build_program_with_args, BuildArgs};

fn main() {
    let manifest_dir = PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").unwrap());
    let elf_dir = manifest_dir.join("../elf");
    let elf_dir_str = elf_dir.to_str().unwrap().to_string();

    // Build vanilla (no precompile) ELF
    build_program_with_args(
        "../program",
        BuildArgs {
            docker: false,
            elf_name: Some("sha2-program-vanilla".to_string()),
            output_directory: Some(elf_dir_str.clone()),
            ..Default::default()
        },
    );
    println!(
        "cargo:rustc-env=SP1_ELF_sha2-program-vanilla={}",
        elf_dir.join("sha2-program-vanilla").display()
    );

    // Build precompile ELF
    build_program_with_args(
        "../program",
        BuildArgs {
            docker: false,
            features: vec!["precompile".to_string()],
            elf_name: Some("sha2-program-precompile".to_string()),
            output_directory: Some(elf_dir_str),
            ..Default::default()
        },
    );
    println!(
        "cargo:rustc-env=SP1_ELF_sha2-program-precompile={}",
        elf_dir.join("sha2-program-precompile").display()
    );
}
