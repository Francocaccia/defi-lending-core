// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {InterestRateModel} from "./InterestRateModel.sol";
import {BorrowMath} from "./BorrowMath.sol";
import {RiskMath} from "./RiskMath.sol";

/// @title MarketMath
/// @notice Pure "kernels" that compose the lower-level libraries into the multi-step calculations
///         the market performs: interest accrual, repayment, liquidation and bad-debt write-off.
/// @dev These live outside `LendingMarket` on purpose: they take every input explicitly and touch
///      no storage, so the exact same procedure can be re-implemented independently (the C++
///      reference model, see docs/DESIGN.md section 9) and compared output-for-output. The market
///      keeps only the state changes, checks and token transfers.
library MarketMath {
    /// @notice Per-liquidation inputs that are not position-specific.
    /// @param collPrice Collateral USD price (WAD).
    /// @param debtPrice Borrow-asset USD price (WAD).
    /// @param collDecimals Collateral token decimals.
    /// @param debtDecimals Borrow token decimals.
    /// @param bonus Liquidation bonus (WAD).
    /// @param closeFactor Max share of the debt repayable in one liquidation (WAD).
    struct LiquidationParams {
        uint256 collPrice;
        uint256 debtPrice;
        uint8 collDecimals;
        uint8 debtDecimals;
        uint256 bonus;
        uint256 closeFactor;
    }

    /// @notice Interest accrual over `elapsed` seconds (DESIGN section 5.2).
    /// @dev The rate is evaluated at the utilization at the START of the interval. Suppliers are
    ///      credited exactly `interest`, the increase in the DERIVED total debt, so
    ///      `supply <= cash + debt` cannot be broken by rounding of the rate.
    /// @param totalScaledDebt Sum of all borrowers' scaled debt.
    /// @param totalSupplyAssets Assets owed to suppliers before the accrual.
    /// @param borrowIndex Current borrow index (RAY).
    /// @param elapsed Seconds since the last accrual.
    /// @param rate Validated rate model parameters.
    /// @return newIndex The borrow index after the accrual.
    /// @return interest Interest added to total borrows and to supplier assets.
    function accrue(
        uint256 totalScaledDebt,
        uint256 totalSupplyAssets,
        uint256 borrowIndex,
        uint256 elapsed,
        InterestRateModel.Params memory rate
    ) internal pure returns (uint256 newIndex, uint256 interest) {
        uint256 oldDebt = BorrowMath.debtFromScaled(totalScaledDebt, borrowIndex);
        uint256 u = InterestRateModel.utilization(totalSupplyAssets, oldDebt);
        uint256 ratePerSecond = InterestRateModel.borrowRatePerSecond(rate, u);

        newIndex = BorrowMath.accrueIndex(borrowIndex, ratePerSecond, elapsed);
        interest = BorrowMath.debtFromScaled(totalScaledDebt, newIndex) - oldDebt;
    }

    /// @notice Amounts for a repayment (DESIGN section 5.3). `assets` is a cap.
    /// @dev A full repayment (assets >= debt) burns ALL scaled debt; a partial one burns the
    ///      scaled equivalent rounded DOWN. `burned == 0` is possible for a tiny partial repayment
    ///      once the index is above 1.0; the caller rejects that.
    /// @param assets Max amount the payer is willing to pay.
    /// @param scaled The borrower's scaled debt (> 0).
    /// @param index Current borrow index (RAY).
    /// @return repaid Amount actually pulled from the payer.
    /// @return burned Scaled debt removed from the borrower.
    function repayAmounts(uint256 assets, uint256 scaled, uint256 index)
        internal
        pure
        returns (uint256 repaid, uint256 burned)
    {
        uint256 debt = BorrowMath.debtFromScaled(scaled, index);
        if (assets >= debt) return (debt, scaled);
        return (assets, BorrowMath.scaledFromAssetsDown(assets, index));
    }

    /// @notice Amounts for one liquidation (DESIGN section 7.1 - 7.3).
    /// @dev repaid = min(requested, maxRepayable(debt)); seized = seizeForRepay(repaid), capped
    ///      at `collateral`. When the cap binds, the liquidator is only charged for what it
    ///      receives: repaid = min(repaid, repayForSeize(collateral)). `burned` is the scaled
    ///      debt removed (all of it when repaid >= debt).
    /// @param scaled The borrower's scaled debt (> 0).
    /// @param index Current borrow index (RAY).
    /// @param requested Liquidator's repay cap (`type(uint256).max` = no cap).
    /// @param collateral The borrower's collateral amount.
    /// @param p Prices, decimals, bonus and close factor.
    /// @return repaid Debt repaid by the liquidator.
    /// @return seized Collateral received by the liquidator.
    /// @return burned Scaled debt removed from the borrower.
    function liquidationAmounts(
        uint256 scaled,
        uint256 index,
        uint256 requested,
        uint256 collateral,
        LiquidationParams memory p
    ) internal pure returns (uint256 repaid, uint256 seized, uint256 burned) {
        uint256 debt = BorrowMath.debtFromScaled(scaled, index);

        repaid = RiskMath.maxRepayable(debt, p.closeFactor);
        if (requested < repaid) repaid = requested;

        seized = RiskMath.seizeForRepay(
            repaid, p.debtPrice, p.debtDecimals, p.collPrice, p.collDecimals, p.bonus
        );
        if (seized > collateral) {
            seized = collateral;
            uint256 forSeize = RiskMath.repayForSeize(
                collateral, p.debtPrice, p.debtDecimals, p.collPrice, p.collDecimals, p.bonus
            );
            // Rounding up can overshoot by <= 1 unit; never charge more than was asked/allowed.
            if (forSeize < repaid) repaid = forSeize;
        }

        burned = repaid >= debt ? scaled : BorrowMath.scaledFromAssetsDown(repaid, index);
    }

    /// @notice Write-off of a borrower's remaining debt (DESIGN section 7.5).
    /// @dev The supplier loss is the DROP in derived total debt, not the borrower's own ceil'd
    ///      debt, which keeps `supply <= cash + debt` exact. The new supplier total saturates at
    ///      zero: a revert here would make liquidation impossible forever.
    /// @param totalScaledDebt Sum of all scaled debt BEFORE the write-off.
    /// @param borrowerScaled The borrower's scaled debt being removed.
    /// @param index Current borrow index (RAY).
    /// @param totalSupplyAssets Supplier assets before the write-off.
    /// @return debtWrittenOff The borrower's own debt (informational, for the event).
    /// @return loss Supplier loss = drop in derived total debt.
    /// @return newTotalSupplyAssets Supplier assets after the loss (saturating at 0).
    function badDebt(
        uint256 totalScaledDebt,
        uint256 borrowerScaled,
        uint256 index,
        uint256 totalSupplyAssets
    ) internal pure returns (uint256 debtWrittenOff, uint256 loss, uint256 newTotalSupplyAssets) {
        uint256 debtBefore = BorrowMath.debtFromScaled(totalScaledDebt, index);
        uint256 debtAfter = BorrowMath.debtFromScaled(totalScaledDebt - borrowerScaled, index);

        debtWrittenOff = BorrowMath.debtFromScaled(borrowerScaled, index);
        loss = debtBefore - debtAfter;
        newTotalSupplyAssets = loss >= totalSupplyAssets ? 0 : totalSupplyAssets - loss;
    }
}
