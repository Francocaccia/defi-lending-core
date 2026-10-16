#include "report.hpp"

#include <cstdio>
#include <set>
#include <sstream>

#include "units.hpp"

namespace sim {

namespace {

std::string fmt(const char* f, double v) {
  char buf[64];
  std::snprintf(buf, sizeof buf, f, v);
  return buf;
}

std::string pct(double fraction, int decimals = 2) {
  char buf[64];
  std::snprintf(buf, sizeof buf, "%.*f%%", decimals, fraction * 100.0);
  return buf;
}

std::string label(const Row& r) {
  return fmt("%.0f", r.maxLtv * 100.0) + "% / " + fmt("%.0f", r.liquidationThreshold * 100.0) + "% / " +
         fmt("%.0f", r.liquidationBonus * 100.0) + "%";
}

}  // namespace

std::string isoDate(std::int64_t t) {
  std::int64_t z = t / 86400;
  if (t % 86400 < 0) --z;
  z += 719468;
  const std::int64_t era = (z >= 0 ? z : z - 146096) / 146097;
  const std::int64_t doe = z - era * 146097;
  const std::int64_t yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
  std::int64_t y = yoe + era * 400;
  const std::int64_t doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
  const std::int64_t mp = (5 * doy + 2) / 153;
  const std::int64_t d = doy - (153 * mp + 2) / 5 + 1;
  const std::int64_t m = mp < 10 ? mp + 3 : mp - 9;
  if (m <= 2) ++y;
  char buf[32];
  std::snprintf(buf, sizeof buf, "%04d-%02d-%02d", static_cast<int>(y), static_cast<int>(m),
                static_cast<int>(d));
  return buf;
}

std::string renderMarkdown(const Config& cfg, const Grid& grid, const std::vector<Row>& rows) {
  std::ostringstream o;
  const bool hist = cfg.source.kind == SourceSpec::Kind::Historical;
  o << "# " << cfg.name << "\n\n";
  if (!cfg.description.empty()) o << cfg.description << "\n\n";

  o << "## Setup\n\n";
  o << "- **Path source:** " << (hist ? "historical replay of EVERY rolling window" : "stationary block bootstrap of historical returns")
    << "\n";
  if (hist) {
    o << "  (a window starts every " << cfg.source.startStrideDays
      << " day(s) across the whole loaded history; no period inside it is selected or excluded)\n";
  } else {
    o << "  (" << cfg.source.paths << " synthetic paths per horizon, mean block length "
      << fmt("%.1f", cfg.source.meanBlockDays) << " days, seed " << cfg.source.seed << ")\n";
  }
  o << "- **Oracle history:** Chainlink ETH/USD from " << isoDate(grid.t0) << " to "
    << isoDate(grid.timeAt(grid.size() - 1)) << ", observed every " << cfg.stepSeconds
    << " s with carry-forward of the last round (" << grid.size() << " observations).\n";
  if (!cfg.fromText.empty()) {
    o << "  The history starts on " << cfg.fromText << " (`data.from`): earlier rounds of this proxy are not market data "
      << "(pre-launch rounds with constant answers and gaps of days to weeks) and are excluded on purpose.\n";
  }
  if (grid.firstRealUsdc == 0) {
    o << "- **USDC/USD:** real Chainlink USDC/USD data over the whole span.\n";
  } else if (grid.firstRealUsdc < grid.size()) {
    o << "- **USDC/USD:** real Chainlink USDC/USD from " << isoDate(grid.timeAt(grid.firstRealUsdc))
      << "; before that date USDC is ASSUMED to be exactly $1.00.\n";
  } else {
    o << "- **USDC/USD:** assumed to be exactly $1.00 throughout (no feed data).\n";
  }
  o << "- **Position:** " << (cfg.collateralUsd.isZero() ? formatScaled(cfg.collateralWei, 18, 4) + " ETH"
                                                      : "$" + formatScaled(cfg.collateralUsd, 18, 2) + " worth of ETH (at the opening price)")
    << " collateral, opened at a stated "
    << "fraction of the max-LTV limit; passive borrower (no top-ups, no repayments).\n";
  o << "- **Market:** utilization held at " << pct(toDouble(cfg.utilization) / 1e18, 0)
    << " to price interest (a single position does not move the market).\n";
  o << "- **Liquidator:** acts after the stated latency, repays up to the close factor, "
    << "then re-acts on later observations; no slippage, gas or capital limits.\n";
  o << "- **Protocol math:** every decision uses the integer functions of the independent reference model "
    << "(verified against the Solidity). Floating point is used only to skip obviously healthy steps.\n\n";

  std::set<int> horizons;
  for (const Row& r : rows) horizons.insert(r.horizonDays);

  for (int h : horizons) {
    o << "## Results, " << h << "-day horizon\n\n";
    o << "`variant` is `maxLTV / liquidation threshold / bonus`; `start LTV` is the absolute LTV at opening; "
         "`latency` is the liquidator's delay. Bad debt is the supplier loss as a percentage of the position's initial debt. "
         "`stuck` counts runs where the position was unhealthy at least once but nobody could or would liquidate it (debt below the "
         "liquidator's minimum); the number in brackets is how many of those were also insolvent (debt worth more than the collateral) at "
         "that moment: a loss nobody has recognised.\n\n";
    o << "| variant | max LTV / LT / bonus | start LTV | latency | N | liquidated [95% CI] | bad debt (runs) | bad debt %, mean / p99 / max | stuck (insolvent) |"
      << (hist ? " episodes |" : "") << "\n";
    o << "|---|---|---|---|---|---|---|---|---|" << (hist ? "---|" : "") << "\n";
    for (const Row& r : rows) {
      if (r.horizonDays != h) continue;
      o << "| " << r.variant << " | " << label(r) << " | " << pct(r.initialLtv, 1) << " | " << r.latencyHours << " h | "
        << r.n << " | " << pct(static_cast<double>(r.liquidated) / static_cast<double>(r.n), 1) << " ["
        << pct(r.pLiquidated.lo, 1) << ", " << pct(r.pLiquidated.hi, 1) << "] | " << r.badDebt << " ("
        << pct(static_cast<double>(r.badDebt) / static_cast<double>(r.n), 2) << ") | " << pct(r.badMean, 3) << " / "
        << pct(r.badP99, 2) << " / " << pct(r.badMax, 1) << " | " << r.stuck << " (" << r.stuckUnderwater << ") |";
      if (hist) o << " " << r.episodes << " |";
      o << "\n";
    }
    o << "\n";
    if (hist) {
      o << "*Windows overlap heavily, so they are NOT independent: the confidence interval assumes independence and is therefore "
           "too narrow. `episodes` counts distinct crash episodes (liquidated windows starting more than 7 days apart), which is the "
           "honest sample size behind the liquidation rate.*\n\n";
    }
  }

  if (hist) {
    std::set<int> years;
    for (const Row& r : rows) {
      for (const auto& y : r.byYear) years.insert(y.first);
    }
    o << "## Liquidated windows by start year (latency " << cfg.latencyHours.front() << " h, highest leverage)\n\n";
    for (int h : horizons) {
      o << "**" << h << "-day horizon** (liquidated / windows starting that year)\n\n| variant |";
      for (int y : years) o << " " << y << " |";
      o << "\n|---|";
      for (std::size_t i = 0; i < years.size(); ++i) o << "---|";
      o << "\n";
      std::set<std::string> done;
      // pick, per variant, the row with latency = first listed and the largest start LTV
      for (const Row& want : rows) {
        if (want.horizonDays != h || done.count(want.variant) != 0) continue;
        const Row* best = nullptr;
        for (const Row& r : rows) {
          if (r.horizonDays != h || r.variant != want.variant || r.latencyHours != cfg.latencyHours.front()) continue;
          if (best == nullptr || r.initialLtv > best->initialLtv) best = &r;
        }
        if (best == nullptr) continue;
        done.insert(want.variant);
        o << "| " << best->variant << " (" << pct(best->initialLtv, 0) << ") |";
        for (int y : years) {
          const auto it = best->byYear.find(y);
          if (it == best->byYear.end()) o << " - |";
          else o << " " << it->second.second << "/" << it->second.first << " |";
        }
        o << "\n";
      }
      o << "\n";
    }
  }
  return o.str();
}

std::string renderCsv(const std::vector<Row>& rows) {
  std::ostringstream o;
  o << "horizonDays,variant,maxLtv,liquidationThreshold,liquidationBonus,closeFactor,ltvFraction,initialLtv,latencyHours,"
       "n,unhealthy,liquidated,pLiquidated,pLiquidatedLo,pLiquidatedHi,badDebt,pBadDebt,stuck,stuckUnderwater,episodes,"
       "meanLiquidations,meanBorrowerCostPct,badMean,badP99,badMax,badCondMedian,medianMinHf,byYear\n";
  for (const Row& r : rows) {
    o << r.horizonDays << "," << r.variant << "," << fmt("%.4f", r.maxLtv) << "," << fmt("%.4f", r.liquidationThreshold) << ","
      << fmt("%.4f", r.liquidationBonus) << "," << fmt("%.4f", r.closeFactor) << "," << r.ltvFraction << ","
      << fmt("%.6f", r.initialLtv) << "," << r.latencyHours << "," << r.n << "," << r.unhealthy << "," << r.liquidated << ","
      << fmt("%.6f", static_cast<double>(r.liquidated) / static_cast<double>(r.n)) << "," << fmt("%.6f", r.pLiquidated.lo) << ","
      << fmt("%.6f", r.pLiquidated.hi) << "," << r.badDebt << ","
      << fmt("%.6f", static_cast<double>(r.badDebt) / static_cast<double>(r.n)) << "," << r.stuck << "," << r.stuckUnderwater << "," << r.episodes << ","
      << fmt("%.4f", r.meanLiquidations) << "," << fmt("%.6f", r.meanBorrowerCostPct) << "," << fmt("%.8f", r.badMean) << ","
      << fmt("%.8f", r.badP99) << "," << fmt("%.8f", r.badMax) << "," << fmt("%.8f", r.badCondMedian) << ","
      << fmt("%.6f", r.medianMinHf) << ",";
    bool first = true;
    for (const auto& y : r.byYear) {
      o << (first ? "" : ";") << y.first << ":" << y.second.second << "/" << y.second.first;
      first = false;
    }
    o << "\n";
  }
  return o.str();
}

}  // namespace sim
