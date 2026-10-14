// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {WAD, WAD_TO_RAY, SECONDS_PER_YEAR} from "./Units.sol";

/// @title InterestRateModel
/// @notice Pure, kinked ("two-slope") utilization-based borrow rate model.
/// @dev All functions are `pure` and take every input explicitly, so the exact same math can be
///      re-implemented and differential-tested off-chain (docs/DESIGN.md section 3).
///
///      Shape (annual rate as a function of utilization U, with optimal utilization K):
///
///        rate
///         ^                              /  slope2 (steep)
///         |                            /
///         |                          /
///         |              ___------/   <- kink at U = K: rate = base + slope1
///         |      ___---'
///         | base
///         +--------------------------|----> U
///        0                           K   1
///
///      Below K the rate rises linearly by `slope1` in total; above K it rises linearly by a
///      further `slope2` in total (reaching base + slope1 + slope2 at U = 100%). The steep upper
///      segment is what pushes utilization back down when liquidity runs short.
///
///      Rounding: every division here floors. This is safe for solvency because suppliers are
///      credited exactly the interest that borrowers are charged (see DESIGN.md), so rounding
///      the RATE in either direction cannot create a deficit; flooring everywhere also keeps the
///      function monotone, which the fuzz tests rely on.
library InterestRateModel {
    /*//////////////////////////////////////////////////////////////
                                  TYPES
    //////////////////////////////////////////////////////////////*/

    /// @notice Rate model parameters. All values are annual and WAD-scaled (1e18 = 100%).
    /// @param baseRate Borrow rate at 0% utilization.
    /// @param slope1 Total rate increase from 0% utilization up to `optimalUtilization`.
    /// @param slope2 Total rate increase from `optimalUtilization` up to 100% utilization.
    /// @param optimalUtilization The kink U*, in (0, 1) exclusive.
    struct Params {
        uint256 baseRate;
        uint256 slope1;
        uint256 slope2;
        uint256 optimalUtilization;
    }

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Sanity cap for each of base/slope1/slope2: 1000% APR. Rejects obviously wrong
    ///         units (e.g. a percent passed as 75 instead of 0.75e18) at deploy time.
    uint256 internal constant MAX_ANNUAL_RATE = 10 * WAD;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice `optimalUtilization` must satisfy 0 < optimal < 1e18.
    error InterestRateModel__InvalidOptimalUtilization(uint256 optimalUtilization);
    /// @notice A rate parameter exceeds `MAX_ANNUAL_RATE`.
    error InterestRateModel__RateTooHigh(uint256 rate);
    /// @notice Utilization above 100% was passed to the rate function.
    error InterestRateModel__InvalidUtilization(uint256 utilization);

    /*//////////////////////////////////////////////////////////////
                               VALIDATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Reverts unless `p` is a usable parameter set. Call once at deployment.
    /// @dev Why these checks: `optimalUtilization` is a divisor in both segments (U* for the
    ///      lower one, 1 - U* for the upper one), so it must be strictly inside (0, 1). The rate
    ///      caps only catch unit mistakes; they are not an economic recommendation.
    ///      `slope2 >= slope1` is deliberately NOT enforced: an unusual curve is a modelling
    ///      choice, not a safety problem.
    function validate(Params memory p) internal pure {
        if (p.optimalUtilization == 0 || p.optimalUtilization >= WAD) {
            revert InterestRateModel__InvalidOptimalUtilization(p.optimalUtilization);
        }
        if (p.baseRate > MAX_ANNUAL_RATE) revert InterestRateModel__RateTooHigh(p.baseRate);
        if (p.slope1 > MAX_ANNUAL_RATE) revert InterestRateModel__RateTooHigh(p.slope1);
        if (p.slope2 > MAX_ANNUAL_RATE) revert InterestRateModel__RateTooHigh(p.slope2);
    }

    /*//////////////////////////////////////////////////////////////
                               UTILIZATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Utilization = borrowed / supplied, WAD-scaled, floored, capped at 100%.
    /// @dev `totalSupplyAssets` is everything suppliers are owed (idle cash + outstanding
    ///      borrows, interest included), so U = borrows / (cash + borrows). Cap at 1e18: after a
    ///      bad-debt write-off or rounding, borrows could momentarily meet/exceed supply, and
    ///      the rate curve is only defined on [0, 1].
    /// @param totalSupplyAssets Total assets owed to suppliers (borrow-asset base units).
    /// @param totalBorrowAssets Total outstanding borrows (borrow-asset base units).
    /// @return utilization_ Utilization in WAD, in [0, 1e18].
    function utilization(uint256 totalSupplyAssets, uint256 totalBorrowAssets)
        internal
        pure
        returns (uint256 utilization_)
    {
        if (totalSupplyAssets == 0) return 0;
        if (totalBorrowAssets >= totalSupplyAssets) return WAD;
        return Math.mulDiv(totalBorrowAssets, WAD, totalSupplyAssets);
    }

    /*//////////////////////////////////////////////////////////////
                                  RATES
    //////////////////////////////////////////////////////////////*/

    /// @notice Annual borrow rate at utilization `u`, WAD-scaled (0.05e18 = 5% APR).
    /// @dev   u <= K : rate = base + floor(slope1 * u / K)
    ///        u >  K : rate = base + slope1 + floor(slope2 * (u - K) / (1 - K))
    ///      Continuous at the kink (both give base + slope1 at u = K), non-decreasing in `u`,
    ///      and bounded by [base, base + slope1 + slope2].
    ///      PRECONDITION: `p` passed `validate` (otherwise K = 0 or K = 1 divides by zero).
    /// @param p Validated model parameters.
    /// @param u Utilization in WAD, must be <= 1e18.
    /// @return rate Annual borrow rate in WAD.
    function annualBorrowRate(Params memory p, uint256 u) internal pure returns (uint256 rate) {
        if (u > WAD) revert InterestRateModel__InvalidUtilization(u);

        if (u <= p.optimalUtilization) {
            return p.baseRate + Math.mulDiv(p.slope1, u, p.optimalUtilization);
        }
        return p.baseRate + p.slope1
            + Math.mulDiv(p.slope2, u - p.optimalUtilization, WAD - p.optimalUtilization);
    }

    /// @notice Per-second borrow rate at utilization `u`, RAY-scaled.
    /// @dev   ratePerSecond = floor(annualRateWad * 1e9 / SECONDS_PER_YEAR)
    ///      The 1e9 lifts WAD to RAY BEFORE dividing by the (large) seconds-per-year so the
    ///      division keeps ~27 digits of precision instead of ~18. The index accrual (M3) uses
    ///      this value as `index += index * ratePerSecond * dt / RAY`.
    /// @param p Validated model parameters.
    /// @param u Utilization in WAD, must be <= 1e18.
    /// @return ratePerSecond Borrow rate per second, RAY-scaled.
    function borrowRatePerSecond(Params memory p, uint256 u)
        internal
        pure
        returns (uint256 ratePerSecond)
    {
        // annual <= 3 * MAX_ANNUAL_RATE = 3e19, so annual * 1e9 < 2^256 with huge margin.
        return annualBorrowRate(p, u) * WAD_TO_RAY / SECONDS_PER_YEAR;
    }
}
