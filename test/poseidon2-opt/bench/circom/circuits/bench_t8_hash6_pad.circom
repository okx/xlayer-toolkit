pragma circom 2.2.2;
include "../../../src/circom/poseidon2_t8.circom";
template T8Hash6Pad() {
    signal input a0; signal input a1; signal input a2; signal input a3;
    signal input a4; signal input a5;
    signal output out;
    component perm = Poseidon2Perm_T8();
    perm.inputs[0] <== a0; perm.inputs[1] <== a1; perm.inputs[2] <== a2;
    perm.inputs[3] <== a3; perm.inputs[4] <== a4; perm.inputs[5] <== a5;
    perm.inputs[6] <== 0; perm.inputs[7] <== 0;
    out <== perm.out[0];
}
component main = T8Hash6Pad();
