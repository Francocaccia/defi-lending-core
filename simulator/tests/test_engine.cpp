#include <vector>

#include "engine.hpp"
#include "model.hpp"
#include "simtest.hpp"
#include "units.hpp"

using namespace sim;
using refmodel::U256;

namespace {

constexpr std::uint64_t kUsd1 = 100000000ULL;  // $1.00 with 8 decimals

std::uint64_t usd(std::uint64_t dollars) { return dollars * 100000000ULL; }

ProtocolParams defaults(const char* base = "0") {
  ProtocolParams p;
  p.maxLtv = parseWadParam("0.75");
  p.liquidationThreshold = parseWadParam("0.80");
  p.liquidationBonus = parseWadParam("0.05");
  p.closeFactor = parseWadParam("0.50");
  p.baseRate = parseWadParam(base);
  p.slope1 = U256(0);
  p.slope2 = U256(0);
  p.optimalUtilization = parseWadParam("0.80");
  return p;
}

PositionSpec demoPosition() {
  PositionSpec s;
  s.collateralWei = parseDecimalScaled("10", 18);   // 10 WETH
  s.explicitDebtAssets = U256(10000000000ULL);      // 10,000 USDC
  return s;
}

RunResult run(const ProtocolParams& p, const PositionSpec& spec, std::size_t latency,
              std::vector<std::uint64_t> eth, std::int64_t stepSeconds = 3600,
              U256 minDebtUsd = U256(0)) {
  const Engine e(p, parseWadParam("0.5"), stepSeconds);
  std::vector<std::uint64_t> usdc(eth.size(), kUsd1);
  PolicyParams pol;
  pol.latencySteps = latency;
  pol.minDebtValueUsd = minDebtUsd;
  return e.run(spec, pol, eth.data(), usdc.data(), eth.size());
}

}  // namespace

// GOLDEN TEST: the story of script/Demo.s.sol (run for real on Anvil) reproduced by the simulator
// on the same exact integer math: ETH $2,000 -> $1,200 -> $300, 10 WETH against 10,000 USDC, no
// interest, liquidator acting immediately. The Anvil run printed: first liquidation repays 5,000
// USDC for 4.375 WETH, second repays 1,607.142858 USDC for the remaining 5.625 WETH and records
// 3,392.857142 USDC of bad debt.
TEST(engine_reproduces_the_solidity_demo_story_exactly) {
  const RunResult r = run(defaults(), demoPosition(), 0, {usd(2000), usd(1200), usd(300)});
  CHECK(r.opened);
  CHECK(r.everUnhealthy);
  CHECK(r.liquidated);
  CHECK(r.badDebt);
  CHECK(r.closed);
  CHECK_EQ(r.liquidations, 2U);
  CHECK_EQ(r.firstLiquidationStep, static_cast<std::int64_t>(1));
  CHECK_NEAR(r.badDebtUsdc, 3392.857142, 1e-6);
  CHECK_NEAR(r.badDebtFraction, 0.3392857142, 1e-9);
  // Borrower cost = value of collateral seized minus value of debt repaid:
  //   1st: 4.375 * 1200 - 5000 = 250       2nd: 5.625 * 300 - 1607.142858 = 80.357142
  CHECK_NEAR(r.borrowerCostUsd, 330.357142, 1e-5);
}

TEST(engine_first_liquidation_alone_matches_the_demo_numbers) {
  const RunResult r = run(defaults(), demoPosition(), 0, {usd(2000), usd(1200)});
  CHECK_EQ(r.liquidations, 1U);
  CHECK(!r.badDebt);
  CHECK(!r.closed);
  CHECK_NEAR(r.borrowerCostUsd, 250.0, 1e-6);  // 4.375 WETH * $1,200 - 5,000 USDC (the 5% bonus)
}

TEST(engine_healthy_position_is_never_touched) {
  const RunResult r = run(defaults(), demoPosition(), 0, {usd(2000), usd(1900), usd(2100), usd(1700)});
  CHECK(r.opened);
  CHECK(!r.everUnhealthy);
  CHECK(!r.liquidated);
  CHECK_EQ(r.liquidations, 0U);
  // HF at $1,700 = 10 * 1700 * 0.8 / 10000 = 1.36 is the lowest point.
  CHECK_NEAR(r.minHealthFactor, 1.36, 1e-9);
}

TEST(engine_exactly_hf_one_is_not_liquidatable) {
  // 10 ETH * $1,250 * 0.8 = 10,000 = debt: HF == 1.0 exactly. The market only liquidates HF < 1.
  const RunResult r = run(defaults(), demoPosition(), 0, {usd(2000), usd(1250)});
  CHECK(!r.liquidated);
  CHECK(!r.everUnhealthy);
  const RunResult below = run(defaults(), demoPosition(), 0, {usd(2000), usd(1249)});
  CHECK(below.liquidated);
}

TEST(engine_latency_lets_a_brief_dip_pass) {
  // Unhealthy at step 1 but recovered by step 2: a liquidator arriving after 1 step finds nothing.
  const RunResult late = run(defaults(), demoPosition(), 1, {usd(2000), usd(1200), usd(2000)});
  CHECK(late.everUnhealthy);
  CHECK(!late.liquidated);
  const RunResult instant = run(defaults(), demoPosition(), 0, {usd(2000), usd(1200), usd(2000)});
  CHECK(instant.liquidated);
}

TEST(engine_latency_turns_a_crash_into_bigger_bad_debt) {
  // A slower liquidator meets the lower price: more collateral is needed per unit of debt.
  // Path 2000 -> 1200 -> 300. Immediate: bad debt 3,392.857142 (the demo). With latency 1 the first
  // action happens at $300: 10 WETH are worth $3,000, repaying 10*300/1.05 = 2,857.142858 USDC, so
  // 10,000 - 2,857.142858 = 7,142.857142 USDC is written off.
  const RunResult slow = run(defaults(), demoPosition(), 1, {usd(2000), usd(1200), usd(300)});
  CHECK(slow.badDebt);
  CHECK_EQ(slow.liquidations, 1U);
  CHECK_NEAR(slow.badDebtUsdc, 7142.857142, 1e-6);
  const RunResult fast = run(defaults(), demoPosition(), 0, {usd(2000), usd(1200), usd(300)});
  CHECK(slow.badDebtUsdc > fast.badDebtUsdc);
}

TEST(engine_dust_filter_leaves_an_unhealthy_position_alone) {
  const U256 oneMillionUsd = parseDecimalScaled("1000000", 18);
  const RunResult r = run(defaults(), demoPosition(), 0, {usd(2000), usd(1200), usd(300)}, 3600, oneMillionUsd);
  CHECK(r.everUnhealthy);
  CHECK(r.stuck);
  CHECK(r.stuckUnderwater);  // by the last step 10 WETH ($3,000) no longer cover the 10,000 USDC debt
  CHECK(!r.liquidated);
  CHECK(!r.badDebt);
}

TEST(engine_a_stuck_position_is_flagged_insolvent_only_once_debt_exceeds_collateral) {
  const U256 oneMillionUsd = parseDecimalScaled("1000000", 18);
  // 2000 -> 1200: health factor 0.96 (unhealthy) but 10 WETH = $12,000 still covers the $10,000 debt.
  const RunResult shallow = run(defaults(), demoPosition(), 0, {usd(2000), usd(1200)}, 3600, oneMillionUsd);
  CHECK(shallow.stuck);
  CHECK(!shallow.stuckUnderwater);
  // A position that is liquidated normally never counts as stuck.
  const RunResult normal = run(defaults(), demoPosition(), 0, {usd(2000), usd(1200)});
  CHECK(!normal.stuck);
  CHECK(!normal.stuckUnderwater);
}

TEST(engine_opening_respects_the_max_ltv_limit_exactly) {
  PositionSpec s;
  s.collateralWei = parseDecimalScaled("10", 18);
  s.ltvFractionOfMax = parseWadParam("1.0");  // right at the limit: 75% of $20,000 = $15,000
  const RunResult atLimit = run(defaults(), s, 0, {usd(2000), usd(2000)});
  CHECK_NEAR(atLimit.initialDebtUsdc, 15000.0, 1e-6);
  s.ltvFractionOfMax = parseWadParam("0.5");
  CHECK_NEAR(run(defaults(), s, 0, {usd(2000), usd(2000)}).initialDebtUsdc, 7500.0, 1e-6);
  // The opening collateral value is recorded at the opening price.
  CHECK_NEAR(atLimit.initialCollateralUsd, 20000.0, 1e-6);
}

TEST(engine_interest_alone_can_make_a_position_unhealthy) {
  // 50% APR (base rate), constant price, opened at the limit (LTV 75%). Liquidation threshold is 80%,
  // so the debt must grow by 80/75 = 1.0667: 0.0667 / 0.5 yr = 1,168 hours.
  PositionSpec s;
  s.collateralWei = parseDecimalScaled("10", 18);
  s.ltvFractionOfMax = parseWadParam("1.0");
  std::vector<std::uint64_t> flat(24 * 90, usd(2000));
  const RunResult r = run(defaults("0.5"), s, 0, flat);
  CHECK(r.liquidated);
  CHECK(r.firstLiquidationStep >= 1165 && r.firstLiquidationStep <= 1172);
  // And with a negligible rate nothing happens over the same 90 days.
  const RunResult calm = run(defaults("0.005"), s, 0, flat);
  CHECK(!calm.liquidated);
}

TEST(engine_zero_collateral_cannot_borrow_and_short_paths_are_safe) {
  PositionSpec none;
  none.ltvFractionOfMax = parseWadParam("0.5");
  CHECK(!run(defaults(), none, 0, {usd(2000), usd(2000)}).opened);
  const RunResult single = run(defaults(), demoPosition(), 0, {usd(2000)});
  CHECK(single.opened);
  CHECK(!single.liquidated);
  const Engine e(defaults(), parseWadParam("0.5"), 3600);
  const RunResult empty = e.run(demoPosition(), PolicyParams{}, nullptr, nullptr, 0);
  CHECK(!empty.opened);
}

TEST(engine_rejects_an_invalid_protocol_deployment) {
  ProtocolParams bad = defaults();
  bad.maxLtv = parseWadParam("0.85");  // not below the 0.80 liquidation threshold
  CHECK_THROWS_ANY(Engine(bad, parseWadParam("0.5"), 3600));
  ProtocolParams badBonus = defaults();
  badBonus.liquidationBonus = parseWadParam("0.25");  // LT * (1 + bonus) reaches 1
  CHECK_THROWS_ANY(validateProtocol(badBonus));
  ProtocolParams badRate = defaults();
  badRate.optimalUtilization = U256(0);
  CHECK_THROWS_ANY(validateProtocol(badRate));
}

TEST(engine_higher_bonus_costs_the_borrower_more) {
  ProtocolParams generous = defaults();
  generous.liquidationBonus = parseWadParam("0.10");
  const RunResult a = run(defaults(), demoPosition(), 0, {usd(2000), usd(1200)});
  const RunResult b = run(generous, demoPosition(), 0, {usd(2000), usd(1200)});
  CHECK(b.borrowerCostUsd > a.borrowerCostUsd);
  CHECK_NEAR(b.borrowerCostUsd, 500.0, 1e-6);  // 10% of the 5,000 USDC repaid
}

TEST(engine_depegged_borrow_asset_can_trigger_liquidation_by_itself) {
  // USDC at $1.70: the 10,000 USDC debt is worth $17,000 against $20,000 * 0.8 = $16,000.
  const Engine e(defaults(), parseWadParam("0.5"), 3600);
  const std::vector<std::uint64_t> eth = {usd(2000), usd(2000)};
  const std::vector<std::uint64_t> usdc = {kUsd1, 170000000ULL};
  const RunResult r = e.run(demoPosition(), PolicyParams{}, eth.data(), usdc.data(), 2);
  CHECK(r.liquidated);
}
