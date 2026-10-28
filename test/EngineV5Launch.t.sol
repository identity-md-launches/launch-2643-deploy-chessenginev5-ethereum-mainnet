// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Chess} from "../src/Chess.sol";
import {Rules} from "../src/Rules.sol";
import {ChessEngineV5} from "../src/ChessEngineV5.sol";

/// Deploys like the launch factory: every application in one call, CREATE2, the exact init code, no arguments.
contract LaunchProbe {
    function deploy(bytes memory code, bytes32 salt, uint256 value) external payable returns (address created) {
        assembly ("memory-safe") {
            created := create2(value, add(code, 32), mload(code), salt)
        }
    }

    function predict(bytes memory code, bytes32 salt) external view returns (address) {
        return
            address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, keccak256(code))))));
    }
}

/// The launch as launch.json states it: ChessEngineV5 alone, no constructor arguments, zero ETH, on chain 1. Its
/// runtime is the brief's 22,268 bytes, it has no owner, no state, no payable entry and nothing that escapes it.
contract EngineV5LaunchTest is Test {
    LaunchProbe probe;
    bytes initCode;

    function setUp() public {
        vm.chainId(1);
        probe = new LaunchProbe();
        initCode = vm.getCode("ChessEngineV5.sol:ChessEngineV5");
    }

    function _deploy() internal returns (ChessEngineV5) {
        address a = probe.deploy(initCode, keccak256("imd"), 0);
        assertEq(a, probe.predict(initCode, keccak256("imd")), "CREATE2 address as predicted");
        assertGt(a.code.length, 0, "constructor succeeded");
        return ChessEngineV5(a);
    }

    function test_deploysWithNoArgumentsAtTheBriefsSize() public {
        ChessEngineV5 e = _deploy();
        assertEq(address(e).code.length, 22_268, "runtime bytes stated in the brief");
        assertLe(address(e).code.length, 24_576, "EIP-170");
        assertLe(initCode.length, 49_152, "EIP-3860");
        assertEq(keccak256(address(e).code), keccak256(vm.getDeployedCode("ChessEngineV5.sol:ChessEngineV5")));
        assertEq(address(e).balance, 0);
    }

    function test_usableImmediatelyWithoutInitialisation() public {
        ChessEngineV5 e = _deploy();
        uint64[8] memory none;
        (uint16 m, Rules.Played memory p) =
            e.play(Chess.START_BOARD, Chess.START_WHITE, Chess.START_BLACK, false, 5_000, 1, none, 0, 0);
        assertEq(p.status, 0);
        (uint16 c, uint256 legal) =
            e.choose(Chess.START_BOARD, Chess.START_WHITE, Chess.START_BLACK, false, 5_000, 1, none, 0, 0);
        assertEq(c, m);
        assertEq(legal, 20, "twenty opening moves");
        (, Rules.Played memory q) = e.playAny(Chess.START_BOARD, Chess.START_WHITE, Chess.START_BLACK, false, 7);
        assertEq(q.status, 0);
    }

    /// The implicit constructor is nonpayable: a launch that sent ETH would fail, the brief's zero-ETH launch succeeds.
    function test_deployWithEthFails() public {
        vm.deal(address(probe), 1 ether);
        assertEq(probe.deploy(initCode, keccak256("value"), 1), address(0), "nonpayable constructor");
    }

    /// Redeploying at the same salt fails (CREATE2 collision), so a launch retry cannot silently replace it.
    function test_secondDeployAtSameSaltFails() public {
        _deploy();
        assertEq(probe.deploy(initCode, keccak256("imd"), 0), address(0));
    }

    function test_rejectsEther() public {
        ChessEngineV5 e = _deploy();
        vm.deal(address(this), 10 ether);
        (bool ok,) = address(e).call{value: 1}("");
        assertFalse(ok, "no receive");
        (ok,) = address(e).call{value: 1}(hex"deadbeef");
        assertFalse(ok, "no payable fallback");
        uint64[8] memory none;
        (ok,) = address(e).call{value: 1}(
            abi.encodeCall(e.playAny, (Chess.START_BOARD, Chess.START_WHITE, Chess.START_BLACK, false, 0))
        );
        assertFalse(ok, "playAny is not payable");
        (ok,) = address(e).call{value: 1}(
            abi.encodeCall(e.play, (Chess.START_BOARD, Chess.START_WHITE, Chess.START_BLACK, false, 1, 0, none, 0, 0))
        );
        assertFalse(ok, "play is not payable");
        assertEq(address(e).balance, 0);
    }

    function test_unknownSelectorAndShortCalldataRevert() public {
        ChessEngineV5 e = _deploy();
        (bool ok,) = address(e).call("");
        assertFalse(ok);
        (ok,) = address(e).call(abi.encodeWithSignature("owner()"));
        assertFalse(ok, "no owner");
        (ok,) = address(e).call(abi.encodeWithSignature("initialize()"));
        assertFalse(ok, "no initializer");
        // a truncated argument list is refused rather than read as zeros
        bytes memory full =
            abi.encodeCall(e.playAny, (Chess.START_BOARD, Chess.START_WHITE, Chess.START_BLACK, false, 0));
        bytes memory cut = new bytes(full.length - 32);
        for (uint256 i; i < cut.length; i++) {
            cut[i] = full[i];
        }
        (ok,) = address(e).call(cut);
        assertFalse(ok, "short calldata");
        // a bool argument other than 0 or 1 is refused
        bytes memory badBool =
            abi.encodeCall(e.playAny, (Chess.START_BOARD, Chess.START_WHITE, Chess.START_BLACK, false, 0));
        badBool[4 + 32 * 3 + 31] = 0x02;
        (ok,) = address(e).call(badBool);
        assertFalse(ok, "dirty bool");
        // a uint32 argument with high bits set is refused
        bytes memory badState =
            abi.encodeCall(e.playAny, (Chess.START_BOARD, Chess.START_WHITE, Chess.START_BLACK, false, 0));
        badState[4 + 32 + 27] = 0x01;
        (ok,) = address(e).call(badState);
        assertFalse(ok, "dirty uint32");
    }

    /// Every entry point works through STATICCALL, so none of them can write state; no storage slot is ever used.
    function test_entryPointsAreStatic() public {
        ChessEngineV5 e = _deploy();
        uint64[8] memory none;
        (bool ok,) = address(e)
            .staticcall(
                abi.encodeCall(
                    e.play, (Chess.START_BOARD, Chess.START_WHITE, Chess.START_BLACK, false, 10_000, 3, none, 9, 30)
                )
            );
        assertTrue(ok);
        (ok,) = address(e)
            .staticcall(
                abi.encodeCall(
                    e.choose, (Chess.START_BOARD, Chess.START_WHITE, Chess.START_BLACK, false, 0, 3, none, 9, 30)
                )
            );
        assertTrue(ok);
        (ok,) = address(e)
            .staticcall(abi.encodeCall(e.playAny, (Chess.START_BOARD, Chess.START_WHITE, Chess.START_BLACK, false, 3)));
        assertTrue(ok);
        for (uint256 slot; slot < 4; slot++) {
            assertEq(vm.load(address(e), bytes32(slot)), bytes32(0));
        }
    }

    /// No reachable instruction that writes storage, sends value, calls out, creates or destroys contracts (the
    /// protected floor's reachability rule, extended to every opcode an engine that holds nothing has no need for).
    function test_runtimeHasNoReachableEscapeOrStateOpcodes() public {
        bytes memory code = address(_deploy()).code;
        bool reachable = true;
        for (uint256 j; j < code.length; ++j) {
            uint8 op = uint8(code[j]);
            if (op == 0x5b) reachable = true;
            if (op >= 0x60 && op <= 0x7f) {
                j += op - 0x5f;
                continue;
            }
            if (reachable) {
                assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "DELEGATECALL, CALLCODE or SELFDESTRUCT");
                assertTrue(op != 0xf0 && op != 0xf5, "CREATE or CREATE2");
                assertTrue(op != 0xf1 && op != 0xfa, "CALL or STATICCALL");
                assertTrue(op != 0x55 && op != 0x5d, "SSTORE or TSTORE");
            }
            if (op == 0x00 || op == 0x56 || op == 0xf3 || op == 0xfd || op == 0xfe || op == 0xff) reachable = false;
        }
    }
}
