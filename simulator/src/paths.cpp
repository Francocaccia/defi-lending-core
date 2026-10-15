#include "paths.hpp"

#include <cmath>
#include <stdexcept>

namespace sim {

std::uint64_t SplitMix64::next() {
  state_ += 0x9E3779B97F4A7C15ULL;
  std::uint64_t z = state_;
  z = (z ^ (z >> 30U)) * 0xBF58476D1CE4E5B9ULL;
  z = (z ^ (z >> 27U)) * 0x94D049BB133111EBULL;
  return z ^ (z >> 31U);
}

double SplitMix64::uniform() {
  return static_cast<double>(next() >> 11U) * (1.0 / 9007199254740992.0);  // / 2^53
}

std::uint64_t SplitMix64::below(std::uint64_t n) {
  if (n == 0) throw std::invalid_argument("below(0)");
  const std::uint64_t limit = (~static_cast<std::uint64_t>(0)) - ((~static_cast<std::uint64_t>(0)) % n);
  std::uint64_t v = next();
  while (v >= limit) v = next();
  return v % n;
}

std::vector<std::size_t> historicalWindowStarts(const Grid& grid, std::size_t horizonSteps,
                                                std::size_t strideSteps) {
  if (strideSteps == 0) throw std::invalid_argument("stride must be positive");
  std::vector<std::size_t> starts;
  if (grid.size() < horizonSteps) return starts;
  for (std::size_t s = 0; s + horizonSteps <= grid.size(); s += strideSteps) starts.push_back(s);
  return starts;
}

ReturnSeries logReturns(const Grid& grid) {
  ReturnSeries r;
  if (grid.size() < 2) return r;
  r.eth.reserve(grid.size() - 1);
  r.usdc.reserve(grid.size() - 1);
  for (std::size_t i = 1; i < grid.size(); ++i) {
    r.eth.push_back(std::log(static_cast<double>(grid.eth[i]) / static_cast<double>(grid.eth[i - 1])));
    r.usdc.push_back(
        std::log(static_cast<double>(grid.usdc[i]) / static_cast<double>(grid.usdc[i - 1])));
  }
  return r;
}

namespace {
std::uint64_t toAnswer(double price) {
  long long v = std::llround(price);
  if (v < 1) v = 1;
  return static_cast<std::uint64_t>(v);
}
}  // namespace

void bootstrapPath(const ReturnSeries& r, std::uint64_t seed, std::uint64_t pathIndex,
                   std::size_t horizonSteps, double meanBlockSteps, std::uint64_t startEthAnswer,
                   std::uint64_t startUsdcAnswer, std::vector<std::uint64_t>& outEth,
                   std::vector<std::uint64_t>& outUsdc) {
  if (r.eth.empty() || r.eth.size() != r.usdc.size()) throw std::invalid_argument("empty returns");
  if (meanBlockSteps < 1.0) throw std::invalid_argument("mean block length must be >= 1 step");
  const std::uint64_t n = r.eth.size();
  SplitMix64 rng(seed ^ (pathIndex * 0xD1B54A32D192ED03ULL + 0x8CB92BA72F3D8DD7ULL));

  outEth.assign(horizonSteps, 0);
  outUsdc.assign(horizonSteps, 0);
  double lnE = std::log(static_cast<double>(startEthAnswer));
  double lnU = std::log(static_cast<double>(startUsdcAnswer));
  outEth[0] = startEthAnswer;
  outUsdc[0] = startUsdcAnswer;

  const double pRestart = 1.0 / meanBlockSteps;
  std::uint64_t idx = rng.below(n);
  for (std::size_t k = 1; k < horizonSteps; ++k) {
    if (rng.uniform() < pRestart) idx = rng.below(n);
    else idx = (idx + 1) % n;
    lnE += r.eth[idx];
    lnU += r.usdc[idx];
    outEth[k] = toAnswer(std::exp(lnE));
    outUsdc[k] = toAnswer(std::exp(lnU));
  }
}

}  // namespace sim
