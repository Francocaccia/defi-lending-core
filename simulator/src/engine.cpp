#include "engine.hpp"

#include <algorithm>
#include <limits>

#include "model.hpp"
#include "units.hpp"

namespace sim {

namespace {

constexpr std::uint8_t kCollDecimals = 18;  // WETH
constexpr std::uint8_t kDebtDecimals = 6;   // USDC

// Chainlink USD feeds have 8 decimals; the protocol's oracle wrapper normalizes to 18 (x 1e10).
U256 priceWad(std::uint64_t answer) { return U256(answer) * U256(10000000000ULL); }

}  // namespace

void validateProtocol(const ProtocolParams& p) {
  refmodel::validateRiskParams(p.maxLtv, p.liquidationThreshold, p.liquidationBonus,
                               p.closeFactor);
  refmodel::validateRateParams(p.baseRate, p.slope1, p.slope2, p.optimalUtilization);
}

Engine::Engine(const ProtocolParams& protocol, const U256& utilization, std::int64_t stepSeconds)
    : p_(protocol), stepSeconds_(stepSeconds) {
  validateProtocol(p_);
  ratePerSecond_ = refmodel::borrowRatePerSecond(p_.baseRate, p_.slope1, p_.slope2,
                                                 p_.optimalUtilization, utilization);
  ltD_ = toDouble(p_.liquidationThreshold) / 1e18;
  ratePerSecondD_ = toDouble(ratePerSecond_) / 1e27;
}

RunResult Engine::run(const PositionSpec& spec, const PolicyParams& policy,
                      const std::uint64_t* eth, const std::uint64_t* usdc, std::size_t n) const {
  using namespace refmodel;
  RunResult r;
  r.minHealthFactor = std::numeric_limits<double>::infinity();
  if (n == 0) return r;

  // ---- open the position (same valuation roundings as the market's `borrow`) -------------------
  U256 coll = spec.collateralWei;
  const U256 pc0 = priceWad(eth[0]);
  const U256 pb0 = priceWad(usdc[0]);
  U256 debtAssets;
  if (!spec.explicitDebtAssets.isZero()) {
    debtAssets = spec.explicitDebtAssets;
  } else {
    const U256 collValue = collateralValueUsd(coll, pc0, kCollDecimals);
    const U256 limit = maxDebtValue(collValue, p_.maxLtv);
    const U256 targetValue = mulDiv(limit, spec.ltvFractionOfMax, WAD);
    debtAssets = mulDiv(targetValue, pow10(kDebtDecimals), pb0);
    // Rounding in `borrow` is against the borrower (debt value rounds UP): step down until the
    // exact check passes, as the contract would reject anything above the limit.
    while (!debtAssets.isZero() &&
           isWithinMaxLtv(collValue, debtValueUsd(debtAssets, pb0, kDebtDecimals), p_.maxLtv)
               .isZero()) {
      debtAssets = debtAssets - U256(1);
    }
  }
  if (debtAssets.isZero()) return r;
  r.opened = true;
  r.initialDebtUsdc = toDouble(debtAssets) / 1e6;
  r.initialCollateralUsd = toDouble(coll) / 1e18 * (static_cast<double>(eth[0]) / 1e8);

  U256 scaled = scaledFromAssetsUp(debtAssets, RAY);
  U256 index = RAY;
  std::size_t lastAccrual = 0;

  double collEth = toDouble(coll) / 1e18;
  double debtLastUsdc = toDouble(debtFromScaled(scaled, index)) / 1e6;

  bool pending = false;
  std::size_t pendingStep = 0;
  const U256 supplyBig = pow10(30);

  for (std::size_t k = 1; k < n; ++k) {
    // ---- cheap screen (floating point; never used for a decision) ------------------------------
    const double elapsedSec = static_cast<double>(k - lastAccrual) * static_cast<double>(stepSeconds_);
    const double debtNow = debtLastUsdc * (1.0 + ratePerSecondD_ * elapsedSec);
    const double hfApprox = collEth * (static_cast<double>(eth[k]) / 1e8) * ltD_ /
                            (debtNow * (static_cast<double>(usdc[k]) / 1e8));
    if (hfApprox < r.minHealthFactor) r.minHealthFactor = hfApprox;

    if (pending && k < pendingStep) continue;  // a liquidator is on its way: nothing to decide yet
    if (!pending && hfApprox > 1.0 + 1e-9) continue;  // obviously healthy

    // ---- exact inspection (lazy accrual, like a contract interaction) --------------------------
    index = accrueIndex(index, ratePerSecond_,
                        U256(static_cast<std::uint64_t>(k - lastAccrual) *
                             static_cast<std::uint64_t>(stepSeconds_)));
    lastAccrual = k;
    const U256 debt = debtFromScaled(scaled, index);
    debtLastUsdc = toDouble(debt) / 1e6;

    const U256 pc = priceWad(eth[k]);
    const U256 pb = priceWad(usdc[k]);
    const U256 collValue = collateralValueUsd(coll, pc, kCollDecimals);
    const U256 debtValue = debtValueUsd(debt, pb, kDebtDecimals);
    const bool unhealthy = healthFactor(collValue, debtValue, p_.liquidationThreshold) < WAD;
    if (!unhealthy) {
      pending = false;  // price recovered before the liquidator acted
      continue;
    }

    r.everUnhealthy = true;
    if (!pending) {
      pending = true;
      pendingStep = k + policy.latencySteps;
    }
    if (k < pendingStep) continue;
    pending = false;  // the liquidator acts now

    if (!policy.minDebtValueUsd.isZero() && debtValue < policy.minDebtValueUsd) {
      r.stuck = true;  // not worth the gas for anyone: the position just stays unhealthy
      continue;
    }

    const LiquidationResult lq = liquidationAmounts(scaled, index, UINT256_MAX, coll, pc, pb,
                                                    kCollDecimals, kDebtDecimals,
                                                    p_.liquidationBonus, p_.closeFactor);
    // The market's own rejection rule (NothingToLiquidate).
    const bool takesAll = lq.seized == coll;
    if (lq.repaid.isZero() || lq.seized.isZero() || (lq.burned.isZero() && !takesAll)) {
      r.stuck = true;
      continue;
    }

    scaled = scaled - lq.burned;
    coll = coll - lq.seized;
    ++r.liquidations;
    if (!r.liquidated) {
      r.liquidated = true;
      r.firstLiquidationStep = static_cast<std::int64_t>(k);
    }
    r.borrowerCostUsd += toDouble(lq.seized) / 1e18 * (static_cast<double>(eth[k]) / 1e8) -
                         toDouble(lq.repaid) / 1e6 * (static_cast<double>(usdc[k]) / 1e8);

    if (coll.isZero() && !scaled.isZero()) {
      const BadDebtResult bd = badDebt(scaled, scaled, index, supplyBig);
      r.badDebt = true;
      r.badDebtUsdc = toDouble(bd.loss) / 1e6;
      r.badDebtFraction = r.initialDebtUsdc > 0.0 ? r.badDebtUsdc / r.initialDebtUsdc : 0.0;
      r.closed = true;
      break;
    }
    if (scaled.isZero()) {
      r.closed = true;
      break;
    }
    collEth = toDouble(coll) / 1e18;
    debtLastUsdc = toDouble(debtFromScaled(scaled, index)) / 1e6;
  }
  if (r.minHealthFactor == std::numeric_limits<double>::infinity()) r.minHealthFactor = 0.0;
  return r;
}

}  // namespace sim
