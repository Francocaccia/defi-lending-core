// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {InterestRateModel} from "../../src/libraries/InterestRateModel.sol";
import {BorrowMath} from "../../src/libraries/BorrowMath.sol";
import {SharesMath} from "../../src/libraries/SharesMath.sol";
import {RiskMath} from "../../src/libraries/RiskMath.sol";
import {MarketMath} from "../../src/libraries/MarketMath.sol";

/// @notice Every pure function that the C++ reference model re-implements, exposed with FLAT
///         `uint256` arguments in EXACTLY the order of the reference-model CLI
///         (docs/M8_HANDOFF.md). The function names equal the CLI function names.
///
///         The differential tests call these and the C++ binary with the same inputs and demand:
///           - both revert / exit non-zero, or
///           - both succeed with identical outputs (every returned word, in order).
///
///         Notes for readers of the spec:
///           - `uint8` parameters (`decimals`) are the types used by the library functions.
///           - Functions are deliberately called WITHOUT prior validation of rate/risk
///             parameters, so unvalidated inputs (divide by zero, underflow, overflow) are
///             compared too. `validateRateParams` / `validateRiskParams` expose validation itself.
contract DiffHarness {
    /*//////////////////////////////////////////////////////////////
                             INTEREST RATE MODEL
    //////////////////////////////////////////////////////////////*/

    function utilization(uint256 supply, uint256 borrows) external pure returns (uint256) {
        return InterestRateModel.utilization(supply, borrows);
    }

    /// @return ok Always 1 when it does not revert.
    function validateRateParams(uint256 base, uint256 slope1, uint256 slope2, uint256 optimal)
        external
        pure
        returns (uint256 ok)
    {
        InterestRateModel.validate(_rate(base, slope1, slope2, optimal));
        return 1;
    }

    function annualBorrowRate(
        uint256 base,
        uint256 slope1,
        uint256 slope2,
        uint256 optimal,
        uint256 u
    ) external pure returns (uint256) {
        return InterestRateModel.annualBorrowRate(_rate(base, slope1, slope2, optimal), u);
    }

    function borrowRatePerSecond(
        uint256 base,
        uint256 slope1,
        uint256 slope2,
        uint256 optimal,
        uint256 u
    ) external pure returns (uint256) {
        return InterestRateModel.borrowRatePerSecond(_rate(base, slope1, slope2, optimal), u);
    }

    /*//////////////////////////////////////////////////////////////
                              BORROW INDEX
    //////////////////////////////////////////////////////////////*/

    function accrueIndex(uint256 index, uint256 ratePerSecond, uint256 dt)
        external
        pure
        returns (uint256)
    {
        return BorrowMath.accrueIndex(index, ratePerSecond, dt);
    }

    function scaledFromAssetsUp(uint256 assets, uint256 index) external pure returns (uint256) {
        return BorrowMath.scaledFromAssetsUp(assets, index);
    }

    function scaledFromAssetsDown(uint256 assets, uint256 index) external pure returns (uint256) {
        return BorrowMath.scaledFromAssetsDown(assets, index);
    }

    function debtFromScaled(uint256 scaled, uint256 index) external pure returns (uint256) {
        return BorrowMath.debtFromScaled(scaled, index);
    }

    /*//////////////////////////////////////////////////////////////
                                 SHARES
    //////////////////////////////////////////////////////////////*/

    function toSharesDown(uint256 assets, uint256 totalAssets, uint256 totalShares)
        external
        pure
        returns (uint256)
    {
        return SharesMath.toSharesDown(assets, totalAssets, totalShares);
    }

    function toSharesUp(uint256 assets, uint256 totalAssets, uint256 totalShares)
        external
        pure
        returns (uint256)
    {
        return SharesMath.toSharesUp(assets, totalAssets, totalShares);
    }

    function toAssetsDown(uint256 shares, uint256 totalAssets, uint256 totalShares)
        external
        pure
        returns (uint256)
    {
        return SharesMath.toAssetsDown(shares, totalAssets, totalShares);
    }

    function toAssetsUp(uint256 shares, uint256 totalAssets, uint256 totalShares)
        external
        pure
        returns (uint256)
    {
        return SharesMath.toAssetsUp(shares, totalAssets, totalShares);
    }

    /*//////////////////////////////////////////////////////////////
                                  RISK
    //////////////////////////////////////////////////////////////*/

    function collateralValueUsd(uint256 amount, uint256 priceWad, uint8 decimals)
        external
        pure
        returns (uint256)
    {
        return RiskMath.collateralValueUsd(amount, priceWad, decimals);
    }

    function debtValueUsd(uint256 amount, uint256 priceWad, uint8 decimals)
        external
        pure
        returns (uint256)
    {
        return RiskMath.debtValueUsd(amount, priceWad, decimals);
    }

    function healthFactor(uint256 collateralValue, uint256 debtValue, uint256 liquidationThreshold)
        external
        pure
        returns (uint256)
    {
        return RiskMath.healthFactor(collateralValue, debtValue, liquidationThreshold);
    }

    function maxDebtValue(uint256 collateralValue, uint256 maxLtv) external pure returns (uint256) {
        return RiskMath.maxDebtValue(collateralValue, maxLtv);
    }

    /// @return 1 if within the limit, else 0.
    function isWithinMaxLtv(uint256 collateralValue, uint256 debtValue, uint256 maxLtv)
        external
        pure
        returns (uint256)
    {
        return RiskMath.isWithinMaxLtv(collateralValue, debtValue, maxLtv) ? 1 : 0;
    }

    function maxRepayable(uint256 debt, uint256 closeFactor) external pure returns (uint256) {
        return RiskMath.maxRepayable(debt, closeFactor);
    }

    function seizeForRepay(
        uint256 repay,
        uint256 debtPriceWad,
        uint8 debtDecimals,
        uint256 collPriceWad,
        uint8 collDecimals,
        uint256 bonus
    ) external pure returns (uint256) {
        return RiskMath.seizeForRepay(
            repay, debtPriceWad, debtDecimals, collPriceWad, collDecimals, bonus
        );
    }

    function repayForSeize(
        uint256 seize,
        uint256 debtPriceWad,
        uint8 debtDecimals,
        uint256 collPriceWad,
        uint8 collDecimals,
        uint256 bonus
    ) external pure returns (uint256) {
        return RiskMath.repayForSeize(
            seize, debtPriceWad, debtDecimals, collPriceWad, collDecimals, bonus
        );
    }

    /// @return ok Always 1 when it does not revert.
    function validateRiskParams(
        uint256 maxLtv,
        uint256 liquidationThreshold,
        uint256 bonus,
        uint256 closeFactor
    ) external pure returns (uint256 ok) {
        RiskMath.validate(
            RiskMath.RiskParams({
                maxLtv: maxLtv,
                liquidationThreshold: liquidationThreshold,
                liquidationBonus: bonus,
                closeFactor: closeFactor
            })
        );
        return 1;
    }

    /*//////////////////////////////////////////////////////////////
                            MARKET KERNELS
    //////////////////////////////////////////////////////////////*/

    function accrue(
        uint256 totalScaledDebt,
        uint256 totalSupplyAssets,
        uint256 borrowIndex,
        uint256 elapsed,
        uint256 base,
        uint256 slope1,
        uint256 slope2,
        uint256 optimal
    ) external pure returns (uint256 newIndex, uint256 interest) {
        return MarketMath.accrue(
            totalScaledDebt,
            totalSupplyAssets,
            borrowIndex,
            elapsed,
            _rate(base, slope1, slope2, optimal)
        );
    }

    function repayAmounts(uint256 assets, uint256 scaled, uint256 index)
        external
        pure
        returns (uint256 repaid, uint256 burned)
    {
        return MarketMath.repayAmounts(assets, scaled, index);
    }

    function liquidationAmounts(
        uint256 scaled,
        uint256 index,
        uint256 requested,
        uint256 collateral,
        uint256 collPrice,
        uint256 debtPrice,
        uint8 collDecimals,
        uint8 debtDecimals,
        uint256 bonus,
        uint256 closeFactor
    ) external pure returns (uint256 repaid, uint256 seized, uint256 burned) {
        return MarketMath.liquidationAmounts(
            scaled,
            index,
            requested,
            collateral,
            MarketMath.LiquidationParams({
                collPrice: collPrice,
                debtPrice: debtPrice,
                collDecimals: collDecimals,
                debtDecimals: debtDecimals,
                bonus: bonus,
                closeFactor: closeFactor
            })
        );
    }

    function badDebt(
        uint256 totalScaledDebt,
        uint256 borrowerScaled,
        uint256 index,
        uint256 totalSupplyAssets
    ) external pure returns (uint256 debtWrittenOff, uint256 loss, uint256 newTotalSupplyAssets) {
        return MarketMath.badDebt(totalScaledDebt, borrowerScaled, index, totalSupplyAssets);
    }

    /*//////////////////////////////////////////////////////////////
                                 HELPERS
    //////////////////////////////////////////////////////////////*/

    function _rate(uint256 base, uint256 slope1, uint256 slope2, uint256 optimal)
        private
        pure
        returns (InterestRateModel.Params memory)
    {
        return InterestRateModel.Params({
            baseRate: base, slope1: slope1, slope2: slope2, optimalUtilization: optimal
        });
    }
}
