# PLAN

Living plan for `defi-lending-core`. Updated at the end of every milestone. Numbers here come
from real command output; the date and commit they were measured at are stated next to them.

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
| M4 | Risk (HF, guards, liquidation, bad-debt recording) | **done** | found + fixed a liquidity hole (zero-burn liquidation) |
| M5 | Invariant tests + mainnet fork tests | in progress | |
| M6 | Security pass (Slither, threat model, rounding review, gas, coverage) | pending | needs Slither; WSL not installed, trying native venv |
| M7 | Demo script, optional Sepolia deploy, README/DESIGN polish, `docs/M8_HANDOFF.md` | pending | |
| M8 | C++ reference model + differential tests | pending, **needs your approval after M7** | must run in a FRESH session that only sees `docs/DESIGN.md` and `reference-model/` |
| M9 | Monte Carlo risk simulator | stretch, only if asked | |

## 3. What exists today (as of the M4 commit `e6bba55`)

- `src/oracle/ChainlinkOracle.sol`: one instance per asset, 18-decimal USD price, fails closed
  (zero/negative, incomplete round, future timestamp, stale round, stale heartbeat, overflow,
  broken feed).
- `src/libraries/`: `Units`, `InterestRateModel`, `SharesMath`, `BorrowMath`, `RiskMath`: all
  pure, all spec'd in `docs/DESIGN.md`.
- `src/LendingMarket.sol`: supply/withdraw/redeem (shares), collateral deposit/withdraw,
  borrow/repay (global index, scaled debt), liquidation with close factor + bonus, bad-debt
  write-off socialized to suppliers. Immutable parameters, no admin.
- Tests: unit, fuzz, scenario (oracle failures, cascade, bank run, lifecycle). Mutation check
  by hand: 20/20 injected bugs in the market killed.
- Measured at `e6bba55`: 263 tests pass (default and CI profile), 100% line/statement/branch/
  function coverage of `src/`.
- CI (GitHub Actions): fmt check, build, test. Green.

## 4. Pending work

### M5: Invariants and fork tests
- Invariant tests with a handler (actors: suppliers, borrowers, liquidator; actions: supply,
  withdraw, redeem, deposit/withdraw collateral, borrow, repay, liquidate, price moves, time
  warps, interest accrual):
  - (a) solvency: `totalSupplyAssets <= cash + totalBorrowAssets`, with bad debt accounted;
  - (b) `sum(user debts)` vs derived total within N-1 wei;
  - (c) every successful collateral withdrawal leaves the position within max LTV (ghost check);
  - (d) share price never decreases except through recorded bad debt;
  - plus supporting: token conservation (collateral held == `totalCollateral`), `sum(shares)
    == totalSupplyShares`, `sum(scaled) == totalScaledDebt`, `borrowIndex` monotone.
- Fork tests against mainnet with the REAL Chainlink ETH/USD and USDC/USD feeds and real
  WETH/USDC; skipped automatically when `MAINNET_RPC_URL` is not set.

### M6: Security pass
- Slither: run, triage every finding (fix or justify) in `docs/`.
- `docs/THREAT_MODEL.md`: oracle manipulation/staleness, liquidation cascades, bad debt,
  rounding/donation attacks, reentrancy (incl. a hostile-token test), unsupported tokens, and
  what is NOT mitigated.
- Rounding review of every conversion; gas snapshot; coverage report with explanations.

### M7: Demo and polish
- `forge script` demo (supply, borrow, price crash via mock oracle, liquidation) with readable
  output; optional Sepolia deploy script (burner key only).
- README complete (architecture diagram, run instructions with/without C++, limitations).
- DESIGN.md final. **`docs/M8_HANDOFF.md`**: exact CLI function names, argument order, output
  encoding, and the steps to start the clean M8 session.

### M8: C++ reference model (after approval)
- Fresh session. Reads only `docs/DESIGN.md` (+ `docs/M8_HANDOFF.md`) and `reference-model/`.
  CMake, Boost.Multiprecision, Catch2/GoogleTest. Needs WSL (or a Windows C++ toolchain).
- Differential fuzz tests via `vm.ffi` under `FOUNDRY_PROFILE=diff`; CI builds and tests the C++
  before `forge test`.

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

## 6. Open decisions / things only the owner can do

- Install WSL (`wsl --install -d Ubuntu`, admin PowerShell, reboot): needed for M8, and a
  cleaner Slither setup in M6.
- Confirm the copyright holder name in `LICENSE` ("Franco Caccia" is a guess).
- Decide: repo visibility (private for now), repo name, public Sepolia deploy (burner key only).
- Choose a free public RPC for fork tests (a throwaway one is used for local checks only; the
  URL lives in `.env`, never in the repo) and decide whether to add it as a CI secret.
- Write the README section "What I learned".

## 7. Rules that always apply

Zero cost; no secrets in the repo; no code copied from other protocols; every address verified
from official sources; no invented metrics; commits in English, small, authored with the
GitHub noreply address; C/C++ only in the off-chain model; the protocol must build and test
with no C++ toolchain installed.
