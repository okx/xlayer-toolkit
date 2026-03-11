use sp1_build::{build_program_with_args, BuildArgs};

fn main() {
    build_program_with_args(
        "../program",
        BuildArgs {
            docker: false,
            output_directory: Some("target/elf-compilation/local".to_string()),
            ..Default::default()
        },
    );
}
