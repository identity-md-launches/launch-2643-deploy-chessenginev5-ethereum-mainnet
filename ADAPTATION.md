# Engine launch adaptation

The existing `launch.json` already selects only `ChessEngineV5`, with
`constructorArgs: []`, for the Ethereum contracts-only launch. No launch-rule
adaptation is needed. The engine has an implicit, nonpayable constructor with no
arguments, no initialization step, no owner or admin, and no external library
link references. Its three external functions (`choose`, `play`, `playAny`) are
pure. No live deployment or transaction was performed.

Production sources changed only where a reproduced finding required it (the
second round of review, below). `launch.json`, `foundry.toml`, and all six
corpora in `test/data/` are preserved. No hook, integration harness, token,
dependency, or compiler profile is added to the deliverable. Compilation remains
Solidity 0.8.26, Cancun, optimizer enabled with 200 runs, `via_ir = true`,
`bytecode_hash = "none"`, and `cbor_metadata = false`.

## Changes

| File | Change and reason |
| --- | --- |
| `src/ChessEngineV5.sol` | **Enemy promotion threat** (review finding `10cde183`, medium, with a proof test): `_context` records the enemy pawns a step from promotion (`passers`); `_risk` and `_exact` score every move against them through the new `_promotion`, which charges a queen for a pawn (`PROMOTION = 800`) unless the move takes the pawn, blocks it, or leaves the promotion square attacked by us (then nothing if the square is undefended, else the attacker's value minus the pawn; a king cannot take a defended queen). Lines are read with the pawn lifted off its square, so a rook behind the pawn counts for either side. When such a pawn exists every move is looked at, as in check, so the saving move is never overlooked. **Promotion by capture** (review finding `be477030`, medium, with a proof test, third round): `passers` is now every enemy pawn on its seventh rank, whether or not it has a promotion move before ours, and `_promotion` scores each square the pawn can queen on in the position after our move: the square ahead when empty, and the squares diagonally ahead that hold a piece of ours other than the king. A capture square costs the piece taken on top of the queen (`_queening` gives the queen's part, `_typeOn` the piece), and when we can retake the new queen on an undefended square the capture costs the piece less the pawn. The promoting pawn no longer counts as a defender of its own capture square. **Second-look mate guard** (review finding `5088cfe5`, low): `_exact` now asks `Bitboard.mateInOne` without the six-check bound, so a position and its colour mirror get the same verdict. Header paragraphs document the risk term and the seed trust assumption (review finding `7e5e89e6`, info). Runtime grows from 22,268 to 23,339 bytes (1,237 under EIP-170). |
| `src/Strength.sol` | **No revert on huge payments** (audit finding `8116943f`, review finding `916b9526`, low): `fromShare` returns the cap at once when `paid >= depth` (already past the cap on the old curve), and when `paid * FLOOR` would overflow it shifts `paid` and `depth` by 17 bits (`FLOOR_BITS`; 2^17 > FLOOR) before scaling. Both keep their eight fraction bits, so the result equals what the unbounded computation would give, and the curve is unchanged wherever it did not revert. Not linked into `ChessEngineV5`; the library is the later hook's. |
| `test/EngineV5Passers.t.sol` | New in the second round; extended in the third. The three reported positions (K+R v K+P with Rb7 and with Ra1, K+R+B v K+P), each as White and as Black in its colour mirror, at strengths 0, 4,000, 9,000 and 10,000 over eight seeds: after the engine's move every promotion of the pawn, by a push or by a capture, is illegal or lands where the new queen can be taken at once (the check now walks every legal promotion rather than one given push). Third round: the reviewer's two positions (push blocked by our bishop; push square covered but the capture square not), a position where the pawn has no promotion move until our knight takes the rook on its capture square, each as White and in its mirror, and a second-look probe of four moves in one position whose scores are worked out by hand (a queen plus the bishop taken, 1,120; an uncovered push, 800; the bishop less the pawn, 220; nothing). A further position where the pawn's king defends the promotion square: the engine still brings the rook to bear (Rb1 or Rh7) and sells it for the queen. A last test scores the reviewer's mate position and its mirror through the second look and expects `-MATE` from both (the mirror scored -320 on the previous engine). |
| `test/Strength.t.sol` | The two tests that pinned the `Panic(0x11)` become tests of the fixed behaviour (the cap at and beyond the scaling boundary, a 100% share, the largest payment, and a 2^-15 share of about 1,400 bps). The fuzz bounds that avoided the overflow are removed, and two fuzz tests check that shifting a payment and its depth together keeps the strength, across the boundary. |
| `test/EngineV5Games.t.sol` | `GOLDEN` updated to the new self-play fingerprint (second and third rounds), as the test's own comment asks whenever play changes. |
| `test/RulesRandom.t.sol` | (Previous round.) Decodes all recorded game moves once in `setUp` and runs the corpus in five independent ranges of 50 games; every position, move and assertion is kept. |
| `ADAPTATION.md` | This record. |

## Review findings (third round)

1. **Promotion threat reads only the square straight ahead — reproduced;
   fixed.**
   `be47703048502d5369fda019ecef02bf287ac08eb29ba9d17bb05261dbce539f`.
   The proof (`Proof_be4770304850.t.sol`, run from `test/scratch/`) failed on
   the starting tree with 32 failing strength/seed pairs in each of its three
   tests (Ng4xh6 every time, then b2xc1=Q+) and passes on this tree. The cause
   was as reported: a pawn whose push square was occupied was dropped from
   `passers`, and `_promotion` read only the push square, so a queen made by
   capturing onto the last rank was never charged. The fix follows the
   reviewer's outline, slightly wider: `passers` is every enemy pawn on its
   seventh rank rather than only those with a promotion move now, because the
   position after our move decides which squares the pawn can reach (our knight
   taking a rook on the pawn's capture square gives the pawn a move it did not
   have; the new test `test_pawnWithoutAMoveStillCounts` plays that on the
   previous engine and gets Nd3xc1). Every square is scored on the position
   after the move, as before, in both the cheap pass and the second look.
   Self-play over the same 40 games: the fingerprint changed; average gas per
   choice is 206k/218k/239k by effort tier (from 201k/213k/234k) and the
   maximum per choice 778k (from 690k); rook-or-queen giveaways are 2/6/3 by
   tier (from the second round's 3 at 70%+), mates in one taken 4/5, 25/25
   and 7/8, and the other counts moved by one or two.

## Review findings (second round)

1. **Engine never scores an enemy pawn about to promote — reproduced; fixed.**
   `10cde183415bd8a4cb2873aa403aa484573eb883bc2e0957e24efc23a353239f`.
   The proof test failed on the starting tree with 16, 6 and 12 failing
   seed/strength pairs; it passes on this tree. The term is applied in the
   cheap pass (`_risk`) so unrefined moves carry it, and in `_exact` so a
   refined leader keeps it. It applies at every strength: at strength 0 the
   seeded mistake (up to 400) cannot outweigh the 800 at stake. Self-play
   over the same 40 games: the fingerprint changed, average gas per choice
   rose by 3% (193k/208k/227k to 201k/213k/234k by effort tier), the maximum
   per choice from 557k to 690k (positions with a passer now look at every
   move), rook-or-queen giveaways at 70%+ effort fell from 6 to 3, and the
   other mistake counts moved by one or two.

2. **Second-look mate guard is walk-order dependent — reproduced; fixed.**
   `5088cfe512a795311de472d9bbf906d89da805ec3ab5c7f2bf144f34484e8f94`.
   On the reviewer's position the bounded search found Qe3-f2# and the
   mirror's bounded search returned 0 (full search: 2869). The guard runs at
   most four times per choice; on that position the full search cost 118k gas
   against 82k bounded, and in self-play the change added about 300 gas to the
   average and nothing to the maximum. `Bitboard.sol` is unchanged; the
   engine's own mate tests keep their bound (`MATE_TESTS`).

3. **`Strength.fromShare` reverts above `type(uint256).max / 100_000` —
   reproduced; fixed.**
   `916b952617f687b3d94beb870a570c82b4ee7a953e1caf4df94b84b31d07ab1b`.
   The scratch reproduction panicked on the starting tree and passes now:
   `fromShare(max/1e5 + 1, 1)` and `fromShare(p, p)` return 9,000, and
   `fromShare(1 << 240, 1 << 255)` is about 1,400. The previous round left this
   unresolved on the preservation rule; a finding reproduced by three auditors
   and raised again on review outweighs it, and the change does not touch the
   engine's bytecode.

4. **Seed trust assumption — reproduced; documented.**
   `7e5e89e60e9cda1e7aee3a2be38cd5a9ef5e9f70ae5118e0d609b0900c6c7b68`.
   The engine is pure and takes the seed as an argument by design; nothing in
   it can change that. The contract header now states that the caller must
   draw the seed from something the trader cannot choose or predict when
   committing the trade, and this is an open item for the hook launch.

5. **Stale runtime size in the `foundry.toml` comment — reproduced; out of
   scope.**
   `318c54ed611fb816b76cc633bdafcd439e8daf9c8a9294b9f99da435c84c1cc7`.
   `foundry.toml` is protected build configuration a submission may not touch,
   and `launch.json` (whose notes in this tree also still say 22,111) is the
   manifest step's. The built figure is now **23,220 runtime bytes, 23,246
   initcode bytes, 1,356 under the limit**; the manifest step is told the
   values.

## Imported audit findings

1. **Stale runtime size — reproduced; documented, original notes preserved.**
   `61f8e48c582ef5bee5ce3d12c6aa30ad11645b994fd6bb4251158577b8d1f17e`.
   As in item 5 above: the figure is now 23,220 runtime bytes, and the two
   files that state 22,111 are outside this job's write paths.

2. **Missing Strength coverage and overflow — reproduced; coverage restored
   (previous round), overflow fixed (this round).**
   `8116943f6a824b1cbb5ca4e4689378bc9d6027cd78bebc276da12682a822bbe2`.
   `test/Strength.t.sol` covers the curve directly; see review item 3.

3. **Engine launch compatibility — corroborated.**
   `6080035969f5310a32574ac9314980c4088ad70d40113be2c2890cbb6bd3c69d`.
   The ABI still exposes only the three pure functions, with no constructor
   arguments, fallback, receive, owner, or initialization entry point. A scan
   of the rebuilt runtime with the protected check's reachability rule finds
   no `DELEGATECALL`, `CALLCODE`, `SELFDESTRUCT`, `CREATE`, `CREATE2`, `CALL`,
   `STATICCALL` or `SSTORE`.

## Validation

- `forge build`: passes with the project's own configuration. Existing
  compiler warnings remain; no setting was changed.
- `forge build --sizes`: `ChessEngineV5` 23,339 runtime / 23,365 initcode
  bytes. The diagnostic still exits non-zero because the **test-only** `Judge`
  and `V5Probe` exceed the runtime limit; neither is in `launch.json`.
- Second round: the full suite with the verifier's seed passed, 34 tests in
  11 suites, zero failures, in 109 seconds:

  ```sh
  FOUNDRY_FUZZ_SEED=0x19cc974ee7ba9f885d7a56b5f4a4df8b75d155aee61086a4683f510280a584a2 timeout 600s forge test
  ```

- Third round, on a slower machine with a memory limit that killed the suite
  when run whole (exit 137 with 8, 4 and even 1 thread): the suites were run
  one at a time with the same seed. **Passed: Strength (8), EngineV5Passers
  (9, with the four new tests), EngineV5 (3), EngineV5Conversion (6),
  Endings (1), V5Profile (1), BitboardGas (1), Bitboard's castling and lsb
  tests (2), and EngineV5Games (1) with the new fingerprint: 32 of 38 tests,
  zero failures.** Not completed here: `Bitboard.t.sol`'s
  `test_againstChessJs` (killed, exit 137, after the small tests in the file
  passed) and the five `RulesRandom.t.sol` ranges (killed together; one range
  alone was still running at its 400-second timeout). Those six tests check
  `src/Bitboard.sol` and `src/Rules.sol` against the chess.js corpora; neither
  library, nor their tests, nor the corpora changed in this round, and both
  suites passed in the previous round on the same sources.
- The reviewers' proofs (`Proof_10cde183415b.t.sol`, second round, and
  `Proof_be4770304850.t.sol`, third round) were run from `test/scratch/`: all
  three tests of each failed on their starting tree and pass now. A scratch
  copy of the second-round engine, run against the extended passer suite,
  fails the two reviewer positions and the blocked-pawn position (Nd3xc1) and
  passes the rest, so each new test pins the change it describes.
- A scratch rehearsal deployed the built creation code with `CREATE2`, zero
  value and no arguments on chain id 1, checked the runtime length, and called
  `play` on the start position without any initialization.
- A scratch copy of the previous engine confirmed the baseline self-play
  figures above and that the new mirror test fails on it (-320).

The environment-driven protected suites, Slither and Mythril were not run.
