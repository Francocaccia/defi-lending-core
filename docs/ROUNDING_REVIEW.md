# Rounding review

Policy (DESIGN §0.3): round **against the user, in favour of the protocol's solvency**. Debt up,
withdrawable amounts down. This file walks every place where an integer division or a choice of
rounding happens, states the direction, who benefits, the maximum error, and which test pins it.
"MD" = `mulDiv` (floor), "MDU" = `mulDivUp` (ceil).

Review method: read every function in `src/` for `/`, `mulDiv` and casts; for each, ask "if this
were rounded the other way, who could extract value, and would a test notice?". The second half
was done mechanically: each direction was flipped by hand (mutation) and the suite had to fail.

## 1. Table

| # | Where | Formula | Dir. | Benefits | Max error | Pinned by |
|---|---|---|---|---|---|---|
| 1 | `InterestRateModel.utilization` | MD(borrows·1e18, supply) | floor | neutral (input only) | 1e-18 | `test_utilization_floors`, `testFuzz_utilization_matchesFloorDivision` |
| 2 | `annualBorrowRate` (both segments) | base + MD(slope·u, K) | floor | neutral | 1 wei of WAD | `testFuzz_rate_matchesSegmentFormula`, monotonic fuzz |
| 3 | `borrowRatePerSecond` | annual·1e9 / SPY | floor | borrowers (tiny) | ≤ 1 RAY-unit/s ≈ 3e-20 per year | `testFuzz_perSecond_reconstructsAnnualRate` |
| 4 | `BorrowMath.accrueIndex` | index + MDU(index·r·dt, RAY) | **ceil** | protocol | +1 index unit (1e-27) per accrual | `testFuzz_accrueIndex_*`, mutation (accrual not credited) |
| 5 | `debtFromScaled` (user and total) | MDU(scaled·index, RAY) | **ceil** | protocol | +1 wei per user | `testFuzz_sumOfUserDebtsMatchesTotalWithinNMinusOne`, invariant (b) |
| 6 | `scaledFromAssetsUp` (borrow) | MDU(assets·RAY, index) | **ceil** | protocol | borrower owes ≤ +1 wei more | `testFuzz_borrowDebtIsAtLeastBorrowed`, mutation (borrow rounds down) caught |
| 7 | `scaledFromAssetsDown` (partial repay, liquidation burn) | MD(assets·RAY, index) | floor | protocol | debt falls ≤ `repaid`, ≤ 2 wei less | `testFuzz_partialRepayNeverOverCredits`, `testFuzz_partialRepaymentsNeverCheaperThanFullRepayment`, mutation (repay rounds up) caught |
| 8 | interest credited to suppliers | ceil(S·newIdx/RAY) − ceil(S·oldIdx/RAY) | derived | neutral | ±1 wei vs "exact" | invariant (a); identity in DESIGN §5.5 |
| 9 | `SharesMath.toSharesDown` (supply) | MD(a·(S+VS), A+VA) | floor | existing suppliers | < 1 share (≈ 1e-6 asset units) | `testFuzz_depositNeverDilutesExistingHolders`, mutation (supply rounds up) caught |
| 10 | `toSharesUp` (withdraw by assets) | MDU | **ceil** | remaining suppliers | ≤ 1 share | `testFuzz_withdrawBurnsEnoughShares`, mutation (withdraw rounds down) caught by unit AND invariant (d) |
| 11 | `toAssetsDown` (redeem, balance view) | MD | floor | remaining suppliers | ≤ 1 wei | `testFuzz_depositRedeemRoundTripNeverProfits`, mutation (redeem rounds up) caught |
| 12 | `toAssetsUp` | MDU | ceil | (unused on-chain; spec/tests only) | 1 wei | `testFuzz_upIsDownOrDownPlusOne` |
| 13 | `collateralValueUsd` | MD(amount·price, 10^dec) | floor | protocol | < 1 wei-USD | `testFuzz_valuationRoundingDirection` |
| 14 | `debtValueUsd` | MDU | **ceil** | protocol | < 1 wei-USD | same |
| 15 | `healthFactor` | MD(coll·LT, debt) | floor | n/a: the *decision* is exact | HF < 1 ⇔ c·LT < d·1e18 | `testFuzz_isLiquidatable_matchesCrossMultiplication` |
| 16 | `maxDebtValue` (LTV limit) | MD(coll·ltv, 1e18) | floor | protocol | < 1 wei-USD | `testFuzz_isWithinMaxLtv_matchesCrossMultiplication`, `testFuzz_borrowLimitIsExact` |
| 17 | `maxRepayable` (close factor) | MDU(debt·cf, 1e18) | **ceil** | liquidator (≤ 1 wei) | ≤ 1 wei above the exact 50% | `test_maxRepayable`, `testFuzz_maxRepayable_bounds` |
| 18 | `seizeForRepay` | MD(r·(1+b)·pb·10^dc, pc·10^db·1e18) | floor | borrower / protocol | < 1 collateral wei | `testFuzz_seize_neverExceedsBonusValue` |
| 19 | `repayForSeize` (collateral cap) | MDU | **ceil** | protocol | ≤ 1 unit | `testFuzz_seizeAndRepayAreConsistent` |
| 20 | bad-debt `loss` | derived-total drop | derived | exact identity | 0 | `test_badDebt_*`, invariants (a),(d) |

## 2. Conclusions

1. **No direction is accidental.** Everything that touches a user's balance rounds against the
   user (rows 5–7, 9–11, 13, 14, 16, 18, 19), and the tests fail if any of them is flipped
   (mutations listed above).
2. **Two deliberate deviations from "always against the user"**, both immaterial and documented:
   - Row 17: the close factor is rounded **up**. Rounding down would make a 1-wei debt impossible
     to liquidate (50% of 1 floors to 0). Cost: ≤ 1 wei more can be repaid in one liquidation.
   - Row 3: the per-second rate is floored, so over a year borrowers can pay up to ~3e-20 of
     principal less than the nominal rate (the ceil in row 4 adds at most 1e-27 per accrual, which
     does NOT offset that over long intervals). It is immaterial, and it cannot create a deficit:
     suppliers are credited exactly the increase in derived total debt (row 8), so what borrowers
     owe and what suppliers are credited always move together.
3. **Accumulated dust is bounded and sits in the protocol's favour**: per-user debt vs total
   differs by at most N−1 wei (invariant (b)); a full lifecycle leaves ≤ 3 wei in the contract
   (`test_scenario_fullLifecycleEveryoneExitsSolvent`).
4. **Calling `accrueInterest()` repeatedly cannot be used to inflate debts**: each call adds at
   most 1e-27 relative (row 4); even one call per second for a year is ≈ 3e-20 relative, and the
   interest goes to suppliers.
5. **Share-price monotonicity** (spec invariant (d)) is checked per action by fuzzing and across
   random sequences by the invariant suite; it can only fall via recorded bad debt.
6. **No change to the contracts resulted from this review**; it confirmed the existing choices.
