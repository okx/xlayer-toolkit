use std::collections::HashMap;

use risc0_build::{embed_methods_with_options, DockerOptionsBuilder, GuestOptionsBuilder};

fn main() {
    let opts = GuestOptionsBuilder::default()
        .use_docker(
            DockerOptionsBuilder::default()
                .root_dir("../..")
                .build()
                .unwrap(),
        )
        .build()
        .unwrap();
    embed_methods_with_options(HashMap::from([("fibonacci-guest", opts)]));
}
