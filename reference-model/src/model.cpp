#include "model.hpp"

namespace refmodel {

// ---------------------------------------------------------------- 9.2 interest rate model

U256 utilization(const U256& supply, const U256& borrows) {
  if (supply.isZero()) return U256(0);
  if (borrows >= supply) return WAD;
  return mulDiv(borrows, WAD, supply);
}

U256 validateRateParams(const U256& base, const U256& slope1, const U256& slope2,
                        const U256& optimal) {
  if (optimal.isZero() || optimal >= WAD) throw ModelError("optimal utilization not in (0, WAD)");
  if (base > MAX_ANNUAL_RATE || slope1 > MAX_ANNUAL_RATE || slope2 > MAX_ANNUAL_RATE)
    throw ModelError("rate parameter above MAX_ANNUAL_RATE");
  return U256(1);
}

U256 annualBorrowRate(const U256& base, const U256& slope1, const U256& slope2,
                      const U256& optimal, const U256& u) {
  if (u > WAD) throw ModelError("utilization above WAD");
  if (u <= optimal) return base + mulDiv(slope1, u, optimal);
  return base + slope1 + mulDiv(slope2, u - optimal, WAD - optimal);
}

U256 borrowRatePerSecond(const U256& base, const U256& slope1, const U256& slope2,
                         const U256& optimal, const U256& u) {
  const U256 annual = annualBorrowRate(base, slope1, slope2, optimal, u);
  return (annual * WAD_TO_RAY) / SECONDS_PER_YEAR;
}

// ---------------------------------------------------------------- 9.3 index and scaled debt

U256 accrueIndex(const U256& index, const U256& ratePerSecond, const U256& dt) {
  const U256 t = ratePerSecond * dt;
  return index + mulDivUp(index, t, RAY);
}

U256 scaledFromAssetsUp(const U256& assets, const U256& index) {
  return mulDivUp(assets, RAY, index);
}

U256 scaledFromAssetsDown(const U256& assets, const U256& index) {
  return mulDiv(assets, RAY, index);
}

U256 debtFromScaled(const U256& scaled, const U256& index) {
  return mulDivUp(scaled, index, RAY);
}

// ---------------------------------------------------------------- 9.4 supplier shares

U256 toSharesDown(const U256& assets, const U256& totalAssets, const U256& totalShares) {
  return mulDiv(assets, totalShares + VIRTUAL_SHARES, totalAssets + VIRTUAL_ASSETS);
}

U256 toSharesUp(const U256& assets, const U256& totalAssets, const U256& totalShares) {
  return mulDivUp(assets, totalShares + VIRTUAL_SHARES, totalAssets + VIRTUAL_ASSETS);
}

U256 toAssetsDown(const U256& shares, const U256& totalAssets, const U256& totalShares) {
  return mulDiv(shares, totalAssets + VIRTUAL_ASSETS, totalShares + VIRTUAL_SHARES);
}

U256 toAssetsUp(const U256& shares, const U256& totalAssets, const U256& totalShares) {
  return mulDivUp(shares, totalAssets + VIRTUAL_ASSETS, totalShares + VIRTUAL_SHARES);
}

// ---------------------------------------------------------------- 9.5 valuation and limits

U256 collateralValueUsd(const U256& amount, const U256& priceWad, std::uint8_t decimals) {
  return mulDiv(amount, priceWad, pow10(decimals));
}

U256 debtValueUsd(const U256& amount, const U256& priceWad, std::uint8_t decimals) {
  return mulDivUp(amount, priceWad, pow10(decimals));
}

U256 healthFactor(const U256& collateralValue, const U256& debtValue,
                  const U256& liquidationThreshold) {
  if (debtValue.isZero()) return UINT256_MAX;
  return mulDiv(collateralValue, liquidationThreshold, debtValue);
}

U256 maxDebtValue(const U256& collateralValue, const U256& maxLtv) {
  return mulDiv(collateralValue, maxLtv, WAD);
}

U256 isWithinMaxLtv(const U256& collateralValue, const U256& debtValue, const U256& maxLtv) {
  return U256(debtValue <= maxDebtValue(collateralValue, maxLtv) ? 1 : 0);
}

U256 maxRepayable(const U256& debt, const U256& closeFactor) {
  return mulDivUp(debt, closeFactor, WAD);
}

U256 validateRiskParams(const U256& maxLtv, const U256& liquidationThreshold, const U256& bonus,
                        const U256& closeFactor) {
  // R1/R4: the products are evaluated even when an earlier check would already fail. Every
  // failure is the same failure, so the order of the checks below is irrelevant.
  const U256 lhs = liquidationThreshold * (WAD + bonus);
  const U256 rhs = WAD * WAD;
  if (maxLtv.isZero()) throw ModelError("maxLtv is zero");
  if (maxLtv >= liquidationThreshold) throw ModelError("maxLtv >= liquidationThreshold");
  if (liquidationThreshold >= WAD) throw ModelError("liquidationThreshold >= WAD");
  if (bonus.isZero()) throw ModelError("bonus is zero");
  if (bonus > MAX_LIQUIDATION_BONUS) throw ModelError("bonus above MAX_LIQUIDATION_BONUS");
  if (lhs >= rhs) throw ModelError("liquidationThreshold * (1 + bonus) >= 1");
  if (closeFactor.isZero()) throw ModelError("closeFactor is zero");
  if (closeFactor > WAD) throw ModelError("closeFactor above WAD");
  return U256(1);
}

// ---------------------------------------------------------------- 9.6 liquidation formulas

U256 seizeForRepay(const U256& repay, const U256& dp, std::uint8_t dd, const U256& cp,
                   std::uint8_t cd, const U256& bonus) {
  const U256 numeratorA = repay * (WAD + bonus);
  const U256 numeratorB = dp * pow10(cd);
  const U256 denominator = cp * pow10(dd) * WAD;  // (cp * 10**dd) * WAD
  return mulDiv(numeratorA, numeratorB, denominator);
}

U256 repayForSeize(const U256& seize, const U256& dp, std::uint8_t dd, const U256& cp,
                   std::uint8_t cd, const U256& bonus) {
  const U256 numeratorB = cp * pow10(dd) * WAD;                // (cp * 10**dd) * WAD
  const U256 denominator = dp * (WAD + bonus) * pow10(cd);     // (dp * (WAD + bonus)) * 10**cd
  return mulDivUp(seize, numeratorB, denominator);
}

// ---------------------------------------------------------------- 9.7 market kernels

AccrueResult accrue(const U256& totalScaledDebt, const U256& totalSupplyAssets,
                    const U256& borrowIndex, const U256& elapsed, const U256& base,
                    const U256& slope1, const U256& slope2, const U256& optimal) {
  const U256 oldDebt = debtFromScaled(totalScaledDebt, borrowIndex);
  const U256 u = utilization(totalSupplyAssets, oldDebt);
  const U256 r = borrowRatePerSecond(base, slope1, slope2, optimal, u);
  const U256 newIndex = accrueIndex(borrowIndex, r, elapsed);
  const U256 interest = debtFromScaled(totalScaledDebt, newIndex) - oldDebt;
  return {newIndex, interest};
}

RepayResult repayAmounts(const U256& assets, const U256& scaled, const U256& index) {
  const U256 debt = debtFromScaled(scaled, index);
  if (assets >= debt) return {debt, scaled};
  return {assets, scaledFromAssetsDown(assets, index)};
}

LiquidationResult liquidationAmounts(const U256& scaled, const U256& index, const U256& requested,
                                     const U256& collateral, const U256& cp, const U256& dp,
                                     std::uint8_t cd, std::uint8_t dd, const U256& bonus,
                                     const U256& closeFactor) {
  const U256 debt = debtFromScaled(scaled, index);
  U256 repaid = maxRepayable(debt, closeFactor);
  if (requested < repaid) repaid = requested;
  U256 seized = seizeForRepay(repaid, dp, dd, cp, cd, bonus);
  if (seized > collateral) {
    seized = collateral;
    const U256 forSeize = repayForSeize(collateral, dp, dd, cp, cd, bonus);
    if (forSeize < repaid) repaid = forSeize;
  }
  const U256 burned = (repaid >= debt) ? scaled : scaledFromAssetsDown(repaid, index);
  return {repaid, seized, burned};
}

BadDebtResult badDebt(const U256& totalScaledDebt, const U256& borrowerScaled, const U256& index,
                      const U256& totalSupplyAssets) {
  const U256 debtBefore = debtFromScaled(totalScaledDebt, index);
  const U256 debtAfter = debtFromScaled(totalScaledDebt - borrowerScaled, index);
  const U256 debtWrittenOff = debtFromScaled(borrowerScaled, index);
  const U256 loss = debtBefore - debtAfter;
  const U256 newSupply =
      (loss >= totalSupplyAssets) ? U256(0) : (totalSupplyAssets - loss);
  return {debtWrittenOff, loss, newSupply};
}

}  // namespace refmodel
