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
| M7 | Demo script, optional Sepolia deploy, README/DESIGN polish, `docs/M8_HANDOFF.md` | **next** | |
| M8 | C++ reference model + differential tests | pending, **needs your approval after M7** | must run in a FRESH session that only sees `docs/DESIGN.md` and `reference-model/` |
| M9 | Monte Carlo risk simulator | stretch, only if asked | |

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
- Measured (details in `docs/GAS_AND_COVERAGE.md`): 275 tests pass without an RPC (1 skipped:
  the fork suite), 282 with one; 100% line/statement/branch/function coverage of `src/`;
  Slither 0 findings after documented triage (41 raw).
- Mutation checks by hand: 18/18 distinct bugs in the market caught by the tests; 11/11 by the
  invariant suite alone; 8/8 `nonReentrant` guards verified by the reentrancy tests.
- CI (GitHub Actions): fmt check, build, test. Fork tests skip (no secret configured).

## 4. Pending work

### M7: Demo and polish
- `forge script` demo (supply, borrow, price crash via mock oracle, liquidation) with readable
  output on a local Anvil; optional Sepolia deploy script (burner key only).
- README complete: architecture diagram (incl. the Solidity/C++ split), run instructions
  with/without C++, design decisions, limitations, "reference model" section placeholder.
- DESIGN.md final (complete before M8; section 9 lists the pure-function catalogue).
- **`docs/M8_HANDOFF.md`**: exact CLI function names, argument order, output encoding, and the
  steps for you to start the clean M8 session.

### M8: C++ reference model (after your approval)
- Fresh session. Reads only `docs/DESIGN.md` (+ `docs/M8_HANDOFF.md`) and `reference-model/`.
  CMake, Boost.Multiprecision, Catch2/GoogleTest. Needs WSL (or a Windows C++ toolchain).
- Differential fuzz tests via `vm.ffi` under `FOUNDRY_PROFILE=diff`; CI builds and tests the C++
  before `forge test`.

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

- Install WSL (`wsl --install -d Ubuntu`, admin PowerShell, reboot): needed for M8 (C++ toolchain).
- Confirm the copyright holder name in `LICENSE` ("Franco Caccia" is a guess).
- Decide: repo visibility (private for now), repo name, public Sepolia deploy (burner key only).
- Decide whether to add a free public mainnet RPC as a CI secret for the fork suite (the tests
  skip without it; a public keyless endpoint was used for local verification only).
- Write the README section "What I learned".

## 7. Rules that always apply

Zero cost; no secrets in the repo; no code copied from other protocols; every address verified
from official sources; no invented metrics; commits in English, small, authored with the
GitHub noreply address; C/C++ only in the off-chain model; the protocol must build and test
with no C++ toolchain installed.
