// The protocol's pure math, re-implemented from docs/DESIGN.md section 9 ONLY.
//
// Each function is a transcription of its row in the spec. Rules R1-R4 hold by construction:
//  - every `+ - *` on U256 is checked (R1) and throws ModelError;
//  - every operand is evaluated before the operation runs, because C++ evaluates arguments
//    eagerly (R4); `?:` and `if/else` evaluate only the taken branch, as the spec requires;
//  - products are written left-associative, exactly as in the spec (R5);
//  - rate / risk parameters are NOT validated by the functions that use them (R7).
#pragma once

#include <cstdint>

#include "uint256.hpp"

namespace refmodel {

// R6 constants
inline const U256 WAD = U256(1000000000000000000ULL);  // 1e18
inline const U256 RAY = pow10(27);                      // 1e27
inline const U256 WAD_TO_RAY = U256(1000000000ULL);     // 1e9
inline const U256 SECONDS_PER_YEAR = U256(31536000ULL);
inline const U256 VIRTUAL_SHARES = U256(1000000ULL);
inline const U256 VIRTUAL_ASSETS = U256(1);
inline const U256 MAX_ANNUAL_RATE = U256(10) * WAD;
inline const U256 MAX_LIQUIDATION_BONUS = U256(250000000000000000ULL);  // 0.25 WAD
// (UINT_MAX in the spec; renamed because <limits.h> defines a macro of that name)
inline const U256 UINT256_MAX = U256::max();

// 9.2 interest rate model
U256 utilization(const U256& supply, const U256& borrows);
U256 validateRateParams(const U256& base, const U256& slope1, const U256& slope2,
                        const U256& optimal);
U256 annualBorrowRate(const U256& base, const U256& slope1, const U256& slope2,
                      const U256& optimal, const U256& u);
U256 borrowRatePerSecond(const U256& base, const U256& slope1, const U256& slope2,
                         const U256& optimal, const U256& u);

// 9.3 borrow index and scaled debt
U256 accrueIndex(const U256& index, const U256& ratePerSecond, const U256& dt);
U256 scaledFromAssetsUp(const U256& assets, const U256& index);
U256 scaledFromAssetsDown(const U256& assets, const U256& index);
U256 debtFromScaled(const U256& scaled, const U256& index);

// 9.4 supplier shares
U256 toSharesDown(const U256& assets, const U256& totalAssets, const U256& totalShares);
U256 toSharesUp(const U256& assets, const U256& totalAssets, const U256& totalShares);
U256 toAssetsDown(const U256& shares, const U256& totalAssets, const U256& totalShares);
U256 toAssetsUp(const U256& shares, const U256& totalAssets, const U256& totalShares);

// 9.5 valuation, health factor, limits. `decimals` is a uint8 in the Solidity.
U256 collateralValueUsd(const U256& amount, const U256& priceWad, std::uint8_t decimals);
U256 debtValueUsd(const U256& amount, const U256& priceWad, std::uint8_t decimals);
U256 healthFactor(const U256& collateralValue, const U256& debtValue,
                  const U256& liquidationThreshold);
U256 maxDebtValue(const U256& collateralValue, const U256& maxLtv);
U256 isWithinMaxLtv(const U256& collateralValue, const U256& debtValue, const U256& maxLtv);
U256 maxRepayable(const U256& debt, const U256& closeFactor);
U256 validateRiskParams(const U256& maxLtv, const U256& liquidationThreshold, const U256& bonus,
                        const U256& closeFactor);

// 9.6 liquidation formulas (debt asset first: dp/dd, then collateral asset: cp/cd)
U256 seizeForRepay(const U256& repay, const U256& dp, std::uint8_t dd, const U256& cp,
                   std::uint8_t cd, const U256& bonus);
U256 repayForSeize(const U256& seize, const U256& dp, std::uint8_t dd, const U256& cp,
                   std::uint8_t cd, const U256& bonus);

// 9.7 market kernels
struct AccrueResult {
  U256 newIndex;
  U256 interest;
};
AccrueResult accrue(const U256& totalScaledDebt, const U256& totalSupplyAssets,
                    const U256& borrowIndex, const U256& elapsed, const U256& base,
                    const U256& slope1, const U256& slope2, const U256& optimal);

struct RepayResult {
  U256 repaid;
  U256 burned;
};
RepayResult repayAmounts(const U256& assets, const U256& scaled, const U256& index);

struct LiquidationResult {
  U256 repaid;
  U256 seized;
  U256 burned;
};
// NOTE the argument order: collateral price/decimals (cp, cd) BEFORE debt ones (dp, dd).
LiquidationResult liquidationAmounts(const U256& scaled, const U256& index, const U256& requested,
                                     const U256& collateral, const U256& cp, const U256& dp,
                                     std::uint8_t cd, std::uint8_t dd, const U256& bonus,
                                     const U256& closeFactor);

struct BadDebtResult {
  U256 debtWrittenOff;
  U256 loss;
  U256 newTotalSupplyAssets;
};
BadDebtResult badDebt(const U256& totalScaledDebt, const U256& borrowerScaled, const U256& index,
                      const U256& totalSupplyAssets);

}  // namespace refmodel
