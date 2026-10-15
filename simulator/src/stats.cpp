#include "stats.hpp"

#include <cmath>

namespace sim {

double quantileSorted(const std::vector<double>& sorted, double q) {
  if (sorted.empty()) return 0.0;
  if (q <= 0.0) return sorted.front();
  if (q >= 1.0) return sorted.back();
  const double pos = q * static_cast<double>(sorted.size() - 1);
  const std::size_t lo = static_cast<std::size_t>(std::floor(pos));
  const std::size_t hi = lo + 1 < sorted.size() ? lo + 1 : lo;
  const double frac = pos - static_cast<double>(lo);
  return sorted[lo] + (sorted[hi] - sorted[lo]) * frac;
}

Interval wilson95(std::size_t k, std::size_t n) {
  if (n == 0) return {0.0, 0.0};
  const double z = 1.959963984540054;
  const double nn = static_cast<double>(n);
  const double p = static_cast<double>(k) / nn;
  const double denom = 1.0 + z * z / nn;
  const double centre = (p + z * z / (2.0 * nn)) / denom;
  const double half = z * std::sqrt(p * (1.0 - p) / nn + z * z / (4.0 * nn * nn)) / denom;
  Interval r;
  r.lo = centre - half < 0.0 ? 0.0 : centre - half;
  r.hi = centre + half > 1.0 ? 1.0 : centre + half;
  return r;
}

std::size_t countEpisodes(const std::vector<std::size_t>& idx, std::size_t maxGap) {
  if (idx.empty()) return 0;
  std::size_t episodes = 1;
  for (std::size_t i = 1; i < idx.size(); ++i) {
    if (idx[i] - idx[i - 1] > maxGap) ++episodes;
  }
  return episodes;
}

}  // namespace sim
