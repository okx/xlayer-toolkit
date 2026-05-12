pragma circom 2.2.2;

include "poseidon2_t2_const.circom";

// Poseidon2 t=2, BN254 (RF=8, RP=56, x^5)
// D=[1,2], external matrix circ(2,1)

template SBox_T2() {
    signal input inp;
    signal output out;
    signal x2 <== inp * inp;
    signal x4 <== x2 * x2;
    out <== inp * x4;
}

template InternalRound_T2(roundIdx) {
    signal input inp[2];
    signal output out[2];

    var rc[56] = PARTIAL_RC_T2();

    component sb = SBox_T2();
    sb.inp <== inp[0] + rc[roundIdx];

    // M_I = [[2,1],[1,3]], D=[1,2]
    // sum = sb.out + inp[1]
    // out[0] = sb.out + sum = 2*sb.out + inp[1]
    // out[1] = 2*inp[1] + sum = sb.out + 3*inp[1]
    var sum = sb.out + inp[1];
    out[0] <== sum + sb.out;
    out[1] <== sum + 2 * inp[1];
}

template ExternalRound_T2(roundIdx) {
    signal input inp[2];
    signal output out[2];

    var rc[8][2] = FULL_RC_T2();

    component sb[2];
    for (var j = 0; j < 2; j++) {
        sb[j] = SBox_T2();
        sb[j].inp <== inp[j] + rc[roundIdx][j];
    }

    // circ(2,1): out[i] = s[i] + sum
    var sum = sb[0].out + sb[1].out;
    out[0] <== sb[0].out + sum;
    out[1] <== sb[1].out + sum;
}

template Poseidon2Perm_T2() {
    signal input inputs[2];
    signal output out[2];

    signal aux[65][2];

    // Initial linear layer: circ(2,1)
    var initSum = inputs[0] + inputs[1];
    aux[0][0] <== inputs[0] + initSum;
    aux[0][1] <== inputs[1] + initSum;

    // First 4 external rounds
    component ext_first[4];
    for (var k = 0; k < 4; k++) {
        ext_first[k] = ExternalRound_T2(k);
        for (var j = 0; j < 2; j++) { ext_first[k].inp[j] <== aux[k][j]; }
        for (var j = 0; j < 2; j++) { ext_first[k].out[j] ==> aux[k+1][j]; }
    }

    // 56 internal rounds
    component intrnl[56];
    for (var k = 0; k < 56; k++) {
        intrnl[k] = InternalRound_T2(k);
        for (var j = 0; j < 2; j++) { intrnl[k].inp[j] <== aux[k+4][j]; }
        for (var j = 0; j < 2; j++) { intrnl[k].out[j] ==> aux[k+5][j]; }
    }

    // Last 4 external rounds
    component ext_last[4];
    for (var k = 0; k < 4; k++) {
        ext_last[k] = ExternalRound_T2(k + 4);
        for (var j = 0; j < 2; j++) { ext_last[k].inp[j] <== aux[k+60][j]; }
        for (var j = 0; j < 2; j++) { ext_last[k].out[j] ==> aux[k+61][j]; }
    }

    for (var j = 0; j < 2; j++) { out[j] <== aux[64][j]; }
}

// hash1(a0) = perm(a0, 0)[0]
template Poseidon2T2_Hash1() {
    signal input a0;
    signal output out;

    component perm = Poseidon2Perm_T2();
    perm.inputs[0] <== a0;
    perm.inputs[1] <== 0;
    out <== perm.out[0];
}

// compress(a0, a1) = perm(a0, a1)[0] + a0 (feed-forward)
template Poseidon2T2FF_Compress() {
    signal input a0;
    signal input a1;
    signal output out;

    component perm = Poseidon2Perm_T2();
    perm.inputs[0] <== a0;
    perm.inputs[1] <== a1;
    out <== perm.out[0] + a0;
}
