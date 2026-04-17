pragma circom 2.0.0;

include "../vendored/worldcoin_poseidon2.circom";

// Benchmark: Worldcoin Poseidon2 with t=4 (Noir/Aztec standard)
// 3 inputs in rate, domain separation = 0 in capacity
template BenchWorldcoinT4() {
    signal input left;
    signal input right;
    signal input third;
    signal output out;

    component perm = Poseidon2(4);
    perm.in[0] <== left;
    perm.in[1] <== right;
    perm.in[2] <== third;
    perm.in[3] <== 0;
    out <== perm.out[0];
}

component main = BenchWorldcoinT4();
