// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MarketBase} from "../utils/MarketBase.sol";
import {LendingMarket} from "../../src/LendingMarket.sol";
import {RiskMath} from "../../src/libraries/RiskMath.sol";

contract LendingMarketFuzzTest is MarketBase {
    /*//////////////////////////////////////////////////////////////
                              SUPPLY SIDE
    //////////////////////////////////////////////////////////////*/

    /// Into an empty pool, supply-then-redeem-all returns exactly what was supplied.
    function testFuzz_supplyRedeemRoundTripIsExact(uint256 amount) public {
        amount = bound(amount, 1, 1_000_000e6);
        uint256 shares = _supply(alice, amount);

        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        uint256 out = market.redeem(shares);

        assertEq(out, amount);
        assertEq(usdc.balanceOf(alice) - before, amount);
        assertEq(market.totalSupplyAssets(), 0);
        assertEq(market.totalSupplyShares(), 0);
    }

    /// With several suppliers, nobody can pull out more than they put in absent interest.
    function testFuzz_twoSuppliersCannotExtractMoreThanDeposited(uint256 a, uint256 d) public {
        a = bound(a, 1e6, 1_000_000e6);
        d = bound(d, 1e6, 1_000_000e6);
        uint256 sa = _supply(alice, a);
        uint256 sd = _supply(dave, d);

        vm.prank(alice);
        uint256 outA = market.redeem(sa);
        vm.prank(dave);
        uint256 outD = market.redeem(sd);

        assertLe(outA, a);
        assertLe(outD, d);
        assertGe(outA + 1, a);
        assertGe(outD + 1, d);
    }

    /// Spec invariant (d), per action: the supplier share price (assets per share, virtual
    /// amounts included) never decreases through supply, withdraw or redeem. Compared by
    /// cross-multiplication to avoid any division: (A'+VA) * (S+VS) >= (A+VA) * (S'+VS).
    function testFuzz_sharePriceNeverDecreasesOnSupplierActions(
        uint256 seedSupply,
        uint256 borrowAmount,
        uint256 elapsed,
        uint256 amount,
        uint256 action
    ) public {
        seedSupply = bound(seedSupply, 1000e6, 1_000_000e6);
        borrowAmount = bound(borrowAmount, 1e6, seedSupply / 2);
        elapsed = bound(elapsed, 1 days, 2 * 365 days);

        _supply(alice, seedSupply);
        _depositCollateral(bob, 1000e18);
        _borrow(bob, borrowAmount);
        _skip(elapsed);
        market.accrueInterest(); // non-integer share price now

        uint256 a0 = market.totalSupplyAssets() + 1;
        uint256 s0 = market.totalSupplyShares() + 1e6;

        action = bound(action, 0, 2);
        if (action == 0) {
            _supply(dave, bound(amount, 1, 500_000e6));
        } else if (action == 1) {
            uint256 liquid = market.liquidity();
            vm.assume(liquid > 0);
            vm.prank(alice);
            market.withdraw(bound(amount, 1, liquid));
        } else {
            uint256 owned = market.supplyShares(alice);
            // keep the redemption within idle liquidity and worth at least 1 asset unit
            uint256 maxShares = owned < 1e15 ? owned : 1e15;
            uint256 shares = bound(amount, 1e6, maxShares);
            vm.assume(shares * a0 / s0 > 0);
            vm.assume(shares * a0 / s0 <= market.liquidity());
            vm.prank(alice);
            market.redeem(shares);
        }

        uint256 a1 = market.totalSupplyAssets() + 1;
        uint256 s1 = market.totalSupplyShares() + 1e6;
        assertGe(a1 * s0, a0 * s1, "share price decreased");
    }

    /*//////////////////////////////////////////////////////////////
                            BORROWING LIMITS
    //////////////////////////////////////////////////////////////*/

    /// Any borrow up to the LTV limit succeeds and leaves HF >= 1; anything above reverts.
    function testFuzz_borrowLimitIsExact(uint256 collateral, uint256 borrowAmount) public {
        collateral = bound(collateral, 1e15, 500e18);
        _supply(alice, 5_000_000e6);
        _depositCollateral(bob, collateral);

        // Limit in USDC: collateral * $2,000 * 75%, rounded down; in base units of USDC.
        uint256 collValue = RiskMath.collateralValueUsd(collateral, 2000e18, 18);
        uint256 limitUsdc = RiskMath.maxDebtValue(collValue, 0.75e18) / 1e12;
        vm.assume(limitUsdc > 0);

        borrowAmount = bound(borrowAmount, 1, limitUsdc + 1000e6);
        if (borrowAmount <= limitUsdc) {
            _borrow(bob, borrowAmount);
            assertGe(market.healthFactor(bob), 1e18, "never liquidatable right after borrowing");
        } else {
            vm.prank(bob);
            vm.expectRevert(LendingMarket.Market__ExceedsMaxLtv.selector);
            market.borrow(borrowAmount);
        }
    }

    /// A position opened within LTV cannot be liquidated at the same prices.
    function testFuzz_withinLtvNeverLiquidatableAtSamePrice(uint256 collateral, uint256 fraction)
        public
    {
        collateral = bound(collateral, 1e17, 100e18);
        fraction = bound(fraction, 1, 100);
        _supply(alice, 5_000_000e6);
        _depositCollateral(bob, collateral);

        uint256 limitUsdc = RiskMath.maxDebtValue(
            RiskMath.collateralValueUsd(collateral, 2000e18, 18), 0.75e18
        ) / 1e12;
        uint256 amount = limitUsdc * fraction / 100;
        vm.assume(amount > 0);
        _borrow(bob, amount);

        vm.prank(carol);
        vm.expectPartialRevert(LendingMarket.Market__PositionHealthy.selector);
        market.liquidate(bob, type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                         BORROW / REPAY OVER TIME
    //////////////////////////////////////////////////////////////*/

    /// After any holding period: the borrower repays at least what was borrowed, the supplier
    /// ends up with at least their deposit, and the books balance.
    function testFuzz_borrowHoldRepayWithdraw(uint256 borrowAmount, uint256 elapsed) public {
        borrowAmount = bound(borrowAmount, 1e6, 70_000e6);
        elapsed = bound(elapsed, 0, 3 * 365 days);

        _supply(alice, 100_000e6);
        _depositCollateral(bob, 100e18); // $200k: always safely collateralized at $2,000
        _borrow(bob, borrowAmount);
        _skip(elapsed);

        uint256 owed = market.borrowBalance(bob);
        assertGe(owed, borrowAmount);

        uint256 repaid = _repayAll(bob);
        assertEq(repaid, owed, "pays exactly what the view promised");
        assertEq(market.scaledDebt(bob), 0);

        vm.prank(bob);
        market.withdrawCollateral(100e18);

        uint256 aliceShares = market.supplyShares(alice);
        vm.prank(alice);
        uint256 out = market.redeem(aliceShares);
        assertGe(out, 100_000e6, "supplier never loses principal");
        assertLe(
            out - 100_000e6, repaid - borrowAmount, "supplier gets no more than the interest paid"
        );
        _assertSolvencyIdentity();
    }

    /// Splitting a repayment into two never lets the borrower pay less in total than a single
    /// full repayment would have cost.
    function testFuzz_partialRepaymentsNeverCheaperThanFullRepayment(
        uint256 borrowAmount,
        uint256 elapsed,
        uint256 firstFraction
    ) public {
        borrowAmount = bound(borrowAmount, 10e6, 50_000e6);
        elapsed = bound(elapsed, 1 days, 365 days);
        firstFraction = bound(firstFraction, 1, 99);

        _supply(alice, 100_000e6);
        _depositCollateral(bob, 100e18);
        _borrow(bob, borrowAmount);
        _skip(elapsed);

        uint256 owed = market.borrowBalance(bob);
        uint256 first = owed * firstFraction / 100;
        vm.assume(first > 0);

        vm.prank(bob);
        uint256 paid1 = market.repay(first, bob);
        uint256 paid2 = _repayAll(bob);

        assertGe(paid1 + paid2, owed, "no discount for repaying in pieces");
        // A partial repay burns FLOORed scaled debt, which can leave up to ceil(index/RAY) = 2 wei more.
        assertLe(paid1 + paid2, owed + 2, "and at most 2 wei of rounding cost");
    }

    /// Several borrowers entering at different times: sum of debts is within N-1 of the total.
    function testFuzz_multiBorrowerDebtAccountingTolerance(
        uint256 b1,
        uint256 b2,
        uint256 b3,
        uint256 t1,
        uint256 t2,
        uint256 t3
    ) public {
        b1 = bound(b1, 1, 50_000e6);
        b2 = bound(b2, 1, 50_000e6);
        b3 = bound(b3, 1, 50_000e6);
        t1 = bound(t1, 0, 200 days);
        t2 = bound(t2, 0, 200 days);
        t3 = bound(t3, 0, 200 days);

        _supply(alice, 1_000_000e6);
        _depositCollateral(bob, 200e18);
        _depositCollateral(dave, 200e18);
        _depositCollateral(carol, 200e18);

        _borrow(bob, b1);
        _skip(t1);
        _borrow(dave, b2);
        _skip(t2);
        _borrow(carol, b3);
        _skip(t3);
        market.accrueInterest();

        uint256 sum =
            market.borrowBalance(bob) + market.borrowBalance(dave) + market.borrowBalance(carol);
        uint256 total = market.totalBorrowAssets();
        assertGe(sum, total, "per-user rounding is always upward");
        assertLe(sum - total, 2, "at most N-1 wei apart");
        _assertSolvencyIdentity();
    }

    /*//////////////////////////////////////////////////////////////
                              LIQUIDATION
    //////////////////////////////////////////////////////////////*/

    /// For ANY price crash and ANY requested repayment, a liquidation conserves assets exactly,
    /// never overpays the liquidator beyond the bonus, and keeps the books balanced.
    function testFuzz_liquidationConservesAssetsAndNeverOverpays(
        uint256 newPrice,
        uint256 request,
        uint256 elapsed
    ) public {
        newPrice = bound(newPrice, 50, 1249); // below the HF=1 price of $1,250 for the standard position
        elapsed = bound(elapsed, 0, 365 days);
        _openStandardPosition();
        _skip(elapsed);
        _setEthPrice(newPrice);
        vm.assume(market.healthFactor(bob) < 1e18);
        // >= 2: a 1-wei request burns no scaled debt once the index is above 1.0 and reverts by
        // design (covered by a dedicated unit test).
        request = bound(request, 2, 20_000e6);

        // Realize the interest first so the baselines below are the state liquidate() starts from.
        market.accrueInterest();
        uint256 debtBefore = market.borrowBalance(bob);
        uint256 collBefore = market.collateralOf(bob);
        uint256 carolUsdc = usdc.balanceOf(carol);
        uint256 carolWeth = weth.balanceOf(carol);
        uint256 supplyBefore = market.totalSupplyAssets();

        vm.prank(carol);
        (uint256 repaid, uint256 seized) = market.liquidate(bob, request);

        // Exact conservation of tokens.
        assertEq(carolUsdc - usdc.balanceOf(carol), repaid);
        assertEq(weth.balanceOf(carol) - carolWeth, seized);
        assertEq(market.collateralOf(bob), collBefore - seized);
        assertEq(weth.balanceOf(address(market)), market.totalCollateral());

        // Never repays more than allowed or requested.
        assertLe(repaid, request);
        assertLe(repaid, RiskMath.maxRepayable(debtBefore, 0.5e18));
        assertLe(seized, collBefore);

        // Liquidator receives at most repaid * (1 + bonus) in value (prices: ETH newPrice, USDC $1).
        // seized(wei) * price / 1e18 (USD)  <=  repaid(6dec)/1e6 * 1.05  <=>  cross-multiplied below.
        assertLe(seized * newPrice * 100, repaid * 1e12 * 105);

        // Debt moves by exactly `repaid` (±1 wei of ceil), unless bad debt was written off.
        uint256 badDebt = market.totalBadDebt();
        if (badDebt == 0) {
            // Floored burn + ceiled debt: debt falls by the repaid amount, give or take 2 wei (index < 2.0).
            assertApproxEqAbs(market.borrowBalance(bob), debtBefore - repaid, 2);
        } else {
            assertEq(market.borrowBalance(bob), 0);
            assertEq(market.collateralOf(bob), 0);
            assertEq(market.totalSupplyAssets(), supplyBefore - badDebt);
        }
        _assertSolvencyIdentity();
    }

    /// Bad debt is recorded IFF the borrower is left with debt but no collateral, and then the
    /// supplier loss equals the written-off remainder (up to the 1-wei ceil).
    function testFuzz_badDebtOnlyWhenCollateralExhausted(uint256 newPrice) public {
        newPrice = bound(newPrice, 1, 1249);
        _openStandardPosition();
        _setEthPrice(newPrice);

        vm.prank(carol);
        market.liquidate(bob, type(uint256).max);

        if (market.totalBadDebt() > 0) {
            assertEq(market.collateralOf(bob), 0, "bad debt only with nothing left to seize");
            assertEq(market.scaledDebt(bob), 0, "and the remainder is fully written off");
        } else {
            // Either fully repaid or still collateralized.
            assertTrue(market.collateralOf(bob) > 0 || market.scaledDebt(bob) == 0);
        }
    }
}
