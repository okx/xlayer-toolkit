pragma circom 2.2.2;

include "poseidon2_t4_const.circom";

// ============================================================
//  Poseidon2 for t=4, BN254 (RF=8, RP=56, x^5)
//  Permutation based on NethermindEth (compact constraints)
//  Sponge matching Noir/Barretenberg/our Solidity Poseidon2Optimized
// ============================================================

// ── S-box: x^5 ──
template SBox() {
    signal input inp;
    signal output out;
    signal x2 <== inp * inp;
    signal x4 <== x2 * x2;
    out <== inp * x4;
}

// ── M4 matrix multiplication (Appendix B, Poseidon2 paper) ──
// Intermediates as var: pure linear combinations of inp signals.
// Only out[] assignments produce constraints (same pattern as circomlib Mix).
template MatMul_M4() {
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

// ── Internal round: add_rc(s0) + sbox(s0) + internal_mat_mul ──
template InternalRound(roundIdx) {
    signal input inp[4];
    signal output out[4];

    var rc[56] = PARTIAL_RC_T4();
    var diag[4] = INTERNAL_DIAG_T4();

    // S-box on first element only
    component sb = SBox();
    sb.inp <== inp[0] + rc[roundIdx];

    // Internal matrix: out[i] = diag[i] * inp[i] + sum
    // where sum includes sb.out instead of inp[0]
    var total = sb.out;
    for (var j = 1; j < 4; j++) {
        total += inp[j];
    }
    out[0] <== total + sb.out * diag[0];
    out[1] <== total + inp[1] * diag[1];
    out[2] <== total + inp[2] * diag[2];
    out[3] <== total + inp[3] * diag[3];
}

// ── External round: add_rc + full_sbox + M4 ──
template ExternalRound(roundIdx) {
    signal input inp[4];
    signal output out[4];

    var rc[8][4] = FULL_RC_T4();

    component sb[4];
    for (var j = 0; j < 4; j++) {
        sb[j] = SBox();
        sb[j].inp <== inp[j] + rc[roundIdx][j];
    }

    component m4 = MatMul_M4();
    for (var j = 0; j < 4; j++) { m4.inp[j] <== sb[j].out; }
    for (var j = 0; j < 4; j++) { out[j] <== m4.out[j]; }
}

// ── Permutation (t=4) ──
template Poseidon2Perm() {
    signal input inputs[4];
    signal output out[4];

    // 64 rounds total: 4 full + 56 partial + 4 full
    signal aux[65][4];

    // Initial linear layer
    component ll = MatMul_M4();
    for (var j = 0; j < 4; j++) { ll.inp[j] <== inputs[j]; }
    for (var j = 0; j < 4; j++) { ll.out[j] ==> aux[0][j]; }

    // First 4 external rounds
    component ext_first[4];
    for (var k = 0; k < 4; k++) {
        ext_first[k] = ExternalRound(k);
        for (var j = 0; j < 4; j++) { ext_first[k].inp[j] <== aux[k][j]; }
        for (var j = 0; j < 4; j++) { ext_first[k].out[j] ==> aux[k + 1][j]; }
    }

    // 56 internal rounds
    component intrnl[56];
    for (var k = 0; k < 56; k++) {
        intrnl[k] = InternalRound(k);
        for (var j = 0; j < 4; j++) { intrnl[k].inp[j] <== aux[k + 4][j]; }
        for (var j = 0; j < 4; j++) { intrnl[k].out[j] ==> aux[k + 5][j]; }
    }

    // Last 4 external rounds
    component ext_last[4];
    for (var k = 0; k < 4; k++) {
        ext_last[k] = ExternalRound(k + 4);
        for (var j = 0; j < 4; j++) { ext_last[k].inp[j] <== aux[k + 60][j]; }
        for (var j = 0; j < 4; j++) { ext_last[k].out[j] ==> aux[k + 61][j]; }
    }

    for (var j = 0; j < 4; j++) { out[j] <== aux[64][j]; }
}

// ============================================================
//  Sponge construction (matching Noir / our Solidity)
//
//  State: [s0, s1, s2, s3] where rate=3 (s0..s2), capacity=1 (s3)
//  IV:    nInputs * 2^64, placed in s3
//  Absorb: add up to 3 inputs to s0..s2 per round, then permute
//  Squeeze: return s0 after final permute
// ============================================================

template Poseidon2T4_Hash3() {
    signal input a0;
    signal input a1;
    signal input a2;
    signal output out;

    component perm = Poseidon2Perm();
    perm.inputs[0] <== a0;
    perm.inputs[1] <== a1;
    perm.inputs[2] <== a2;
    perm.inputs[3] <== 0;
    out <== perm.out[0];
}
