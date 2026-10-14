// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {WAD} from "./Units.sol";

/// @title RiskMath
/// @notice Pure math for valuation, health factor, borrow limits and liquidation amounts.
/// @dev Units: prices are USD per WHOLE token, WAD-scaled (from `IOracle`); token amounts are in
///      base units; `*Decimals` are the token's decimals. USD values are WAD-scaled.
///
///      Rounding rules (against the user, for the protocol):
///        collateral value      : DOWN  (user is credited less)
///        debt value            : UP    (user is charged more)
///        borrow limit          : DOWN
///        collateral seized     : DOWN  (liquidator receives less; also keeps seizing <= collateral)
///        repay for given seize : UP    (liquidator pays more)
///        close-factor cap      : UP    (see `maxRepayable`: keeps tiny debts liquidatable)
library RiskMath {
    /*//////////////////////////////////////////////////////////////
                                  TYPES
    //////////////////////////////////////////////////////////////*/

    /// @notice Risk parameters, WAD-scaled ratios (0.75e18 = 75%).
    /// @param maxLtv Max debt/collateral value when borrowing or withdrawing collateral.
    /// @param liquidationThreshold Debt/collateral value at which a position becomes liquidatable.
    /// @param liquidationBonus Extra collateral value paid to the liquidator (0.05e18 = 5%).
    /// @param closeFactor Max share of a borrower's debt repayable in one liquidation.
    struct RiskParams {
        uint256 maxLtv;
        uint256 liquidationThreshold;
        uint256 liquidationBonus;
        uint256 closeFactor;
    }

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Sanity cap on the liquidation bonus (25%). The binding constraint is
    ///         `LT * (1 + bonus) < 1`; this just rejects unit mistakes.
    uint256 internal constant MAX_LIQUIDATION_BONUS = 0.25e18;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Violates 0 < maxLtv < liquidationThreshold < 1.
    error RiskMath__InvalidLtvOrThreshold(uint256 maxLtv, uint256 liquidationThreshold);
    /// @notice Bonus is zero or above MAX_LIQUIDATION_BONUS.
    error RiskMath__InvalidBonus(uint256 liquidationBonus);
    /// @notice Violates liquidationThreshold * (1 + bonus) < 1.
    error RiskMath__BonusTooHighForThreshold(
        uint256 liquidationThreshold, uint256 liquidationBonus
    );
    /// @notice Close factor is zero or above 100%.
    error RiskMath__InvalidCloseFactor(uint256 closeFactor);

    /*//////////////////////////////////////////////////////////////
                               VALIDATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Reverts unless `p` is a coherent parameter set. Call once at deployment.
    /// @dev Why `LT * (1 + bonus) < 1`: when a position sits exactly at the threshold its debt is
    ///      LT of its collateral value. Repaying debt D gives the liquidator D*(1+bonus) of
    ///      collateral; if LT*(1+bonus) >= 1, even a position that has JUST become liquidatable
    ///      holds less collateral than the liquidator is owed, so every liquidation would create
    ///      bad debt. Why `maxLtv < LT`: a buffer between "cannot borrow more" and "can be
    ///      liquidated", otherwise a position is liquidatable the instant it is opened.
    function validate(RiskParams memory p) internal pure {
        if (p.maxLtv == 0 || p.maxLtv >= p.liquidationThreshold || p.liquidationThreshold >= WAD) {
            revert RiskMath__InvalidLtvOrThreshold(p.maxLtv, p.liquidationThreshold);
        }
        if (p.liquidationBonus == 0 || p.liquidationBonus > MAX_LIQUIDATION_BONUS) {
            revert RiskMath__InvalidBonus(p.liquidationBonus);
        }
        if (p.liquidationThreshold * (WAD + p.liquidationBonus) >= WAD * WAD) {
            revert RiskMath__BonusTooHighForThreshold(p.liquidationThreshold, p.liquidationBonus);
        }
        if (p.closeFactor == 0 || p.closeFactor > WAD) {
            revert RiskMath__InvalidCloseFactor(p.closeFactor);
        }
    }

    /*//////////////////////////////////////////////////////////////
                               VALUATION
    //////////////////////////////////////////////////////////////*/

    /// @notice USD value (WAD) of a collateral amount, rounded DOWN.
    /// @dev value = floor(amount * price / 10**decimals)
    function collateralValueUsd(uint256 amount, uint256 priceWad, uint8 decimals)
        internal
        pure
        returns (uint256)
    {
        return Math.mulDiv(amount, priceWad, 10 ** decimals);
    }

    /// @notice USD value (WAD) of a debt amount, rounded UP.
    /// @dev value = ceil(amount * price / 10**decimals)
    function debtValueUsd(uint256 amount, uint256 priceWad, uint8 decimals)
        internal
        pure
        returns (uint256)
    {
        return Math.mulDiv(amount, priceWad, 10 ** decimals, Math.Rounding.Ceil);
    }

    /*//////////////////////////////////////////////////////////////
                             HEALTH FACTOR
    //////////////////////////////////////////////////////////////*/

    /// @notice Health factor, WAD-scaled: HF = collateralValue * LT / debtValue. Max uint if no debt.
    /// @dev Floored. The decision "HF < 1" is EXACT despite the floor: HF is a floor of
    ///      c*LT/d and 1e18 is an integer, so floor(c*LT/d) < 1e18  <=>  c*LT < d*1e18.
    /// @param collateralValue Collateral value (USD, WAD).
    /// @param debtValue Debt value (USD, WAD).
    /// @param liquidationThreshold LT, WAD.
    function healthFactor(uint256 collateralValue, uint256 debtValue, uint256 liquidationThreshold)
        internal
        pure
        returns (uint256)
    {
        if (debtValue == 0) return type(uint256).max;
        return Math.mulDiv(collateralValue, liquidationThreshold, debtValue);
    }

    /// @notice True iff HF < 1, i.e. the position may be liquidated.
    function isLiquidatable(
        uint256 collateralValue,
        uint256 debtValue,
        uint256 liquidationThreshold
    ) internal pure returns (bool) {
        return healthFactor(collateralValue, debtValue, liquidationThreshold) < WAD;
    }

    /// @notice Max debt value (USD, WAD) a position with `collateralValue` may carry: floor(c * LTV).
    function maxDebtValue(uint256 collateralValue, uint256 maxLtv) internal pure returns (uint256) {
        return Math.mulDiv(collateralValue, maxLtv, WAD);
    }

    /// @notice True iff `debtValue <= collateralValue * maxLtv`: the position may stand after a
    ///         borrow or a collateral withdrawal.
    function isWithinMaxLtv(uint256 collateralValue, uint256 debtValue, uint256 maxLtv)
        internal
        pure
        returns (bool)
    {
        return debtValue <= maxDebtValue(collateralValue, maxLtv);
    }

    /*//////////////////////////////////////////////////////////////
                              LIQUIDATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Max debt repayable in ONE liquidation: min(debt, ceil(debt * closeFactor)).
    /// @dev Rounded UP so a 1-wei debt (floor would give 0) can still be liquidated; with
    ///      closeFactor <= 1 the result never exceeds `debt`.
    function maxRepayable(uint256 debt, uint256 closeFactor) internal pure returns (uint256) {
        return Math.mulDiv(debt, closeFactor, WAD, Math.Rounding.Ceil);
    }

    /// @notice Collateral (base units) paid for repaying `repay` of debt, bonus included, DOWN.
    /// @dev seize = floor( repay * (1 + bonus) * debtPrice * 10**collDec
    ///                      / ( collPrice * 10**debtDec ) )
    ///      computed as one mulDiv so there is a single rounding step.
    /// @param repay Debt repaid (borrow-token base units).
    /// @param debtPriceWad Borrow-asset USD price (WAD).
    /// @param debtDecimals Borrow-token decimals.
    /// @param collPriceWad Collateral USD price (WAD).
    /// @param collDecimals Collateral-token decimals.
    /// @param bonus Liquidation bonus (WAD).
    function seizeForRepay(
        uint256 repay,
        uint256 debtPriceWad,
        uint8 debtDecimals,
        uint256 collPriceWad,
        uint8 collDecimals,
        uint256 bonus
    ) internal pure returns (uint256) {
        return Math.mulDiv(
            repay * (WAD + bonus),
            debtPriceWad * 10 ** collDecimals,
            collPriceWad * 10 ** debtDecimals * WAD
        );
    }

    /// @notice Debt repayment (base units) that corresponds to seizing `seize` collateral, UP.
    /// @dev Inverse of `seizeForRepay`; used when the borrower has less collateral than the
    ///      requested repayment would seize, to charge the liquidator only for what they get.
    ///      repay = ceil( seize * collPrice * 10**debtDec
    ///                   / ( debtPrice * (1 + bonus) * 10**collDec ) )
    function repayForSeize(
        uint256 seize,
        uint256 debtPriceWad,
        uint8 debtDecimals,
        uint256 collPriceWad,
        uint8 collDecimals,
        uint256 bonus
    ) internal pure returns (uint256) {
        return Math.mulDiv(
            seize,
            collPriceWad * 10 ** debtDecimals * WAD,
            debtPriceWad * (WAD + bonus) * 10 ** collDecimals,
            Math.Rounding.Ceil
        );
    }
}
