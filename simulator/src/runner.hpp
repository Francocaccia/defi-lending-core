// Runs a whole experiment: every (protocol variant x borrower leverage x liquidator latency) over
// every price path of every horizon, in parallel and deterministically.
#pragma once

#include <cstddef>
#include <map>
#include <string>
#include <utility>
#include <vector>

#include "config.hpp"
#include "data.hpp"
#include "engine.hpp"
#include "stats.hpp"

namespace sim {

struct Row {
  std::string variant;
  double maxLtv = 0.0;
  double liquidationThreshold = 0.0;
  double liquidationBonus = 0.0;
  double closeFactor = 0.0;
  std::string ltvFraction;       // as written in the config
  double initialLtv = 0.0;       // maxLtv x fraction (absolute, at opening)
  int latencyHours = 0;
  int horizonDays = 0;

  std::size_t n = 0;             // paths / windows
  std::size_t unhealthy = 0;     // ever had HF < 1
  std::size_t liquidated = 0;
  std::size_t badDebt = 0;
  std::size_t stuck = 0;
  std::size_t stuckUnderwater = 0;  // stuck runs whose debt exceeded the collateral value at some point
  std::size_t episodes = 0;      // historical only: distinct crash episodes behind liquidated windows
  Interval pLiquidated;
  Interval pBadDebt;
  double meanLiquidations = 0.0; // among liquidated runs
  double meanBorrowerCostPct = 0.0;  // among liquidated: (seized value - repaid value) / initial collateral value
  double badMean = 0.0;          // bad debt as a fraction of initial debt, over ALL runs
  double badP99 = 0.0;           // ... 99th percentile over all runs
  double badMax = 0.0;           // ... worst run
  double badCondMedian = 0.0;    // ... median among runs WITH bad debt
  double medianMinHf = 0.0;      // median over runs of the minimum health factor reached
  /// historical only: year -> (windows starting that year, of which liquidated)
  std::map<int, std::pair<std::size_t, std::size_t>> byYear;
};

struct Progress {
  virtual ~Progress() = default;
  virtual void note(const std::string& message) = 0;
};

/// Runs everything in `cfg` on `grid`. Output rows are ordered horizon, variant, fraction, latency.
std::vector<Row> runExperiment(const Config& cfg, const Grid& grid, Progress* progress);

}  // namespace sim
