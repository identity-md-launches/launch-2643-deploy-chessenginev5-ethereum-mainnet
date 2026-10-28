// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Chess} from "../src/Chess.sol";
import {Chessboard} from "./Chessboard.sol";
import {BB} from "./Bitboard.t.sol";

/// The rules core against chess.js on 250 random games biased towards the rare rules (scripts/gen-random.mjs): 29,828
/// positions with 96 castlings, 69 en passant captures, 229 promotions, 276 rooks taken on their home squares, ~4,600
/// checks and 131 mates. Every chess.js move is played through Rules (which reverts on an illegal move); at every
/// position the exact legal move list (as a hash), check, mate / stalemate and the four castling rights must match; on
/// every 4th position the fast check flags and on every 8th the fast mate-in-one search are compared with playing each
/// move out.
contract RulesRandomTest is Chessboard {
    BB bb = BB(vm.deployCode("Bitboard.t.sol:BB"));
    uint256[][] recordedMoves;
    uint256[] games;
    uint256[] plies;
    uint256[] hashes;
    uint256[] counts;
    uint256[] checks;
    uint256[] statuses;
    uint256[] rights;

    function setUp() public {
        string memory data = vm.readFile("./test/data/random.json");
        // Avoid copying the full JSON from storage and reparsing it at every game boundary.
        recordedMoves = abi.decode(vm.parseJson(data, ".games"), (uint256[][]));
        games = vm.parseJsonUintArray(data, ".game");
        plies = vm.parseJsonUintArray(data, ".ply");
        hashes = vm.parseJsonUintArray(data, ".hash");
        counts = vm.parseJsonUintArray(data, ".count");
        checks = vm.parseJsonUintArray(data, ".check");
        statuses = vm.parseJsonUintArray(data, ".status");
        rights = vm.parseJsonUintArray(data, ".rights");
        assertEq(recordedMoves.length, 250, "complete game corpus");
        assertEq(games.length, 29_828, "complete position corpus");
    }

    // Independent game ranges let Forge run the full corpus in parallel and bound each call's memory growth.
    function test_randomGamesAgainstChessJs_000_049() public {
        _randomGamesAgainstChessJs(0, 50);
    }

    function test_randomGamesAgainstChessJs_050_099() public {
        _randomGamesAgainstChessJs(50, 100);
    }

    function test_randomGamesAgainstChessJs_100_149() public {
        _randomGamesAgainstChessJs(100, 150);
    }

    function test_randomGamesAgainstChessJs_150_199() public {
        _randomGamesAgainstChessJs(150, 200);
    }

    function test_randomGamesAgainstChessJs_200_249() public {
        _randomGamesAgainstChessJs(200, 250);
    }

    function _randomGamesAgainstChessJs(uint256 firstGame, uint256 endGame) internal {
        uint256 last = type(uint256).max;
        uint256[] memory moves;
        uint256 b;
        uint32 w;
        uint32 k;
        uint256[6] memory wrong; // move list, count, check, status, fast check / mate, castling rights
        uint256 compared;
        for (uint256 p; p < games.length; p++) {
            if (games[p] < firstGame) continue;
            if (games[p] >= endGame) break;
            if (games[p] != last) {
                last = games[p];
                moves = recordedMoves[last];
                (b, w, k) = (Chess.START_BOARD, Chess.START_WHITE, Chess.START_BLACK);
            }
            uint256 ply = plies[p];
            bool white = ply % 2 == 0;
            uint16[] memory got = bb.legal(b, w, k, white);
            if (uint64(uint256(keccak256(abi.encodePacked(got))) >> 192) != hashes[p]) wrong[0]++;
            if (got.length != counts[p]) wrong[1]++;
            if (bb.inCheck(b, w, k, white) != (checks[p] == 1)) wrong[2]++;
            uint256 status = bb.hasMove(b, w, k, white) ? 0 : (checks[p] == 1 ? 2 : 1);
            if (status != statuses[p]) wrong[3]++;
            if (castlingRights(w, k) != rights[p]) wrong[5]++;
            if (p % 4 == 0) {
                for (uint256 i; i < got.length; i++) {
                    (bool fast, bool full) = bb.givesCheck(b, w, k, got[i], white);
                    if (fast != full) wrong[4]++;
                }
            }
            if (p % 8 == 0) {
                (bool fastMate, bool fullMate) = bb.mates(b, w, k, white);
                if (fastMate != fullMate) wrong[4]++;
            }
            compared++;
            if (ply < moves.length) (b, w, k,) = step(b, w, k, !white, uint16(moves[ply])); // reverts if illegal
        }
        emit log_named_uint("positions compared", compared);
        uint256 expected;
        for (uint256 g = firstGame; g < endGame; g++) {
            expected += recordedMoves[g].length + 1;
        }
        assertEq(compared, expected, "all positions including each game's final state");
        assertEq(wrong[0], 0, "legal move lists");
        assertEq(wrong[1], 0, "move counts");
        assertEq(wrong[2], 0, "in check");
        assertEq(wrong[3], 0, "mate / stalemate");
        assertEq(wrong[4], 0, "fast check and mate-in-one detection");
        assertEq(wrong[5], 0, "castling rights");
    }

    /// The rights the side states still hold: a rook byte below 64 (its square, no moved-or-taken flag).
    function castlingRights(uint32 w, uint32 k) internal pure returns (uint256 r) {
        if (uint8(w >> 16) < 64) r |= 1;
        if (uint8(w >> 24) < 64) r |= 2;
        if (uint8(k >> 16) < 64) r |= 4;
        if (uint8(k >> 24) < 64) r |= 8;
    }
}
