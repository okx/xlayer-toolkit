pragma circom 2.2.2;

include "poseidon2_t3_const.circom";

// Poseidon2 t=3, BN254 (RF=8, RP=56, x^5)
// D=[1,1,2], external matrix circ(2,1,1)
// Constants from HorizenLabs reference implementation

template SBox_T3() {
    signal input inp;
    signal output out;
    signal x2 <== inp * inp;
    signal x4 <== x2 * x2;
    out <== inp * x4;
}

template InternalRound_T3(roundIdx) {
    signal input inp[3];
    signal output out[3];

    var rc[56] = PARTIAL_RC_T3();

    component sb = SBox_T3();
    sb.inp <== inp[0] + rc[roundIdx];

    // M_I = [[2,1,1],[1,2,1],[1,1,3]], D=[1,1,2]
    // sum = sb.out + inp[1] + inp[2]
    // out[0] = 1*sb.out + sum = 2*sb.out + inp[1] + inp[2]
    // out[1] = 1*inp[1] + sum = sb.out + 2*inp[1] + inp[2]
    // out[2] = 2*inp[2] + sum = sb.out + inp[1] + 3*inp[2]
    var sum = sb.out + inp[1] + inp[2];
    out[0] <== sum + sb.out;
    out[1] <== sum + inp[1];
    out[2] <== sum + 2 * inp[2];
}

template ExternalRound_T3(roundIdx) {
    signal input inp[3];
    signal output out[3];

    var rc[8][3] = FULL_RC_T3();

    component sb[3];
    for (var j = 0; j < 3; j++) {
        sb[j] = SBox_T3();
        sb[j].inp <== inp[j] + rc[roundIdx][j];
    }

    // circ(2,1,1): out[i] = s[i] + sum
    var sum = sb[0].out + sb[1].out + sb[2].out;
    for (var j = 0; j < 3; j++) {
        out[j] <== sb[j].out + sum;
    }
}

template Poseidon2Perm_T3() {
    signal input inputs[3];
    signal output out[3];

    signal aux[65][3];

    // Initial linear layer: circ(2,1,1)
    var initSum = inputs[0] + inputs[1] + inputs[2];
    for (var j = 0; j < 3; j++) { aux[0][j] <== inputs[j] + initSum; }

    component ext_first[4];
    for (var k = 0; k < 4; k++) {
        ext_first[k] = ExternalRound_T3(k);
        for (var j = 0; j < 3; j++) { ext_first[k].inp[j] <== aux[k][j]; }
        for (var j = 0; j < 3; j++) { ext_first[k].out[j] ==> aux[k+1][j]; }
    }

    component intrnl[56];
    for (var k = 0; k < 56; k++) {
        intrnl[k] = InternalRound_T3(k);
        for (var j = 0; j < 3; j++) { intrnl[k].inp[j] <== aux[k+4][j]; }
        for (var j = 0; j < 3; j++) { intrnl[k].out[j] ==> aux[k+5][j]; }
    }

    component ext_last[4];
    for (var k = 0; k < 4; k++) {
        ext_last[k] = ExternalRound_T3(k + 4);
        for (var j = 0; j < 3; j++) { ext_last[k].inp[j] <== aux[k+60][j]; }
        for (var j = 0; j < 3; j++) { ext_last[k].out[j] ==> aux[k+61][j]; }
    }

    for (var j = 0; j < 3; j++) { out[j] <== aux[64][j]; }
}

// hash2(a0, a1) = perm(a0, a1, 0)[0]
template Poseidon2T3_Hash2() {
    signal input a0;
    signal input a1;
    signal output out;

    component perm = Poseidon2Perm_T3();
    perm.inputs[0] <== a0;
    perm.inputs[1] <== a1;
    perm.inputs[2] <== 0;
    out <== perm.out[0];
}
