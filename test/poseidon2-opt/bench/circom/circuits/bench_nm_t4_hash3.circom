pragma circom 2.2.2;

include "../vendored/poseidon2_hash.circom";

// Benchmark: NethermindEth Poseidon2 hash with 3 inputs (t=4)
// 3 inputs in rate, domainSeparation in capacity
template BenchNMT4Hash3() {
    signal input left;
    signal input right;
    signal input third;
    signal output out;

    component h = Poseidon2(3);
    h.inputs[0] <== left;
    h.inputs[1] <== right;
    h.inputs[2] <== third;
    h.domainSeparation <== 0;
    out <== h.out;
}

component main = BenchNMT4Hash3();
