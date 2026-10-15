// One borrower position evolving along one price path, using the protocol's EXACT integer math
// (the independent reference model's functions, which were verified against the Solidity).
//
// The engine mirrors what the deployed market would do to ONE position:
//   open  : deposit collateral, borrow a fraction of the max-LTV limit (checked with the same
//           valuation rounding as `borrow`);
//   accrue: debt grows through the global borrow index, evaluated lazily (only when the position
//           is actually inspected, as the contract does);
//   check : health factor < 1 using the same collateral/debt valuation roundings;
//   liquidate: a liquidator repays up to the close factor after `latencySteps`, receiving
//           collateral + bonus; when all collateral is gone the rest is written off as BAD DEBT.
//
// A cheap floating-point screen skips steps that are obviously healthy; every DECISION (is the
// position unhealthy? how much is repaid/seized? is there bad debt?) is made with exact integers.
#pragma once

#include <cstddef>
#include <cstdint>

#include "uint256.hpp"

namespace sim {

using refmodel::U256;

struct ProtocolParams {
  U256 maxLtv;
  U256 liquidationThreshold;
  U256 liquidationBonus;
  U256 closeFactor;
  U256 baseRate;
  U256 slope1;
  U256 slope2;
  U256 optimalUtilization;
};

/// Applies the protocol's own deployment validation (throws refmodel::ModelError when invalid).
void validateProtocol(const ProtocolParams& p);

struct PolicyParams {
  /// Oracle steps between the position first being unhealthy and a liquidator acting
  /// (0 = in the same observation). The liquidator re-checks the position when it acts.
  std::size_t latencySteps = 0;
  /// A liquidator ignores positions whose debt value (USD, WAD) is below this (gas not worth it).
  /// Zero disables the filter.
  U256 minDebtValueUsd;
};

struct PositionSpec {
  U256 collateralWei;      // collateral amount (18 decimals)
  U256 ltvFractionOfMax;   // WAD: borrow this fraction of the max-LTV limit (1e18 = at the limit)
  U256 explicitDebtAssets; // if non-zero: borrow exactly this many USDC base units instead
};

struct RunResult {
  bool opened = false;          // false if nothing could be borrowed
  bool everUnhealthy = false;   // health factor < 1 at some inspection
  bool liquidated = false;      // at least one liquidation happened
  bool badDebt = false;         // collateral exhausted with debt left (written off)
  bool closed = false;          // position fully repaid or written off before the horizon
  bool stuck = false;           // unhealthy but not liquidated (dust filter / nothing to liquidate)
  std::uint32_t liquidations = 0;
  double initialDebtUsdc = 0.0;
  double initialCollateralUsd = 0.0;  // collateral value at opening (oracle price)
  double badDebtUsdc = 0.0;       // supplier loss written off
  double badDebtFraction = 0.0;   // badDebtUsdc / initialDebtUsdc
  double borrowerCostUsd = 0.0;   // collateral value seized minus debt value repaid
  double minHealthFactor = 0.0;   // approximate (screening precision), over all steps
  std::int64_t firstLiquidationStep = -1;
};

class Engine {
 public:
  /// `utilization` (WAD) fixes the market utilization used for the borrow rate: a modelling
  /// assumption, since one position does not move a whole market's utilization.
  Engine(const ProtocolParams& protocol, const U256& utilization, std::int64_t stepSeconds);

  /// `eth`/`usdc` are oracle answers (8 decimals), one per step; index 0 is the opening moment.
  RunResult run(const PositionSpec& spec, const PolicyParams& policy, const std::uint64_t* eth,
                const std::uint64_t* usdc, std::size_t n) const;

  const ProtocolParams& protocol() const { return p_; }

 private:
  ProtocolParams p_;
  U256 ratePerSecond_;  // RAY
  std::int64_t stepSeconds_;
  double ltD_;
  double ratePerSecondD_;
};

}  // namespace sim
