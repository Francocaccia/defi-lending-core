#include "config.hpp"
#include "simtest.hpp"
#include "units.hpp"

using namespace sim;

namespace {

const char* kMinimal = R"({
  "name": "mini",
  "data": { "eth": "eth.csv", "usdc": "usdc.csv" },
  "stepSeconds": 3600,
  "source": { "type": "historical", "horizonDays": [30, 90], "startStrideDays": 2 },
  "market": { "utilization": "0.6" },
  "borrower": { "collateralEth": "10", "ltvFractionOfMax": ["0.9", "0.99"] },
  "liquidator": { "latencyHours": [0, 6], "minDebtUsd": "50" },
  "defaultRate": { "baseRate": "0", "slope1": "0.04", "slope2": "0.75", "optimalUtilization": "0.8" },
  "variants": [
    { "label": "default", "maxLtv": "0.75", "liquidationThreshold": "0.80", "liquidationBonus": "0.05", "closeFactor": "0.5" },
    { "label": "raw-wad", "maxLtv": "700000000000000000", "liquidationThreshold": "750000000000000000",
      "liquidationBonus": "50000000000000000", "closeFactor": "500000000000000000",
      "rate": { "baseRate": "0", "slope1": "0.05", "slope2": "1.0", "optimalUtilization": "0.9" } }
  ]
})";

std::string replaceOnce(std::string s, const std::string& from, const std::string& to) {
  const std::size_t p = s.find(from);
  if (p != std::string::npos) s.replace(p, from.size(), to);
  return s;
}

}  // namespace

TEST(config_parses_the_protocols_own_parameter_names) {
  const Config c = parseConfig(parseJson(kMinimal), "/base");
  CHECK_EQ(c.name, std::string("mini"));
  CHECK_EQ(c.ethCsv, std::string("/base/eth.csv"));
  CHECK_EQ(c.stepSeconds, static_cast<std::int64_t>(3600));
  CHECK(c.source.kind == SourceSpec::Kind::Historical);
  CHECK_EQ(c.source.horizonDays.size(), static_cast<std::size_t>(2));
  CHECK_EQ(c.source.startStrideDays, 2);
  CHECK_EQ(c.collateralWei, parseDecimalScaled("10", 18));
  CHECK_EQ(c.ltvFractions.size(), static_cast<std::size_t>(2));
  CHECK_EQ(c.latencyHours.size(), static_cast<std::size_t>(2));
  CHECK_EQ(c.minDebtUsd, parseDecimalScaled("50", 18));
  CHECK_EQ(c.variants.size(), static_cast<std::size_t>(2));
  // Fraction text and raw-WAD spellings describe the same number.
  CHECK_EQ(c.variants[0].params.maxLtv, parseWadParam("750000000000000000"));
  CHECK_EQ(c.variants[1].params.maxLtv, parseWadParam("0.70"));
  // The first variant inherits the default rate, the second overrides it.
  CHECK_EQ(c.variants[0].params.slope1, parseWadParam("0.04"));
  CHECK_EQ(c.variants[1].params.slope1, parseWadParam("0.05"));
}

TEST(config_rejects_invalid_protocol_deployments_naming_the_variant) {
  const std::string bad = replaceOnce(kMinimal, R"("maxLtv": "0.75")", R"("maxLtv": "0.85")");
  try {
    (void)parseConfig(parseJson(bad), ".");
    CHECK(false);
  } catch (const std::exception& e) {
    CHECK(std::string(e.what()).find("default") != std::string::npos);
  }
}

TEST(config_rejects_missing_and_nonsensical_fields) {
  CHECK_THROWS_ANY(parseConfig(parseJson(replaceOnce(kMinimal, R"("name": "mini",)", "")), "."));
  CHECK_THROWS_ANY(parseConfig(parseJson(replaceOnce(kMinimal, R"("utilization": "0.6")", R"("utilization": "1.5")")), "."));
  CHECK_THROWS_ANY(parseConfig(parseJson(replaceOnce(kMinimal, R"("0.9", "0.99")", R"("0", "1.2")")), "."));
  CHECK_THROWS_ANY(parseConfig(parseJson(replaceOnce(kMinimal, R"("historical")", R"("magic")")), "."));
  CHECK_THROWS_ANY(parseConfig(parseJson(replaceOnce(kMinimal, "[30, 90]", "[0]")), "."));
  CHECK_THROWS_ANY(parseConfig(parseJson(replaceOnce(kMinimal, R"("stepSeconds": 3600)", R"("stepSeconds": 0)")), "."));
  CHECK_THROWS_ANY(parseConfig(parseJson(replaceOnce(kMinimal, R"("latencyHours": [0, 6])", R"("latencyHours": [-1])")), "."));
}

TEST(config_bootstrap_source_fields) {
  const std::string j = replaceOnce(
      kMinimal, R"({ "type": "historical", "horizonDays": [30, 90], "startStrideDays": 2 })",
      R"({ "type": "bootstrap", "horizonDays": 30, "paths": 500, "meanBlockDays": 5.5, "seed": 99 })");
  const Config c = parseConfig(parseJson(j), ".");
  CHECK(c.source.kind == SourceSpec::Kind::Bootstrap);
  CHECK_EQ(c.source.paths, static_cast<std::uint64_t>(500));
  CHECK_NEAR(c.source.meanBlockDays, 5.5, 0.0);
  CHECK_EQ(c.source.seed, static_cast<std::uint64_t>(99));
}

TEST(config_the_committed_example_configs_are_valid) {
  // Every shipped experiment must load, and every variant in it must be a valid protocol deployment.
  const char* files[] = {"/configs/historical_baseline.json", "/configs/bootstrap_baseline.json",
                         "/configs/parameter_sweep.json", "/configs/dust_positions.json"};
  for (const char* f : files) {
    const Config c = loadConfig(std::string(SIM_SOURCE_DIR) + f);
    CHECK(!c.variants.empty());
    CHECK(!c.source.horizonDays.empty());
    CHECK(!c.ltvFractions.empty());
    CHECK(!c.latencyHours.empty());
  }
}
