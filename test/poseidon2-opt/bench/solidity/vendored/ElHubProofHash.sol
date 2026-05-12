// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Constants} from "./ElHubConstants.sol";

/// @notice Poseidon2 hash helpers (BN254 field, width t=3) for settlement proof public inputs.
/// @dev Parameters match the proving pipeline: RF=8, RP=56, alpha=5.
library ProofHash {
    uint256 internal constant P = Constants.SNARK_SCALAR_FIELD;
    uint256 internal constant EXTERNAL_ROUNDS = 8;
    uint256 internal constant INTERNAL_ROUNDS = 56;
    uint256 internal constant EXTERNAL_HALF_ROUNDS = EXTERNAL_ROUNDS / 2;

    function toField(uint256 value) internal pure returns (uint256) {
        return value % P;
    }

    function hashPair(uint256 left, uint256 right) internal pure returns (uint256) {
        uint256[3] memory state = [toField(left), toField(right), uint256(0)];
        _permute(state);
        return state[0];
    }

    function permute3(uint256[3] memory state) internal pure returns (uint256[3] memory) {
        state[0] = toField(state[0]);
        state[1] = toField(state[1]);
        state[2] = toField(state[2]);
        _permute(state);
        return state;
    }

    function _permute(uint256[3] memory state) private pure {
        _matmulExternal(state);

        for (uint256 round = 0; round < EXTERNAL_HALF_ROUNDS; round++) {
            _addExternalRoundConstants(state, round);
            _sboxFull(state);
            _matmulExternal(state);
        }

        for (uint256 round = 0; round < INTERNAL_ROUNDS; round++) {
            state[0] = addmod(state[0], _rcInternal(round), P);
            state[0] = _pow5(state[0]);
            _matmulInternal(state);
        }

        for (uint256 round = EXTERNAL_HALF_ROUNDS; round < EXTERNAL_ROUNDS; round++) {
            _addExternalRoundConstants(state, round);
            _sboxFull(state);
            _matmulExternal(state);
        }
    }

    function _addExternalRoundConstants(uint256[3] memory state, uint256 round) private pure {
        uint256 base = round * 3;
        state[0] = addmod(state[0], _rcExternal(base), P);
        state[1] = addmod(state[1], _rcExternal(base + 1), P);
        state[2] = addmod(state[2], _rcExternal(base + 2), P);
    }

    function _sboxFull(uint256[3] memory state) private pure {
        state[0] = _pow5(state[0]);
        state[1] = _pow5(state[1]);
        state[2] = _pow5(state[2]);
    }

    function _pow5(uint256 value) private pure returns (uint256) {
        uint256 valueSquared = mulmod(value, value, P);
        uint256 valueFourth = mulmod(valueSquared, valueSquared, P);
        return mulmod(valueFourth, value, P);
    }

    // External matrix for t=3, equivalent to adding sum(state) to each lane.
    function _matmulExternal(uint256[3] memory state) private pure {
        uint256 s0 = state[0];
        uint256 s1 = state[1];
        uint256 s2 = state[2];

        uint256 t0 = addmod(addmod(s0, s0, P), addmod(s1, s2, P), P);
        uint256 t1 = addmod(addmod(s1, s1, P), addmod(s0, s2, P), P);
        uint256 t2 = addmod(addmod(s2, s2, P), addmod(s0, s1, P), P);

        state[0] = t0;
        state[1] = t1;
        state[2] = t2;
    }

    // Internal matrix for t=3 with MAT_DIAG3_M_1 = [2,2,3]:
    // lane_i' = MAT_DIAG3_M_1[i] * lane_i + sum(state).
    function _matmulInternal(uint256[3] memory state) private pure {
        uint256 s0 = state[0];
        uint256 s1 = state[1];
        uint256 s2 = state[2];

        uint256 sum = addmod(addmod(s0, s1, P), s2, P);
        uint256 twoS0 = addmod(s0, s0, P);
        uint256 twoS1 = addmod(s1, s1, P);
        uint256 tripleS2 = addmod(s2, addmod(s2, s2, P), P);

        state[0] = addmod(sum, twoS0, P);
        state[1] = addmod(sum, twoS1, P);
        state[2] = addmod(sum, tripleS2, P);
    }

    function _rcExternal(uint256 index) private pure returns (uint256 value) {
        assembly {
            switch index
            case 0 { value := 0x1d066a255517b7fd8bddd3a93f7804ef7f8fcde48bb4c37a59a09a1a97052816 }
            case 1 { value := 0x29daefb55f6f2dc6ac3f089cebcc6120b7c6fef31367b68eb7238547d32c1610 }
            case 2 { value := 0x1f2cb1624a78ee001ecbd88ad959d7012572d76f08ec5c4f9e8b7ad7b0b4e1d1 }
            case 3 { value := 0x0aad2e79f15735f2bd77c0ed3d14aa27b11f092a53bbc6e1db0672ded84f31e5 }
            case 4 { value := 0x2252624f8617738cd6f661dd4094375f37028a98f1dece66091ccf1595b43f28 }
            case 5 { value := 0x1a24913a928b38485a65a84a291da1ff91c20626524b2b87d49f4f2c9018d735 }
            case 6 { value := 0x22fc468f1759b74d7bfc427b5f11ebb10a41515ddff497b14fd6dae1508fc47a }
            case 7 { value := 0x1059ca787f1f89ed9cd026e9c9ca107ae61956ff0b4121d5efd65515617f6e4d }
            case 8 { value := 0x02be9473358461d8f61f3536d877de982123011f0bf6f155a45cbbfae8b981ce }
            case 9 { value := 0x0ec96c8e32962d462778a749c82ed623aba9b669ac5b8736a1ff3a441a5084a4 }
            case 10 { value := 0x292f906e073677405442d9553c45fa3f5a47a7cdb8c99f9648fb2e4d814df57e }
            case 11 { value := 0x274982444157b86726c11b9a0f5e39a5cc611160a394ea460c63f0b2ffe5657e }
            case 12 { value := 0x1acd63c67fbc9ab1626ed93491bda32e5da18ea9d8e4f10178d04aa6f8747ad0 }
            case 13 { value := 0x19f8a5d670e8ab66c4e3144be58ef6901bf93375e2323ec3ca8c86cd2a28b5a5 }
            case 14 { value := 0x1c0dc443519ad7a86efa40d2df10a011068193ea51f6c92ae1cfbb5f7b9b6893 }
            case 15 { value := 0x14b39e7aa4068dbe50fe7190e421dc19fbeab33cb4f6a2c4180e4c3224987d3d }
            case 16 { value := 0x1d449b71bd826ec58f28c63ea6c561b7b820fc519f01f021afb1e35e28b0795e }
            case 17 { value := 0x1ea2c9a89baaddbb60fa97fe60fe9d8e89de141689d1252276524dc0a9e987fc }
            case 18 { value := 0x0478d66d43535a8cb57e9c1c3d6a2bd7591f9a46a0e9c058134d5cefdb3c7ff1 }
            case 19 { value := 0x19272db71eece6a6f608f3b2717f9cd2662e26ad86c400b21cde5e4a7b00bebe }
            case 20 { value := 0x14226537335cab33c749c746f09208abb2dd1bd66a87ef75039be846af134166 }
            case 21 { value := 0x01fd6af15956294f9dfe38c0d976a088b21c21e4a1c2e823f912f44961f9a9ce }
            case 22 { value := 0x18e5abedd626ec307bca190b8b2cab1aaee2e62ed229ba5a5ad8518d4e5f2a57 }
            case 23 { value := 0x0fc1bbceba0590f5abbdffa6d3b35e3297c021a3a409926d0e2d54dc1c84fda6 }
            default {
                revert(0, 0)
            }
        }
    }

    function _rcInternal(uint256 index) private pure returns (uint256 value) {
        assembly {
            switch index
            case 0 { value := 0x1a1d063e54b1e764b63e1855bff015b8cedd192f47308731499573f23597d4b5 }
            case 1 { value := 0x26abc66f3fdf8e68839d10956259063708235dccc1aa3793b91b002c5b257c37 }
            case 2 { value := 0x0c7c64a9d887385381a578cfed5aed370754427aabca92a70b3c2b12ff4d7be8 }
            case 3 { value := 0x1cf5998769e9fab79e17f0b6d08b2d1eba2ebac30dc386b0edd383831354b495 }
            case 4 { value := 0x0f5e3a8566be31b7564ca60461e9e08b19828764a9669bc17aba0b97e66b0109 }
            case 5 { value := 0x18df6a9d19ea90d895e60e4db0794a01f359a53a180b7d4b42bf3d7a531c976e }
            case 6 { value := 0x04f7bf2c5c0538ac6e4b782c3c6e601ad0ea1d3a3b9d25ef4e324055fa3123dc }
            case 7 { value := 0x29c76ce22255206e3c40058523748531e770c0584aa2328ce55d54628b89ebe6 }
            case 8 { value := 0x198d425a45b78e85c053659ab4347f5d65b1b8e9c6108dbe00e0e945dbc5ff15 }
            case 9 { value := 0x25ee27ab6296cd5e6af3cc79c598a1daa7ff7f6878b3c49d49d3a9a90c3fdf74 }
            case 10 { value := 0x138ea8e0af41a1e024561001c0b6eb1505845d7d0c55b1b2c0f88687a96d1381 }
            case 11 { value := 0x306197fb3fab671ef6e7c2cba2eefd0e42851b5b9811f2ca4013370a01d95687 }
            case 12 { value := 0x1a0c7d52dc32a4432b66f0b4894d4f1a21db7565e5b4250486419eaf00e8f620 }
            case 13 { value := 0x2b46b418de80915f3ff86a8e5c8bdfccebfbe5f55163cd6caa52997da2c54a9f }
            case 14 { value := 0x12d3e0dc0085873701f8b777b9673af9613a1af5db48e05bfb46e312b5829f64 }
            case 15 { value := 0x263390cf74dc3a8870f5002ed21d089ffb2bf768230f648dba338a5cb19b3a1f }
            case 16 { value := 0x0a14f33a5fe668a60ac884b4ca607ad0f8abb5af40f96f1d7d543db52b003dcd }
            case 17 { value := 0x28ead9c586513eab1a5e86509d68b2da27be3a4f01171a1dd847df829bc683b9 }
            case 18 { value := 0x1c6ab1c328c3c6430972031f1bdb2ac9888f0ea1abe71cffea16cda6e1a7416c }
            case 19 { value := 0x1fc7e71bc0b819792b2500239f7f8de04f6decd608cb98a932346015c5b42c94 }
            case 20 { value := 0x03e107eb3a42b2ece380e0d860298f17c0c1e197c952650ee6dd85b93a0ddaa8 }
            case 21 { value := 0x2d354a251f381a4669c0d52bf88b772c46452ca57c08697f454505f6941d78cd }
            case 22 { value := 0x094af88ab05d94baf687ef14bc566d1c522551d61606eda3d14b4606826f794b }
            case 23 { value := 0x19705b783bf3d2dc19bcaeabf02f8ca5e1ab5b6f2e3195a9d52b2d249d1396f7 }
            case 24 { value := 0x09bf4acc3a8bce3f1fcc33fee54fc5b28723b16b7d740a3e60cef6852271200e }
            case 25 { value := 0x1803f8200db6013c50f83c0c8fab62843413732f301f7058543a073f3f3b5e4e }
            case 26 { value := 0x0f80afb5046244de30595b160b8d1f38bf6fb02d4454c0add41f7fef2faf3e5c }
            case 27 { value := 0x126ee1f8504f15c3d77f0088c1cfc964abcfcf643f4a6fea7dc3f98219529d78 }
            case 28 { value := 0x23c203d10cfcc60f69bfb3d919552ca10ffb4ee63175ddf8ef86f991d7d0a591 }
            case 29 { value := 0x2a2ae15d8b143709ec0d09705fa3a6303dec1ee4eec2cf747c5a339f7744fb94 }
            case 30 { value := 0x07b60dee586ed6ef47e5c381ab6343ecc3d3b3006cb461bbb6b5d89081970b2b }
            case 31 { value := 0x27316b559be3edfd885d95c494c1ae3d8a98a320baa7d152132cfe583c9311bd }
            case 32 { value := 0x1d5c49ba157c32b8d8937cb2d3f84311ef834cc2a743ed662f5f9af0c0342e76 }
            case 33 { value := 0x2f8b124e78163b2f332774e0b850b5ec09c01bf6979938f67c24bd5940968488 }
            case 34 { value := 0x1e6843a5457416b6dc5b7aa09a9ce21b1d4cba6554e51d84665f75260113b3d5 }
            case 35 { value := 0x11cdf00a35f650c55fca25c9929c8ad9a68daf9ac6a189ab1f5bc79f21641d4b }
            case 36 { value := 0x21632de3d3bbc5e42ef36e588158d6d4608b2815c77355b7e82b5b9b7eb560bc }
            case 37 { value := 0x0de625758452efbd97b27025fbd245e0255ae48ef2a329e449d7b5c51c18498a }
            case 38 { value := 0x2ad253c053e75213e2febfd4d976cc01dd9e1e1c6f0fb6b09b09546ba0838098 }
            case 39 { value := 0x1d6b169ed63872dc6ec7681ec39b3be93dd49cdd13c813b7d35702e38d60b077 }
            case 40 { value := 0x1660b740a143664bb9127c4941b67fed0be3ea70a24d5568c3a54e706cfef7fe }
            case 41 { value := 0x0065a92d1de81f34114f4ca2deef76e0ceacdddb12cf879096a29f10376ccbfe }
            case 42 { value := 0x1f11f065202535987367f823da7d672c353ebe2ccbc4869bcf30d50a5871040d }
            case 43 { value := 0x26596f5c5dd5a5d1b437ce7b14a2c3dd3bd1d1a39b6759ba110852d17df0693e }
            case 44 { value := 0x16f49bc727e45a2f7bf3056efcf8b6d38539c4163a5f1e706743db15af91860f }
            case 45 { value := 0x1abe1deb45b3e3119954175efb331bf4568feaf7ea8b3dc5e1a4e7438dd39e5f }
            case 46 { value := 0x0e426ccab66984d1d8993a74ca548b779f5db92aaec5f102020d34aea15fba59 }
            case 47 { value := 0x0e7c30c2e2e8957f4933bd1942053f1f0071684b902d534fa841924303f6a6c6 }
            case 48 { value := 0x0812a017ca92cf0a1622708fc7edff1d6166ded6e3528ead4c76e1f31d3fc69d }
            case 49 { value := 0x21a5ade3df2bc1b5bba949d1db96040068afe5026edd7a9c2e276b47cf010d54 }
            case 50 { value := 0x01f3035463816c84ad711bf1a058c6c6bd101945f50e5afe72b1a5233f8749ce }
            case 51 { value := 0x0b115572f038c0e2028c2aafc2d06a5e8bf2f9398dbd0fdf4dcaa82b0f0c1c8b }
            case 52 { value := 0x1c38ec0b99b62fd4f0ef255543f50d2e27fc24db42bc910a3460613b6ef59e2f }
            case 53 { value := 0x1c89c6d9666272e8425c3ff1f4ac737b2f5d314606a297d4b1d0b254d880c53e }
            case 54 { value := 0x03326e643580356bf6d44008ae4c042a21ad4880097a5eb38b71e2311bb88f8f }
            case 55 { value := 0x268076b0054fb73f67cee9ea0e51e3ad50f27a6434b5dceb5bdde2299910a4c9 }
            default {
                revert(0, 0)
            }
        }
    }

}
