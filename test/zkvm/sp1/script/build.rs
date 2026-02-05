use sp1_build::{build_program_with_args, BuildArgs};

fn main() {
    // Build the fibonacci program
    build_program_with_args(
        "../program",
        BuildArgs {
            docker: true,
            tag: "v5.2.4".to_string(),
            output_directory: Some("target/elf-compilation/docker".to_string()),
            ..Default::default()
        },
    );
}
