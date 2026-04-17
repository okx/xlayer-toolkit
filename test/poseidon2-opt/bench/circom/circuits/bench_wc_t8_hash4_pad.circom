pragma circom 2.0.0;
include "../vendored/worldcoin_poseidon2.circom";
template WCT8Hash4Pad() {
    signal input a0; signal input a1; signal input a2; signal input a3;
    signal output out;
    component perm = Poseidon2(8);
    perm.in[0] <== a0; perm.in[1] <== a1; perm.in[2] <== a2;
    perm.in[3] <== a3; perm.in[4] <== 0; perm.in[5] <== 0;
    perm.in[6] <== 0; perm.in[7] <== 0;
    out <== perm.out[0];
}
component main = WCT8Hash4Pad();
