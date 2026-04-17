// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {Test, console} from "forge-std/Test.sol";
import {Poseidon1Wrapper} from "./wrappers/Poseidon1Wrapper.sol";
import {IP1Cljs1, IP1Cljs2, IP1Cljs3, IP1Cljs4, IP1Cljs5, IP1Cljs6} from "./wrappers/P1CljsDeployer.sol";
import {T2Wrapper} from "./wrappers/T2Wrapper.sol";
import {CompressWrapper} from "./wrappers/CompressWrapper.sol";
import {T3Wrapper} from "./wrappers/T3Wrapper.sol";
import {T4PermWrapper} from "./wrappers/T4PermWrapper.sol";
import {OptimizedWrapper} from "./wrappers/OptimizedWrapper.sol";
import {T8Wrapper} from "./wrappers/T8Wrapper.sol";
import {ZemseYulWrapper} from "./wrappers/ZemseYulWrapper.sol";
import {VkhWrapper} from "./wrappers/VkhWrapper.sol";
import {ElHubWrapper} from "./wrappers/ElHubWrapper.sol";

/// @notice Comprehensive gas benchmark: all Poseidon1 & Poseidon2 implementations.
contract FullBenchmark is Test {
    // P1 implementations
    Poseidon1Wrapper internal p1sol;
    address internal p1cljs_t2;
    address internal p1cljs_t3;
    address internal p1cljs_t4;
    address internal p1cljs_t5;
    address internal p1cljs_t6;
    address internal p1cljs_t7;

    // P2 implementations
    T2Wrapper internal p2t2;
    CompressWrapper internal p2t2ff;
    T3Wrapper internal p2t3;
    T4PermWrapper internal p2t4;
    OptimizedWrapper internal p2t4s;
    T8Wrapper internal p2t8;
    ZemseYulWrapper internal p2yul;
    VkhWrapper internal p2vkh;
    ElHubWrapper internal p2elhub;

    function _deployBytecodeFromFile(string memory path) internal returns (address) {
        string memory hexStr = vm.readFile(path);
        bytes memory bytecode = vm.parseBytes(hexStr);
        address addr;
        assembly {
            addr := create(0, add(bytecode, 0x20), mload(bytecode))
        }
        require(addr != address(0), string.concat("deploy failed: ", path));
        return addr;
    }

    function setUp() public {
        p1sol = new Poseidon1Wrapper();
        p2t2 = new T2Wrapper();
        p2t2ff = new CompressWrapper();
        p2t3 = new T3Wrapper();
        p2t4 = new T4PermWrapper();
        p2t4s = new OptimizedWrapper();
        p2t8 = new T8Wrapper();
        p2yul = new ZemseYulWrapper();
        p2vkh = new VkhWrapper();
        p2elhub = new ElHubWrapper();

        // Deploy circomlibjs bytecode contracts
        p1cljs_t2 = _deployBytecodeFromFile("bench/solidity/vendored/poseidon1_cljs/t2_bytecode.hex");
        p1cljs_t3 = _deployBytecodeFromFile("bench/solidity/vendored/poseidon1_cljs/t3_bytecode.hex");
        p1cljs_t4 = _deployBytecodeFromFile("bench/solidity/vendored/poseidon1_cljs/t4_bytecode.hex");
        p1cljs_t5 = _deployBytecodeFromFile("bench/solidity/vendored/poseidon1_cljs/t5_bytecode.hex");
        p1cljs_t6 = _deployBytecodeFromFile("bench/solidity/vendored/poseidon1_cljs/t6_bytecode.hex");
        p1cljs_t7 = _deployBytecodeFromFile("bench/solidity/vendored/poseidon1_cljs/t7_bytecode.hex");
    }

    // ================================================================
    //  Gas measurement helpers
    // ================================================================

    function _gasP1Cljs1(address addr, uint256 a) internal view returns (uint256) {
        uint256 g = gasleft();
        IP1Cljs1(addr).poseidon([a]);
        return g - gasleft();
    }

    function _gasP1Cljs2(address addr, uint256 a, uint256 b) internal view returns (uint256) {
        uint256 g = gasleft();
        IP1Cljs2(addr).poseidon([a, b]);
        return g - gasleft();
    }

    function _gasP1Cljs3(address addr, uint256 a, uint256 b, uint256 c) internal view returns (uint256) {
        uint256 g = gasleft();
        IP1Cljs3(addr).poseidon([a, b, c]);
        return g - gasleft();
    }

    function _gasP1Cljs4(address addr, uint256 a, uint256 b, uint256 c, uint256 d) internal view returns (uint256) {
        uint256 g = gasleft();
        IP1Cljs4(addr).poseidon([a, b, c, d]);
        return g - gasleft();
    }

    function _gasP1Cljs5(address addr, uint256 a, uint256 b, uint256 c, uint256 d, uint256 e) internal view returns (uint256) {
        uint256 g = gasleft();
        IP1Cljs5(addr).poseidon([a, b, c, d, e]);
        return g - gasleft();
    }

    function _gasP1Cljs6(address addr, uint256 a, uint256 b, uint256 c, uint256 d, uint256 e, uint256 f) internal view returns (uint256) {
        uint256 g = gasleft();
        IP1Cljs6(addr).poseidon([a, b, c, d, e, f]);
        return g - gasleft();
    }

    // ================================================================
    //  Main benchmark
    // ================================================================

    function test_gas_1_input() public view {
        uint256 g;
        console.log("--- 1 input ---");

        g = gasleft(); p1sol.hash_1(42);
        console.log("P1-chancehudson(t=2):  ", g - gasleft());

        console.log("P1-circomlibjs(t=2):   ", _gasP1Cljs1(p1cljs_t2, 42));

        g = gasleft(); p2t2.hash1(42);
        console.log("P2-T2 hash1:           ", g - gasleft());

        g = gasleft(); p2t4s.hash_1(42);
        console.log("P2-T4S hash1:          ", g - gasleft());

        g = gasleft(); p2yul.hash_1(42);
        console.log("P2-zemse hash1:        ", g - gasleft());

        g = gasleft(); p2vkh.hash_1(42);
        console.log("P2-Vkh hash1:          ", g - gasleft());
    }

    function test_gas_2_inputs() public view {
        uint256 g;
        console.log("--- 2 inputs ---");

        g = gasleft(); p1sol.hash_2(1, 2);
        console.log("P1-chancehudson(t=3):  ", g - gasleft());

        console.log("P1-circomlibjs(t=3):   ", _gasP1Cljs2(p1cljs_t3, 1, 2));

        g = gasleft(); p2t2ff.compress(1, 2);
        console.log("P2-T2FF compress:      ", g - gasleft());

        g = gasleft(); p2t3.hash2(1, 2);
        console.log("P2-T3 hash2:           ", g - gasleft());

        g = gasleft(); p2t4s.hash_2(1, 2);
        console.log("P2-T4S hash2:          ", g - gasleft());

        g = gasleft(); p2yul.hash_2(1, 2);
        console.log("P2-zemse hash2:        ", g - gasleft());

        g = gasleft(); p2vkh.hash_2(1, 2);
        console.log("P2-Vkh hash2:          ", g - gasleft());

        g = gasleft(); p2elhub.hash2(1, 2);
        console.log("P2-sserrano44 hash2:   ", g - gasleft());
    }

    function test_gas_3_inputs() public view {
        uint256 g;
        console.log("--- 3 inputs ---");

        g = gasleft(); p1sol.hash_3(1, 2, 3);
        console.log("P1-chancehudson(t=4):  ", g - gasleft());

        console.log("P1-circomlibjs(t=4):   ", _gasP1Cljs3(p1cljs_t4, 1, 2, 3));

        g = gasleft(); p2t4.hash3(1, 2, 3);
        console.log("P2-T4 hash3:           ", g - gasleft());

        g = gasleft(); p2t4s.hash_3(1, 2, 3);
        console.log("P2-T4S hash3:          ", g - gasleft());

        g = gasleft(); p2yul.hash_3(1, 2, 3);
        console.log("P2-zemse hash3:        ", g - gasleft());

        g = gasleft(); p2vkh.hash_3(1, 2, 3);
        console.log("P2-Vkh hash3:          ", g - gasleft());
    }

    function test_gas_4_inputs() public view {
        uint256 g;
        console.log("--- 4 inputs ---");

        g = gasleft(); p1sol.hash_4(1, 2, 3, 4);
        console.log("P1-chancehudson(t=5):  ", g - gasleft());

        console.log("P1-circomlibjs(t=5):   ", _gasP1Cljs4(p1cljs_t5, 1, 2, 3, 4));

        g = gasleft(); p2t4s.hash_4(1, 2, 3, 4);
        console.log("P2-T4S hash4:          ", g - gasleft());

        g = gasleft(); p2t8.hash4_padded(1, 2, 3, 4);
        console.log("P2-T8 hash4(pad):      ", g - gasleft());

        g = gasleft(); p2vkh.hash_4(1, 2, 3, 4);
        console.log("P2-Vkh hash4:          ", g - gasleft());
    }

    function test_gas_5_inputs() public view {
        uint256 g;
        console.log("--- 5 inputs ---");

        g = gasleft(); p1sol.hash_5(1, 2, 3, 4, 5);
        console.log("P1-chancehudson(t=6):  ", g - gasleft());

        console.log("P1-circomlibjs(t=6):   ", _gasP1Cljs5(p1cljs_t6, 1, 2, 3, 4, 5));

        g = gasleft(); p2t4s.hash_5(1, 2, 3, 4, 5);
        console.log("P2-T4S hash5:          ", g - gasleft());

        g = gasleft(); p2t8.hash5_padded(1, 2, 3, 4, 5);
        console.log("P2-T8 hash5(pad):      ", g - gasleft());

        g = gasleft(); p2vkh.hash_5(1, 2, 3, 4, 5);
        console.log("P2-Vkh hash5:          ", g - gasleft());
    }

    function test_gas_6_inputs() public view {
        uint256 g;
        console.log("--- 6 inputs ---");

        console.log("P1-circomlibjs(t=7):   ", _gasP1Cljs6(p1cljs_t7, 1, 2, 3, 4, 5, 6));

        g = gasleft(); p2t4s.hash_6(1, 2, 3, 4, 5, 6);
        console.log("P2-T4S hash6:          ", g - gasleft());

        g = gasleft(); p2t8.hash6_padded(1, 2, 3, 4, 5, 6);
        console.log("P2-T8 hash6(pad):      ", g - gasleft());

        g = gasleft(); p2vkh.hash_6(1, 2, 3, 4, 5, 6);
        console.log("P2-Vkh hash6:          ", g - gasleft());
    }

    function test_gas_7_inputs() public view {
        uint256 g;
        console.log("--- 7 inputs ---");

        g = gasleft(); p2t4s.hash_7(1, 2, 3, 4, 5, 6, 7);
        console.log("P2-T4S hash7:          ", g - gasleft());

        g = gasleft(); p2t8.hash7(1, 2, 3, 4, 5, 6, 7);
        console.log("P2-T8 hash7:           ", g - gasleft());

        g = gasleft(); p2vkh.hash_7(1, 2, 3, 4, 5, 6, 7);
        console.log("P2-Vkh hash7:          ", g - gasleft());
    }

    function test_gas_8_inputs() public view {
        uint256 g;
        console.log("--- 8 inputs ---");

        g = gasleft(); p2t4s.hash_8(1, 2, 3, 4, 5, 6, 7, 8);
        console.log("P2-T4S hash8:          ", g - gasleft());

        g = gasleft(); p2vkh.hash_8(1, 2, 3, 4, 5, 6, 7, 8);
        console.log("P2-Vkh hash8:          ", g - gasleft());
    }

    function test_gas_9_inputs() public view {
        uint256 g;
        console.log("--- 9 inputs ---");

        g = gasleft(); p2t4s.hash_9(1, 2, 3, 4, 5, 6, 7, 8, 9);
        console.log("P2-T4S hash9:          ", g - gasleft());

        g = gasleft(); p2vkh.hash_9(1, 2, 3, 4, 5, 6, 7, 8, 9);
        console.log("P2-Vkh hash9:          ", g - gasleft());
    }

    // ================================================================
    //  Bytecode sizes
    // ================================================================

    function test_bytecode_sizes() public view {
        console.log("=== Bytecode Sizes (bytes) ===");
        console.log("P1-chancehudson:       ", address(p1sol).code.length);
        console.log("P1-circomlibjs t=2:    ", p1cljs_t2.code.length);
        console.log("P1-circomlibjs t=3:    ", p1cljs_t3.code.length);
        console.log("P1-circomlibjs t=4:    ", p1cljs_t4.code.length);
        console.log("P1-circomlibjs t=5:    ", p1cljs_t5.code.length);
        console.log("P1-circomlibjs t=6:    ", p1cljs_t6.code.length);
        console.log("P1-circomlibjs t=7:    ", p1cljs_t7.code.length);
        console.log("P2-T2:                 ", address(p2t2).code.length);
        console.log("P2-T2FF:               ", address(p2t2ff).code.length);
        console.log("P2-T3:                 ", address(p2t3).code.length);
        console.log("P2-T4:                 ", address(p2t4).code.length);
        console.log("P2-T4S:                ", address(p2t4s).code.length);
        console.log("P2-T8:                 ", address(p2t8).code.length);
        console.log("P2-zemse:              ", address(p2yul.yul()).code.length);
        console.log("P2-Vkh:                ", address(p2vkh).code.length);
        console.log("P2-sserrano44:         ", address(p2elhub).code.length);
    }
}
