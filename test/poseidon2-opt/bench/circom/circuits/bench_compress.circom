pragma circom 2.0.0;

include "../vendored/nm_poseidon2_compress.circom";

// Benchmark: compress using t=2 (2 inputs, feed-forward: P(x)+x)
// NethermindEth style Merkle compression
template BenchCompress() {
    signal input left;
    signal input right;
    signal output out;

    component c = PoseidonCompress();
    c.inputs[0] <== left;
    c.inputs[1] <== right;
    out <== c.out;
}

component main = BenchCompress();
