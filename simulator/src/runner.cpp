#include "runner.hpp"

#include <algorithm>
#include <atomic>
#include <exception>
#include <mutex>
#include <thread>

#include "model.hpp"
#include "paths.hpp"
#include "units.hpp"

namespace sim {

namespace {

struct Combo {
  std::size_t variant;
  std::size_t fraction;
  std::size_t latency;
};

template <class F>
void parallelFor(std::size_t count, unsigned threads, F&& fn) {
  if (threads == 0) threads = std::max(1U, std::thread::hardware_concurrency());
  threads = static_cast<unsigned>(std::min<std::size_t>(threads, std::max<std::size_t>(1, count)));
  std::atomic<std::size_t> next{0};
  std::exception_ptr error;
  std::mutex errorMutex;
  auto worker = [&]() {
    try {
      while (true) {
        const std::size_t i = next.fetch_add(1);
        if (i >= count) break;
        fn(i);
      }
    } catch (...) {
      std::lock_guard<std::mutex> lock(errorMutex);
      if (!error) error = std::current_exception();
      next.store(count);
    }
  };
  std::vector<std::thread> pool;
  for (unsigned t = 1; t < threads; ++t) pool.emplace_back(worker);
  worker();
  for (std::thread& t : pool) t.join();
  if (error) std::rethrow_exception(error);
}

Row aggregate(const std::vector<RunResult>& runs, const std::vector<std::size_t>* startIndices,
              const std::vector<std::int64_t>* startTimes, std::size_t episodeGapSteps) {
  Row row;
  row.n = runs.size();
  std::vector<double> badAll;
  std::vector<double> badCond;
  std::vector<double> minHf;
  std::vector<std::size_t> liquidatedStarts;
  double liqCount = 0.0;
  double costPct = 0.0;
  badAll.reserve(runs.size());
  for (std::size_t i = 0; i < runs.size(); ++i) {
    const RunResult& r = runs[i];
    if (r.everUnhealthy) ++row.unhealthy;
    if (r.stuck) ++row.stuck;
    if (r.stuckUnderwater) ++row.stuckUnderwater;
    badAll.push_back(r.badDebtFraction);
    minHf.push_back(r.minHealthFactor);
    if (r.liquidated) {
      ++row.liquidated;
      liqCount += static_cast<double>(r.liquidations);
      if (r.initialCollateralUsd > 0.0) costPct += r.borrowerCostUsd / r.initialCollateralUsd;
      if (startIndices != nullptr) liquidatedStarts.push_back((*startIndices)[i]);
    }
    if (r.badDebt) {
      ++row.badDebt;
      badCond.push_back(r.badDebtFraction);
    }
    if (startTimes != nullptr) {
      auto& slot = row.byYear[yearOf((*startTimes)[i])];
      ++slot.first;
      if (r.liquidated) ++slot.second;
    }
  }
  row.pLiquidated = wilson95(row.liquidated, row.n);
  row.pBadDebt = wilson95(row.badDebt, row.n);
  if (row.liquidated > 0) {
    row.meanLiquidations = liqCount / static_cast<double>(row.liquidated);
    row.meanBorrowerCostPct = costPct / static_cast<double>(row.liquidated);
  }
  double sum = 0.0;
  for (double b : badAll) sum += b;
  row.badMean = row.n > 0 ? sum / static_cast<double>(row.n) : 0.0;
  std::sort(badAll.begin(), badAll.end());
  row.badP99 = quantileSorted(badAll, 0.99);
  row.badMax = badAll.empty() ? 0.0 : badAll.back();
  std::sort(badCond.begin(), badCond.end());
  row.badCondMedian = quantileSorted(badCond, 0.5);
  std::sort(minHf.begin(), minHf.end());
  row.medianMinHf = quantileSorted(minHf, 0.5);
  if (startIndices != nullptr) row.episodes = countEpisodes(liquidatedStarts, episodeGapSteps);
  return row;
}

}  // namespace

std::vector<Row> runExperiment(const Config& cfg, const Grid& grid, Progress* progress) {
  // One engine per protocol variant (validated, rate precomputed).
  std::vector<Engine> engines;
  engines.reserve(cfg.variants.size());
  for (const Variant& v : cfg.variants) engines.emplace_back(v.params, cfg.utilization, cfg.stepSeconds);

  std::vector<Combo> combos;
  for (std::size_t v = 0; v < cfg.variants.size(); ++v) {
    for (std::size_t f = 0; f < cfg.ltvFractions.size(); ++f) {
      for (std::size_t l = 0; l < cfg.latencyHours.size(); ++l) combos.push_back({v, f, l});
    }
  }

  const std::int64_t stepsPerDay = 86400 / cfg.stepSeconds;
  if (stepsPerDay <= 0 || 86400 % cfg.stepSeconds != 0) {
    throw std::runtime_error("config: stepSeconds must divide a day evenly");
  }

  std::vector<Row> rows;
  ReturnSeries returns;
  if (cfg.source.kind == SourceSpec::Kind::Bootstrap) returns = logReturns(grid);

  for (int horizonDays : cfg.source.horizonDays) {
    const std::size_t horizonSteps = static_cast<std::size_t>(horizonDays * stepsPerDay);
    if (progress != nullptr) progress->note("horizon " + std::to_string(horizonDays) + " days");

    std::vector<std::size_t> starts;
    std::vector<std::int64_t> startTimes;
    std::size_t runsPerCombo = 0;
    if (cfg.source.kind == SourceSpec::Kind::Historical) {
      starts = historicalWindowStarts(grid, horizonSteps,
                                      static_cast<std::size_t>(cfg.source.startStrideDays * stepsPerDay));
      for (std::size_t s : starts) startTimes.push_back(grid.timeAt(s));
      runsPerCombo = starts.size();
      if (runsPerCombo == 0) throw std::runtime_error("history shorter than the horizon");
    } else {
      runsPerCombo = static_cast<std::size_t>(cfg.source.paths);
    }

    std::vector<std::vector<RunResult>> results(combos.size(), std::vector<RunResult>(runsPerCombo));

    parallelFor(runsPerCombo, cfg.threads, [&](std::size_t i) {
      std::vector<std::uint64_t> ethPath;
      std::vector<std::uint64_t> usdcPath;
      const std::uint64_t* eth = nullptr;
      const std::uint64_t* usdc = nullptr;
      if (cfg.source.kind == SourceSpec::Kind::Historical) {
        eth = grid.eth.data() + starts[i];
        usdc = grid.usdc.data() + starts[i];
      } else {
        // Synthetic paths start at $2,000 and 1.00; the dynamics are scale-free so the start
        // level does not matter for the liquidation mechanics.
        bootstrapPath(returns, cfg.source.seed, i, horizonSteps,
                      cfg.source.meanBlockDays * static_cast<double>(stepsPerDay), 200000000000ULL,
                      100000000ULL, ethPath, usdcPath);
        eth = ethPath.data();
        usdc = usdcPath.data();
      }
      for (std::size_t c = 0; c < combos.size(); ++c) {
        PositionSpec spec;
        spec.collateralWei = cfg.collateralWei;
        if (!cfg.collateralUsd.isZero()) {
          // dollars -> wei of ETH at the opening oracle price (rounded down)
          spec.collateralWei = refmodel::mulDiv(cfg.collateralUsd, refmodel::WAD,
                                                U256(eth[0]) * U256(10000000000ULL));
        }
        spec.ltvFractionOfMax = cfg.ltvFractions[combos[c].fraction];
        PolicyParams policy;
        policy.latencySteps = static_cast<std::size_t>(cfg.latencyHours[combos[c].latency]) *
                              static_cast<std::size_t>(3600 / cfg.stepSeconds);
        policy.minDebtValueUsd = cfg.minDebtUsd;
        results[c][i] = engines[combos[c].variant].run(spec, policy, eth, usdc, horizonSteps);
      }
    });

    const std::size_t episodeGapSteps = static_cast<std::size_t>(7 * stepsPerDay);
    for (std::size_t v = 0; v < cfg.variants.size(); ++v) {
      for (std::size_t f = 0; f < cfg.ltvFractions.size(); ++f) {
        for (std::size_t l = 0; l < cfg.latencyHours.size(); ++l) {
          std::size_t c = 0;
          for (; c < combos.size(); ++c) {
            if (combos[c].variant == v && combos[c].fraction == f && combos[c].latency == l) break;
          }
          const bool hist = cfg.source.kind == SourceSpec::Kind::Historical;
          Row row = aggregate(results[c], hist ? &starts : nullptr, hist ? &startTimes : nullptr,
                              episodeGapSteps);
          const ProtocolParams& p = cfg.variants[v].params;
          row.variant = cfg.variants[v].label;
          row.maxLtv = toDouble(p.maxLtv) / 1e18;
          row.liquidationThreshold = toDouble(p.liquidationThreshold) / 1e18;
          row.liquidationBonus = toDouble(p.liquidationBonus) / 1e18;
          row.closeFactor = toDouble(p.closeFactor) / 1e18;
          row.ltvFraction = cfg.ltvFractionText[f];
          row.initialLtv = row.maxLtv * (toDouble(cfg.ltvFractions[f]) / 1e18);
          row.latencyHours = cfg.latencyHours[l];
          row.horizonDays = horizonDays;
          rows.push_back(std::move(row));
        }
      }
    }
  }
  return rows;
}

}  // namespace sim
