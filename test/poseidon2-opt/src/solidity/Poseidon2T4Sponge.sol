// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

/// @title Poseidon2T4Sponge
/// @notice Poseidon2 (BN254, t=4, RF=8, RP=56, x^5) — loop-based with Yul dirty-value optimization.
/// @dev Combines V-k-h's loop architecture (compact bytecode) with zemse's ADD-instead-of-ADDMOD
///      trick (lower gas). Round constants loaded from memory; rounds executed in loops.
///      Compatible with Noir / Barretenberg.
library Poseidon2T4Sponge {
    uint256 internal constant PRIME = 0x30644e72e131a029b85045b68181585d2833e84879b9709143e1f593f0000001;

    // Internal diagonal matrix constants (I + D): same as Noir/zemse/V-k-h
    uint256 internal constant D0 = 0x10dc6e9c006ea38b04b1e03b4bd9490c0d03f98929ca1d7fb56821fd19d3b6e7;
    uint256 internal constant D1 = 0x0c28145b6a44df3e0149b3d0a30b3bb599df9756d4dd9b84a86b38cfb45a740b;
    uint256 internal constant D2 = 0x00544b8338791518b2c7645a50392798b21f75bb60e3596170067d00141cac15;
    uint256 internal constant D3 = 0x222c01175718386f2e2e82eb122789e352e105a3b8fa852613bc534433ee428b;

    // Round constants: packed layout to minimize bytecode.
    // Layout: [first4_full: 16×32B][partial: 56×32B][last4_full: 16×32B] = 2816 bytes.
    // Full rounds store 4 RCs per round; partial rounds store 1 RC (only s0 needs it).
    // Source: identical to V-k-h/Poseidon2T4Sponge and Noir/Barretenberg.
    bytes internal constant RC_BYTES =
                hex"19b849f69450b06848da1d39bd5e4a4302bb86744edc26238b0878e269ed23e5265ddfe127dd51bd7239347b758f0a1320eb2cc7450acc1dad47f80c8dcf34d6199750ec472f1809e0f66a545e1e51624108ac845015c2aa3dfc36bab497d8aa"
        hex"157ff3fe65ac7208110f06a5f74302b14d743ea25067f0ffd032f787c7f1cdf82e49c43c4569dd9c5fd35ac45fca33f10b15c590692f8beefe18f4896ac949020e35fb89981890520d4aef2b6d6506c3cb2f0b6973c24fa82731345ffa2d1f1e"
        hex"251ad47cb15c4f1105f109ae5e944f1ba9d9e7806d667ffec6fe723002e0b99613da07dc64d428369873e97160234641f8beb56fdd05e5f3563fa39d9c22df4e0c009b84e650e6d23dc00c7dccef7483a553939689d350cd46e7b89055fd4738"
        hex"011f16b1c63a854f01992e3956f42d8b04eb650c6d535eb0203dec74befdca060ed69e5e383a688f209d9a561daa79612f3f78d0467ad45485df07093f36754904dba94a7b0ce9e221acad41472b6bbe3aec507f5eb3d33f463672264c9f789b"
        hex"0a3f2637d840f3a16eb094271c9d237b6036757d4bb50bf7ce732ff1d4fa28e8259a666f129eea198f8a1c502fdb38fa39b1f075569564b6e54a485d1182323f28bf7459c9b2f4c6d8e7d06a4ee3a47f7745d4271038e5157a32fdf7ede0d6a1"
        hex"0a1ca941f057037526ea200f489be8d4c37c85bbcce6a2aeec91bd69414324470c6f8f958be0e93053d7fd4fc54512855535ed1539f051dcb43a26fd926361cf123106a93cd17578d426e8128ac9d90aa9e8a00708e296e084dd57e69caaf811"
        hex"26e1ba52ad9285d97dd3ab52f8e840085e8fa83ff1e8f1877b074867cd2dee751cb55cad7bd133de18a64c5c47b9c97cbe4d8b7bf9e095864471537e6a4ae2c51dcd73e46acd8f8e0e2c7ce04bde7f6d2a53043d5060a41c7143f08e6e9055d0"
        hex"011003e32f6d9c66f5852f05474a4def0cda294a0eb4e9b9b12b9bb4512e55742b1e809ac1d10ab29ad5f20d03a57dfebadfe5903f58bafed7c508dd2287ae8c2539de1785b735999fb4dac35ee17ed0ef995d05ab2fc5faeaa69ae87bcec0a5"
        hex"0c246c5a2ef8ee0126497f222b3e0a0ef4e1c3d41c86d46e43982cb11d77951d192089c4974f68e95408148f7c0632edbb09e6a6ad1a1c2f3f0305f5d03b527b1eae0ad8ab68b2f06a0ee36eeb0d0c058529097d91096b756d8fdc2fb5a60d85"
        hex"179190e5d0e22179e46f8282872abc88db6e2fdc0dee99e69768bd98c5d06bfb29bb9e2c9076732576e9a81c7ac4b83214528f7db00f31bf6cafe794a9b3cd1c225d394e42207599403efd0c2464a90d52652645882aac35b10e590e6e691e08"
        hex"064760623c25c8cf753d238055b444532be13557451c087de09efd454b23fd5910ba3a0e01df92e87f301c4b716d8a394d67f4bf42a75c10922910a78f6b5b870e070bf53f8451b24f9c6e96b0c2a801cb511bc0c242eb9d361b77693f21471c"
        hex"1b94cd61b051b04dd39755ff93821a73ccd6cb11d2491d8aa7f921014de252fb1d7cb39bafb8c744e148787a2e70230f9d4e917d5713bb050487b5aa7d74070b2ec93189bd1ab4f69117d0fe980c80ff8785c2961829f701bb74ac1f303b17db"
        hex"2db366bfdd36d277a692bb825b86275beac404a19ae07a9082ea46bd83517926062100eb485db06269655cf186a68532985275428450359adc99cec6960711b80761d33c66614aaa570e7f1e8244ca1120243f92fa59e4f900c567bf41f5a59b"
        hex"20fc411a114d13992c2705aa034e3f315d78608a0f7de4ccf7a72e494855ad0d25b5c004a4bdfcb5add9ec4e9ab219ba102c67e8b3effb5fc3a30f317250bc5a23b1822d278ed632a494e58f6df6f5ed038b186d8474155ad87e7dff62b37f4b"
        hex"22734b4c5c3f9493606c4ba9012499bf0f14d13bfcfcccaa16102a29cc2f69e026c0c8fe09eb30b7e27a74dc33492347e5bdff409aa3610254413d3fad795ce5070dd0ccb6bd7bbae88eac03fa1fbb26196be3083a809829bbd626df348ccad9"
        hex"12b6595bdb329b6fb043ba78bb28c3bec2c0a6de46d8c5ad6067c4ebfd4250da248d97d7f76283d63bec30e7a5876c11c06fca9b275c671c5e33d95bb7e8d7291a306d439d463b0816fc6fd64cc939318b45eb759ddde4aa106d15d9bd9baaaa"
        hex"28a8f8372e3c38daced7c00421cb4621f4f1b54ddc27821b0d62d3d6ec7c56cf0094975717f9a8a8bb35152f24d43294071ce320c829f388bc852183e1e2ce7e04d5ee4c3aa78f7d80fde60d716480d3593f74d4f653ae83f4103246db2e8d65"
        hex"2a6cf5e9aa03d4336349ad6fb8ed2269c7bef54b8822cc76d08495c12efde1872304d31eaab960ba9274da43e19ddeb7f792180808fd6e43baae48d7efcba3f303fd9ac865a4b2a6d5e7009785817249bff08a7e0726fcb4e1c11d39d199f0b0"
        hex"00b7258ded52bbda2248404d55ee5044798afc3a209193073f7954d4d63b0b64159f81ada0771799ec38fca2d4bf65ebb13d3a74f3298db36272c5ca65e92d9a1ef90e67437fbc8550237a75bc28e3bb9000130ea25f0c5471e144cf4264431f"
        hex"1e65f838515e5ff0196b49aa41a2d2568df739bc176b08ec95a79ed82932e30d2b1b045def3a166cec6ce768d079ba74b18c844e570e1f826575c1068c94c33f0832e5753ceb0ff6402543b1109229c165dc2d73bef715e3f1c6e07c168bb173"
        hex"02f614e9cedfb3dc6b762ae0a37d41bab1b841c2e8b6451bc5a8e3c390b6ad160e2427d38bd46a60dd640b8e362cad967370ebb777bedff40f6a0be27e7ed7050493630b7c670b6deb7c84d414e7ce79049f0ec098c3c7c50768bbe29214a53a"
        hex"22ead100e8e482674decdab17066c5a26bb1515355d5461a3dc06cc85327cea925b3e56e655b42cdaae2626ed2554d48583f1ae35626d04de5084e0b6d2a6f161e32752ada8836ef5837a6cde8ff13dbb599c336349e4c584b4fdc0a0cf6f9d0"
        hex"2fa2a871c15a387cc50f68f6f3c3455b23c00995f05078f672a9864074d412e52f569b8a9a4424c9278e1db7311e889f54ccbf10661bab7fcd18e7c7a7d83505044cb455110a8fdd531ade530234c518a7df93f7332ffd2144165374b246b43d"
        hex"227808de93906d5d420246157f2e42b191fe8c90adfe118178ddc723a531902502fcca2934e046bc623adead873579865d03781ae090ad4a8579d2e7a68003550ef915f0ac120b876abccceb344a1d36bad3f3c5ab91a8ddcbec2e060d8befac"
        hex"1797130f4b7a3e1777eb757bc6f287f6ab0fb85f6be63b09f3b16ef2b1405d380a76225dc04170ae3306c85abab59e608c7f497c20156d4d36c668555decc6e51fffb9ec1992d66ba1e77a7b93209af6f8fa76d48acb664796174b5326a31a5c"
        hex"25721c4fc15a3f2853b57c338fa538d85f8fbba6c6b9c6090611889b797b9c5f0c817fd42d5f7a41215e3d07ba197216adb4c3790705da95eb63b982bfcaf75a13abe3f5239915d39f7e13c2c24970b6df8cf86ce00a22002bc15866e52b5a96"
        hex"2106feea546224ea12ef7f39987a46c85c1bc3dc29bdbd7a92cd60acb4d391ce21ca859468a746b6aaa79474a37dab49f1ca5a28c748bc7157e1b3345bb0f95905ccd6255c1e6f0c5cf1f0df934194c62911d14d0321662a8f1a48999e34185b"
        hex"0f0e34a64b70a626e464d846674c4c8816c4fb267fe44fe6ea28678cb09490a40558531a4e25470c6157794ca36d0e9647dbfcfe350d64838f5b1a8a2de0d4bf09d3dca9173ed2faceea125157683d18924cadad3f655a60b72f5864961f1455"
        hex"0328cbd54e8c0913493f866ed03d218bf23f92d68aaec48617d4c722e5bd43352bf07216e2aff0a223a487b1a7094e07e79e7bcc9798c648ee3347dd5329d34b1daf345a58006b736499c583cb76c316d6f78ed6a6dffc82111e11a63fe412df"
        hex"176563472456aaa746b694c60e1823611ef39039b2edc7ff391e6f2293d2c404";

    // ================================================================
    //  Core permutation — single assembly block, loop-based, ADD-optimized
    // ================================================================

    /// @dev Permutation with externally provided RC pointer (avoids re-copying for multi-permute sponge).
    ///      Dirty-value convention (BN254-specific, PRIME < 2^254):
    ///        - "clean" = value < PRIME
    ///        - After N `add` ops on clean values, value < (N+1)*PRIME
    ///        - Safe as long as (N+1)*PRIME < 2^256 ⟹ N ≤ 3 for BN254
    ///        - `mulmod`/`addmod` always produce clean output regardless of dirty inputs
    function _permute(uint256 s0, uint256 s1, uint256 s2, uint256 s3, bytes memory rc)
        private
        pure
        returns (uint256, uint256, uint256, uint256)
    {
        assembly ("memory-safe") {
            let P := 0x30644e72e131a029b85045b68181585d2833e84879b9709143e1f593f0000001
            let rcPtr := add(rc, 32) // skip bytes length prefix

            // Ensure all inputs are valid field elements (< PRIME).
            // Users may pass arbitrary uint256 values; without this,
            // subsequent `add` operations could overflow uint256.
            s0 := mod(s0, P)
            s1 := mod(s1, P)
            s2 := mod(s2, P)
            s3 := mod(s3, P)

            // ────────────────────────────────────────────────
            //  Initial external linear layer
            //  Inputs: s0..s3 all clean (0/3) from mod above
            // ────────────────────────────────────────────────
            {
                let t0 := add(s0, s1)           // 0/3 + 0/3 → 1/3 (< 2P)
                let t1 := add(s2, s3)           // 0/3 + 0/3 → 1/3 (< 2P)
                let t2 := add(s1, s1)           // 0/3 + 0/3 → 1/3 (< 2P)
                t2 := addmod(t2, t1, P)         // addmod → 0/3
                let t3 := add(s3, s3)           // 0/3 + 0/3 → 1/3 (< 2P)
                t3 := addmod(t3, t0, P)         // addmod → 0/3
                let t4 := mulmod(t1, 4, P)      // mulmod → 0/3
                t4 := add(t4, t3)               // 0/3 + 0/3 → 1/3 (< 2P)
                let t5 := mulmod(t0, 4, P)      // mulmod → 0/3
                t5 := add(t5, t2)               // 0/3 + 0/3 → 1/3 (< 2P)
                s0 := addmod(t3, t5, P)         // addmod → 0/3
                s1 := t5                        // 1/3 (< 2P)
                s2 := addmod(t2, t4, P)         // addmod → 0/3
                s3 := t4                        // 1/3 (< 2P)
            }

            // ────────────────────────────────────────────────
            //  First 4 external (full) rounds
            // ────────────────────────────────────────────────
            // Loop invariant: s0 0/3, s1 1/3, s2 0/3, s3 1/3
            for { let r := 0 } lt(r, 4) { r := add(r, 1) } {
                let base := shl(7, r) // r * 128 (4 constants × 32 bytes)

                // Add round constants (RC are 0/3, i.e. < PRIME)
                s0 := add(s0, mload(add(rcPtr, base)))              // 0/3 + 0/3 → 1/3
                s1 := add(s1, mload(add(rcPtr, add(base, 0x20))))   // 1/3 + 0/3 → 2/3 (< 3P)
                s2 := add(s2, mload(add(rcPtr, add(base, 0x40))))   // 0/3 + 0/3 → 1/3
                s3 := add(s3, mload(add(rcPtr, add(base, 0x60))))   // 1/3 + 0/3 → 2/3 (< 3P)

                // Full S-box: x^5 — mulmod accepts any uint256, output 0/3
                let tmp := s0                   // s0 is 1/3, ok for mulmod
                s0 := mulmod(tmp, tmp, P)       // 0/3
                s0 := mulmod(s0, s0, P)         // 0/3
                s0 := mulmod(s0, tmp, P)        // 0/3

                tmp := s1                       // s1 is 2/3, ok for mulmod
                s1 := mulmod(tmp, tmp, P)       // 0/3
                s1 := mulmod(s1, s1, P)         // 0/3
                s1 := mulmod(s1, tmp, P)        // 0/3

                tmp := s2                       // s2 is 1/3, ok for mulmod
                s2 := mulmod(tmp, tmp, P)       // 0/3
                s2 := mulmod(s2, s2, P)         // 0/3
                s2 := mulmod(s2, tmp, P)        // 0/3

                tmp := s3                       // s3 is 2/3, ok for mulmod
                s3 := mulmod(tmp, tmp, P)       // 0/3
                s3 := mulmod(s3, s3, P)         // 0/3
                s3 := mulmod(s3, tmp, P)        // 0/3
                // All s0..s3 are 0/3 after sbox

                // External layer
                {
                    let t0 := add(s0, s1)       // 0/3 + 0/3 → 1/3
                    let t1 := add(s2, s3)       // 0/3 + 0/3 → 1/3
                    let t2 := add(s1, s1)       // 0/3 + 0/3 → 1/3
                    t2 := addmod(t2, t1, P)     // addmod → 0/3
                    let t3 := add(s3, s3)       // 0/3 + 0/3 → 1/3
                    t3 := addmod(t3, t0, P)     // addmod → 0/3
                    let t4 := mulmod(t1, 4, P)  // mulmod → 0/3
                    t4 := add(t4, t3)           // 0/3 + 0/3 → 1/3
                    let t5 := mulmod(t0, 4, P)  // mulmod → 0/3
                    t5 := add(t5, t2)           // 0/3 + 0/3 → 1/3
                    s0 := addmod(t3, t5, P)     // addmod → 0/3
                    s1 := t5                    // 1/3
                    s2 := addmod(t2, t4, P)     // addmod → 0/3
                    s3 := t4                    // 1/3
                }
                // Invariant restored: s0 0/3, s1 1/3, s2 0/3, s3 1/3
            }

            // ────────────────────────────────────────────────
            //  56 partial (internal) rounds
            // ────────────────────────────────────────────────
            // After full rounds: s0 0/3, s1 1/3, s2 0/3, s3 1/3
            // Partial round sum needs 4 clean values added (→ 3/3).
            // If s1,s3 were 1/3, sum could reach: 0/3 + 1/3 + 0/3 + 1/3 = 4 values
            // with max = P + 2P + P + 2P = 6P > 2^256 → OVERFLOW!
            // Must clean s1,s3 first.
            s1 := mod(s1, P)                    // 1/3 → 0/3
            s3 := mod(s3, P)                    // 1/3 → 0/3

            let d0 := 0x10dc6e9c006ea38b04b1e03b4bd9490c0d03f98929ca1d7fb56821fd19d3b6e7
            let d1 := 0x0c28145b6a44df3e0149b3d0a30b3bb599df9756d4dd9b84a86b38cfb45a740b
            let d2 := 0x00544b8338791518b2c7645a50392798b21f75bb60e3596170067d00141cac15
            let d3 := 0x222c01175718386f2e2e82eb122789e352e105a3b8fa852613bc534433ee428b

            // Packed offset: 4 full rounds × 4 × 32B = 512. Stride: 32B per partial round.
            let partialBase := add(rcPtr, 512)

            // Loop invariant: s0..s3 all 0/3 at start of each iteration
            for { let r := 0 } lt(r, 56) { r := add(r, 1) } {
                // Add RC to s0 only (RC is 0/3)
                s0 := add(s0, mload(add(partialBase, shl(5, r))))    // 0/3 + 0/3 → 1/3

                // Single S-box on s0 — mulmod accepts any uint256, output 0/3
                let tmp := s0                   // 1/3, ok for mulmod
                s0 := mulmod(tmp, tmp, P)       // 0/3
                s0 := mulmod(s0, s0, P)         // 0/3
                s0 := mulmod(s0, tmp, P)        // 0/3

                // Internal layer: s[i] = D[i] * s[i] + sum
                // s0..s3 all 0/3. Three adds on 4 clean values:
                // sum < P + P + P + P = 4P ≈ 2^255.97 < 2^256 ✓
                let sum := add(add(add(s0, s1), s2), s3) // 3/3 (< 4P)
                // mulmod(0/3, 0/3, P) → 0/3; addmod(0/3, 3/3, P) → 0/3
                s0 := addmod(mulmod(s0, d0, P), sum, P) // 0/3
                s1 := addmod(mulmod(s1, d1, P), sum, P) // 0/3
                s2 := addmod(mulmod(s2, d2, P), sum, P) // 0/3
                s3 := addmod(mulmod(s3, d3, P), sum, P) // 0/3
                // Invariant restored: s0..s3 all 0/3
            }

            // ────────────────────────────────────────────────
            //  Last 4 external (full) rounds
            // ────────────────────────────────────────────────
            // After partial rounds: s0..s3 all 0/3
            // Same loop invariant as first full rounds: s0 0/3, s1 1/3, s2 0/3, s3 1/3
            // But on first iteration entry, all are 0/3. After add_rc, s1/s3 become 1/3.
            // This is stricter than the invariant (0/3 ⊂ 1/3), so safe.
            // Packed offset: 512 + 56×32 = 2304.
            let lastBase := add(rcPtr, 2304)
            for { let r := 0 } lt(r, 4) { r := add(r, 1) } {
                let base := shl(7, r)

                // Add round constants (RC are 0/3)
                s0 := add(s0, mload(add(lastBase, base)))              // ≤1/3 + 0/3 → ≤1/3
                s1 := add(s1, mload(add(lastBase, add(base, 0x20))))   // ≤1/3 + 0/3 → ≤2/3
                s2 := add(s2, mload(add(lastBase, add(base, 0x40))))   // ≤1/3 + 0/3 → ≤1/3
                s3 := add(s3, mload(add(lastBase, add(base, 0x60))))   // ≤1/3 + 0/3 → ≤2/3

                // Full S-box — mulmod accepts any uint256, output 0/3
                let tmp := s0
                s0 := mulmod(tmp, tmp, P)       // 0/3
                s0 := mulmod(s0, s0, P)         // 0/3
                s0 := mulmod(s0, tmp, P)        // 0/3

                tmp := s1
                s1 := mulmod(tmp, tmp, P)       // 0/3
                s1 := mulmod(s1, s1, P)         // 0/3
                s1 := mulmod(s1, tmp, P)        // 0/3

                tmp := s2
                s2 := mulmod(tmp, tmp, P)       // 0/3
                s2 := mulmod(s2, s2, P)         // 0/3
                s2 := mulmod(s2, tmp, P)        // 0/3

                tmp := s3
                s3 := mulmod(tmp, tmp, P)       // 0/3
                s3 := mulmod(s3, s3, P)         // 0/3
                s3 := mulmod(s3, tmp, P)        // 0/3
                // All 0/3 after sbox

                // External layer
                {
                    let t0 := add(s0, s1)       // 0/3 + 0/3 → 1/3
                    let t1 := add(s2, s3)       // 0/3 + 0/3 → 1/3
                    let t2 := add(s1, s1)       // 0/3 + 0/3 → 1/3
                    t2 := addmod(t2, t1, P)     // addmod → 0/3
                    let t3 := add(s3, s3)       // 0/3 + 0/3 → 1/3
                    t3 := addmod(t3, t0, P)     // addmod → 0/3
                    let t4 := mulmod(t1, 4, P)  // mulmod → 0/3
                    t4 := add(t4, t3)           // 0/3 + 0/3 → 1/3
                    let t5 := mulmod(t0, 4, P)  // mulmod → 0/3
                    t5 := add(t5, t2)           // 0/3 + 0/3 → 1/3
                    s0 := addmod(t3, t5, P)     // addmod → 0/3
                    s1 := t5                    // 1/3
                    s2 := addmod(t2, t4, P)     // addmod → 0/3
                    s3 := t4                    // 1/3
                }
                // End of round: s0 0/3, s1 1/3, s2 0/3, s3 1/3
            }

            // After last external layer: s0 0/3, s1 1/3, s2 0/3, s3 1/3
            // Must return clean values for callers (sponge absorb uses addmod,
            // but _permute output should be canonical field elements).
            s1 := mod(s1, P)                    // 1/3 → 0/3
            s3 := mod(s3, P)                    // 1/3 → 0/3
        }
        return (s0, s1, s2, s3);
    }

    // ================================================================
    //  Sponge hash functions
    // ================================================================

    function hash1(uint256 a0) internal pure returns (uint256) {
        bytes memory rc = RC_BYTES;
        (uint256 s0,,,) = _permute(a0, 0, 0, 1 << 64, rc);
        return s0;
    }

    function hash2(uint256 a0, uint256 a1) internal pure returns (uint256) {
        bytes memory rc = RC_BYTES;
        (uint256 s0,,,) = _permute(a0, a1, 0, 2 << 64, rc);
        return s0;
    }

    function hash3(uint256 a0, uint256 a1, uint256 a2) internal pure returns (uint256) {
        bytes memory rc = RC_BYTES;
        (uint256 s0,,,) = _permute(a0, a1, a2, 3 << 64, rc);
        return s0;
    }

    function hash4(uint256 a0, uint256 a1, uint256 a2, uint256 a3) internal pure returns (uint256) {
        bytes memory rc = RC_BYTES;
        (uint256 s0, uint256 s1, uint256 s2, uint256 s3) = _permute(a0, a1, a2, 4 << 64, rc);
        s0 = addmod(s0, a3, PRIME);
        (s0,,,) = _permute(s0, s1, s2, s3, rc);
        return s0;
    }

    function hash5(uint256 a0, uint256 a1, uint256 a2, uint256 a3, uint256 a4) internal pure returns (uint256) {
        bytes memory rc = RC_BYTES;
        (uint256 s0, uint256 s1, uint256 s2, uint256 s3) = _permute(a0, a1, a2, 5 << 64, rc);
        s0 = addmod(s0, a3, PRIME);
        s1 = addmod(s1, a4, PRIME);
        (s0,,,) = _permute(s0, s1, s2, s3, rc);
        return s0;
    }

    function hash6(uint256 a0, uint256 a1, uint256 a2, uint256 a3, uint256 a4, uint256 a5)
        internal
        pure
        returns (uint256)
    {
        bytes memory rc = RC_BYTES;
        (uint256 s0, uint256 s1, uint256 s2, uint256 s3) = _permute(a0, a1, a2, 6 << 64, rc);
        s0 = addmod(s0, a3, PRIME);
        s1 = addmod(s1, a4, PRIME);
        s2 = addmod(s2, a5, PRIME);
        (s0,,,) = _permute(s0, s1, s2, s3, rc);
        return s0;
    }

    function hash7(
        uint256 a0,
        uint256 a1,
        uint256 a2,
        uint256 a3,
        uint256 a4,
        uint256 a5,
        uint256 a6
    ) internal pure returns (uint256) {
        bytes memory rc = RC_BYTES;
        (uint256 s0, uint256 s1, uint256 s2, uint256 s3) = _permute(a0, a1, a2, 7 << 64, rc);
        s0 = addmod(s0, a3, PRIME);
        s1 = addmod(s1, a4, PRIME);
        s2 = addmod(s2, a5, PRIME);
        (s0, s1, s2, s3) = _permute(s0, s1, s2, s3, rc);
        s0 = addmod(s0, a6, PRIME);
        (s0,,,) = _permute(s0, s1, s2, s3, rc);
        return s0;
    }

    function hash8(
        uint256 a0,
        uint256 a1,
        uint256 a2,
        uint256 a3,
        uint256 a4,
        uint256 a5,
        uint256 a6,
        uint256 a7
    ) internal pure returns (uint256) {
        bytes memory rc = RC_BYTES;
        (uint256 s0, uint256 s1, uint256 s2, uint256 s3) = _permute(a0, a1, a2, 8 << 64, rc);
        s0 = addmod(s0, a3, PRIME);
        s1 = addmod(s1, a4, PRIME);
        s2 = addmod(s2, a5, PRIME);
        (s0, s1, s2, s3) = _permute(s0, s1, s2, s3, rc);
        s0 = addmod(s0, a6, PRIME);
        s1 = addmod(s1, a7, PRIME);
        (s0,,,) = _permute(s0, s1, s2, s3, rc);
        return s0;
    }

    function hash9(
        uint256 a0,
        uint256 a1,
        uint256 a2,
        uint256 a3,
        uint256 a4,
        uint256 a5,
        uint256 a6,
        uint256 a7,
        uint256 a8
    ) internal pure returns (uint256) {
        bytes memory rc = RC_BYTES;
        (uint256 s0, uint256 s1, uint256 s2, uint256 s3) = _permute(a0, a1, a2, 9 << 64, rc);
        s0 = addmod(s0, a3, PRIME);
        s1 = addmod(s1, a4, PRIME);
        s2 = addmod(s2, a5, PRIME);
        (s0, s1, s2, s3) = _permute(s0, s1, s2, s3, rc);
        s0 = addmod(s0, a6, PRIME);
        s1 = addmod(s1, a7, PRIME);
        s2 = addmod(s2, a8, PRIME);
        (s0,,,) = _permute(s0, s1, s2, s3, rc);
        return s0;
    }
}
