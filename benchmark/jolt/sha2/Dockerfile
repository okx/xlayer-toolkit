FROM rustlang/rust:nightly

# Install RISC-V target
RUN rustup target add riscv64imac-unknown-none-elf

# Install jolt CLI
ARG JOLT_REV=2e05fe883920054df2ee3a6df8f85c2caba77c99
RUN cargo install --git https://github.com/a16z/jolt --rev ${JOLT_REV} --force --bins jolt

# Copy guest source only (all we need to compile the ELF)
WORKDIR /src
COPY guest/ /src/guest/

# Compile guest ELFs (builds all #[jolt::provable] functions in the package)
RUN jolt build -p sha2-guest --backtrace off --stack-size 4096 \
    -- --release --target-dir /src/target/jolt-guest --features guest
