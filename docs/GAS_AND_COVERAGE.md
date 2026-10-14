# Gas and coverage report

All numbers below were produced by the commands shown, on Foundry 1.8.5, solc 0.8.28
(optimizer on, 200 runs), `evm_version = cancun`, at the M7 commit that introduced this version of
the file (after the `MarketMath` refactor).

## Test results

| Profile | Command | Result |
|---|---|---|
| default, no RPC (what CI sees) | `forge test` | 277 passed, 0 failed, 2 skipped (fork + differential suites) |
| ci (1000 fuzz runs, invariant depth 128) | `FOUNDRY_PROFILE=ci forge test` | 277 passed, 0 failed, 2 skipped; ~35 s |
| default, with a mainnet RPC | `MAINNET_RPC_URL=... forge test` | 284 passed, 0 failed, 1 skipped (differential) |

Notes: `forge` counts the whole invariant suite as one test (it contains 13 `invariant_*`
properties). The two skipped items are the `setUp` of the fork contract (skips all 7 fork tests
when no RPC is configured) and of the differential contract (skips its tests when `ffi` is off or
`reference-model/build/refmodel` is not built).

## Coverage of `src/`

`forge coverage --report summary --no-match-coverage "^(test|script|lib)/"`

| File | Lines | Statements | Branches | Functions |
|---|---|---|---|---|
| `LendingMarket.sol` | 100% (181/181) | 100% (224/224) | 100% (29/29) | 100% (25/25) |
| `libraries/BorrowMath.sol` | 100% (8/8) | 100% (9/9) | n/a | 100% (4/4) |
| `libraries/InterestRateModel.sol` | 100% (18/18) | 100% (30/30) | 100% (8/8) | 100% (4/4) |
| `libraries/MarketMath.sol` | 100% (26/26) | 100% (33/33) | 100% (8/8) | 100% (4/4) |
| `libraries/RiskMath.sol` | 100% (28/28) | 100% (40/40) | 100% (5/5) | 100% (10/10) |
| `libraries/SharesMath.sol` | 100% (8/8) | 100% (8/8) | n/a | 100% (4/4) |
| `oracle/ChainlinkOracle.sol` | 100% (28/28) | 100% (37/37) | 100% (11/11) | 100% (3/3) |
| **Total** | **100% (297/297)** | **100% (381/381)** | **100% (61/61)** | **100% (54/54)** |

There are **no uncovered lines or branches**. Two branches are *defensive* and only reachable
through contrived state, so they are exercised by dedicated tests that force that state: the
zero-shares guard in `supply` (`test_supply_revertsInsteadOfMintingZeroShares`, writes storage with
`stdstore`) and the saturating bad-debt write-off (`test_badDebt_totalLossSaturatesSupplyAtZero`).
One further guard is provably redundant (`forSeize < repaid` in `MarketMath.liquidationAmounts`:
the two formulas are exact inverses, so `forSeize <= repaid` always); it is kept as
defense-in-depth and documented as such in the code.

Coverage is a measure of lines executed, not of correctness; the mutation checks in
`docs/THREAT_MODEL.md` section 4 are the better signal.

## Contract size

From `forge build --sizes`: `LendingMarket` runtime **9,386 B** (initcode 11,423 B; limits 24,576 /
49,152), `ChainlinkOracle` runtime 1,143 B (initcode 1,969 B).

## Gas

Command: `forge test --gas-report --no-match-test "testFuzz|invariant|test_diff|test_plumbing|test_vectors"`
(unit and scenario tests only; fuzz, invariant and differential runs would skew the statistics).
The raw per-test snapshot is committed as `.gas-snapshot`
(`forge snapshot --no-match-test "testFuzz|invariant"`).

| Function | Min | Avg | Median | Max | # calls |
|---|---|---|---|---|---|
| `supply` | 26,701 | 127,354 | 133,488 | 136,777 | 117 |
| `withdraw` | 26,657 | 50,613 | 41,525 | 68,349 | 9 |
| `redeem` | 26,732 | 56,089 | 68,081 | 68,081 | 9 |
| `depositCollateral` | 26,676 | 102,845 | 108,071 | 111,360 | 100 |
| `withdrawCollateral` | 26,698 | 68,221 | 66,145 | 99,911 | 20 |
| `borrow` | 26,720 | 128,991 | 138,193 | 141,471 | 103 |
| `repay` | 27,218 | 61,855 | 63,555 | 80,104 | 17 |
| `liquidate` | 27,171 | 115,815 | 131,833 | 194,908 | 35 |
| `accrueInterest` | 23,530 | 36,566 | 44,018 | 44,018 | 9 |
| `ChainlinkOracle.price` | 2,595 | 14,435 | 15,095 | 15,095 | 355 |

How to read it honestly:
- **Min** values (~26k) are calls that revert early (zero amount, no allowance, ...); use the
  median/max for successful paths.
- The tests mostly act on **fresh storage** (first deposit, first borrow), so many calls pay the
  cold-slot write cost (~22k gas per new slot). A long-lived market's steady-state gas is lower.
  These are not mainnet estimates, only a relative comparison and a regression guard.
- `liquidate` is the most expensive path (two oracle reads, math, up to bad-debt write-off).
- Moving the accrual / repay / liquidation / bad-debt kernels into `MarketMath` (M7) did not
  change gas materially (the library functions are `internal` and inlined).
- No gas optimization was attempted: correctness and readability came first. Obvious candidates
  if it mattered: pack the per-user mappings, cache immutables in memory.

## Reproduce

```bash
forge test                                   # default profile
FOUNDRY_PROFILE=ci forge test                # heavier fuzz/invariant settings
forge coverage --report summary --no-match-coverage "^(test|script|lib)/"
forge snapshot --no-match-test "testFuzz|invariant"
forge test --gas-report --no-match-test "testFuzz|invariant|test_diff|test_plumbing|test_vectors"
forge build --sizes
MAINNET_RPC_URL=<free public RPC> forge test --match-path "test/fork/*"
FOUNDRY_PROFILE=diff forge test --match-path "test/differential/*"   # needs the C++ model (M8)
```
