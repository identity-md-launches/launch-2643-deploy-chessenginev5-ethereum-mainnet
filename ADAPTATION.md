# Engine launch adaptation

The existing `launch.json` already selects only `ChessEngineV5`, with
`constructorArgs: []`, for the Ethereum contracts-only launch. No production
adaptation is needed. The engine has an implicit, nonpayable constructor with no
arguments, no initialization step, no owner or admin, and no external library
link references. Its three external functions (`choose`, `play`, `playAny`) are
pure. No live deployment or transaction was performed.

All files in `src/`, `launch.json`, `foundry.toml`, and all six corpora in
`test/data/` are preserved. The existing rules test loads its data once and runs
in five independent game ranges; its chess assertions and sampling intervals
are unchanged. No hook, integration harness, token,
dependency, or compiler profile is added to the deliverable. Compilation remains
Solidity 0.8.26, Cancun, optimizer enabled with 200 runs, `via_ir = true`,
`bytecode_hash = "none"`, and `cbor_metadata = false`.

## Changes

| File | Change and reason |
| --- | --- |
| `test/Strength.t.sol` | Restores standalone coverage of the shipped `Strength` library identified as missing by audit finding `8116943f`. Seven tests cover nominal curve points, zero inputs, the cap, monotonicity in payment and depth, approximate thirty-percentage-point growth per tenfold share, and the existing multiplication overflow boundary. It uses only the existing forge-std dependency and `src/Strength.sol`. |
| `test/RulesRandom.t.sol` | Decodes all recorded game moves once in `setUp`, instead of copying the entire stored JSON and parsing one move list at each game boundary. Runs the corpus in five independent ranges of 50 games so Forge can parallelize them and each call uses less memory. Adds corpus-size and per-range position-count assertions. Addresses the local full-suite timeout while retaining every position, move, and original assertion. |
| `ADAPTATION.md` | Records the launch compatibility checks, actual bytecode sizes, changes, and disposition of every imported audit finding, as required by the assignment. |

The Strength tests restore the three reported coverage areas
(`test_decidedPoints`, `testFuzz_boundedAndMonotonic`, and
`testFuzz_tenfoldIsAboutThirtyPoints`) and add boundary coverage. They are not
claimed to be a verbatim copy of the historical test file. Successful-result fuzz
tests bound `paid` to the multiplication-safe range; separate deterministic and
fuzz tests explicitly reproduce the failing range. Thus a passing suite does
**not** mean the overflow is fixed.

The local check stopped after 600 seconds with nine suites passing and
`RulesRandomTest` still unfinished. Its previous loader copied the 1,274,585-byte
JSON string from storage and parsed it again for each of 250 games. The revised
loader keeps the JSON in memory during setup and decodes `.games` once into the
recorded move lists. To bound each call's memory growth and allow parallel
execution, the test runs game ranges 0–49, 50–99, 100–149, 150–199, and 200–249
independently. Each
range starts with a fresh board at its first game and asserts its number of
compared positions equals the sum of its move counts plus one final position
per game. Setup also asserts the full corpus has 250 games and 29,828 positions.
The existing loop still compares all 29,828 positions and plays all 29,578
recorded moves through `Rules`. Exact move-list hashes, move
counts, check, terminal status, and castling rights are checked at every
position; fast check flags are still compared at 7,457 positions and fast
mate-in-one results at 3,729 positions, using the original global position
indices. No corpus is reduced, test skipped, or compiler setting changed.

## Imported audit findings

1. **Stale runtime size — reproduced; documented, original notes preserved.**
   Finding `61f8e48c582ef5bee5ce3d12c6aa30ad11645b994fd6bb4251158577b8d1f17e`.
   `forge build --sizes` and the compiled artifact report **22,268 runtime bytes**
   and **22,294 initcode bytes**. The runtime has **2,308 bytes** of headroom below
   the 24,576-byte limit. The 22,111 figures in `launch.json` and the comment in
   `foundry.toml` are stale. They remain untouched because the assignment
   explicitly preserves the manifest unless launch requires a change and forbids
   any edit to existing build configuration. Neither comment affects deployment.
   This document supplies the corrected measurement; it does not claim to repair
   those two original notes.

2. **Missing Strength coverage and overflow — reproduced; coverage restored,
   arithmetic issue unresolved.**
   Finding `8116943f6a824b1cbb5ca4e4689378bc9d6027cd78bebc276da12682a822bbe2`.
   The imported tree lacked `test/Strength.t.sol`; the earlier tree contains an
   entry for it. Direct tests now exercise the library independently of self-play.
   `fromShare(1e9, 1e9)` returns 9,000. Calling through `StrengthHarness` with
   `paid = type(uint256).max / 100_000 + 1` and
   `depth = type(uint256).max` produces `Panic(0x11)`. At the preceding payment,
   the call succeeds. The new tests also reproduce the panic throughout the
   larger-payment range with nonzero depth, and verify the existing zero-depth
   early return even for maximum payment.

   `Strength` is not imported or called by `ChessEngineV5`; it is used by the
   existing self-play test to generate strengths. Fixing or removing it would
   change `src/` without being necessary for this engine launch, contrary to the
   assignment's explicit preservation requirement. The overflow remains a known
   limitation for the separate future hook work. The tests expecting a panic
   characterize the preserved implementation, not a desired restriction on the
   function's inputs or evidence of remediation.

3. **Engine launch compatibility — corroborated.**
   Finding `6080035969f5310a32574ac9314980c4088ad70d40113be2c2890cbb6bd3c69d`.
   The artifact ABI exposes only the three pure functions, with no constructor
   arguments, fallback, receive, owner, or initialization entry point. Creation
   and runtime bytecode have no external link references. Scanning with the
   supplied protected check's reachability rule found no reachable `DELEGATECALL`,
   `CALLCODE`, `SELFDESTRUCT`, `CREATE`, `CREATE2`, `CALL`, or `SSTORE` in the
   engine's creation or runtime bytecode. The engine needs no owner argument.

No imported finding was dismissed as unreproducible. The preservation constraints
take precedence over the audit's suggestions to edit production files or their
notes.

## Validation

- `forge build`: passed using the project's own configuration. Existing compiler
  and lint warnings remain; no settings were changed to suppress them.
- `forge build --sizes`: confirmed the engine sizes above. This diagnostic exits
  with an error because the existing **test-only** `Judge` (26,184 bytes) and
  `V5Probe` (26,172 bytes) exceed the runtime limit. Neither is listed in
  `launch.json`; ordinary `forge build` succeeds. They are preserved as part of
  the requested test suite.
- The seven direct Strength tests passed, including four fuzz tests with 256 runs
  each, with the assignment's seed:
  `0x19cc974ee7ba9f885d7a56b5f4a4df8b75d155aee61086a4683f510280a584a2`.
- The five random-game ranges passed together in **40.28 seconds** when run as
  a targeted suite. Their compared-position counts were 6,445, 6,354, 5,727,
  5,795, and 5,507, totaling the original 29,828. A temporary test in
  `test/scratch/` also compared the new bulk decoder with the original per-game
  JSON parser for every recorded move and verified the game/ply sequence,
  including every final position. It passed and is not delivered. A separate
  corpus check verified that the five entry-point ranges cover every original
  row exactly once and preserve the global sampling indices.
- The complete suite passed with **28 tests in 10 suites, zero failures and zero
  skips, in 107.42 seconds**, including self-play, conversion, bitboard and
  random-game rules corpora. The original 17 tests now have four extra cases
  because one corpus test became five complete game ranges; the seven Strength
  tests are retained. The rules suite took 72.25 seconds within this full run.
  The command enforced the same 600-second limit as the failed local check and
  exited successfully:

  ```sh
  FOUNDRY_FUZZ_SEED=0x19cc974ee7ba9f885d7a56b5f4a4df8b75d155aee61086a4683f510280a584a2 timeout 600s forge test
  ```

- During the initial adaptation, three temporary tests in `test/scratch/` passed a local deployment rehearsal
  using the supplied `ContractsDeploymentProbe`: deploy the exact creation
  bytecode with CREATE2, zero value and no arguments on chain id 1; check the
  predicted address, exact runtime and size, and opcode policy; exercise
  `choose`, `play`, and `playAny` immediately without initialization. The
  rehearsal used no fork or live network and its scaffolding is not delivered.
- File hashes and a comparison to the original compiled artifact confirmed that
  every production source, the manifest, compiler configuration, and all corpora
  are unchanged, as are the engine's complete creation and runtime bytecode.

The environment-driven protected suites themselves, Slither, and Mythril were
not run. The local checks above do not replace the subsequent independent audit
and launch verification.
