pragma circom 2.0.0;

include "../vendored/worldcoin_poseidon2.circom";

// Benchmark: Worldcoin Poseidon2 permutation with t=2
// Direct permutation, no sponge, no feed-forward
template BenchWorldcoinT2() {
    signal input left;
    signal input right;
    signal output out;

    component perm = Poseidon2(2);
    perm.in[0] <== left;
    perm.in[1] <== right;
    out <== perm.out[0];
}

component main = BenchWorldcoinT2();
