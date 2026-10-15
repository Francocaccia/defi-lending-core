// Small statistics helpers.
#pragma once

#include <cstddef>
#include <vector>

namespace sim {

/// Linear-interpolation quantile of an ASCENDING-sorted sample (q in [0,1]); 0 for an empty sample.
double quantileSorted(const std::vector<double>& sorted, double q);

struct Interval {
  double lo = 0.0;
  double hi = 0.0;
};

/// 95% Wilson score interval for a proportion k/n. NOTE: it assumes independent trials. Overlapping
/// historical windows are NOT independent, so for those it is a lower bound on the true
/// uncertainty (the report says so wherever it is shown).
Interval wilson95(std::size_t k, std::size_t n);

/// Number of "episodes": maximal groups of flagged items whose indices are at most `maxGap` apart.
/// Used to count distinct crash episodes behind many overlapping liquidated windows.
std::size_t countEpisodes(const std::vector<std::size_t>& sortedFlaggedIndices, std::size_t maxGap);

}  // namespace sim
