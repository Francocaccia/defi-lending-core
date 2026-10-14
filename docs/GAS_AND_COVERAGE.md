# Gas and coverage report

All numbers below were produced by the commands shown, on Foundry 1.8.5, solc 0.8.28
(optimizer on, 200 runs), `evm_version = cancun`, at the commit that introduced this file.

## Test results

| Profile | Command | Result |
|---|---|---|
| default, no RPC (what CI sees) | `forge test` | 275 passed, 0 failed, 1 skipped (the fork suite) |
| ci (1000 fuzz runs, invariant depth 128) | `FOUNDRY_PROFILE=ci forge test` | 275 passed, 0 failed, 1 skipped; ~25 s |
| default, with a mainnet RPC | `MAINNET_RPC_URL=... forge test` | 282 passed, 0 failed, 0 skipped |

Notes: `forge` counts the whole invariant suite as one test (it contains 13 `invariant_*`
properties). The skipped item is the fork contract's `setUp`, which skips all 7 fork tests when
no RPC is configured.

## Coverage of `src/`

`forge coverage --report summary --no-match-coverage "^(test|script|lib)/"`

| File | Lines | Statements | Branches | Functions |
|---|---|---|---|---|
| `LendingMarket.sol` | 100% (200/200) | 100% (251/251) | 100% (38/38) | 100% (26/26) |
| `libraries/BorrowMath.sol` | 100% (8/8) | 100% (9/9) | n/a | 100% (4/4) |
| `libraries/InterestRateModel.sol` | 100% (18/18) | 100% (30/30) | 100% (8/8) | 100% (4/4) |
| `libraries/RiskMath.sol` | 100% (28/28) | 100% (40/40) | 100% (5/5) | 100% (10/10) |
| `libraries/SharesMath.sol` | 100% (8/8) | 100% (8/8) | n/a | 100% (4/4) |
| `oracle/ChainlinkOracle.sol` | 100% (28/28) | 100% (37/37) | 100% (11/11) | 100% (3/3) |
| **Total** | **100% (290/290)** | **100% (375/375)** | **100% (62/62)** | **100% (51/51)** |

There are **no uncovered lines or branches**. Two branches are *defensive* and only reachable
through contrived state, so they are exercised by dedicated tests that force that state:
the zero-shares guard in `supply` (`test_supply_revertsInsteadOfMintingZeroShares`, writes
storage with `stdstore`) and the saturating bad-debt write-off
(`test_badDebt_totalLossSaturatesSupplyAtZero`).

Coverage is a measure of lines executed, not of correctness; the mutation checks in
`docs/THREAT_MODEL.md` §4 are the better signal.

## Contract size

From `forge build --sizes`: `LendingMarket` runtime **9,272 B** (initcode 11,330 B; limits 24,576 /
49,152), `ChainlinkOracle` runtime 1,143 B (initcode 1,969 B).

## Gas

Command: `forge test --gas-report --no-match-test "testFuzz|invariant"` (unit and scenario tests
only; fuzz and invariant runs would skew the statistics). The raw per-test snapshot is committed
as `.gas-snapshot` (`forge snapshot --no-match-test "testFuzz|invariant"`).

| Function | Min | Avg | Median | Max | # calls |
|---|---|---|---|---|---|
| `supply` | 26,701 | 127,357 | 133,488 | 136,777 | 117 |
| `withdraw` | 26,657 | 50,613 | 41,525 | 68,349 | 9 |
| `redeem` | 26,732 | 56,089 | 68,081 | 68,081 | 9 |
| `depositCollateral` | 26,676 | 102,845 | 108,071 | 111,360 | 100 |
| `withdrawCollateral` | 26,698 | 68,241 | 66,209 | 99,911 | 20 |
| `borrow` | 26,720 | 129,002 | 138,193 | 141,471 | 103 |
| `repay` | 27,218 | 61,842 | 63,537 | 80,144 | 17 |
| `liquidate` | 27,171 | 115,236 | 130,932 | 194,005 | 35 |
| `accrueInterest` | 23,530 | 36,651 | 44,146 | 44,146 | 9 |
| `ChainlinkOracle.price` | 5,553 | 14,993 | 15,095 | 15,095 | 339 |

How to read it honestly:
- **Min** values (~26k) are calls that revert early (zero amount, no allowance, ...); use the
  median/max for successful paths.
- The tests mostly act on **fresh storage** (first deposit, first borrow), so many calls pay the
  cold-slot write cost (~22k gas per new slot). A long-lived market's steady-state gas is lower.
  These are not mainnet estimates, only a relative comparison and a regression guard.
- `liquidate` is the most expensive path (two oracle reads, math, up to bad-debt write-off).
- No gas optimization was attempted: correctness and readability came first. Obvious candidates
  if it mattered: pack the per-user mappings, cache immutables in memory.

## Reproduce

```bash
forge test                                   # default profile
FOUNDRY_PROFILE=ci forge test                # heavier fuzz/invariant settings
forge coverage --report summary --no-match-coverage "^(test|script|lib)/"
forge snapshot --no-match-test "testFuzz|invariant"
forge test --gas-report --no-match-test "testFuzz|invariant"
MAINNET_RPC_URL=<free public RPC> forge test --match-path "test/fork/*"
```
