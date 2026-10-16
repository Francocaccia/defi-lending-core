# PLAN

Living plan for `defi-lending-core`. Updated at the end of every milestone. Numbers here come
from real command output (commands in `docs/GAS_AND_COVERAGE.md`).

## 1. Goal

A small, correct, well-tested over-collateralized lending protocol (Solidity + Foundry +
Chainlink) as a portfolio piece, whose math is checked against an independent C++ reference
model. Quality over feature count. Educational only: never real funds, never mainnet.

## 2. Milestone status

| # | Milestone | Status | Notes |
|---|---|---|---|
| M0 | Setup (Foundry, deps, CI skeleton, docs skeletons) | **done** | solc 0.8.28 pinned; `ffi` only in `[profile.diff]` |
| M1 | Oracle wrapper + mock aggregator + tests | **done** | verified mainnet/Sepolia feed addresses in `script/Addresses.sol` |
| M2 | Interest rate model + tests | **done** | kinked model, WAD annual / RAY per-second |
| M3 | Core accounting (shares, collateral, borrow/repay, index) | **done** | scaled-debt model, virtual shares |
| M4 | Risk (HF, guards, liquidation, bad-debt recording) | **done** | found + fixed a liveness hole (zero-burn liquidation) |
| M5 | Invariant tests + mainnet fork tests | **done** | 13 invariants; fork tests skip without `MAINNET_RPC_URL` |
| M6 | Security pass (Slither, threat model, rounding review, gas, coverage) | **done** | Slither ran natively in a venv (no WSL); 0 findings after triage |
| M7 | Demo script, optional Sepolia deploy, README/DESIGN polish, `docs/M8_HANDOFF.md` | **done** | demo verified on Anvil (22 txs) and in simulation; Sepolia script dry-run against live feeds |
| M8 | C++ reference model + differential tests | **done** | independent C++17 model written from `docs/DESIGN.md` only; 0 mismatches in 25,000 fuzz comparisons + 1,139 vectors; `docs/DIFFERENTIAL_REPORT.md` |
| M9 | Risk simulator (historical replay + bootstrap) | **done** | C++17 `simulator/` linking the reference model; real Chainlink history; independent Python cross-check; `docs/RISK_SIMULATION.md` |

## 3. What exists today

- `src/oracle/ChainlinkOracle.sol`: one instance per asset, 18-decimal USD price, fails closed
  (zero/negative, incomplete round, future timestamp, stale round, stale heartbeat, overflow,
  broken feed).
- `src/libraries/`: `Units`, `InterestRateModel`, `SharesMath`, `BorrowMath`, `RiskMath`: all
  pure, all spec'd in `docs/DESIGN.md`.
- `src/LendingMarket.sol`: supply/withdraw/redeem (shares), collateral deposit/withdraw,
  borrow/repay (global index, scaled debt), liquidation with close factor + bonus, bad-debt
  write-off socialized to suppliers. Immutable parameters, no admin.
- Tests: unit, fuzz, scenario, **invariant** (13 properties, handler with 5 actors), **fork**
  (real Chainlink feeds, WETH, USDC), **security** (hostile-token reentrancy, read-only
  reentrancy).
- Static analysis and review docs: `docs/THREAT_MODEL.md`, `docs/SLITHER_TRIAGE.md`,
  `docs/ROUNDING_REVIEW.md`, `docs/GAS_AND_COVERAGE.md`.
- Measured (details in `docs/GAS_AND_COVERAGE.md`): 277 tests pass without an RPC (2 skipped: the fork
  and differential suites), 284 with one; 100% line/statement/branch/function coverage of `src/`;
  Slither 0 findings after documented triage (41 raw).
- Demo: `script/Demo.s.sol` (Anvil + simulation, guarded by `test/script/Demo.t.sol`); optional
  `script/DeploySepolia.s.sol` (live Sepolia feeds, mock tokens, throwaway key, refuses other chains).
- M7 refactor: accrual / repay / liquidation / bad-debt kernels moved into the pure `MarketMath`;
  `docs/DESIGN.md` section 9 is the full function catalogue (with evaluation rules R1-R7);
  `test/differential/vectors.txt` holds ~1,100 spec vectors from an independent implementation,
  verified against the Solidity; `test/differential/Differential.t.sol` is the ffi side (skips
  without ffi or the binary).
- Mutation checks by hand: 18/18 distinct bugs in the market caught by the tests; 11/11 by the
  invariant suite alone; 8/8 `nonReentrant` guards verified by the reentrancy tests.
- CI (GitHub Actions): fmt check, build, test, the C++ reference model (GCC + MSVC) and the differential run, and the risk simulator (build, unit tests, smoke run). Fork tests skip (no secret configured).

## 4. Pending work

### M8: C++ reference model (done)
- Delivered: `reference-model/` (CMake, C++17, hand-written exact 256-bit math with a 512-bit
  `mulDiv`, no third-party dependency), C++ unit + CLI + vector tests, CI building the model before
  `forge test`, `docs/DIFFERENTIAL_REPORT.md`, README "Reference model".
- Result: 0 mismatches (details and the evidence in `docs/DIFFERENTIAL_REPORT.md`). CI is green
  on `main`: model built with GCC and MSVC, 11/11 C++ tests, differential suite 29/29.
- Pending / deferred from M8:
  - The fuzz distribution almost never produces VALID `validateRiskParams` inputs (about 1%); that
    success path is covered by the 30 successful vectors, not by the fuzzer.
  - Optional: swap the hand-written test harness for Catch2 and/or the big-integer type for
    Boost.Multiprecision (needs the owner's OK to download; not needed for correctness).
### M9: risk simulator (done)
- Delivered: `simulator/` (engine on the reference model's exact math, historical-window and block-bootstrap
  path sources, JSON configs with the contracts' parameter names, Markdown/CSV reports, 61 unit tests),
  `simulator/tools/fetch_chainlink_history.py` (read-only on-chain download; honours `MAINNET_RPC_URL`, never
  prints it), `simulator/tools/crosscheck.py` (second implementation from DESIGN section 9), the committed price
  data with SHA-256, four experiments and their results, `docs/RISK_SIMULATION.md`, a `simulator` job in CI.
- Findings are in `docs/RISK_SIMULATION.md`; threat-model rows T12 and T22 now cite them.
- Deferred / not verified:
  - The CI job builds the simulator with GCC (Linux) and MSVC (Windows); only MSVC has been run so far. The bootstrap
    uses `log`/`exp`, so its exact numbers may differ in rare paths on another compiler.
  - Not simulated: late bad-debt recognition and the supplier bank-run dynamic (T32; needs a multi-account market
    model), stale-oracle liquidation blocks, a multi-position market with utilization feedback.
  - The ETH/USD history is used from 2020-10-06; the earlier rounds of the proxy are not market data.

### Smaller follow-ups (not blocking)
- Add Slither to CI once a Linux runner setup is confirmed (currently documented, run manually).
- gitleaks is configured (`.gitleaks.toml`) but not installed locally nor run in CI.
- Optionally add `MAINNET_RPC_URL` as a CI secret to run the fork suite in CI.
- Hardening ideas listed in `docs/THREAT_MODEL.md` §3 (circuit breaker, insurance fund) are
  intentionally out of scope for v1.

## 5. Key design decisions so far (details in `docs/DESIGN.md`)

1. All protocol math lives in pure libraries so it can be differential-tested.
2. Debt = `ceil(scaled * index / RAY)`; total borrows are DERIVED from `totalScaledDebt`.
3. Suppliers earn exactly the increase in derived total debt; rate rounding cannot cause a deficit.
4. Virtual shares (`1e6` shares, `1` asset) defeat the first-depositor inflation attack.
5. Idle liquidity is an accounting number (not `balanceOf`): donations change nothing.
6. Withdrawals of collateral are limited by max LTV (not the liquidation threshold).
7. Bad debt: written off and socialized to suppliers (no admin, no insurance fund in v1).
8. A liquidation that burns no scaled debt is allowed only if it seizes all collateral.
9. An unusable oracle freezes borrow / liquidate / debt-bearing collateral withdrawal only;
   deposits, repayments and supplier exits keep working.
10. Static-analysis suppressions are inline, scoped and justified (`docs/SLITHER_TRIAGE.md`).

## 6. Open decisions / things only the owner can do

- Confirm the copyright holder name in `LICENSE` ("Franco Caccia" is a guess).
- Decide: repo visibility (private for now), repo name, public Sepolia deploy (burner key only).
- Decide whether to add a free public mainnet RPC as a CI secret for the fork suite (the tests
  skip without it; a public keyless endpoint was used for local verification only).

## 7. Rules that always apply

Zero cost; no secrets in the repo; no code copied from other protocols; every address verified
from official sources; no invented metrics; commits in English, small, authored with the
GitHub noreply address; C/C++ only in the off-chain model; the protocol must build and test
with no C++ toolchain installed.
