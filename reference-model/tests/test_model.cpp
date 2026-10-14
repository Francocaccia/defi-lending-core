// Hand-computed cases from docs/DESIGN.md (worked examples) and edge cases of the evaluation
// rules R1-R7 (DESIGN 9.1). The ~1,100 shared vectors are exercised separately (test_vectors).
#include "model.hpp"
#include "testlib.hpp"

using namespace refmodel;

namespace {
U256 U(const char* s) {
  const ParseResult p = parseU256(s);
  if (!p.value) throw std::runtime_error(std::string("bad literal in test: ") + s);
  return *p.value;
}
const U256 MAXV = U256::max();
// Rate parameters of DESIGN 3.5
const U256 S1 = U("40000000000000000");    // 0.04e18
const U256 S2 = U("750000000000000000");   // 0.75e18
const U256 K = U("800000000000000000");    // 0.8e18
}  // namespace

// ------------------------------------------------------------------ 3 interest rate model

TEST(design_3_5_rate_table_base_zero) {
  struct Row { const char* u; const char* annual; const char* perSecond; };
  const Row rows[] = {
      {"0", "0", "0"},
      {"400000000000000000", "20000000000000000", "634195839675291730"},
      {"800000000000000000", "40000000000000000", "1268391679350583460"},
      {"900000000000000000", "415000000000000000", "13159563673262303399"},
      {"1000000000000000000", "790000000000000000", "25050735667174023338"},
  };
  for (const Row& r : rows) {
    CHECK_EQ(annualBorrowRate(0, S1, S2, K, U(r.u)), U(r.annual));
    CHECK_EQ(borrowRatePerSecond(0, S1, S2, K, U(r.u)), U(r.perSecond));
  }
}

TEST(design_3_5_rate_table_base_one_percent) {
  const U256 base = U("10000000000000000");
  const char* us[] = {"0", "400000000000000000", "800000000000000000", "900000000000000000",
                      "1000000000000000000"};
  const char* want[] = {"10000000000000000", "30000000000000000", "50000000000000000",
                        "425000000000000000", "800000000000000000"};
  for (int i = 0; i < 5; ++i) CHECK_EQ(annualBorrowRate(base, S1, S2, K, U(us[i])), U(want[i]));
}

TEST(design_3_5_floor_and_utilization) {
  CHECK_EQ(annualBorrowRate(0, 10, 0, K, U("100000000000000000")), U256(1));  // 1.25 -> 1
  CHECK_EQ(utilization(3, 1), U("333333333333333333"));
  CHECK_EQ(utilization(3, 2), U("666666666666666666"));
}

TEST(utilization_edges) {
  CHECK_EQ(utilization(0, 0), U256(0));
  CHECK_EQ(utilization(0, MAXV), U256(0));  // supply == 0 wins over borrows >= supply
  CHECK_EQ(utilization(1, 1), WAD);         // borrows >= supply is capped
  CHECK_EQ(utilization(5, 100), WAD);
  CHECK_EQ(utilization(MAXV, MAXV), WAD);
  CHECK_EQ(utilization(MAXV, 0), U256(0));
  CHECK_EQ(utilization(MAXV, MAXV - U256(1)), U("999999999999999999"));  // 512-bit product
  CHECK_EQ(utilization(MAXV, U256(1)), U256(0));
}

TEST(annualBorrowRate_failures_and_edges) {
  CHECK_THROWS(annualBorrowRate(0, 0, 0, K, WAD + U256(1)));  // u > WAD
  CHECK_THROWS(annualBorrowRate(0, 0, 0, 0, 0));              // K = 0: mulDiv by zero even at u = 0
  CHECK_EQ(annualBorrowRate(7, 0, 0, K, 0), U256(7));
  // optimal > WAD with u <= WAD: the u <= optimal branch is taken, WAD - optimal never evaluated
  CHECK_EQ(annualBorrowRate(0, 100, 0, WAD + U256(1), WAD), U256(99));  // floor(100*WAD/(WAD+1))
  CHECK_EQ(annualBorrowRate(0, 100, 0, WAD, WAD), U256(100));
  // u > optimal and optimal < WAD: the steep branch; u == WAD
  CHECK_EQ(annualBorrowRate(1, 2, 3, K, WAD), U256(1 + 2 + 3));
  // R4 lazy branches: the steep branch is not evaluated when u <= K
  CHECK_EQ(annualBorrowRate(MAXV, MAXV, 0, K, 0), MAXV);          // base + 0 (slope1 * 0 / K)
  CHECK_THROWS(annualBorrowRate(MAXV, 1, 0, K, K));               // base + mulDiv(1,K,K) overflows
  CHECK_THROWS(annualBorrowRate(MAXV, 1, 0, K, K + U256(1)));     // R1: base + slope1 evaluated
  CHECK_EQ(annualBorrowRate(0, 0, MAXV, K, WAD), MAXV);           // mulDiv(MAX, WAD-K, WAD-K)
  CHECK_THROWS(annualBorrowRate(1, 0, MAXV, K, WAD));             // ... + base overflows
}

TEST(borrowRatePerSecond_edges) {
  CHECK_EQ(borrowRatePerSecond(0, 0, 0, K, 0), U256(0));
  // annual * 1e9 overflows: base so large that *WAD_TO_RAY exceeds 2^256
  CHECK_THROWS(borrowRatePerSecond(MAXV, 0, 0, K, 0));
  // floor division: 1 * 1e9 / 31_536_000 = 31
  CHECK_EQ(borrowRatePerSecond(1, 0, 0, K, 0), U256(31));
  // largest annual rate whose *1e9 still fits: floor(max / 1e9)
  const U256 big = MAXV / WAD_TO_RAY;
  CHECK_NOTHROW(borrowRatePerSecond(big, 0, 0, K, 0));
  CHECK_THROWS(borrowRatePerSecond(big + U256(1), 0, 0, K, 0));
}

TEST(validateRateParams_boundaries) {
  CHECK_EQ(validateRateParams(0, S1, S2, K), U256(1));
  CHECK_EQ(validateRateParams(MAX_ANNUAL_RATE, MAX_ANNUAL_RATE, MAX_ANNUAL_RATE, WAD - U256(1)),
           U256(1));
  CHECK_EQ(validateRateParams(0, 0, 0, U256(1)), U256(1));
  CHECK_THROWS(validateRateParams(0, 0, 0, 0));
  CHECK_THROWS(validateRateParams(0, 0, 0, WAD));
  CHECK_THROWS(validateRateParams(0, 0, 0, WAD + U256(1)));
  CHECK_THROWS(validateRateParams(MAX_ANNUAL_RATE + U256(1), 0, 0, K));
  CHECK_THROWS(validateRateParams(0, MAX_ANNUAL_RATE + U256(1), 0, K));
  CHECK_THROWS(validateRateParams(0, 0, MAX_ANNUAL_RATE + U256(1), K));
  CHECK_THROWS(validateRateParams(MAXV, MAXV, MAXV, MAXV));
}

// ------------------------------------------------------------------ 4 supplier shares

TEST(design_4_share_examples) {
  CHECK_EQ(toSharesDown(U("1000000000"), 0, 0), U("1000000000000000"));  // 1000e6 -> 1e15
  const U256 a = U("100000000"), A = U("1050000000"), S = U("1000000000000000");
  CHECK_EQ(toSharesDown(a, A, S), U("95238095242630"));
  CHECK_EQ(toSharesUp(a, A, S), U("95238095242631"));
  const U256 s = U("100000000000000");
  CHECK_EQ(toAssetsDown(s, A, S), U("104999999"));
  CHECK_EQ(toAssetsUp(s, A, S), U("105000000"));
}

TEST(shares_virtual_additions_are_checked) {
  CHECK_THROWS(toSharesDown(0, 0, MAXV));      // totalShares + 1e6 overflows (R1, eager)
  CHECK_THROWS(toSharesDown(0, MAXV, 0));      // totalAssets + 1 overflows
  CHECK_THROWS(toAssetsUp(0, MAXV, 0));
  CHECK_NOTHROW(toSharesDown(0, MAXV - U256(1), MAXV - VIRTUAL_SHARES));
  CHECK_THROWS(toSharesDown(0, MAXV - U256(1), MAXV - VIRTUAL_SHARES + U256(1)));
  CHECK_EQ(toSharesDown(0, 0, 0), U256(0));
  CHECK_EQ(toSharesUp(0, 0, 0), U256(0));
  CHECK_EQ(toSharesUp(1, 0, 0), U256(1000000));
}

// ------------------------------------------------------------------ 5 borrow index

TEST(design_5_2_accrual_examples) {
  const U256 supply = U("100000000000"), debt = U("50000000000");
  const AccrueResult year = accrue(debt, supply, RAY, U256(31536000), 0, S1, S2, K);
  CHECK_EQ(year.newIndex, U("1024999999999999999980832000"));
  CHECK_EQ(year.interest, U("1250000000"));

  // Two accruals of 100 days from the same start.
  const U256 hundredDays = U256(100ULL * 86400ULL);
  const AccrueResult first = accrue(debt, supply, RAY, hundredDays, 0, S1, S2, K);
  const AccrueResult second =
      accrue(debt, supply + first.interest, first.newIndex, hundredDays, 0, S1, S2, K);
  CHECK_EQ(second.newIndex, U("1013769079868900432720487744"));
  CHECK_EQ(debtFromScaled(debt, second.newIndex), U("50688453994"));
  CHECK_EQ(supply + first.interest + second.interest, U("100688453994"));
}

TEST(accrue_edges) {
  // no debt, no time: nothing happens
  const AccrueResult z = accrue(0, 0, RAY, 0, 0, S1, S2, K);
  CHECK_EQ(z.newIndex, RAY);
  CHECK_EQ(z.interest, U256(0));
  // invalid rate params are NOT validated (R7): K = 0 and u = 0 -> divide by zero
  CHECK_THROWS(accrue(0, 0, RAY, 0, 0, S1, S2, 0));
  // elapsed so large that rate * elapsed overflows
  CHECK_THROWS(accrue(1, 2, RAY, MAXV, 0, S1, S2, K));
  // rate 0 and huge elapsed: rate * elapsed = 0, fine
  CHECK_EQ(accrue(0, 0, RAY, MAXV, 0, 0, 0, K).newIndex, RAY);
}

TEST(index_functions_edges) {
  CHECK_EQ(accrueIndex(RAY, 0, MAXV), RAY);
  CHECK_EQ(accrueIndex(0, MAXV, 0), U256(0));
  CHECK_THROWS(accrueIndex(RAY, MAXV, U256(2)));                // rate * dt overflows
  CHECK_THROWS(accrueIndex(MAXV, RAY, U256(1)));                // index + growth overflows
  CHECK_THROWS(scaledFromAssetsUp(1, 0));                       // index == 0
  CHECK_THROWS(scaledFromAssetsDown(0, 0));
  CHECK_EQ(debtFromScaled(1, 1), U256(1));                      // ceil: 1 wei stays 1
  CHECK_EQ(debtFromScaled(0, 0), U256(0));
  CHECK_EQ(debtFromScaled(RAY, RAY), RAY);                      // exact: no round-up
  CHECK_EQ(debtFromScaled(RAY, RAY + U256(1)), RAY + U256(1));
  CHECK_EQ(scaledFromAssetsUp(3, RAY * U256(2)), U256(2));      // 1.5 -> 2
  CHECK_EQ(scaledFromAssetsDown(3, RAY * U256(2)), U256(1));    // 1.5 -> 1
  CHECK_EQ(scaledFromAssetsDown(MAXV, RAY), MAXV);
  CHECK_THROWS(scaledFromAssetsDown(MAXV, 1));                  // quotient overflows
  CHECK_EQ(debtFromScaled(MAXV, RAY), MAXV);
  CHECK_THROWS(debtFromScaled(MAXV, RAY + U256(1)));
}

TEST(repayAmounts_cases) {
  const U256 idx = RAY * U256(2);
  // debt of 10 scaled at index 2.0 = 20
  CHECK_EQ(repayAmounts(20, 10, idx).repaid, U256(20));
  CHECK_EQ(repayAmounts(20, 10, idx).burned, U256(10));
  CHECK_EQ(repayAmounts(MAXV, 10, idx).repaid, U256(20));  // "repay everything"
  CHECK_EQ(repayAmounts(MAXV, 10, idx).burned, U256(10));
  CHECK_EQ(repayAmounts(19, 10, idx).repaid, U256(19));
  CHECK_EQ(repayAmounts(19, 10, idx).burned, U256(9));     // floor(19/2)
  CHECK_EQ(repayAmounts(1, 10, idx).burned, U256(0));      // zero burn is NOT rejected here
  CHECK_EQ(repayAmounts(5, 0, 0).repaid, U256(0));         // index 0: debt 0, assets >= debt
  CHECK_EQ(repayAmounts(5, 7, 0).burned, U256(7));         // index 0: debt 0 -> whole scaled burned
}

// ------------------------------------------------------------------ 5/6 valuation and limits

TEST(valuation_rounding_and_decimals) {
  // 1 wei at $2000/ETH (18 decimals): collateral rounds down to 2000 wei-USD, debt up
  CHECK_EQ(collateralValueUsd(1, U("2000000000000000000000"), 18), U256(2000));
  CHECK_EQ(collateralValueUsd(1, 1, 18), U256(0));
  CHECK_EQ(debtValueUsd(1, 1, 18), U256(1));
  CHECK_EQ(debtValueUsd(0, 1, 18), U256(0));
  CHECK_EQ(collateralValueUsd(1000000, WAD, 6), WAD);  // 1 USDC at $1
  CHECK_EQ(collateralValueUsd(MAXV, WAD, 18), MAXV);
  CHECK_EQ(debtValueUsd(MAXV, WAD, 18), MAXV);
  CHECK_THROWS(collateralValueUsd(MAXV, WAD + U256(1), 18));
  CHECK_THROWS(debtValueUsd(MAXV, WAD + U256(1), 18));
}

TEST(valuation_decimals_76_77_78_255) {
  CHECK_EQ(collateralValueUsd(0, 0, 76), U256(0));
  CHECK_EQ(collateralValueUsd(0, 0, 77), U256(0));
  CHECK_EQ(debtValueUsd(1, 1, 77), U256(1));  // ceil(1 / 1e77)
  CHECK_EQ(collateralValueUsd(pow10(77), WAD, 77), WAD);
  // R3 + R4: 10**78 fails even though amount == 0 would make the result 0
  CHECK_THROWS(collateralValueUsd(0, 0, 78));
  CHECK_THROWS(debtValueUsd(0, 0, 78));
  CHECK_THROWS(collateralValueUsd(1, 1, 255));
  CHECK_THROWS(debtValueUsd(1, 1, 255));
}

TEST(healthFactor_cases) {
  CHECK_EQ(healthFactor(0, 0, 0), MAXV);
  CHECK_EQ(healthFactor(MAXV, 0, MAXV), MAXV);  // debt == 0 short-circuits (lazy branch)
  CHECK_EQ(healthFactor(0, 1, WAD), U256(0));
  CHECK_EQ(healthFactor(U("20000000000000000000000"), U("10000000000000000000000"),
                        U("800000000000000000")),
           U("1600000000000000000"));
  CHECK_THROWS(healthFactor(MAXV, 1, MAXV));  // quotient overflows
  CHECK_EQ(healthFactor(MAXV, MAXV, MAXV), MAXV);
  // exact liquidation boundary: c*LT == d*WAD -> hf == WAD (not liquidatable), one wei less -> < WAD
  CHECK_EQ(healthFactor(U("1250000000000000000"), U("1000000000000000000"), U("800000000000000000")),
           WAD);
  CHECK(healthFactor(U("1249999999999999999"), U("1000000000000000000"), U("800000000000000000")) <
        WAD);
}

TEST(maxDebtValue_and_isWithinMaxLtv) {
  CHECK_EQ(maxDebtValue(100, U("750000000000000000")), U256(75));
  CHECK_EQ(maxDebtValue(1, U("750000000000000000")), U256(0));
  CHECK_THROWS(maxDebtValue(MAXV, WAD + U256(1)));
  CHECK_EQ(maxDebtValue(MAXV, WAD), MAXV);
  const U256 ltv = U("750000000000000000");
  CHECK_EQ(isWithinMaxLtv(100, 75, ltv), U256(1));  // equality is within
  CHECK_EQ(isWithinMaxLtv(100, 76, ltv), U256(0));
  CHECK_EQ(isWithinMaxLtv(0, 0, ltv), U256(1));
  CHECK_EQ(isWithinMaxLtv(0, 1, ltv), U256(0));
  CHECK_EQ(isWithinMaxLtv(1, 1, ltv), U256(0));     // maxDebt = floor(0.75) = 0
  CHECK_THROWS(isWithinMaxLtv(MAXV, 0, WAD + U256(1)));
  CHECK_EQ(isWithinMaxLtv(0, MAXV, ltv), U256(0));
}

TEST(maxRepayable_ceil) {
  const U256 half = U("500000000000000000");
  CHECK_EQ(maxRepayable(3, half), U256(2));
  CHECK_EQ(maxRepayable(1, half), U256(1));  // a 1-wei debt stays liquidatable
  CHECK_EQ(maxRepayable(4, half), U256(2));
  CHECK_EQ(maxRepayable(0, half), U256(0));
  CHECK_EQ(maxRepayable(MAXV, WAD), MAXV);
  CHECK_THROWS(maxRepayable(MAXV, WAD + U256(1)));
  CHECK_EQ(maxRepayable(7, 0), U256(0));
}

TEST(validateRiskParams_boundaries) {
  const U256 ltv = U("750000000000000000"), lt = U("800000000000000000"),
             bonus = U("50000000000000000"), cf = U("500000000000000000");
  CHECK_EQ(validateRiskParams(ltv, lt, bonus, cf), U256(1));
  CHECK_THROWS(validateRiskParams(0, lt, bonus, cf));
  CHECK_THROWS(validateRiskParams(lt, lt, bonus, cf));                     // maxLtv == LT
  CHECK_THROWS(validateRiskParams(ltv, WAD, bonus, cf));                   // LT == WAD
  CHECK_THROWS(validateRiskParams(ltv, lt, 0, cf));                        // bonus == 0
  CHECK_THROWS(validateRiskParams(ltv, lt, MAX_LIQUIDATION_BONUS + U256(1), cf));
  // LT*(1+b) == 1 exactly (0.8 * 1.25) is rejected (strict); one wei of LT less passes
  CHECK_THROWS(validateRiskParams(ltv, lt, MAX_LIQUIDATION_BONUS, cf));
  CHECK_EQ(validateRiskParams(ltv, lt - U256(1), MAX_LIQUIDATION_BONUS, cf), U256(1));
  CHECK_THROWS(validateRiskParams(ltv, lt, bonus, 0));
  CHECK_EQ(validateRiskParams(ltv, lt, bonus, WAD), U256(1));
  CHECK_THROWS(validateRiskParams(ltv, lt, bonus, WAD + U256(1)));
  CHECK_THROWS(validateRiskParams(MAXV, MAXV, MAXV, MAXV));
  // R1: LT * (WAD + bonus) overflowing is also a failure (it could never pass anyway)
  CHECK_THROWS(validateRiskParams(ltv, MAXV, bonus, cf));
}

// ------------------------------------------------------------------ 7 liquidation

TEST(design_7_2_liquidation_examples) {
  CHECK_EQ(seizeForRepay(U("5000000000"), WAD, 6, U("1200000000000000000000"), 18,
                         U("50000000000000000")),
           U("4375000000000000000"));
  CHECK_EQ(repayForSeize(U("10000000000000000000"), WAD, 6, U("500000000000000000000"), 18,
                         U("50000000000000000")),
           U("4761904762"));
}

TEST(design_7_5_bad_debt_example) {
  const U256 half = U("500000000000000000"), bonus = U("50000000000000000");
  const LiquidationResult l = liquidationAmounts(U("10000000000"), RAY, MAXV,
                                                 U("10000000000000000000"),
                                                 U("500000000000000000000"), WAD, 18, 6, bonus,
                                                 half);
  CHECK_EQ(l.repaid, U("4761904762"));
  CHECK_EQ(l.seized, U("10000000000000000000"));
  CHECK_EQ(l.burned, U("4761904762"));
  // remaining scaled debt after the burn is then written off
  const U256 total = U("10000000000");
  const BadDebtResult b = badDebt(total - l.burned, total - l.burned, RAY, U("100000000000"));
  CHECK_EQ(b.debtWrittenOff, U("5238095238"));
  CHECK_EQ(b.loss, U("5238095238"));
  CHECK_EQ(b.newTotalSupplyAssets, U("94761904762"));
}

TEST(liquidation_formulas_eager_operands) {
  const U256 one = WAD;
  // R3/R4: 10**78 is evaluated even for repay == 0
  CHECK_THROWS(seizeForRepay(0, one, 78, one, 18, 0));
  CHECK_THROWS(seizeForRepay(0, one, 6, one, 78, 0));
  CHECK_THROWS(repayForSeize(0, one, 78, one, 18, 0));
  CHECK_THROWS(repayForSeize(0, one, 6, one, 78, 0));
  // 10**dd * WAD * cp must fit: with cp = 1, dd = 59 fits (1e77), dd = 60 does not (1e78)
  CHECK_EQ(seizeForRepay(0, 1, 59, 1, 0, 0), U256(0));
  CHECK_THROWS(seizeForRepay(0, 1, 60, 1, 0, 0));
  CHECK_THROWS(seizeForRepay(0, 1, 77, 1, 77, 0));
  // R1: repay * (WAD + bonus) overflows -> fails even though the result would be small
  CHECK_THROWS(seizeForRepay(MAXV, one, 6, one, 18, 0));
  // denominator cp * 10**dd * WAD overflows
  CHECK_THROWS(seizeForRepay(1, one, 6, MAXV, 1, 0));
  CHECK_THROWS(seizeForRepay(1, one, 0, MAXV, 0, 0));  // cp * 1 * WAD overflows
  // zero price: denominator 0 -> mulDiv by zero
  CHECK_THROWS(seizeForRepay(1, one, 6, 0, 18, 0));
  CHECK_THROWS(repayForSeize(1, 0, 6, one, 18, 0));
  CHECK_EQ(seizeForRepay(0, 0, 6, one, 18, 0), U256(0));
  // bonus overflow in WAD + bonus
  CHECK_THROWS(seizeForRepay(0, one, 6, one, 18, MAXV));
  CHECK_THROWS(repayForSeize(0, one, 6, one, 18, MAXV));
}

TEST(liquidation_formulas_round_trip_properties) {
  const U256 bonus = U("50000000000000000");
  const U256 dp = WAD, cp = U("1700000000000000000000");
  for (unsigned long long r : {1ULL, 7ULL, 1000ULL, 123456789ULL, 5000000000ULL}) {
    const U256 s = seizeForRepay(U256(r), dp, 6, cp, 18, bonus);
    CHECK(repayForSeize(s, dp, 6, cp, 18, bonus) <= U256(r));
  }
}

TEST(liquidationAmounts_cases) {
  const U256 half = U("500000000000000000"), bonus = U("50000000000000000");
  const U256 cp = U("2000000000000000000000"), dp = WAD;
  // debt 10_000e6; ETH $2000: plenty of collateral -> capped by close factor (5000e6)
  LiquidationResult r = liquidationAmounts(U("10000000000"), RAY, MAXV, U("100000000000000000000"),
                                           cp, dp, 18, 6, bonus, half);
  CHECK_EQ(r.repaid, U("5000000000"));
  CHECK_EQ(r.seized, U("2625000000000000000"));  // 5000 * 1.05 / 2000 ETH
  CHECK_EQ(r.burned, U("5000000000"));
  // requested below the cap
  r = liquidationAmounts(U("10000000000"), RAY, U("1000000000"), U("100000000000000000000"), cp,
                         dp, 18, 6, bonus, half);
  CHECK_EQ(r.repaid, U("1000000000"));
  CHECK_EQ(r.burned, U("1000000000"));
  // requested == 0: everything zero, no failure
  r = liquidationAmounts(U("10000000000"), RAY, 0, U("100000000000000000000"), cp, dp, 18, 6,
                         bonus, half);
  CHECK_EQ(r.repaid, U256(0));
  CHECK_EQ(r.seized, U256(0));
  CHECK_EQ(r.burned, U256(0));
  // collateral smaller than needed: seized == collateral, repaid reduced to repayForSeize
  r = liquidationAmounts(U("10000000000"), RAY, MAXV, U("1000000000000000000"), cp, dp, 18, 6,
                         bonus, half);
  CHECK_EQ(r.seized, U("1000000000000000000"));
  CHECK_EQ(r.repaid, repayForSeize(U("1000000000000000000"), dp, 6, cp, 18, bonus));
  // closeFactor == WAD and requested == MAX: whole debt repaid, burned = all scaled
  r = liquidationAmounts(U("10000000000"), RAY, MAXV, U("100000000000000000000"), cp, dp, 18, 6,
                         bonus, WAD);
  CHECK_EQ(r.repaid, U("10000000000"));
  CHECK_EQ(r.burned, U("10000000000"));
  // zero collateral: seized > 0 > collateral -> seized = 0, repayForSeize(0) = 0 caps repaid
  r = liquidationAmounts(U("10000000000"), RAY, MAXV, 0, cp, dp, 18, 6, bonus, half);
  CHECK_EQ(r.repaid, U256(0));
  CHECK_EQ(r.seized, U256(0));
  CHECK_EQ(r.burned, U256(0));
  // decimals 78 fail eagerly (seizeForRepay evaluates 10**dd)
  CHECK_THROWS(liquidationAmounts(0, RAY, 0, 0, cp, dp, 18, 78, bonus, half));
  CHECK_THROWS(liquidationAmounts(0, RAY, 0, 0, cp, dp, 78, 6, bonus, half));
  // R7: unvalidated closeFactor > WAD flows through: repaid = ceil(debt * 2)
  r = liquidationAmounts(10, RAY, MAXV, MAXV, cp, dp, 18, 6, bonus, WAD * U256(2));
  CHECK_EQ(r.repaid, U256(20));
  CHECK_EQ(r.burned, U256(10));  // repaid >= debt -> burn all scaled
}

TEST(badDebt_cases) {
  BadDebtResult b = badDebt(100, 100, RAY, 1000);
  CHECK_EQ(b.debtWrittenOff, U256(100));
  CHECK_EQ(b.loss, U256(100));
  CHECK_EQ(b.newTotalSupplyAssets, U256(900));
  // loss >= supply saturates at 0, and exactly equal also gives 0
  CHECK_EQ(badDebt(100, 100, RAY, 100).newTotalSupplyAssets, U256(0));
  CHECK_EQ(badDebt(100, 100, RAY, 50).newTotalSupplyAssets, U256(0));
  CHECK_EQ(badDebt(100, 100, RAY, 101).newTotalSupplyAssets, U256(1));
  // borrower larger than total: checked subtraction fails
  CHECK_THROWS(badDebt(5, 6, RAY, 1000));
  // per-user rounding vs total rounding: loss is the DROP in derived total debt
  const U256 idx = RAY + RAY / U256(2);  // 1.5
  b = badDebt(2, 1, idx, 1000);
  CHECK_EQ(debtFromScaled(2, idx), U256(3));    // total debt before
  CHECK_EQ(debtFromScaled(1, idx), U256(2));    // total debt after (ceil(1.5))
  CHECK_EQ(b.loss, U256(1));                    // 3 - 2: the drop in DERIVED total debt
  CHECK_EQ(b.debtWrittenOff, U256(2));          // the borrower's own ceil'd debt is larger
  CHECK_EQ(b.newTotalSupplyAssets, U256(999));
  CHECK_EQ(badDebt(0, 0, 0, 0).newTotalSupplyAssets, U256(0));
  CHECK_THROWS(badDebt(MAXV, 0, MAXV, 0));      // debtFromScaled overflows
}
