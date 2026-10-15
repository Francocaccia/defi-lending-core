#include <sstream>

#include "config.hpp"
#include "data.hpp"
#include "report.hpp"
#include "runner.hpp"
#include "simtest.hpp"

using namespace sim;

namespace {

// 300 days of hourly data: flat $2,000, except days 100-103 where ETH is $1,000 (a -50% crash that
// recovers). Everything else about the experiment is deterministic and small.
Grid syntheticGrid() {
  std::ostringstream eth;
  eth << "updatedAt,answer\n";
  for (std::int64_t h = 0; h < 24 * 300; ++h) {
    const std::int64_t day = h / 24;
    const std::uint64_t price = (day >= 100 && day < 103) ? 100000000000ULL : 200000000000ULL;
    eth << (1600000000 + h * 3600) << "," << price << "\n";
  }
  std::ostringstream usdc;
  usdc << "updatedAt,answer\n1600000000,100000000\n";
  return buildGrid(parseOracleCsv(eth.str(), "eth"), parseOracleCsv(usdc.str(), "usdc"), 3600);
}

Config smallConfig(const char* sourceJson) {
  const std::string doc = std::string(R"({
    "name": "t", "data": {"eth": "x", "usdc": "y"}, "stepSeconds": 3600,
    "source": )") + sourceJson + R"(,
    "market": {"utilization": "0.5"},
    "borrower": {"collateralEth": "10", "ltvFractionOfMax": ["0.9", "1.0"]},
    "liquidator": {"latencyHours": [0, 24]},
    "defaultRate": {"baseRate": "0", "slope1": "0.04", "slope2": "0.75", "optimalUtilization": "0.8"},
    "variants": [
      {"label": "tight", "maxLtv": "0.75", "liquidationThreshold": "0.80", "liquidationBonus": "0.05", "closeFactor": "0.5"},
      {"label": "safe",  "maxLtv": "0.40", "liquidationThreshold": "0.50", "liquidationBonus": "0.05", "closeFactor": "0.5"}
    ]
  })";
  return parseConfig(parseJson(doc), ".");
}

}  // namespace

TEST(runner_historical_windows_find_exactly_the_windows_that_contain_the_crash) {
  const Grid g = syntheticGrid();
  const Config c = smallConfig(R"({"type": "historical", "horizonDays": 30, "startStrideDays": 1})");
  const std::vector<Row> rows = runExperiment(c, g, nullptr);
  CHECK_EQ(rows.size(), static_cast<std::size_t>(2 * 2 * 2));  // variants x fractions x latencies

  for (const Row& r : rows) {
    // 7199 grid points, 720-step (30-day) windows starting every 24 steps: 270 windows.
    CHECK_EQ(r.n, static_cast<std::size_t>(270));
    if (r.variant == "tight") {
      // The crash occupies grid points 2400..2471. A window opened at $2,000 that contains point 2400
      // starts at 24k with 71 <= k <= 99 (k >= 100 would OPEN inside the crash, at $1,000, and then
      // only ever sees prices go up): 29 windows. A 67-75% LTV position halves in value -> liquidated.
      // With a 24 h liquidator latency the earliest of those windows (crash at step 696 of 720) ends
      // before the liquidator arrives, so it is (correctly) not counted: 28 instead of 29.
      CHECK_EQ(r.liquidated, static_cast<std::size_t>(r.latencyHours == 0 ? 29 : 28));
      CHECK_EQ(r.episodes, static_cast<std::size_t>(1));  // one crash = one episode
    } else {
      CHECK(r.liquidated <= 29);
    }
    const double p = static_cast<double>(r.liquidated) / static_cast<double>(r.n);
    CHECK(r.pLiquidated.lo <= p && p <= r.pLiquidated.hi);
  }
}
TEST(runner_a_safer_variant_is_liquidated_no_more_often_than_a_riskier_one) {
  const Grid g = syntheticGrid();
  const Config c = smallConfig(R"({"type": "historical", "horizonDays": 30, "startStrideDays": 1})");
  const std::vector<Row> rows = runExperiment(c, g, nullptr);
  for (const Row& a : rows) {
    for (const Row& b : rows) {
      if (a.variant == "safe" && b.variant == "tight" && a.ltvFraction == b.ltvFraction &&
          a.latencyHours == b.latencyHours) {
        CHECK(a.liquidated <= b.liquidated);
      }
    }
  }
}

TEST(runner_bootstrap_is_identical_for_any_number_of_threads) {
  const Grid g = syntheticGrid();
  Config c1 = smallConfig(R"({"type": "bootstrap", "horizonDays": 30, "paths": 300, "meanBlockDays": 5, "seed": 5})");
  Config c4 = c1;
  c1.threads = 1;
  c4.threads = 4;
  const std::string a = renderCsv(runExperiment(c1, g, nullptr));
  const std::string b = renderCsv(runExperiment(c4, g, nullptr));
  CHECK(a == b);
  CHECK(a.size() > 100);
  // Same seed twice: identical; another seed: (almost surely) different numbers somewhere.
  Config other = c1;
  other.source.seed = 6;
  CHECK(renderCsv(runExperiment(other, g, nullptr)) != a);
}

TEST(runner_reports_render_every_row_and_the_stated_assumptions) {
  const Grid g = syntheticGrid();
  const Config c = smallConfig(R"({"type": "historical", "horizonDays": 30, "startStrideDays": 7})");
  const std::vector<Row> rows = runExperiment(c, g, nullptr);
  const std::string md = renderMarkdown(c, g, rows);
  CHECK(md.find("## Setup") != std::string::npos);
  CHECK(md.find("ASSUMED") == std::string::npos);            // the synthetic USDC feed exists from the start
  CHECK(md.find("NOT independent") != std::string::npos);    // the overlap warning is always shown
  CHECK(md.find("tight") != std::string::npos);
  CHECK(md.find("2020-09-13") != std::string::npos);         // 1600000000 = 2020-09-13 UTC
  const std::string csv = renderCsv(rows);
  std::size_t lines = 0;
  for (char ch : csv) {
    if (ch == '\n') ++lines;
  }
  CHECK_EQ(lines, rows.size() + 1);
}

TEST(runner_rejects_a_history_shorter_than_the_horizon) {
  const Grid g = syntheticGrid();
  const Config c = smallConfig(R"({"type": "historical", "horizonDays": 400, "startStrideDays": 1})");
  CHECK_THROWS_ANY(runExperiment(c, g, nullptr));
}

TEST(runner_isoDate_is_correct) {
  CHECK_EQ(isoDate(0), std::string("1970-01-01"));
  CHECK_EQ(isoDate(1582934400), std::string("2020-02-29"));
  CHECK_EQ(isoDate(1600000000), std::string("2020-09-13"));
  CHECK_EQ(isoDate(1609459199), std::string("2020-12-31"));
}
