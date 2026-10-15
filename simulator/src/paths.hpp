// Price-path sources: rolling historical windows (every start date) and a stationary block
// bootstrap of the historical hourly returns.
#pragma once

#include <cstddef>
#include <cstdint>
#include <vector>

#include "data.hpp"

namespace sim {

/// Start indices of ALL rolling windows of `horizonSteps` steps, every `strideSteps` steps, over the
/// whole grid. Deliberately no filtering: no period is chosen or excluded.
std::vector<std::size_t> historicalWindowStarts(const Grid& grid, std::size_t horizonSteps,
                                                std::size_t strideSteps);

/// Log-returns of consecutive grid prices (zero while a feed is stale), ETH and USDC aligned.
struct ReturnSeries {
  std::vector<double> eth;
  std::vector<double> usdc;
};
ReturnSeries logReturns(const Grid& grid);

/// Deterministic stationary block bootstrap (Politis-Romano): the next return follows the previous
/// one in the history with probability 1 - 1/meanBlockSteps, else a uniformly random restart. ETH and
/// USDC returns are resampled JOINTLY (same indices), preserving their co-movement. The path starts at
/// `startEthAnswer` / `startUsdcAnswer` and has `horizonSteps` points (index 0 is the start).
/// The same (seed, pathIndex) always yields the same path, independent of thread scheduling.
void bootstrapPath(const ReturnSeries& r, std::uint64_t seed, std::uint64_t pathIndex,
                   std::size_t horizonSteps, double meanBlockSteps, std::uint64_t startEthAnswer,
                   std::uint64_t startUsdcAnswer, std::vector<std::uint64_t>& outEth,
                   std::vector<std::uint64_t>& outUsdc);

/// splitmix64: tiny, well-distributed, fully specified PRNG (identical on every platform).
class SplitMix64 {
 public:
  explicit SplitMix64(std::uint64_t seed) : state_(seed) {}
  std::uint64_t next();
  /// Uniform in [0, 1) with 53 random bits.
  double uniform();
  /// Uniform integer in [0, n) (n > 0), by rejection to avoid modulo bias.
  std::uint64_t below(std::uint64_t n);

 private:
  std::uint64_t state_;
};

}  // namespace sim
