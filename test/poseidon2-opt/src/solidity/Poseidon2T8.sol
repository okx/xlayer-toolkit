// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

/// @title Poseidon2T8
/// @notice Poseidon2 direct permutation for BN254 (t=8, RF=8, RP=57, x^5).
/// @dev rate=7, capacity=1. hash7(a0..a6) = perm(a0..a6,0)[0]. External matrix: circ(2*M4, M4) block structure.
///      Internal matrix: 8-element diagonal (254-bit values, requires mulmod).
///      Constants from HorizenLabs SAGE script (t=8 BN254).
///      RC packed: full rounds store 8 RCs per round, partial rounds store 1 RC per round.
///      Layout: [first4_full: 32×32B][partial: 57×32B][last4_full: 32×32B] = 3,872 bytes.
library Poseidon2T8 {
    uint256 internal constant PRIME = 0x30644e72e131a029b85045b68181585d2833e84879b9709143e1f593f0000001;

    bytes internal constant RC_BYTES =
        hex"0dad22d08a6b8d81d4a5ffc34b9677a7c5254c85e953551f9eba9a0a97590c1003cfc441111f1bab6e75957b9f0274e92d17aefc2d8da460435dfaf259bd103927c6d1b8a2e2ce670376cd2970192a2a08e4290883f6ca49e7976c6c447d6392"
        hex"28f2882b9abfda8efc2d121da0c871d2d5313a53c67d0407eef4e93ee23e6c2d0a3943390fe4939fa2e931e18094c7c93aa107ced2bfaefcfe5e613a3f1262d52a8f37d8da8f2319e188f8909007408b57fba3555bb784c1ad6c7b0755805456"
        hex"0cef8658e33f20c39649528f353ef5d03198c75683f8493534add693a4ff4f0f1cdc2a6f0f0e7c6c62ee1c0cad4fd11363a48db7095171faaf9a7b6e01c3e52b0a2e681a2db19c8d1cfb0c28f0b7b3d9830d35fca8c0b076b4e64328060139d6"
        hex"16f013cd703be7de16b4361ce5c67cc2997f858e8a808885da67fbafd30d271729af57131c9cf548be669fe76c675e6d90bee17a76cccf4ddc5d35f9a936ebb821807b1ec6258bb155ed159da90b815dee119eae8138b1bdf950111bf5205b3b"
        hex"07c00db8c50a8c860fbcb8ebd234a54350bdbcb8747891a4e5adab1c4abc690922bc08fc054d08a3dbb6094396d0de373a4c33205c49a1254cf25ebec17477652dad58bdf3e24c78f21146de084d9b8afad58956fedce67d43f7d375a813bb2e"
        hex"292cee6bc19a64dc5a8a74036e676e238f60b4577db86213ced417906f1d6e9127d655ae125928ad6b48bba54593b74ca0c23002b32a0a9ef375939a22387a8c0e0e2e781fe9ac0a97f0d961c7b359a415d1ead41c99eccee90e56b68fbfa2a8"
        hex"13fec23e678d1c9943b6daed8ed8212289116ab96344ded7ced8aac2f09f167227550dd21647e37fc31640684e02cb07810669b1c1545443fd58204b2cde73c21de6d5f356a92c48c7b9f6aa45c8a6216e0a6adbc799c0bec242054674cb8f09"
        hex"14c5347c4580363f74c885d1fbb378c61d953e490892b10baf84f6e1f3a3f39d27f2768023c4df7952ca0d967f14034e98c4ca76973ae1cddfccd212cbd786831f4f499fc4853f7e189ad6d2269c467f77e15bbd28963c516b4fbf1ba7b88f95"
        hex"0d62ba9a8de3b97c72a5425a97a7f027fbad23f299ff46bafa12dcffb0e72bf122b649ae468f20c7cbfb435d932ba9ba4be14ea40c0c54e6bec970ab4c513f0403a1aae439e47e7e14186d5513da5e263e063a3da6d042c16e55cab2e81a8e95"
        hex"25c7eee1fce422600f5b1e78323f2e99cceee803f62763217eadbd046c1e0e6c1c66258f103a955274ed71de56169bba34ff6aea97a2c32b98805dc3b011a38329403b00757a647671a3691094aef420ad830f95743d45894d6d7f40aa356e4b"
        hex"13496363ef5f7d0e91fd1319fd5dc0269c5190d05d8a0ad28a3ce0638a133e0e1c6a4586c15c4638a1686921d7c204e2b6e1a88c1fc49dcfb87ded2a1ed7edc50da23df12d0bf47bb92f15ee189386c20f552d0bc66ae492b92d69556b2fe75a"
        hex"155be88bc5ddf8e0c6c741286cdd5ddd559279a455b9bbb61d5a0b004e545d5e0553fbb5b32db860e0bb12cef3aab4e0dbbdb1ea8704d335a18fa8b4df112c3612f6a3a61a3139221cb5875cf455b942580c00942499932dfcacf6f75cb80ad6"
        hex"2faf9e95457781b3c61de8a1faadda67f76f52bb81255fac8819bcc104071e051c7639cb68d3cfa69f3d795d1a1dd4eba176d0c29701e7b677ea0750b4ccd1db0d9d85a46281f81502fbcfb430f4d08ab504c502d2feae2ab4a26d87bebea0dd"
        hex"00a9b7074ea11d9931cf4af16952f398777aaa36413df14cedc101c7693812d307fab349ddb7d62a5edc0b6a62b300715634e5dccab808d8fa6ae62b406705a311f8f3afbd6fe6bda7d055a536ab3de9c40c8155b31d397f63ef21ac974cf52d"
        hex"0007c569f8f49899805d22a1930883968a3cf058993e0adfd06da437ae50e83015dfb18bf1b6087c0e638f2189a7b34534549ffe8fca5afccf7e528a3338cc922140caa062d2fa72722ad48fb71bbc9f534043dab90dfa24b96664eaa2f0ac6a"
        hex"11c06fe4e5398d4704271b84e6023b07b189dd1d2023dd599b33defe4251b7150775f90bae5f8f8157eb73bbc7ae69b74d44761cf0df3b4666eeb2860878c0df0225befb64b758b837a4305e104d5e510d893653559d8768dc79325ff89d6b9f"
        hex"201a730245d9227f1232cc02f486c18cfa1fba40665ed3d1bbbdcd19b03cac4f128b63b12a6647f80c686aaab15b0563c1a33f475dc18caa434ab64f1e290acb0a34ce8153d4e2e1158de05d276530cf3c749c16c7e09f3b671a973b0efb0839"
        hex"2809c5d323665513c8c4a96ea4dc08e3aba43699bca1198f2b559915082495ce23b929e7d71fe425f36f32975e9a68bbf83c16622678f061ed78a0c9ce318be31ca1a93d02ae448ab773f95c6b88c0d01f89c0c3d25ad625042771dd5a7e74a9"
        hex"03c7381ccdfd209a8cba5627a058c33f472b24d2b1a55d9dd47f60dc7b474e7e00be1a29bb668a25eaedffccef6c01c90688229e8fc4be9812e371d4d61c30152c821bfbd5c415fc076fc83895edab9e5256ee826946a865b8c82f0189af4626"
        hex"0b8ff5b252182f6a15cff90144c1e7ac1678739882c90fe46d0a29db7a0cba771c0e94b15306baf1b017623888b8d4c5402ee81fd213c4a5e42f52729deb7d5c2031deb0f13ce17a5b44edbacf5a0410e23348c2c7657383a8ffdeb5c5ca1cd4"
        hex"0e34d14f44e8eb98ac078ec90eb718c3034249fbaeb13d24f3d5b6a4002018ac2a10f1b76f8b1cc429820030c58b3d23ebfb775a43b07928b9868891c2cb4cca0535bf4f7fb763f981d2c0c7ecd2237a461ac385e2235fb35222b512f1dbd1b7"
        hex"12ccb3fbffeff74fb7ce3b9943f609dc0d7fe34e3b5e6b199628e86d5576cc181f44cd78220a2e66be6c9eb3bcffc498a47f22c3eb476591cf456d518e3e126c1d60e9e3444a748b8c22d7d10e825c536290b723fcdfa046436353d6f9abc073"
        hex"05a3ccc67bd014ef2544927f9b96ff58e348954e40af67861ab88d78ff4b66881be5b195896e9ec23b9d3eb898734c385272ed64bdcb236223f5a3436986dc6d1d6427dd07a0b46a8ebacaa82e8c04de8e7e94a18849c9275b8b4827a873cdab"
        hex"2f09a403f946b692704fe4d5ae69625441c93a7f93dcb4f8f7d337baa735ad9a1807540511593488e084b7297b6ff67b748c71731b6ca64aa8d3823e81f41b370f1daab7a702ac80d108b24845bda04b732f3564ebe57392e470380199522e1d"
        hex"1797d0f72bf0b47a45ceaf82df261439bc5e3b0ae55cf1069733d5a0b51765ca2adbb9b4003631c5e3d02ce959930c75d4d25281c86febc61dfdf35e00cfbdad1347ad87393ef928d2800fa2a548328ef9bddf5646da79d507d2f2055db335d6"
        hex"15658e02d31e2c200dadf6a985652eccd30cb959168cde7b74c7239539d2df1e01f00dc28bced12a74c3ce687dd3fa996d6f8bb29bc60cda4f3aed191a6fe8d0154ebcc230244b68b9a8f51a56ff0541a92ea2cbb3e77b263cb03a8bd89491f7"
        hex"1f65f74b523a8c875885378e93d1946c7a3f810e2eecdea94b80c4f741ea6cf92504a559a4bd23ed689acc9b6cb4062479a6b29692e2b8cce40058daf050577824496d9926e4e565ef860e52396a2935689c87ca99abd046bc279ce1bfc43206"
        hex"2c9ccd22b143f4d8d483846d1960e7144a5c9354ea48cd1a71bdc82fbb9298382b9bd02e1b064a8db321a1cd212a7a6dc47274f6eb5fcfa4f17d6f690dddf8c40b21f0004118382f32fe441fbf36c0a38ae41873ae42d3b6ea5f0c6816e00472"
        hex"10756efb491852587059f3e48b605a3bebabaab0a1ee5ff1758eb30623b7602c127574a38823886d1f4841b540e29d67efe35aa8b3c685f969b6bc6cbab5064a24751d620ed2a3db4382265b8c33b666b85beae7aa87f38e28bd2f8d637ff9d0"
        hex"2e3d7208892e8a92e887fccccfe04d8d0fe994bc443641a9fc76c43da02f453d11c3f6719071e6810699be20e1b1858b9ed00d8166bf15434cd5e43507b9d62b00b86112693a4e7f3ac4eadfcc3f04d24a7afe51a87f82d4a435ad27f30aa2f9"
        hex"1a77348400a87f0180e294286a7a06c857f590e8ed17eed7a6b4cc1ca5a97929207feb0ffff2e419bc967dd544abbdd2dcc601316f49957f2319c9a04f56157d0df4aac4e6483265aa3fc462835a90380bc84004fc46d1a85e61baed3196ba48"
        hex"2f2df3db6ed0e27d3151201dfe7f57fc2e5ccc69c2458535dbdbb5d88aeabb4f2f51811c3568dbae396f86838c5c8b1bbf9b5bcb2ce98542e289184b95f74b7e1198ec466dc8c3f55b048369eac0490e835928891325d4cf4461da1d22230219"
        hex"19036827eb0714a1ee4fdd653d8667df192402e290dfdfc39bf005fdfa86c0430978d774018c29f2818df365312371ce4082a6c8c52d2a965516b76436349069231ed2d94767eb9ace111af9317b233fee037214e3f6d7e366a5812c8fd1dce5"
        hex"0fbd8502ceba8ab93eb04d1db535d25f4c3be8acac4e8e0467b9d606653456c220e9fac35dda464e436a4d2eae4cdd5b52c9b712d5b4bfa43334463f8478d4bb15ba9fc4b175278a12a5ab39ee0121b06dd09b923bdedb69a26182821445ba00"
        hex"0c3c9aec9048b10a06d062675b63417a1ae8704f2918382466bf575e22a654d32795a46eb4c79595a9de2191c524f0aaf92f764153b23c357ed50bf3a91cddf010ab7893c4253d861276ea30f229eb86b90c69985fb6dde4aa50e24828caa81a"
        hex"2d4509d8159af62c44503f64fc01e953e90c6dced8ba75c58df2aa090a5fd359157946957f4feb94eae09b9a6c272204d107ea7b0e31b67524a6c9ee7f04e7b930464efe02b65b862f9a0b59fea6d6934b393e65cdc3d29ae67a751a0d0f136a"
        hex"0965b3a2d05666d38ffcdac4e5ed020c742ba41d760e70f74dcd8f8b1324c90124531c784663d57639928f0a8f152038a779eebbd70f6585dacc971668ebec552202070df8f85b79bf7debf24a9cc0f2cf30370f26a9372e01718dae7cb6171d"
        hex"08282fc0baa2e9eb76167b9ab2405db9c78f1f37b168be6435d5385a806e745a178c3d6e47cd33e5570311ec8ad8dbca0dbf54aadd1393738d898384c57795e712ad905f9d82f33643b1fefb90dcefffeb818d1ec3f4fc3d6857203eff5ed1ea"
        hex"229682c9e4165b6ed1a2870c14a1c8bb7b1c7d3b52f42ce0228b85480666b4c425190d853744dc11d155de5e479640302a333d47cf18dbf1ff241ce42c88d4c900db47fadc76bf4fd8dcfe26908fe48ab42d399da939ac1f167ca8600cfbe7bc"
        hex"2ba5e88adcbe025760f2c8654935f0557d14c6d4125a838f312f2ba439e2e94c1376bbae85699dcc294f850c858b4b370e51ff3139bc3e0a1e52eb58d08ca41b1333fda1e3d58e0747f5c7361d5075526933ea283eee2ac37b6042c6083b6a42"
        hex"28bfc4dc9594e9add687744b79f4feb979e2143d742d4e4d1d5bb64bb799a02a"
;

    function hash7(
        uint256 a0, uint256 a1, uint256 a2, uint256 a3,
        uint256 a4, uint256 a5, uint256 a6
    ) internal pure returns (uint256 result) {
        bytes memory rc = RC_BYTES;
        uint256 P = PRIME;

        assembly {
            let rcPtr := add(rc, 32)
            let s0 := a0 let s1 := a1 let s2 := a2 let s3 := a3
            let s4 := a4 let s5 := a5 let s6 := a6 let s7 := 0

            function sbox(x, prime) -> y {
                let t := mulmod(x, x, prime)
                y := mulmod(mulmod(t, t, prime), x, prime)
            }

            function matmulM4(v0,v1,v2,v3,prime) -> o0,o1,o2,o3 {
                let t0 := addmod(v0, v1, prime)
                let t1 := addmod(v2, v3, prime)
                let t2 := addmod(mulmod(v1, 2, prime), t1, prime)
                let t3 := addmod(mulmod(v3, 2, prime), t0, prime)
                let t4 := addmod(mulmod(t1, 4, prime), t3, prime)
                let t5 := addmod(mulmod(t0, 4, prime), t2, prime)
                o0 := addmod(t3, t5, prime)
                o1 := t5
                o2 := addmod(t2, t4, prime)
                o3 := t4
            }

            function externalLayer(v0,v1,v2,v3,v4,v5,v6,v7,prime) -> o0,o1,o2,o3,o4,o5,o6,o7 {
                let b00, b01, b02, b03 := matmulM4(v0,v1,v2,v3,prime)
                let b10, b11, b12, b13 := matmulM4(v4,v5,v6,v7,prime)
                let sum0 := add(b00, b10)
                let sum1 := add(b01, b11)
                let sum2 := add(b02, b12)
                let sum3 := add(b03, b13)
                o0 := addmod(b00, sum0, prime)
                o1 := addmod(b01, sum1, prime)
                o2 := addmod(b02, sum2, prime)
                o3 := addmod(b03, sum3, prime)
                o4 := addmod(b10, sum0, prime)
                o5 := addmod(b11, sum1, prime)
                o6 := addmod(b12, sum2, prime)
                o7 := addmod(b13, sum3, prime)
            }

            // ── Initial external layer ──
            s0,s1,s2,s3,s4,s5,s6,s7 := externalLayer(s0,s1,s2,s3,s4,s5,s6,s7,P)

            // ── First 4 full rounds ──
            // Packed offset: 0. Each round = 8 × 32 = 256 bytes.
            for { let r := 0 } lt(r, 4) { r := add(r, 1) } {
                let base := mul(r, 256)

                s0 := addmod(s0, mload(add(rcPtr, base)), P)
                s1 := addmod(s1, mload(add(rcPtr, add(base, 0x20))), P)
                s2 := addmod(s2, mload(add(rcPtr, add(base, 0x40))), P)
                s3 := addmod(s3, mload(add(rcPtr, add(base, 0x60))), P)
                s4 := addmod(s4, mload(add(rcPtr, add(base, 0x80))), P)
                s5 := addmod(s5, mload(add(rcPtr, add(base, 0xa0))), P)
                s6 := addmod(s6, mload(add(rcPtr, add(base, 0xc0))), P)
                s7 := addmod(s7, mload(add(rcPtr, add(base, 0xe0))), P)

                s0 := sbox(s0, P)
                s1 := sbox(s1, P)
                s2 := sbox(s2, P)
                s3 := sbox(s3, P)
                s4 := sbox(s4, P)
                s5 := sbox(s5, P)
                s6 := sbox(s6, P)
                s7 := sbox(s7, P)

                s0,s1,s2,s3,s4,s5,s6,s7 := externalLayer(s0,s1,s2,s3,s4,s5,s6,s7,P)
            }

            // ── 57 partial rounds ──
            // Packed offset: 1024 (after 32 full-round values × 32 bytes).
            // Each partial round = 1 × 32 bytes.
            let d0 := 0x05bffb5e301d8c468c35e24eb2165b6b71725fb7ac9a48efe5ce041bdb05676d
            let d1 := 0x2aa7a81812688343fc6d78073312996d75f4c5505db0ed22af5ec0df7888cdc7
            let d2 := 0x2f5856fd71dab60d78cc3af15a89c1e4d61ba189849a4cea10acc1dd228faf00
            let d3 := 0x12299a260999ac95d271e184968cda40bd4358877a6dcf43d779251fffa61348
            let d4 := 0x1443aad4693d692a62a8e21f03d5643a123f0c8783a3d27c275f9d01089685fb
            let d5 := 0x21561b0204a44488082e31472f5885a3adc179bb278233aedc4b316369ec9937
            let d6 := 0x0c7cc2afa53f9898f30a69b294a4e24f6b2176e1ae0ca49b021792d55e34e97d
            let d7 := 0x2dd221096053de389fae88e7caa5c43ab55e22aeb758ee130d1246c1dff47b53

            let partialBase := add(rcPtr, 1024)
            for { let r := 0 } lt(r, 57) { r := add(r, 1) } {
                s0 := addmod(s0, mload(add(partialBase, mul(r, 32))), P)

                s0 := sbox(s0, P)

                let sum := addmod(addmod(addmod(s0, s1, P), addmod(s2, s3, P), P),
                                  addmod(addmod(s4, s5, P), addmod(s6, s7, P), P), P)
                s0 := addmod(mulmod(s0, d0, P), sum, P)
                s1 := addmod(mulmod(s1, d1, P), sum, P)
                s2 := addmod(mulmod(s2, d2, P), sum, P)
                s3 := addmod(mulmod(s3, d3, P), sum, P)
                s4 := addmod(mulmod(s4, d4, P), sum, P)
                s5 := addmod(mulmod(s5, d5, P), sum, P)
                s6 := addmod(mulmod(s6, d6, P), sum, P)
                s7 := addmod(mulmod(s7, d7, P), sum, P)
            }

            // ── Last 4 full rounds ──
            // Packed offset: 1024 + 57×32 = 2848.
            let lastBase := add(rcPtr, 2848)
            for { let r := 0 } lt(r, 4) { r := add(r, 1) } {
                let base := mul(r, 256)

                s0 := addmod(s0, mload(add(lastBase, base)), P)
                s1 := addmod(s1, mload(add(lastBase, add(base, 0x20))), P)
                s2 := addmod(s2, mload(add(lastBase, add(base, 0x40))), P)
                s3 := addmod(s3, mload(add(lastBase, add(base, 0x60))), P)
                s4 := addmod(s4, mload(add(lastBase, add(base, 0x80))), P)
                s5 := addmod(s5, mload(add(lastBase, add(base, 0xa0))), P)
                s6 := addmod(s6, mload(add(lastBase, add(base, 0xc0))), P)
                s7 := addmod(s7, mload(add(lastBase, add(base, 0xe0))), P)

                s0 := sbox(s0, P)
                s1 := sbox(s1, P)
                s2 := sbox(s2, P)
                s3 := sbox(s3, P)
                s4 := sbox(s4, P)
                s5 := sbox(s5, P)
                s6 := sbox(s6, P)
                s7 := sbox(s7, P)

                s0,s1,s2,s3,s4,s5,s6,s7 := externalLayer(s0,s1,s2,s3,s4,s5,s6,s7,P)
            }

            result := s0
        }

        return result;
    }

    function hash5_padded(uint256 a0, uint256 a1, uint256 a2, uint256 a3, uint256 a4) internal pure returns (uint256) {
        return hash7(a0, a1, a2, a3, a4, 0, 0);
    }

    function hash6_padded(uint256 a0, uint256 a1, uint256 a2, uint256 a3, uint256 a4, uint256 a5) internal pure returns (uint256) {
        return hash7(a0, a1, a2, a3, a4, a5, 0);
    }

    function hash4_padded(uint256 a0, uint256 a1, uint256 a2, uint256 a3) internal pure returns (uint256) {
        return hash7(a0, a1, a2, a3, 0, 0, 0);
    }
}
