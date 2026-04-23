pragma circom 2.2.2;

include "poseidon2_t8_const.circom";

// Poseidon2 t=8, BN254 (RF=8, RP=57, x^5)
// External matrix: circ(2*M4, M4) block structure
// Internal matrix: 8-element 254-bit diagonal
// Constants from Worldcoin/TaceoLabs

template SBox_T8() {
    signal input inp;
    signal output out;
    signal x2 <== inp * inp;
    signal x4 <== x2 * x2;
    out <== inp * x4;
}

// M4 matrix block (same as T4)
template MatMul_M4_T8() {
    signal input inp[4];
    signal output out[4];

    var t_0 = inp[0] + inp[1];
    var t_1 = inp[2] + inp[3];
    var t_2 = 2 * inp[1] + t_1;
    var t_3 = 2 * inp[3] + t_0;
    var t_4 = 4 * t_1 + t_3;
    var t_5 = 4 * t_0 + t_2;

    out[0] <== t_3 + t_5;
    out[1] <== t_5;
    out[2] <== t_2 + t_4;
    out[3] <== t_4;
}

// External layer for t=8: circ(2*M4, M4)
// Apply M4 to each 4-element block, then add cross-block sums
template ExternalLayer_T8() {
    signal input inp[8];
    signal output out[8];

    // M4 on block 0
    component m4_0 = MatMul_M4_T8();
    for (var j = 0; j < 4; j++) { m4_0.inp[j] <== inp[j]; }

    // M4 on block 1
    component m4_1 = MatMul_M4_T8();
    for (var j = 0; j < 4; j++) { m4_1.inp[j] <== inp[j + 4]; }

    // Cross-block sums
    signal sums[4];
    for (var l = 0; l < 4; l++) {
        sums[l] <== m4_0.out[l] + m4_1.out[l];
    }

    // Each element += sum at its position mod 4
    for (var j = 0; j < 4; j++) {
        out[j]     <== m4_0.out[j] + sums[j];
        out[j + 4] <== m4_1.out[j] + sums[j];
    }
}

template InternalRound_T8(roundIdx) {
    signal input inp[8];
    signal output out[8];

    var rc[57] = PARTIAL_RC_T8();
    var diag[8] = INTERNAL_DIAG_T8();

    component sb = SBox_T8();
    sb.inp <== inp[0] + rc[roundIdx];

    // sum = sb.out + inp[1..7]
    var sum = sb.out;
    for (var j = 1; j < 8; j++) { sum += inp[j]; }

    // out[i] = diag[i] * inp[i] + sum (with sb.out for i=0)
    out[0] <== sum + sb.out * diag[0];
    for (var j = 1; j < 8; j++) {
        out[j] <== sum + inp[j] * diag[j];
    }
}

template ExternalRound_T8(roundIdx, isSecondHalf) {
    signal input inp[8];
    signal output out[8];

    var rc1[4][8] = FULL1_RC_T8();
    var rc2[4][8] = FULL2_RC_T8();

    component sb[8];
    for (var j = 0; j < 8; j++) {
        sb[j] = SBox_T8();
        if (isSecondHalf == 0) {
            sb[j].inp <== inp[j] + rc1[roundIdx][j];
        } else {
            sb[j].inp <== inp[j] + rc2[roundIdx][j];
        }
    }

    component ext = ExternalLayer_T8();
    for (var j = 0; j < 8; j++) { ext.inp[j] <== sb[j].out; }
    for (var j = 0; j < 8; j++) { out[j] <== ext.out[j]; }
}

template Poseidon2Perm_T8() {
    signal input inputs[8];
    signal output out[8];

    // 65 rounds: 4 full + 57 partial + 4 full
    signal aux[66][8];

    // Initial external layer
    component initLayer = ExternalLayer_T8();
    for (var j = 0; j < 8; j++) { initLayer.inp[j] <== inputs[j]; }
    for (var j = 0; j < 8; j++) { initLayer.out[j] ==> aux[0][j]; }

    // First 4 external rounds
    component ext_first[4];
    for (var k = 0; k < 4; k++) {
        ext_first[k] = ExternalRound_T8(k, 0);
        for (var j = 0; j < 8; j++) { ext_first[k].inp[j] <== aux[k][j]; }
        for (var j = 0; j < 8; j++) { ext_first[k].out[j] ==> aux[k+1][j]; }
    }

    // 57 internal rounds
    component intrnl[57];
    for (var k = 0; k < 57; k++) {
        intrnl[k] = InternalRound_T8(k);
        for (var j = 0; j < 8; j++) { intrnl[k].inp[j] <== aux[k+4][j]; }
        for (var j = 0; j < 8; j++) { intrnl[k].out[j] ==> aux[k+5][j]; }
    }

    // Last 4 external rounds
    component ext_last[4];
    for (var k = 0; k < 4; k++) {
        ext_last[k] = ExternalRound_T8(k, 1);
        for (var j = 0; j < 8; j++) { ext_last[k].inp[j] <== aux[k+61][j]; }
        for (var j = 0; j < 8; j++) { ext_last[k].out[j] ==> aux[k+62][j]; }
    }

    for (var j = 0; j < 8; j++) { out[j] <== aux[65][j]; }
}

// hash7(a0..a6) = perm(a0..a6, 0)[0]
template Poseidon2T8_Hash7() {
    signal input a0;
    signal input a1;
    signal input a2;
    signal input a3;
    signal input a4;
    signal input a5;
    signal input a6;
    signal output out;

    component perm = Poseidon2Perm_T8();
    perm.inputs[0] <== a0;
    perm.inputs[1] <== a1;
    perm.inputs[2] <== a2;
    perm.inputs[3] <== a3;
    perm.inputs[4] <== a4;
    perm.inputs[5] <== a5;
    perm.inputs[6] <== a6;
    perm.inputs[7] <== 0;
    out <== perm.out[0];
}
