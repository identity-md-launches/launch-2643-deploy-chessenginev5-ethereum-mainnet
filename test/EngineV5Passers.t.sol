// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Rules} from "../src/Rules.sol";
import {ChessEngineV5} from "../src/ChessEngineV5.sol";
import {Bitboard} from "../src/Bitboard.sol";
import {Chessboard} from "./Chessboard.sol";

/// Exposes the second look so a position and its colour mirror can be scored the same way.
contract ExactProbe is ChessEngineV5 {
    function exact(uint256 b, uint32 w, uint32 k, bool white, uint16 m) external pure returns (int256) {
        Ctx memory c = _context(b, w, k, white, true);
        _effort(c, 10_000, 0);
        c.guardBps = 10_000;
        return _exact(c, m, 0);
    }
}

/// An enemy pawn a step from promotion is a risk every move is scored against (review findings 10cde183 and
/// be477030, engine launch): at every strength the engine takes it, blocks it or covers every square it can queen
/// on, by a push or by a capture, and when nothing can stop it, it still sells the cheapest piece for the new queen.
contract EngineV5PassersTest is Chessboard {
    ChessEngineV5 v5 = ChessEngineV5(vm.deployCode("ChessEngineV5.sol:ChessEngineV5"));
    ExactProbe probe = ExactProbe(vm.deployCode("EngineV5Passers.t.sol:ExactProbe"));

    uint16[4] strengths = [uint16(0), 4_000, 9_000, 10_000];

    struct Case {
        string title;
        uint256 b;
        uint32 w;
        uint32 k;
        bool white; // the engine's side
        uint8 pawn; // the enemy pawn's square
    }

    /// After the engine's move, every promotion of the enemy pawn (a push or a capture) is illegal, or lands where
    /// the new queen can be taken at once.
    function stopped(Case memory t, uint256 acc, uint256 seed) internal view returns (bool, uint16) {
        uint64[8] memory none;
        (uint32 mover, uint32 other) = t.white ? (t.w, t.k) : (t.k, t.w);
        (uint16 m, Rules.Played memory p) = v5.play(t.b, mover, other, !t.white, acc, seed, none, 1, 20);
        Bitboard.Pos memory after_ =
            Bitboard.fromBoard(p.board, t.white ? p.mover : p.other, t.white ? p.other : p.mover);
        uint16[] memory replies = Bitboard.legalMoves(after_, !t.white);
        for (uint256 i; i < replies.length; i++) {
            uint16 r = replies[i];
            uint8 to = uint8(r & 63);
            if (r >> 6 != t.pawn || (to >> 3 != 0 && to >> 3 != 7)) continue;
            Rules.Played memory q = rules.move(p.board, p.other, p.mover, t.white, r);
            if (q.status != 0) return (false, m);
            Bitboard.Pos memory then =
                Bitboard.fromBoard(q.board, t.white ? q.other : q.mover, t.white ? q.mover : q.other);
            uint16[] memory ours = Bitboard.legalMoves(then, t.white);
            bool retake;
            for (uint256 j; j < ours.length; j++) {
                if (ours[j] & 63 == to) retake = true;
            }
            if (!retake) return (false, m);
        }
        return (true, m);
    }

    /// Every strength and seed stops the pawn.
    function stopsAll(Case memory t) internal {
        for (uint256 a; a < strengths.length; a++) {
            for (uint256 seed; seed < 8; seed++) {
                (bool ok, uint16 m) = stopped(t, strengths[a], seed);
                assertTrue(
                    ok,
                    string.concat(
                        t.title,
                        t.white ? ": as White, strength " : ": as Black, strength ",
                        vm.toString(strengths[a]),
                        ", seed ",
                        vm.toString(seed),
                        ", move ",
                        vm.toString(m)
                    )
                );
            }
        }
    }

    /// ... as White, and as Black in the colour mirror of the position.
    function stopsBothWays(string memory title, uint256 b, uint32 w, uint32 k, string memory pawn) internal {
        stopsAll(Case(title, b, w, k, true, uint8(sq(pawn))));
        (uint256 mb, uint32 mw, uint32 mk) = mirror(b, w, k);
        stopsAll(Case(title, mb, mw, mk, false, uint8(sq(flip(pawn)))));
    }

    /// The same square seen from the other side of the board.
    function flip(string memory s) internal pure returns (string memory) {
        bytes memory b = bytes(s); // not a copy: build a new string rather than edit the caller's
        return string(abi.encodePacked(b[0], bytes1(uint8(49 + 56 - uint8(b[1])))));
    }

    /// K+R v K+P: White Kd3 Rb7, Black Kg8 pawn h2. Rb1 or Rh7 wins (h1=Q Rxh1); a king move loses the rook.
    function test_rookEndingPawnOnSeventh() public {
        uint256 b = put(put(put(put(0, "d3", 6), "b7", 4), "g8", 14), "h2", 9);
        stopsBothWays("KR v KP", b, side("d3"), side("g8"), "h2");
    }

    /// K+R v K+P: White Kd3 Ra1, Black Kg8 pawn h2. Rh1 blocks the pawn.
    function test_rookCanBlockOnFirstRank() public {
        uint256 b = put(put(put(put(0, "d3", 6), "a1", 4), "g8", 14), "h2", 9);
        stopsBothWays("KR v KP, Ra1", b, side("d3"), side("g8"), "h2");
    }

    /// K+R+B v K+P: White Ke2 Rd8 Bc5, Black Ke6 pawn h2. Rh8 or Rd1 wins.
    function test_rookAndBishopEnding() public {
        uint256 b = put(put(put(put(put(0, "e2", 6), "d8", 4), "c5", 2), "e6", 14), "h2", 9);
        stopsBothWays("KRB v KP", b, side("e2"), side("e6"), "h2");
    }

    /// A pawn whose push is blocked still queens by capture (review finding be477030): White Kg1 Bb1 Nc1 Ng4,
    /// Black Ka8 Rh6 pawn b2. Ng4xh6 wins a rook but lets b2xc1=Q+ through, where nothing takes the queen: B+N v Q
    /// instead of B+N+N v R+P. A knight move off c1 (Nd3, Ne2, Nb3, Na2) leaves the pawn no promotion at all.
    function test_blockedPawnQueensByCapture() public {
        uint256 b =
            put(put(put(put(put(put(put(0, "g1", 6), "b1", 2), "c1", 3), "g4", 3), "a8", 14), "h6", 12), "b2", 9);
        stopsBothWays("B+N+N v R+P, push blocked", b, side("g1"), side("a8"), "b2");
    }

    /// The push square alone is not the threat: White Kg1 Rb8 Nc1 Ng4, Black Ka7 Rh6 pawn b2. b1 is empty and
    /// covered by the rook, so b1=Q loses the queen, but b2xc1=Q+ still queens uncovered after Ng4xh6.
    function test_coveredPushSquareStillQueensByCapture() public {
        uint256 b =
            put(put(put(put(put(put(put(0, "g1", 6), "b8", 4), "c1", 3), "g4", 3), "a7", 14), "h6", 12), "b2", 9);
        stopsBothWays("R+N+N v R+P, push covered", b, side("g1"), side("a7"), "b2");
    }

    /// A pawn with no promotion move now is still a threat after the move: White Ka2 Bb1 Nd3, Black Kh8 Rc1 pawn
    /// b2. Nd3xc1 wins the rook with the knight, and b2xc1=Q takes it back and queens where nothing of ours can
    /// follow (the bishop keeps b1 blocked, the king is a square too far); Kxb2 simply wins the pawn.
    function test_pawnWithoutAMoveStillCounts() public {
        uint256 b = put(put(put(put(put(put(0, "a2", 6), "b1", 2), "d3", 3), "h8", 14), "c1", 12), "b2", 9);
        stopsBothWays("B+N v R+P, blocked pawn", b, side("a2"), side("h8"), "b2");
    }

    /// A capture square counts for exactly what it holds: White Kg2 Rb8 Bc1 Rh1, Black Ka6 Rh6 pawn b2. The second
    /// look (base 0, so the score is minus the threat) charges each move the worse of the pawn's squares, b1 (empty,
    /// covered by Rb8 along the file with the pawn lifted) and c1 (the bishop, covered by Rh1 along the rank).
    function test_captureSquareScoredAtItsPiece() public view {
        uint256 b =
            put(put(put(put(put(put(put(0, "g2", 6), "b8", 4), "c1", 2), "h1", 4), "a6", 14), "h6", 12), "b2", 9);
        uint32 w = side("g2");
        uint32 k = side("a6");
        // Rh1xh6+: nothing covers c1 any more, so b2xc1=Q wins the bishop and queens for good: 320 + 800
        assertEq(probe.exact(b, w, k, true, mv("h1", "h6")), -(320 + 800), "Rxh6: the bishop and a queen");
        // Rb8-a8+: the rook leaves the b-file, and Rh1 cannot see past the bishop: b1=Q is free (800); c1 costs less
        assertEq(probe.exact(b, w, k, true, mv("b8", "a8")), -800, "Ra8+: the push square is uncovered");
        // Rh1-f1: b1 stays covered and undefended (nothing); on c1 the pawn takes the bishop and Rf1 takes the queen,
        // which is the bishop less the pawn (and the same as the plain threat to the bishop): 320 - 100
        assertEq(probe.exact(b, w, k, true, mv("h1", "f1")), -(320 - 100), "Rf1: the bishop for the pawn");
        // Bc1-e3: the pawn's only square is b1, covered by two rooks and undefended: nothing at stake
        assertEq(probe.exact(b, w, k, true, mv("c1", "e3")), 0, "Be3: nothing at stake");
    }

    /// The pawn's own king defends the promotion square (Black Kg2 pawn h2), so nothing stops it: the engine still
    /// brings the rook to bear on h1 (Rb1 or Rh7) and gets the queen for the rook, rather than losing the rook for
    /// nothing after a king move. From 40%: at the weakest the seeded mistake (up to 400) can outweigh the 400 at
    /// stake, which is that strength's play.
    function test_unstoppablePawnIsSoldDearly() public {
        uint256 b = put(put(put(put(0, "d3", 6), "b7", 4), "g2", 14), "h2", 9);
        uint64[8] memory none;
        for (uint256 a = 1; a < strengths.length; a++) {
            for (uint256 seed; seed < 8; seed++) {
                (uint16 m,) = v5.play(b, side("d3"), side("g2"), false, strengths[a], seed, none, 1, 20);
                assertTrue(
                    m == mv("b7", "b1") || m == mv("b7", "h7"),
                    string.concat(
                        "rook to h1's line, strength ",
                        vm.toString(strengths[a]),
                        ", seed ",
                        vm.toString(seed),
                        ", move ",
                        vm.toString(m)
                    )
                );
            }
        }
    }

    /// The second look's guard against the enemy's mate in one gives a position and its colour mirror the same
    /// verdict (review finding 5088cfe5): Qe2-d1 lets Qe3-f2 mate, found whether the mating queen walks early or
    /// late in the enemy's piece order.
    function test_mateGuardIsMirrorSymmetric() public view {
        uint256 b = 0xc000aa0c90e0909000090b02099009000b110001100d00000605111043000204;
        uint32 w = 0x80800eff;
        uint32 k = 0x808035ff;
        uint16 m = mv("e2", "d1");
        assertEq(probe.exact(b, w, k, true, m), -100_000, "White walks into mate");
        (uint256 mb, uint32 mw, uint32 mk) = mirror(b, w, k);
        assertEq(probe.exact(mb, mw, mk, false, mv("e7", "d8")), -100_000, "Black walks into the same mate");
    }
}
