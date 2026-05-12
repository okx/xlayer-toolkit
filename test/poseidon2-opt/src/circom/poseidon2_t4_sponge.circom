pragma circom 2.2.2;

include "poseidon2_t4.circom";

// Sponge on top of T4 permutation (Noir-compatible).

template Poseidon2Hash(nInputs) {
    signal input inputs[nInputs];
    signal output out;

    var RATE = 3;
    // ceil(nInputs / RATE)
    var nPerms = (nInputs + RATE - 1) \ RATE;

    // IV = nInputs << 64 (same as Solidity: nInputs * 2^64)
    var IV = nInputs * 18446744073709551616;

    // Permutation components
    component perms[nPerms];

    // State between permutations: [4] elements after each perm
    // For the first permutation, state comes from inputs + IV
    // For subsequent ones, state = prev_output + absorbed_inputs

    // ── First permutation ──
    perms[0] = Poseidon2Perm();
    // Load first min(nInputs, 3) inputs into rate, zero-pad the rest
    for (var i = 0; i < RATE; i++) {
        if (i < nInputs) {
            perms[0].inputs[i] <== inputs[i];
        } else {
            perms[0].inputs[i] <== 0;
        }
    }
    perms[0].inputs[3] <== IV;  // capacity

    // ── Subsequent permutations (absorb remaining inputs) ──
    for (var p = 1; p < nPerms; p++) {
        perms[p] = Poseidon2Perm();
        var base = p * RATE;

        // Absorb: state[i] = prev_out[i] + input (for rate positions)
        for (var i = 0; i < RATE; i++) {
            if (base + i < nInputs) {
                perms[p].inputs[i] <== perms[p - 1].out[i] + inputs[base + i];
            } else {
                perms[p].inputs[i] <== perms[p - 1].out[i];
            }
        }
        // Capacity passes through unchanged
        perms[p].inputs[3] <== perms[p - 1].out[3];
    }

    // ── Squeeze ──
    out <== perms[nPerms - 1].out[0];
}
