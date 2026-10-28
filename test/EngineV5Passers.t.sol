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

/// An enemy pawn a step from promotion is a risk every move is scored against (review finding 10cde183, engine
/// launch): at every strength the engine takes it, blocks it or covers its promotion square, and when nothing can
/// stop it, it still sells the cheapest piece for the new queen.
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
        uint16 push; // the enemy's promotion
        uint8 promo; // ... and its square
    }

    /// After the engine's move, the enemy's promotion is illegal, or the new queen can be taken at once.
    function stopped(Case memory t, uint256 acc, uint256 seed) internal view returns (bool, uint16) {
        uint64[8] memory none;
        (uint32 mover, uint32 other) = t.white ? (t.w, t.k) : (t.k, t.w);
        (uint16 m, Rules.Played memory p) = v5.play(t.b, mover, other, !t.white, acc, seed, none, 1, 20);
        Bitboard.Pos memory after_ =
            Bitboard.fromBoard(p.board, t.white ? p.mover : p.other, t.white ? p.other : p.mover);
        if (!Bitboard.isLegal(after_, t.push, !t.white)) return (true, m);
        Rules.Played memory q = rules.move(p.board, p.other, p.mover, t.white, t.push);
        if (q.status != 0) return (false, m);
        Bitboard.Pos memory then = Bitboard.fromBoard(q.board, t.white ? q.other : q.mover, t.white ? q.mover : q.other);
        uint16[] memory ours = Bitboard.legalMoves(then, t.white);
        for (uint256 i; i < ours.length; i++) {
            if (ours[i] & 63 == t.promo) return (true, m);
        }
        return (false, m);
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
    function stopsBothWays(string memory title, uint256 b, uint32 w, uint32 k, string memory pawn, string memory promo)
        internal
    {
        stopsAll(Case(title, b, w, k, true, mv(pawn, promo), uint8(sq(promo))));
        (uint256 mb, uint32 mw, uint32 mk) = mirror(b, w, k);
        stopsAll(Case(title, mb, mw, mk, false, mv(flip(pawn), flip(promo)), uint8(sq(flip(promo)))));
    }

    /// The same square seen from the other side of the board.
    function flip(string memory s) internal pure returns (string memory) {
        bytes memory b = bytes(s); // not a copy: build a new string rather than edit the caller's
        return string(abi.encodePacked(b[0], bytes1(uint8(49 + 56 - uint8(b[1])))));
    }

    /// K+R v K+P: White Kd3 Rb7, Black Kg8 pawn h2. Rb1 or Rh7 wins (h1=Q Rxh1); a king move loses the rook.
    function test_rookEndingPawnOnSeventh() public {
        uint256 b = put(put(put(put(0, "d3", 6), "b7", 4), "g8", 14), "h2", 9);
        stopsBothWays("KR v KP", b, side("d3"), side("g8"), "h2", "h1");
    }

    /// K+R v K+P: White Kd3 Ra1, Black Kg8 pawn h2. Rh1 blocks the pawn.
    function test_rookCanBlockOnFirstRank() public {
        uint256 b = put(put(put(put(0, "d3", 6), "a1", 4), "g8", 14), "h2", 9);
        stopsBothWays("KR v KP, Ra1", b, side("d3"), side("g8"), "h2", "h1");
    }

    /// K+R+B v K+P: White Ke2 Rd8 Bc5, Black Ke6 pawn h2. Rh8 or Rd1 wins.
    function test_rookAndBishopEnding() public {
        uint256 b = put(put(put(put(put(0, "e2", 6), "d8", 4), "c5", 2), "e6", 14), "h2", 9);
        stopsBothWays("KRB v KP", b, side("e2"), side("e6"), "h2", "h1");
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
