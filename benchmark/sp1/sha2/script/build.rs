use sp1_build::{build_program_with_args, BuildArgs};

fn main() {
    // Build vanilla (no precompile) ELF
    build_program_with_args(
        "../program",
        BuildArgs {
            elf_name: Some("sha2-program-vanilla".to_string()),
            ..Default::default()
        },
    );

    // Build precompile ELF
    build_program_with_args(
        "../program",
        BuildArgs {
            features: vec!["precompile".to_string()],
            elf_name: Some("sha2-program-precompile".to_string()),
            ..Default::default()
        },
    );
}
