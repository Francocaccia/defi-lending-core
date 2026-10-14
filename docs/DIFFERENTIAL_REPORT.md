# Differential report: Solidity vs the independent C++ model (M8)

**Result: no mismatch.** The Solidity pure math and an independent C++ re-implementation, written
from `docs/DESIGN.md` only, returned identical words (or both failed) on every input tried:
25,000 fuzz comparisons per run (two runs, different seeds), 1,139 shared spec vectors (each run
twice by the C++ side, with decimal and with hex arguments) and the worked examples of the spec.

This is a legitimate outcome, not a placeholder: the report below says exactly what was compared,
how we know the comparison can fail, what the fuzzer does **not** reach, and the (minor) places
where the spec was ambiguous.

## 1. Method and independence

| Item | Value |
|---|---|
| Specification | `docs/DESIGN.md` (section 9 is the contract; sections 0-8 context) |
| Files read while writing the C++ | `docs/M8_HANDOFF.md`, `docs/DESIGN.md`, `test/differential/{vectors.txt, Differential.t.sol, DiffHarness.sol}` (only to see how the CLI is called; the libraries they call were not opened), `foundry.toml`, `.github/workflows/ci.yml`, `README.md`, `PLAN.md`, `.gitignore` |
| `src/`, `test/unit`, `test/fuzz`, `test/invariant`, `test/scenario`, `test/security`, `test/fork`, `test/mocks`, `test/utils`, `script/`, other `docs/` | **never opened** by the C++ author. The handoff allowed reading `src/` after the first complete differential run, only to adjudicate a mismatch. There was no mismatch, so `src/` was not opened at all. |
| Shared vectors | `vectors.txt` was produced by a *third*, separate implementation (Python) of section 9 and checked against the Solidity before M8. The C++ model passes all 1,139 lines. |
| Toolchain | MSVC 14.41 + CMake + Ninja (Visual Studio 2022), Windows 11; Foundry 1.8.5. No download of any kind, no third-party library. |

What can still be common-mode: the model, the Solidity and the vector generator were all derived
from the same `DESIGN.md`. An error *in the specification itself* (a formula that is wrong but
consistently implemented) would not show up here. The spec's worked examples were computed
independently in Python when it was written, which covers part of that risk, not all of it.

## 2. What was run (real output)

C++ side (`reference-model/`):

```text
ctest --test-dir reference-model/build --output-on-failure
  unit  + 10 black-box CLI tests of the real binary : 11/11 passed
unit: 46 tests, 1648 checks, 0 failures
      vectors run (decimal + hex variants): 2278, mismatches: 0
```

Solidity vs C++ (`FOUNDRY_PROFILE=diff forge test --match-path "test/differential/*" -vv`):

| Run | Seed | Result | Time |
|---|---|---|---|
| 1 | default | 29 passed, 0 failed, 0 skipped (28 differential + `VectorsTest`) | 832 s |
| 2 | `--fuzz-seed 0x4d38` | 29 passed, 0 failed, 0 skipped | 1,644 s |

Each of the 25 functions is fuzzed with `runs = 1000` (profile `diff`) and, per run, half of the
inputs are bounded to realistic ranges and half are raw 256-bit values (the `wide` flag of
`Differential.t.sol`): 25 x 1,000 = 25,000 comparisons per run. `test_diff_vectors` additionally
re-checks the worked examples of DESIGN 3.5, 4, 5.2, 6.1, 7.2 and 7.5. `forge test` (default
profile, no ffi, no C++ toolchain involved) still gives 277 passed / 0 failed / 2 skipped, and
with the binary hidden the differential suite skips instead of failing.

## 3. Mismatches

**None.** Consequently: no Solidity fix, no regression test, no change to `vectors.txt`, no
C++ fix prompted by the Solidity. (Before the first differential run the C++ was, of course,
debugged against its own tests; those were typos and a naming clash, see 5.)

## 4. How we know the comparison can fail (sensitivity checks)

Because "0 mismatches" is only worth something if mismatches would be seen, two bugs were injected
into the C++ model, the C++ tests and the differential suite were run, and the bugs were reverted
afterwards (the repo contains the unmodified model). The second row's bug was injected together
with the first in one build; the first row's unit-test result also comes from an earlier build with
that bug alone:

| Injected bug | C++ unit tests | Differential fuzz (`diff` profile) |
|---|---|---|
| `debtFromScaled`: `mulDivUp` -> `mulDiv` (rounding direction) | failed (9 checks, plus the vectors) | failed on the first inputs: `debtFromScaled 1626821193500480210227357 1012057760658635198: 1646437014086104 != 1646437014086105` |
| `collateralValueUsd`: return 0 early when `amount == 0` (breaks rule R4, `10**78` must still be evaluated) | failed (`collateralValueUsd(0, 0, 78)` no longer fails) | failed after 204 runs: `Solidity REVERTED but model succeeded: collateralValueUsd 0 1422913110861814264399369092194630920061234388580222489 123` |

The second row matters: it shows the fuzzer reaches the *eager-operand* corner of the revert
semantics (decimals >= 78 with a zero amount), not just ordinary arithmetic.

The big-integer code was also checked against Python's arbitrary-precision integers through the
CLI (a throw-away script, not in the repo): 3,000 random cases of `healthFactor` (floor `mulDiv`),
`toAssetsDown` and `toAssetsUp` (ceil `mulDiv`) with operands of 1 to 256 bits and the edge values
`0, 1, 2^64, 2^128 - 1, 2^128, 2^255, 2^256 - 2, 2^256 - 1`: 0 mismatches.

## 5. Edge cases covered (C++ tests, vectors and fuzz)

- **Magnitudes**: `0`, `1`, `2^256 - 1` and its neighbours; products that need the full 512 bits
  (`(2^256-1)^2 / (2^256-1)`), quotients of exactly `2^256 - 1` and exactly `2^256`, and a
  `mulDivUp` whose floor is `2^256 - 1` with a non-zero remainder (so the `+1` overflows;
  constructed with a modular inverse: `a*b = (2^256-1)*d + 1`).
- **Rounding boundaries**: exactly divisible vs one off, for every Up/Down pair
  (`toSharesDown/Up`, `toAssetsDown/Up`, `scaledFromAssetsUp/Down`, `collateralValueUsd` vs
  `debtValueUsd`, `maxRepayable` of a 1-wei debt); health factor exactly 1.0 vs one wei below;
  `isWithinMaxLtv` at equality; `LT*(1+bonus) == 1` rejected, one wei less accepted.
- **Decimals**: 0, 18, 76, 77 (valid), 78, 79, 255 (model failure, exit 1) and 256+ (usage
  error, exit 2); `10**d * WAD * price` overflowing earlier than 78 (`d >= 60` with price 1).
- **Division by zero**: `optimal == 0`, `index == 0`, a zero price in the liquidation
  denominators, `debtValue == 0` (health factor short-circuit, not a failure).
- **Eager/lazy rules R4/R5**: operands evaluated although unused (decimals 78 with amount 0),
  untaken `if/else` branches NOT evaluated (steep branch of the rate model when `u <= optimal`,
  `repayForSeize` when `seized <= collateral`).
- **Parameter invalid but unvalidated (R7)**: `K = 0`, `optimal > WAD`, `closeFactor > WAD`, a bonus
  above the cap flowing through the arithmetic.
- **Market kernels**: `requested = 0`, `requested = UINT_MAX`, collateral smaller than needed,
  collateral `0`, burned = all scaled debt vs floor; `badDebt` with `borrowerScaled > total`,
  `loss >= supply` (saturation) and the derived-vs-own-debt rounding gap.
- **CLI**: decimal and hex (`0x`/`0X`, any case) arguments give identical results; empty, signed,
  spaced, underscored, fractional and `>= 2^256` arguments are usage errors; usage errors win over
  model failures; exactly one `\n`-terminated line on stdout (binary mode, no `\r\n` on Windows).

## 6. What this does NOT cover (honest limits)

- **Fuzz distribution.** `Differential.t.sol` is fixed (it was part of the handoff). Sampling its
  input distributions through the C++ CLI (80 samples per function and mode, a statistical
  estimate, not an exact count) shows that the "wide" half of the inputs mostly exercises
  agreement on *failure* (for 17 of the 25 functions essentially every wide input fails: the
  random 256-bit operands overflow), while the "narrow" half exercises agreement on *values*
  (the model succeeds on about 94% of narrow inputs). Two consequences:
  - Agreement on tricky *successful* edge results comes mainly from the narrow half, the 1,139
    vectors (864 successes, 275 failures) and the hand-built cases above, not from the wide half.
  - `validateRiskParams` is the weakest spot: random inputs satisfy all eight conditions about
    1% of the time, so the fuzzer mostly compares failures. The success path and the strict
    `LT*(1+bonus) < 1` boundary are covered by the 30 successful vectors and by hand-written cases
    in `test_model.cpp`, not by the fuzzer.
- **Not verified here**: the market's state machine, access control, token transfers, reentrancy,
  the oracle's validity checks and normalisation. Those belong to the unit, invariant, fork and
  security suites. The differential tests only see the pure functions behind `DiffHarness`.
- **Random testing is not proof.** 50,000 comparisons plus 1,139 vectors make a disagreement in
  the covered functions unlikely, they do not rule one out.
- **One compiler tried locally.** The model was built and tested with MSVC 14.41. GCC (Ubuntu CI)
  and MSVC (Windows CI) builds are configured in `.github/workflows/ci.yml`; no GCC or Clang was
  available on the development machine to try beforehand.
- **Performance.** A comparison costs one process spawn (~50 ms); a full 25,000-comparison run
  takes 14 to 27 minutes on this machine, which is why CI runs the profile once, not per commit
  in a matrix.

## 7. DESIGN.md ambiguities hit

All resolved by the "most natural reading"; none turned out to hide a disagreement with the
Solidity. The clarifications are now in `docs/DESIGN.md` section 9.8.

| # | Place | Question | Resolution (model behaviour) |
|---|---|---|---|
| 1 | 9.2 `annualBorrowRate` | "`WAD - optimal` fails if `optimal > WAD`": can that ever trigger? | No: it is only evaluated when `u > optimal`, and `u <= WAD` is checked first, so the case is unreachable. With `optimal > WAD` the `u <= optimal` branch is taken. Doc now says so. |
| 2 | 9.5 `validateRiskParams` | If `LT * (WAD + bonus)` overflows but an earlier condition already failed, which failure wins? | Irrelevant: every failure is the same failure (R4). Documented as "order unobservable". |
| 3 | 9.7 `liquidationAmounts` | `requested == 0`: failure or `[0,0,0]`? | `[0,0,0]`; the "NothingToLiquidate" revert is a market rule (7.3), not part of the pure function. |
| 4 | 9.7 `liquidationAmounts` | `collateral == 0` with `seized > 0`? | cap branch: `seized = 0`, `repaid = min(repaid, repayForSeize(0)) = 0`. |
| 5 | 9.7 `repayAmounts` | `index == 0`? | `debt = 0`, so `assets >= debt` holds and `scaledFromAssetsDown` (which would divide by zero) is not evaluated: `[0, scaled]`. |
| 6 | M8_HANDOFF 2.1 | Are leading zeros (`007`) and the prefix `0X` accepted? | Yes to both (the handoff says "case-insensitive"; `vm.toString` never produces them). Documented in `reference-model/README.md`. |
| 7 | M8_HANDOFF 2.1 | What does "arguments named `decimals` must be `<= 255`" imply for 78..255? | CLI accepts 78..255 (they are valid `uint8`) and the *model* fails with exit 1 (R3); 256+ is exit 2. |
| 8 | DESIGN 9.1 R6 | The constant `UINT_MAX` collides with the C macro of `<limits.h>` | Not a spec ambiguity: renamed `UINT256_MAX` in the code. |

## 8. Reproduce

```powershell
# PowerShell, from the repo root (Windows: run the build inside a VS developer prompt)
cmd /c '"C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat" && cmake -S reference-model -B reference-model/build -G Ninja -DCMAKE_BUILD_TYPE=Release && cmake --build reference-model/build && ctest --test-dir reference-model/build --output-on-failure'
$env:Path = "C:\Users\cacci\.foundry\bin;$env:Path"
forge test --match-contract VectorsTest -vv                 # vectors vs the Solidity (no ffi)
$env:FOUNDRY_PROFILE = 'diff'
forge test --match-path "test/differential/*" -vv           # Solidity vs C++ (~15-30 min)
```

On Linux/macOS: `cmake -S reference-model -B reference-model/build && cmake --build
reference-model/build && ctest --test-dir reference-model/build`, then the two `forge` commands.
