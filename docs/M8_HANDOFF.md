# M8 handoff: the independent C++ reference model

You are implementing, **from the specification alone**, a command-line program that re-computes
the protocol's pure math, and then proving (or disproving) that the Solidity agrees with it. The
whole value of this milestone is that the C++ is written WITHOUT looking at the Solidity.

## 1. Independence rules (strict)

**Allowed to read while writing the C++:**
- `docs/DESIGN.md`: the ONLY specification (section 9 is the contract; sections 0-8 give context).
- `docs/M8_HANDOFF.md` (this file).
- `test/differential/vectors.txt`: spec test vectors (machine-readable, see section 4).
- `test/differential/Differential.t.sol` and `test/differential/DiffHarness.sol`: ONLY to see how
  the CLI is invoked (names, argument order). They call library functions but you do not need,
  and must not open, those libraries.
- `foundry.toml`, `.github/workflows/ci.yml`, `README.md`, `PLAN.md`, `.gitignore`.

**Forbidden until the C++ passes its own tests AND the differential suite has been run once:**
`src/**`, `test/unit/**`, `test/fuzz/**`, `test/invariant/**`, `test/scenario/**`,
`test/security/**`, `test/fork/**`, `test/mocks/**`, `test/utils/**`, `script/**`, and every
other file in `docs/` (THREAT_MODEL, ROUNDING_REVIEW, SLITHER_TRIAGE, GAS_AND_COVERAGE).

**If `docs/DESIGN.md` is ambiguous or incomplete:** do NOT peek at the Solidity. Write the
ambiguity down (it is a valid finding of this milestone), pick the most natural reading,
implement it, and fix the doc. If a vector or a differential run then disagrees, the doc fix is
the answer.

**After the first complete differential run** you may read `src/` but ONLY to decide, for a
specific mismatch, which side is wrong. State in the report when and why you did.

## 2. The program

A standalone C++17 (or newer) executable built with CMake. No floating point anywhere in the
math. 256-bit unsigned arithmetic with a **512-bit intermediate** for `mulDiv`
(`docs/DESIGN.md` R1-R3). Output must match the Solidity exactly.

### 2.1 Command line

```
refmodel <function> <arg1> <arg2> ...
```

- `<function>` is one of the names in section 3 (case-sensitive).
- Each `<argN>` is an unsigned integer in **decimal** (`123`) or **hex** (`0x7b`, case-insensitive).
  No sign, no whitespace, no underscores, no empty string. Values must be `< 2^256`.
- Arguments named `*Decimals`/`decimals`/`dd`/`cd` must be `<= 255` (the Solidity type is `uint8`).

### 2.2 Output and exit codes

| Situation | stdout | stderr | exit |
|---|---|---|---|
| Success | ONE line: `0x` followed by one 32-byte big-endian word (64 lowercase hex digits) per returned value, concatenated, then `\n`. Nothing else. | empty | `0` |
| The Solidity call would **revert** (any rule R1-R4 failure or an explicit validation failure) | empty | `error: <short reason>` | `1` |
| Usage error: unknown function, wrong number of arguments, unparsable or out-of-range argument | empty | `usage: <reason>` | `2` |

Why: Foundry's `vm.ffi` turns a `0x...` hex line on stdout into raw bytes, so the Solidity test
reads the words directly. Exit `2` is treated as a **test failure** by the harness (it means the
caller is wrong), exit `1` is compared against "Solidity reverted".

Example: `refmodel utilization 3 1` prints
`0x00000000000000000000000000000000000000000000000004a03ce68d215555` (= 333333333333333333).

### 2.3 Where the binary must end up

`reference-model/build/refmodel` (on Windows `refmodel.exe`; Foundry's `vm.ffi` resolves
`reference-model/build/refmodel` to `refmodel.exe` automatically, which was verified on this
machine). Use a single-config generator (Ninja) so the executable is directly in `build/`.
`reference-model/build/` is already in `.gitignore`.

## 3. Functions to implement

Semantics, rules for when each fails, and constants are in **`docs/DESIGN.md` section 9**. The
argument ORDER below is fixed and is what the harness uses. "-> N" is the number of 32-byte
output words.

| Function | Arguments (in order) | -> N |
|---|---|---|
| `utilization` | supply, borrows | 1 |
| `validateRateParams` | base, slope1, slope2, optimal | 1 |
| `annualBorrowRate` | base, slope1, slope2, optimal, u | 1 |
| `borrowRatePerSecond` | base, slope1, slope2, optimal, u | 1 |
| `accrueIndex` | index, ratePerSecond, dt | 1 |
| `scaledFromAssetsUp` | assets, index | 1 |
| `scaledFromAssetsDown` | assets, index | 1 |
| `debtFromScaled` | scaled, index | 1 |
| `toSharesDown` | assets, totalAssets, totalShares | 1 |
| `toSharesUp` | assets, totalAssets, totalShares | 1 |
| `toAssetsDown` | shares, totalAssets, totalShares | 1 |
| `toAssetsUp` | shares, totalAssets, totalShares | 1 |
| `collateralValueUsd` | amount, priceWad, decimals | 1 |
| `debtValueUsd` | amount, priceWad, decimals | 1 |
| `healthFactor` | collateralValue, debtValue, liquidationThreshold | 1 |
| `maxDebtValue` | collateralValue, maxLtv | 1 |
| `isWithinMaxLtv` | collateralValue, debtValue, maxLtv | 1 (0 or 1) |
| `maxRepayable` | debt, closeFactor | 1 |
| `seizeForRepay` | repay, debtPriceWad, debtDecimals, collPriceWad, collDecimals, bonus | 1 |
| `repayForSeize` | seize, debtPriceWad, debtDecimals, collPriceWad, collDecimals, bonus | 1 |
| `validateRiskParams` | maxLtv, liquidationThreshold, bonus, closeFactor | 1 |
| `accrue` | totalScaledDebt, totalSupplyAssets, borrowIndex, elapsed, base, slope1, slope2, optimal | 2: newIndex, interest |
| `repayAmounts` | assets, scaled, index | 2: repaid, burned |
| `liquidationAmounts` | scaled, index, requested, collateral, collPrice, debtPrice, collDecimals, debtDecimals, bonus, closeFactor | 3: repaid, seized, burned |
| `badDebt` | totalScaledDebt, borrowerScaled, index, totalSupplyAssets | 3: debtWrittenOff, loss, newTotalSupplyAssets |

Heads-up (documented in DESIGN 9.7): `liquidationAmounts` takes the COLLATERAL price/decimals
before the DEBT ones, whereas `seizeForRepay`/`repayForSeize` take the debt asset first.

## 4. Test vectors

`test/differential/vectors.txt` holds ~1,100 lines
`name(types) arg1 arg2 ... => out1 out2 ...` or `=> FAIL`, including the worked examples of
DESIGN and many edge cases (zero, `2^256 - 1`, `10^77` vs `10^78`, divide by zero, overflow).
Load it from your C++ unit tests (strip the `(types)` part; `FAIL` means exit code 1). It was
produced by a separate, independent implementation of DESIGN section 9 and is checked against
the Solidity by `forge test --match-contract VectorsTest` (a plain default-profile test).
**Do not edit it** unless a mismatch analysis proves a vector wrong; if so, explain in the report.

## 5. What to deliver (definition of done)

1. `reference-model/` : `CMakeLists.txt`, sources, a short `README.md`, and a CMake test target.
2. **C++ unit tests** (Catch2 or GoogleTest) that include: (a) every line of `vectors.txt`;
   (b) hand-computed cases from DESIGN section 9; (c) edge cases: 0, 1, max uint256 and its
   neighbours, rounding boundaries (value exactly divisible vs one off), `decimals` 76/77/78/255,
   `mulDiv` results at exactly `2^256 - 1` and `2^256`; (d) the CLI itself (exit codes 0/1/2,
   output format, hex and decimal arguments, rejected inputs).
3. **Differential run**: `FOUNDRY_PROFILE=diff forge test --match-path "test/differential/*"`
   (1000 fuzz runs per function in that profile; the tests skip if the binary is missing).
4. **`docs/DIFFERENTIAL_REPORT.md`**: the result, the number of fuzz runs/functions, and for EVERY
   mismatch found: inputs, both outputs, which side was wrong and why, and the fix (in the
   Solidity with a regression test, in the C++, or in DESIGN.md). A real, explained mismatch is
   the headline value of this milestone. If there are none, say so honestly and describe the edge
   cases covered. Also list every DESIGN.md ambiguity you hit and how you resolved it.
5. **CI**: `.github/workflows/ci.yml` builds the model with CMake and runs its tests BEFORE
   `forge test`, then runs the differential suite with `FOUNDRY_PROFILE=diff`. The commented
   template is already in that file. The protocol must still build and pass with NO C++ toolchain.
6. **README.md**: replace the "Reference model" placeholder with what the model verifies (the
   math: formulas, units, rounding, overflow/revert conditions) and its limits (NOT the market's
   state machine, access control, token handling or oracle behaviour), plus how to build/run it
   and why `ffi` is safe here (one fixed binary built from this repo, numeric arguments only,
   no shell, no network, only in `[profile.diff]`).
7. **PLAN.md**: mark M8 done and record what is pending. The private (git-ignored)
   `PORTFOLIO_NOTES.md`: add the licenses of the libraries you used (Boost, Catch2, ...).
8. Small conventional commits, in English. The local git identity of this repo is already the
   GitHub noreply address; do not change it. End each commit message with the
   `Co-Authored-By` line your session instructions give. Pushing `main` to `origin` is allowed by
   the owner once the work is verified.

## 6. Environment facts (discovered on this machine, 2026-10-14)

- Windows 11, PowerShell. **WSL is NOT installed** (cannot be installed without admin + reboot).
- **Visual Studio 2022 Community** with MSVC `14.41.34120` is installed, including a bundled
  CMake and Ninja:
  `C:\Program Files\Microsoft Visual Studio\2022\Community\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe`
  and `...\CMake\Ninja\ninja.exe`. Load the compiler with
  `C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat`.
- **MSVC has NO `__int128`**, so a big-integer type is required (Boost.Multiprecision `cpp_int`/
  `uint512_t`, or another header-only library, or a small hand-written one if you justify it).
- **Boost is NOT installed.** Getting it means a download; downloads need the owner's explicit
  OK, so ASK before fetching (options: vcpkg `boost-multiprecision`, CMake `FetchContent`, or
  another header-only library). The same applies to Catch2/GoogleTest.
- Foundry 1.8.5 is at `C:\Users\cacci\.foundry\bin` (NOT on the global PATH: prepend it in your
  shell). `forge test` works natively on Windows.
- GitHub Actions runs on `ubuntu-latest`: there `sudo apt-get install -y cmake ninja-build libboost-dev`
  (+ `catch2` or fetch it) is free and keeps CI zero-cost.
- Rules that always apply: zero cost; no secrets in the repo; no code copied from other protocols
  (a third-party big-integer LIBRARY as a dependency is fine, with its license recorded).

## 7. Quick reference

```powershell
# PowerShell, from the repo root
$env:Path = "C:\Users\cacci\.foundry\bin;$env:Path"

# build (Developer environment; adjust if you choose another toolchain)
cmd /c '"C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat" && cmake -S reference-model -B reference-model/build -G Ninja -DCMAKE_BUILD_TYPE=Release && cmake --build reference-model/build && ctest --test-dir reference-model/build --output-on-failure'

# spec vectors against the Solidity (no ffi needed)
forge test --match-contract VectorsTest -vv

# differential fuzz: Solidity vs the C++ binary
$env:FOUNDRY_PROFILE = 'diff'
forge test --match-path "test/differential/*" -vv
```

## 8. How the owner starts this session by hand

If this session was not started automatically, open a NEW Claude Code session in
`C:\Users\cacci\defi-lending-core` and paste:

> Do milestone M8 of this repository. Read ONLY `docs/M8_HANDOFF.md` first and follow it exactly,
> including its independence rules: you may read `docs/DESIGN.md`, `test/differential/` and
> `reference-model/`, but NOT `src/` or the other test directories until the handoff allows it.
> Ask me before downloading anything (Boost, Catch2, ...). Report with real command output.
