// Experiment configuration (JSON). Protocol parameters use the SAME names as the contracts'
// constructor structs (maxLtv, liquidationThreshold, liquidationBonus, closeFactor and the rate
// model's baseRate / slope1 / slope2 / optimalUtilization).
#pragma once

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

#include "engine.hpp"
#include "json.hpp"

namespace sim {

struct Variant {
  std::string label;
  ProtocolParams params;
};

struct SourceSpec {
  enum class Kind { Historical, Bootstrap };
  Kind kind = Kind::Historical;
  std::vector<int> horizonDays;
  int startStrideDays = 1;        // historical: spacing of window start dates
  std::uint64_t paths = 0;        // bootstrap: number of synthetic paths per horizon
  double meanBlockDays = 7.0;     // bootstrap: mean block length
  std::uint64_t seed = 1;         // bootstrap
};

struct Config {
  std::string name;
  std::string description;
  std::string ethCsv;
  std::string usdcCsv;
  std::int64_t stepSeconds = 3600;
  SourceSpec source;
  U256 utilization;                         // WAD
  U256 collateralWei;                        // fixed amount of ETH collateral (collateralEth)
  U256 collateralUsd;                        // WAD USD; when non-zero (collateralUsd) the collateral is this many
                                             // dollars of ETH at the opening price, so the position SIZE in dollars
                                             // does not depend on where the price was when the window started
  std::vector<std::string> ltvFractionText;  // as written, for the report
  std::vector<U256> ltvFractions;            // WAD fractions of the max-LTV limit
  std::vector<int> latencyHours;
  U256 minDebtUsd;                           // WAD USD
  std::vector<Variant> variants;
  unsigned threads = 0;                      // 0 = hardware concurrency
};

/// Parses a protocol-parameter object (also usable on its own for a "protocol.json" file).
ProtocolParams parseProtocol(const Json& obj, const ProtocolParams* defaultRate);

/// Loads and validates a config. Relative file paths inside it are resolved against the config
/// file's own directory, so an experiment is runnable from anywhere.
Config loadConfig(const std::string& path);
Config parseConfig(const Json& root, const std::string& baseDir);

}  // namespace sim
