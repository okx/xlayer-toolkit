pragma circom 2.0.0;

include "../vendored/bk_poseidon2_perm.circom";

// Benchmark: bkomuves/hash-circuits Poseidon2 t=3 Compression
// compress(left, right) = perm(left, right, 0)[0] (no feed-forward)
template BenchBkT3Compress() {
    signal input left;
    signal input right;
    signal output out;

    component c = Compression();
    c.inp[0] <== left;
    c.inp[1] <== right;
    out <== c.out;
}

component main = BenchBkT3Compress();
