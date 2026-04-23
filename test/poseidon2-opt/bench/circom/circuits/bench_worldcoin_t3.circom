pragma circom 2.0.0;

include "../vendored/worldcoin_poseidon2.circom";

// Benchmark: Worldcoin Poseidon2 with t=3 (hash2 equivalent)
// 2 inputs in rate, domain separation = 0 in capacity
template BenchWorldcoinT3() {
    signal input left;
    signal input right;
    signal output out;

    component perm = Poseidon2(3);
    perm.in[0] <== left;
    perm.in[1] <== right;
    perm.in[2] <== 0;
    out <== perm.out[0];
}

component main = BenchWorldcoinT3();
