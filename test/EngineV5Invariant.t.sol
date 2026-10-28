// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Rules} from "../src/Rules.sol";
import {ChessEngineV5} from "../src/ChessEngineV5.sol";
import {Chess} from "../src/Chess.sol";
import {RulesHarness} from "./Chessboard.sol";

/// Drives games the way the hook will: each call is one half-move by the engine at a bounded strength, or by playAny
/// (the hook's fallback), with the hook's draw rules (Chess.MAX_PLY, Chess.MAX_QUIET_PLY, too little material) and
/// its repetition memory. Every call is checked against the rules; anything unexpected is counted, never swallowed.
contract EngineGameHandler is Test {
    ChessEngineV5 public immutable engine;
    RulesHarness public immutable rules;

    // the game in progress
    uint256 public board;
    uint32 public white;
    uint32 public black;
    bool public blackToMove;
    uint16 public quiet;
    uint16 public ply;
    uint32 public gameNo;
    uint64[8] public whiteHistory;
    uint64[8] public blackHistory;

    // ghosts
    uint256 public calls;
    uint256 public halfMoves;
    uint256 public gamesEnded;
    uint256 public illegal; // a move the rules refuse, or play() disagreeing with Rules.move / choose()
    uint256 public unexpectedReverts; // an entry point reverting on a position that has a legal move
    uint256 public overCapAccepted; // a strength above 10,000 accepted
    uint256 public reopened; // an entry point accepting a position whose game had ended
    uint256 public materialGrew; // a half-move that added a piece to the board
    uint256 public statusWrong; // status / check flags not as the rules say

    constructor(ChessEngineV5 e, RulesHarness r) {
        engine = e;
        rules = r;
        _newGame();
    }

    function _newGame() internal {
        (board, white, black, blackToMove, quiet, ply) =
        (Chess.START_BOARD, Chess.START_WHITE, Chess.START_BLACK, false, 0, 0);
        delete whiteHistory;
        delete blackHistory;
        gameNo++;
    }

    function _sides() internal view returns (uint32 mover, uint32 other) {
        return blackToMove ? (black, white) : (white, black);
    }

    function pieces(uint256 b) public pure returns (uint256 n) {
        for (uint256 s; s < 64; s++) {
            if ((b >> (s * 4)) & 7 != 0) n++;
        }
    }

    function engineMove(uint256 acc, uint256 seed) external {
        calls++;
        acc = bound(acc, 0, 10_000);
        (uint32 mover, uint32 other) = _sides();
        uint64[8] memory prev = blackToMove ? blackHistory : whiteHistory;
        try engine.play(board, mover, other, blackToMove, acc, seed, prev, gameNo, quiet) returns (
            uint16 m, Rules.Played memory p
        ) {
            try engine.choose(board, mover, other, blackToMove, acc, seed, prev, gameNo, quiet) returns (
                uint16 c, uint256
            ) {
                if (c != m) illegal++;
            } catch {
                unexpectedReverts++;
            }
            _apply(m, p);
        } catch {
            unexpectedReverts++;
            _newGame();
        }
    }

    function fallbackMove(uint256 seed) external {
        calls++;
        (uint32 mover, uint32 other) = _sides();
        try engine.playAny(board, mover, other, blackToMove, seed) returns (uint16 m, Rules.Played memory p) {
            _apply(m, p);
        } catch {
            unexpectedReverts++;
            _newGame();
        }
    }

    /// A strength above the cap must always be refused, whatever the position.
    function overCap(uint256 acc, uint256 seed) external {
        calls++;
        acc = bound(acc, 10_001, type(uint256).max);
        (uint32 mover, uint32 other) = _sides();
        uint64[8] memory none;
        try engine.play(board, mover, other, blackToMove, acc, seed, none, gameNo, quiet) {
            overCapAccepted++;
        } catch {}
        try engine.choose(board, mover, other, blackToMove, acc, seed, none, gameNo, quiet) {
            overCapAccepted++;
        } catch {}
    }

    function _apply(uint16 m, Rules.Played memory p) internal {
        (uint32 mover, uint32 other) = _sides();
        try rules.move(board, mover, other, blackToMove, m) returns (Rules.Played memory q) {
            if (keccak256(abi.encode(p)) != keccak256(abi.encode(q))) illegal++;
        } catch {
            illegal++;
        }
        if ((board >> (uint256(m >> 6) << 2)) & 15 == 0 || ((board >> (uint256(m >> 6) << 2)) & 8 != 0) != blackToMove)
        {
            illegal++;
        }
        if (p.status == 2 && !p.check) statusWrong++;
        if (p.status > 2) statusWrong++;
        bool capture = (board >> (uint256(m & 63) << 2)) & 7 != 0;
        bool pawn = (board >> (uint256(m >> 6) << 2)) & 7 == 1;
        if (pieces(p.board) > pieces(board)) materialGrew++;
        if (pieces(p.board) < pieces(board) && !capture && !pawn) materialGrew++; // only captures remove pieces
        halfMoves++;
        board = p.board;
        (white, black) = blackToMove ? (p.other, p.mover) : (p.mover, p.other);
        // the side that just moved remembers the position it left for the other side (most recent first)
        uint64 key = Chess.positionKey(board, white, black, !blackToMove, gameNo);
        uint64[8] storage h = blackToMove ? blackHistory : whiteHistory;
        for (uint256 j = 7; j > 0; j--) {
            h[j] = h[j - 1];
        }
        h[0] = key;
        blackToMove = !blackToMove;
        quiet = capture || pawn ? 0 : quiet + 1;
        ply++;
        if (p.status != 0) {
            _checkEnded();
            gamesEnded++;
            _newGame();
        } else if (p.insufficient || ply >= Chess.MAX_PLY || quiet >= Chess.MAX_QUIET_PLY) {
            gamesEnded++;
            _newGame();
        }
    }

    /// The side to move has no legal move: every entry point must refuse to continue.
    function _checkEnded() internal {
        (uint32 mover, uint32 other) = _sides();
        uint64[8] memory none;
        try engine.play(board, mover, other, blackToMove, 10_000, 1, none, gameNo, quiet) {
            reopened++;
        } catch {}
        try engine.choose(board, mover, other, blackToMove, 0, 1, none, gameNo, quiet) {
            reopened++;
        } catch {}
        try engine.playAny(board, mover, other, blackToMove, 1) {
            reopened++;
        } catch {}
    }
}

contract EngineV5InvariantTest is Test {
    ChessEngineV5 engine;
    EngineGameHandler handler;
    bytes32 codeHash;

    function setUp() public {
        engine = ChessEngineV5(vm.deployCode("ChessEngineV5.sol:ChessEngineV5"));
        RulesHarness rules = RulesHarness(vm.deployCode("Chessboard.sol:RulesHarness"));
        handler = new EngineGameHandler(engine, rules);
        codeHash = address(engine).codehash;
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = EngineGameHandler.engineMove.selector;
        selectors[1] = EngineGameHandler.fallbackMove.selector;
        selectors[2] = EngineGameHandler.overCap.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 80
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_everyMoveIsLegalAndAppliedByTheRules() public view {
        assertEq(handler.illegal(), 0, "illegal or inconsistent move");
        assertEq(handler.statusWrong(), 0, "wrong game status");
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 80
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_playableGamesNeverRevertAndEndedGamesNeverReopen() public view {
        assertEq(handler.unexpectedReverts(), 0, "reverted with a legal move available");
        assertEq(handler.reopened(), 0, "an ended game was continued");
        assertEq(handler.overCapAccepted(), 0, "strength above 10,000 accepted");
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 80
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_boardStaysAChessPosition() public view {
        uint256 b = handler.board();
        uint256 whiteKings;
        uint256 blackKings;
        uint256 whitePieces;
        uint256 blackPieces;
        for (uint256 s; s < 64; s++) {
            uint256 piece = (b >> (s * 4)) & 15;
            uint256 t = piece & 7;
            assertTrue(t != 7 && piece != 8, "no invalid nibble");
            if (t == 0) continue;
            if (t == 1) assertTrue(s >= 8 && s < 56, "no pawn on a back rank");
            if (piece >= 8) blackPieces++;
            else whitePieces++;
            if (piece == 6) {
                whiteKings++;
                assertEq((handler.white() >> 8) & 0xff, s, "white king square in its state");
            }
            if (piece == 14) {
                blackKings++;
                assertEq((handler.black() >> 8) & 0xff, s, "black king square in its state");
            }
        }
        assertEq(whiteKings, 1);
        assertEq(blackKings, 1);
        assertLe(whitePieces, 16);
        assertLe(blackPieces, 16);
        assertEq(handler.materialGrew(), 0, "pieces appear only from nothing, or vanish without a capture");
    }

    /// The engine holds nothing and nothing about it changes, however it is used.
    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 80
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_engineHoldsNothingAndNeverChanges() public view {
        assertEq(address(engine).balance, 0);
        assertEq(address(engine).codehash, codeHash);
        assertEq(vm.load(address(engine), bytes32(0)), bytes32(0));
    }

    function afterInvariant() external view {
        assertGt(handler.calls(), 0, "the handler was driven");
        assertGt(handler.halfMoves(), 0, "moves were played");
    }
}
