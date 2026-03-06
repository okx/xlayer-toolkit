use sp1_build::{build_program_with_args, BuildArgs};

fn main() {
    build_program_with_args(
        "../program",
        BuildArgs {
            docker: true,
            tag: "v6.0.2".to_string(),
            output_directory: Some("target/elf-compilation/docker".to_string()),
            ..Default::default()
        },
    );
}
