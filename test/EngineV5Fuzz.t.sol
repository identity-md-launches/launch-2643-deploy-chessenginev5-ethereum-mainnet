// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Rules} from "../src/Rules.sol";
import {ChessEngineV5} from "../src/ChessEngineV5.sol";
import {Chess} from "../src/Chess.sol";
import {Chessboard} from "./Chessboard.sol";

/// Stateless properties over random reachable positions: a seeded random walk from the start (playAny), then the
/// engine at a fuzzed strength, seed, history, game number and quiet count.
contract EngineV5FuzzTest is Chessboard {
    ChessEngineV5 v5 = ChessEngineV5(vm.deployCode("ChessEngineV5.sol:ChessEngineV5"));

    struct Walk {
        uint256 b;
        uint32 w;
        uint32 k;
        bool black;
        bool over;
    }

    /// Up to `plies` random legal moves from the start; stops early (over) when the game ends.
    function walk(uint256 seed, uint256 plies) internal view returns (Walk memory g) {
        (g.b, g.w, g.k) = (Chess.START_BOARD, Chess.START_WHITE, Chess.START_BLACK);
        for (uint256 i; i < plies; i++) {
            (uint32 mover, uint32 other) = g.black ? (g.k, g.w) : (g.w, g.k);
            (, Rules.Played memory p) = v5.playAny(g.b, mover, other, g.black, uint256(keccak256(abi.encode(seed, i))));
            g.b = p.board;
            (g.w, g.k) = g.black ? (p.other, p.mover) : (p.mover, p.other);
            g.black = !g.black;
            if (p.status != 0) {
                g.over = true;
                return g;
            }
        }
    }

    /// The engine's move is legal, play() applies it exactly as Rules.move does, choose() agrees on the move and counts
    /// the legal moves as playAny cycles through them, and a repeat call gives the same answer.
    /// forge-config: default.fuzz.runs = 200
    function testFuzz_engineMoveIsLegalAndConsistent(
        uint256 walkSeed,
        uint256 plies,
        uint256 acc,
        uint256 seed,
        uint64 prev0,
        uint32 gameNo,
        uint16 quiet
    ) public view {
        plies = bound(plies, 0, 120);
        acc = bound(acc, 0, 10_000);
        Walk memory g = walk(walkSeed, plies);
        (uint32 mover, uint32 other) = g.black ? (g.k, g.w) : (g.w, g.k);
        uint64[8] memory prev;
        prev[0] = prev0;
        if (g.over) return; // the end of a game is tested in testFuzz_endedGameCannotBePlayed
        (uint16 m, Rules.Played memory p) = v5.play(g.b, mover, other, g.black, acc, seed, prev, gameNo, quiet);
        Rules.Played memory q = rules.move(g.b, mover, other, g.black, m);
        assertEq(abi.encode(p), abi.encode(q), "play() equals the checked move");
        (uint16 c, uint256 count) = v5.choose(g.b, mover, other, g.black, acc, seed, prev, gameNo, quiet);
        assertEq(c, m, "choose() agrees with play()");
        assertGt(count, 0);
        assertLe(count, 218);
        (uint16 any,) = v5.playAny(g.b, mover, other, g.black, seed);
        (uint16 wrapped,) = v5.playAny(g.b, mover, other, g.black, seed % count + count);
        assertEq(any, wrapped, "playAny cycles every `count` seeds");
        (uint16 again,) = v5.play(g.b, mover, other, g.black, acc, seed, prev, gameNo, quiet);
        assertEq(again, m, "deterministic");
        // the moved piece belongs to the mover
        uint256 piece = (g.b >> (uint256(m >> 6) << 2)) & 15;
        assertTrue(piece != 0 && (piece >= 8) == g.black, "moves its own piece");
    }

    /// Played to the end at random, a finished game cannot be continued by any entry point.
    /// forge-config: default.fuzz.runs = 64
    function testFuzz_endedGameCannotBePlayed(uint256 walkSeed, uint256 acc) public {
        acc = bound(acc, 0, 10_000);
        Walk memory g = walk(walkSeed, 400);
        if (!g.over) return; // a long game without mate or stalemate: nothing to check
        (uint32 mover, uint32 other) = g.black ? (g.k, g.w) : (g.w, g.k);
        uint64[8] memory none;
        vm.expectRevert(bytes("no legal move"));
        v5.play(g.b, mover, other, g.black, acc, walkSeed, none, 0, 0);
        vm.expectRevert(bytes("no legal move"));
        v5.choose(g.b, mover, other, g.black, acc, walkSeed, none, 0, 0);
        vm.expectRevert(bytes("no legal move"));
        v5.playAny(g.b, mover, other, g.black, walkSeed);
    }

    /// At full accuracy a mate in one is always taken: a back-rank mate built at random files, for either colour, with
    /// a fuzzed seed, history, game number and quiet count. (Random walks reach a mate in one too rarely to test this.)
    /// forge-config: default.fuzz.runs = 256
    function testFuzz_fullAccuracyTakesBackRankMate(
        uint256 kingFile,
        uint256 rookFile,
        uint256 ownKingFile,
        bool asBlack,
        uint256 seed,
        uint64 prev0,
        uint32 gameNo,
        uint16 quiet
    ) public view {
        kingFile = bound(kingFile, 1, 6); // the mated king, with pawns on its file and both neighbours
        rookFile = bound(rookFile, 0, 4); // a file outside the pawns' three
        if (rookFile >= kingFile - 1) rookFile += 3;
        ownKingFile = bound(ownKingFile, 0, 6);
        if (ownKingFile >= rookFile) ownKingFile++;
        uint256 b =
            (uint256(14) << ((56 + kingFile) * 4)) | (uint256(4) << (rookFile * 4)) | (uint256(6) << (ownKingFile * 4));
        for (uint256 f = kingFile - 1; f <= kingFile + 1; f++) {
            b |= uint256(9) << ((48 + f) * 4);
        }
        uint32 w = 0x808000ff | uint32(ownKingFile << 8);
        uint32 k = 0x808000ff | uint32((56 + kingFile) << 8);
        uint16 mate = uint16(rookFile << 6 | (56 + rookFile));
        if (asBlack) {
            (b, w, k) = mirror(b, w, k); // colours swapped: the attacker is now Black
            mate = uint16((rookFile + 56) << 6 | rookFile);
        }
        uint64[8] memory prev;
        prev[0] = prev0;
        (uint32 mover, uint32 other) = asBlack ? (k, w) : (w, k);
        Rules.Played memory q = rules.move(b, mover, other, asBlack, mate);
        assertEq(q.status, 2, "the constructed move mates");
        (, Rules.Played memory p) = v5.play(b, mover, other, asBlack, 10_000, seed, prev, gameNo, quiet);
        assertEq(p.status, 2, "mate in one taken at full accuracy");
    }
}
