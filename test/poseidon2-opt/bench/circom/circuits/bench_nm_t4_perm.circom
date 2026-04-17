pragma circom 2.2.2;

include "../vendored/poseidon2_perm.circom";

// Benchmark: NethermindEth Poseidon2 raw permutation t=4
// Direct permutation, no hash wrapper
template BenchNMT4Perm() {
    signal input left;
    signal input right;
    signal input third;
    signal output out;

    component perm = Permutation(4);
    perm.inputs[0] <== left;
    perm.inputs[1] <== right;
    perm.inputs[2] <== third;
    perm.inputs[3] <== 0;
    out <== perm.out[0];
}

component main = BenchNMT4Perm();
