pragma circom 2.0.0;

include "../vendored/nm_poseidon2_hash.circom";

// Benchmark: hash2 using t=3 (2 inputs + 1 capacity)
// Noir-compatible style: no feed-forward
template BenchHash2() {
    signal input left;
    signal input right;
    signal output out;

    component h = Poseidon2(2);
    h.inputs[0] <== left;
    h.inputs[1] <== right;
    h.domainSeparation <== 0;
    out <== h.out;
}

component main = BenchHash2();
