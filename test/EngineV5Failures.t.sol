// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Rules} from "../src/Rules.sol";
import {ChessEngineV5} from "../src/ChessEngineV5.sol";
import {Chess} from "../src/Chess.sol";
import {Chessboard} from "./Chessboard.sol";

/// Failure paths of the engine and of the rules it plays by: the strength cap, positions with no legal move (mate and
/// stalemate, either colour, all three entry points), and illegal moves refused by Rules.move. Plus the inputs at their
/// edges (maximum seed, quiet count, game number, a full history) and playAny's choice by seed.
contract EngineV5FailuresTest is Chessboard {
    ChessEngineV5 v5 = ChessEngineV5(vm.deployCode("ChessEngineV5.sol:ChessEngineV5"));
    uint64[8] none;

    // ---------------------------------------------------------------- positions

    /// Fool's mate: 1.f3 e5 2.g4 Qh4#, White to move and mated.
    function foolsMate() internal view returns (uint256 b, uint32 w, uint32 k) {
        (b, w, k) = (Chess.START_BOARD, Chess.START_WHITE, Chess.START_BLACK);
        (b, w, k,) = step(b, w, k, false, mv("f2", "f3"));
        (b, w, k,) = step(b, w, k, true, mv("e7", "e5"));
        (b, w, k,) = step(b, w, k, false, mv("g2", "g4"));
        Rules.Played memory p;
        (b, w, k, p) = step(b, w, k, true, mv("d8", "h4"));
        assertEq(p.status, 2, "fool's mate is mate");
    }

    /// Black Kg8 behind f7 g7 h7, White Ra8 Kg1: Black to move and mated.
    function backRankMate() internal pure returns (uint256 b, uint32 w, uint32 k) {
        b = put(put(put(put(put(put(0, "g8", 14), "f7", 9), "g7", 9), "h7", 9), "a8", 4), "g1", 6);
        (w, k) = (side("g1"), side("g8"));
    }

    /// Black Kh8, White Qf7 Kg6: Black to move, not in check, no move.
    function stalemate() internal pure returns (uint256 b, uint32 w, uint32 k) {
        b = put(put(put(0, "h8", 14), "f7", 5), "g6", 6);
        (w, k) = (side("g6"), side("h8"));
    }

    /// White Kc6 Rh1 against a lone Black Ke8: the engine's conversion path.
    function conversion() internal pure returns (uint256 b, uint32 w, uint32 k) {
        b = put(put(put(0, "c6", 6), "h1", 4), "e8", 14);
        (w, k) = (side("c6"), side("e8"));
    }

    function expectNoMove(uint256 b, uint32 w, uint32 k, bool black) internal {
        (uint32 mover, uint32 other) = black ? (k, w) : (w, k);
        for (uint256 acc; acc <= 10_000; acc += 2_500) {
            vm.expectRevert(bytes("no legal move"));
            v5.play(b, mover, other, black, acc, acc + 1, none, 0, 0);
            vm.expectRevert(bytes("no legal move"));
            v5.choose(b, mover, other, black, acc, acc + 1, none, 0, 0);
        }
        vm.expectRevert(bytes("no legal move"));
        v5.playAny(b, mover, other, black, 0);
        vm.expectRevert(bytes("no legal move"));
        v5.playAny(b, mover, other, black, type(uint256).max);
    }

    // ---------------------------------------------------------------- no legal move

    function test_checkmatedWhiteHasNoMove() public {
        (uint256 b, uint32 w, uint32 k) = foolsMate();
        expectNoMove(b, w, k, false);
    }

    function test_checkmatedBlackHasNoMove() public {
        (uint256 b, uint32 w, uint32 k) = backRankMate();
        expectNoMove(b, w, k, true);
    }

    function test_stalematedSideHasNoMove() public {
        (uint256 b, uint32 w, uint32 k) = stalemate();
        expectNoMove(b, w, k, true);
        // the same position mirrored: White stalemated
        (uint256 mb, uint32 mw, uint32 mk) = mirror(b, w, k);
        expectNoMove(mb, mw, mk, false);
    }

    /// The moves that end those games are reported as mate and stalemate by play(), not just by the rules.
    function test_playReportsTheEnd() public {
        // Ra8 mates from a1 at full accuracy (a mate in one is always taken there)
        uint256 b = put(put(put(put(put(put(0, "g8", 14), "f7", 9), "g7", 9), "h7", 9), "a1", 4), "g1", 6);
        (uint16 m, Rules.Played memory p) = v5.play(b, side("g1"), side("g8"), false, 10_000, 0, none, 0, 0);
        assertEq(m, mv("a1", "a8"));
        assertEq(p.status, 2);
        assertTrue(p.check);
        // and for Black (mirrored)
        (uint256 mb, uint32 mw, uint32 mk) = mirror(b, side("g1"), side("g8"));
        (m, p) = v5.play(mb, mk, mw, true, 10_000, 0, none, 0, 0);
        assertEq(m, mv("a8", "a1"));
        assertEq(p.status, 2);
    }

    // ---------------------------------------------------------------- the strength cap

    function test_strengthAtCapAccepted() public view {
        v5.play(Chess.START_BOARD, Chess.START_WHITE, Chess.START_BLACK, false, 10_000, 0, none, 0, 0);
        v5.choose(Chess.START_BOARD, Chess.START_WHITE, Chess.START_BLACK, false, 10_000, 0, none, 0, 0);
        v5.play(Chess.START_BOARD, Chess.START_WHITE, Chess.START_BLACK, false, 0, 0, none, 0, 0);
    }

    function test_strengthAboveCapReverts() public {
        uint256[3] memory over = [uint256(10_001), 1 << 128, type(uint256).max];
        (uint256 cb, uint32 cw, uint32 ck) = conversion();
        for (uint256 i; i < 3; i++) {
            vm.expectRevert(bytes(""));
            v5.play(Chess.START_BOARD, Chess.START_WHITE, Chess.START_BLACK, false, over[i], 0, none, 0, 0);
            vm.expectRevert(bytes(""));
            v5.choose(Chess.START_BOARD, Chess.START_WHITE, Chess.START_BLACK, false, over[i], 0, none, 0, 0);
            // the conversion path is checked too, though it plays at full effort whatever the strength
            vm.expectRevert(bytes(""));
            v5.play(cb, cw, ck, false, over[i], 0, none, 0, 0);
        }
    }

    function testFuzz_strengthAboveCapReverts(uint256 acc, uint256 seed) public {
        acc = bound(acc, 10_001, type(uint256).max);
        vm.expectRevert(bytes(""));
        v5.play(Chess.START_BOARD, Chess.START_WHITE, Chess.START_BLACK, false, acc, seed, none, 0, 0);
    }

    // ---------------------------------------------------------------- illegal moves (Rules.move)

    function test_rulesRefuseIllegalMoves() public {
        uint256 b = Chess.START_BOARD;
        (uint32 w, uint32 k) = (Chess.START_WHITE, Chess.START_BLACK);
        uint16[7] memory bad = [
            mv("e4", "e5"), // from an empty square
            mv("e7", "e5"), // the opponent's piece
            mv("e2", "e5"), // a pawn three squares
            mv("b1", "d2"), // onto its own piece
            mv("a1", "a3"), // a rook through its own pawn
            mv("e1", "g1"), // castling through pieces
            uint16(4096 | mv("e2", "e4")) // the move word out of range
        ];
        for (uint256 i; i < bad.length; i++) {
            vm.expectRevert(Rules.Illegal.selector);
            rules.move(b, w, k, false, bad[i]);
        }
        // the same square to itself
        vm.expectRevert(Rules.Illegal.selector);
        rules.move(b, w, k, false, mv("e2", "e2"));
    }

    function test_rulesRefuseMovesIntoOrThroughCheck() public {
        // White Ke1 Rh1 with castling right, Black Kh8 Rf8 covering f1: O-O crosses an attacked square
        uint256 b = put(put(put(put(0, "e1", 6), "h1", 4), "h8", 14), "f8", 12);
        uint32 w = 0x8007_04ff; // queenside flag gone, kingside rook on h1, king e1
        vm.expectRevert(Rules.Illegal.selector);
        rules.move(b, w, side("h8"), false, mv("e1", "g1"));
        vm.expectRevert(Rules.Illegal.selector);
        rules.move(b, w, side("h8"), false, mv("e1", "f1")); // into check
        rules.move(b, w, side("h8"), false, mv("e1", "d1")); // legal
        // a pinned knight may not move: White Ke1 Nc3 (no wait) -> White Ke1 Ne2, Black Re8
        uint256 pin = put(put(put(put(0, "e1", 6), "e2", 3), "e8", 12), "a8", 14);
        vm.expectRevert(Rules.Illegal.selector);
        rules.move(pin, side("e1"), side("a8"), false, mv("e2", "c3"));
        // in check, a move that ignores it is illegal
        (uint256 cb, uint32 cw, uint32 ck) =
            (put(put(put(put(0, "e1", 6), "a2", 1), "e8", 12), "a8", 14), side("e1"), side("a8"));
        vm.expectRevert(Rules.Illegal.selector);
        rules.move(cb, cw, ck, false, mv("a2", "a3"));
    }

    // ---------------------------------------------------------------- inputs at their edges

    function test_extremeInputsStillPlayLegally() public {
        uint64[8] memory full;
        for (uint256 j; j < 8; j++) {
            full[j] = type(uint64).max - uint64(j);
        }
        uint256[3] memory seeds = [uint256(0), type(uint256).max, uint256(1) << 128];
        for (uint256 s; s < 3; s++) {
            for (uint256 acc; acc <= 10_000; acc += 5_000) {
                (uint16 m, Rules.Played memory p) = v5.play(
                    Chess.START_BOARD,
                    Chess.START_WHITE,
                    Chess.START_BLACK,
                    false,
                    acc,
                    seeds[s],
                    full,
                    type(uint32).max,
                    type(uint16).max
                );
                Rules.Played memory q = rules.move(Chess.START_BOARD, Chess.START_WHITE, Chess.START_BLACK, false, m);
                assertEq(abi.encode(p), abi.encode(q));
            }
        }
    }

    /// History that names every position the engine could reach does not stop it moving: it still plays legally.
    function test_everyMoveRepeatsStillPlays() public {
        (uint256 b, uint32 w, uint32 k) = conversion();
        // collect the keys after up to eight of White's moves
        uint64[8] memory prev;
        for (uint256 s; s < 8; s++) {
            (uint16 m, Rules.Played memory p) = v5.playAny(b, w, k, false, s * 3);
            m;
            prev[s] = Chess.positionKey(p.board, p.mover, p.other, true, 5);
        }
        for (uint256 acc; acc <= 10_000; acc += 2_500) {
            (uint16 m, Rules.Played memory p) = v5.play(b, w, k, false, acc, 1, prev, 5, 40);
            assertEq(abi.encode(p), abi.encode(rules.move(b, w, k, false, m)));
        }
    }

    /// playAny is moves[seed % count]: over `count` consecutive seeds it plays every legal move exactly once.
    function test_playAnyCoversEveryLegalMove() public {
        (uint256 b, uint32 w, uint32 k) = replay(3, 20);
        (, uint256 count) = v5.choose(b, w, k, false, 0, 0, none, 0, 0);
        uint256[] memory seen = new uint256[](count);
        for (uint256 s; s < count; s++) {
            (uint16 m, Rules.Played memory p) = v5.playAny(b, w, k, false, s);
            assertEq(abi.encode(p), abi.encode(rules.move(b, w, k, false, m)));
            for (uint256 j; j < s; j++) {
                assertTrue(seen[j] != m, "distinct moves");
            }
            seen[s] = m;
        }
        (uint16 again,) = v5.playAny(b, w, k, false, count);
        assertEq(again, seen[0], "seed wraps");
        (again,) = v5.playAny(b, w, k, false, type(uint256).max);
        assertEq(again, seen[type(uint256).max % count]);
    }

    /// In check with a single way out, every strength finds it.
    function test_onlyMoveInCheckIsFound() public {
        // White Kh1, pawns g2 h2; Black Ra1 checks; only Kg... none: give White Rf3 to block on f1? Use: White Kh1,
        // g2 h2, Rd3; Black Ra1+, Kg8. Only Rd1 blocks.
        uint256 b = put(put(put(put(put(put(0, "h1", 6), "g2", 1), "h2", 1), "d3", 4), "a1", 12), "g8", 14);
        (, uint256 count) = v5.choose(b, side("h1"), side("g8"), false, 0, 0, none, 0, 0);
        assertEq(count, 1);
        for (uint256 acc; acc <= 10_000; acc += 1_000) {
            (uint16 m,) = v5.play(b, side("h1"), side("g8"), false, acc, acc, none, 0, 0);
            assertEq(m, mv("d3", "d1"));
        }
    }
}
