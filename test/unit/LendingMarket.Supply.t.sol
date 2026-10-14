// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {stdStorage, StdStorage} from "forge-std/Test.sol";
import {MarketBase} from "../utils/MarketBase.sol";
import {LendingMarket} from "../../src/LendingMarket.sol";

contract LendingMarketSupplyTest is MarketBase {
    using stdStorage for StdStorage;

    event Supply(address indexed supplier, uint256 assets, uint256 shares);
    event Withdraw(address indexed supplier, uint256 assets, uint256 shares);

    /*//////////////////////////////////////////////////////////////
                                 SUPPLY
    //////////////////////////////////////////////////////////////*/

    function test_supply_mintsSharesAndPullsTokens() public {
        uint256 before = usdc.balanceOf(alice);

        vm.expectEmit(true, false, false, true, address(market));
        emit Supply(alice, 1000e6, 1e15);
        uint256 shares = _supply(alice, 1000e6);

        assertEq(shares, 1e15, "first deposit: shares = assets * 1e6");
        assertEq(market.supplyShares(alice), 1e15);
        assertEq(market.totalSupplyShares(), 1e15);
        assertEq(market.totalSupplyAssets(), 1000e6);
        assertEq(usdc.balanceOf(address(market)), 1000e6);
        assertEq(usdc.balanceOf(alice), before - 1000e6);
        assertEq(market.supplyBalance(alice), 1000e6);
    }

    function test_supply_revertsOnZero() public {
        vm.prank(alice);
        vm.expectRevert(LendingMarket.Market__ZeroAmount.selector);
        market.supply(0);
    }

    /// Defense in depth: with virtual shares a deposit can only round to zero shares if the share
    /// price has grown by ~1e6x, which no realistic history reaches. Force that state by writing
    /// storage directly and check the guard refuses to swallow the deposit.
    function test_supply_revertsInsteadOfMintingZeroShares() public {
        stdstore.target(address(market)).sig("totalSupplyAssets()").checked_write(uint256(1e40));
        vm.prank(alice);
        vm.expectRevert(LendingMarket.Market__ZeroShares.selector);
        market.supply(1e6);
    }

    function test_supply_revertsWithoutAllowance() public {
        address stranger = makeAddr("stranger");
        usdc.mint(stranger, 1e6);
        vm.prank(stranger);
        vm.expectRevert(); // ERC20InsufficientAllowance from the token
        market.supply(1e6);
    }

    function test_supply_secondSupplierGetsProportionalShares() public {
        _supply(alice, 1000e6);
        uint256 daveShares = _supply(dave, 500e6);
        assertEq(daveShares, 5e14);
        assertEq(market.totalSupplyShares(), 1.5e15);
        assertEq(market.totalSupplyAssets(), 1500e6);
    }

    function test_supply_afterInterestMintsFewerShares() public {
        _openStandardPosition();
        _skip(365 days);
        uint256 daveShares = _supply(dave, 1000e6);
        // Share price > 1 after interest, so 1,000 USDC buys fewer than 1e15 shares.
        assertLt(daveShares, 1e15);
        assertGt(daveShares, 0);
    }

    /*//////////////////////////////////////////////////////////////
                           WITHDRAW / REDEEM
    //////////////////////////////////////////////////////////////*/

    function test_withdraw_fullAmount() public {
        _supply(alice, 1000e6);
        uint256 before = usdc.balanceOf(alice);

        vm.expectEmit(true, false, false, true, address(market));
        emit Withdraw(alice, 1000e6, 1e15);
        vm.prank(alice);
        uint256 burned = market.withdraw(1000e6);

        assertEq(burned, 1e15);
        assertEq(market.supplyShares(alice), 0);
        assertEq(market.totalSupplyShares(), 0);
        assertEq(market.totalSupplyAssets(), 0);
        assertEq(usdc.balanceOf(alice), before + 1000e6);
    }

    function test_withdraw_partial() public {
        _supply(alice, 1000e6);
        vm.prank(alice);
        market.withdraw(400e6);
        assertEq(market.supplyBalance(alice), 600e6);
        assertEq(market.totalSupplyAssets(), 600e6);
    }

    function test_withdraw_revertsOnZero() public {
        vm.prank(alice);
        vm.expectRevert(LendingMarket.Market__ZeroAmount.selector);
        market.withdraw(0);
    }

    function test_withdraw_revertsWhenMoreThanOwned() public {
        _supply(alice, 1000e6);
        _supply(dave, 1000e6);
        // alice owns 1e15 shares; asking for 1,500 USDC needs 1.5e15.
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(LendingMarket.Market__InsufficientShares.selector, 1.5e15, 1e15)
        );
        market.withdraw(1500e6);
    }

    function test_withdraw_revertsWhenLiquidityIsLentOut() public {
        _openStandardPosition(); // 100k supplied, 10k borrowed => 90k idle
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                LendingMarket.Market__InsufficientLiquidity.selector, 95_000e6, 90_000e6
            )
        );
        market.withdraw(95_000e6);
    }

    function test_withdraw_idlePartWorksWhileRestIsLentOut() public {
        _openStandardPosition();
        vm.prank(alice);
        market.withdraw(90_000e6);
        assertEq(market.liquidity(), 0);
        _assertSolvencyIdentity();
    }

    function test_redeem_returnsAssetsRoundedDown() public {
        _supply(alice, 1000e6);
        vm.prank(alice);
        uint256 assets = market.redeem(1e15);
        assertEq(assets, 1000e6);
        assertEq(market.supplyShares(alice), 0);
    }

    function test_redeem_revertsOnZeroShares() public {
        vm.prank(alice);
        vm.expectRevert(LendingMarket.Market__ZeroAmount.selector);
        market.redeem(0);
    }

    function test_redeem_revertsWhenMoreThanOwned() public {
        _supply(alice, 1000e6);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(LendingMarket.Market__InsufficientShares.selector, 2e15, 1e15)
        );
        market.redeem(2e15);
    }

    function test_redeem_revertsWhenSharesWorthZeroAssets() public {
        _supply(alice, 1000e6);
        // 1 share is worth floor(1 * 1000000001 / 1000000001000000) = 0 assets.
        vm.prank(alice);
        vm.expectRevert(LendingMarket.Market__ZeroAmount.selector);
        market.redeem(1);
    }

    function test_cannotWithdrawAnotherUsersShares() public {
        _supply(alice, 1000e6);
        vm.prank(bob);
        vm.expectRevert();
        market.withdraw(1e6);
    }

    /*//////////////////////////////////////////////////////////////
                         INTEREST & DONATIONS
    //////////////////////////////////////////////////////////////*/

    function test_supplierEarnsInterest() public {
        _openStandardPosition();
        _skip(365 days);
        // 10% utilization => rate 0.5%; 10,000 USDC * 0.5% = 50 USDC of interest.
        uint256 balance = market.supplyBalance(alice);
        assertGt(balance, 100_000e6);
        assertApproxEqAbs(balance, 100_050e6, 1e6);
    }

    function test_suppliersShareInterestProRata() public {
        _supply(alice, 75_000e6);
        _supply(dave, 25_000e6);
        _depositCollateral(bob, 100e18);
        _borrow(bob, 50_000e6);
        _skip(180 days);

        uint256 a = market.supplyBalance(alice);
        uint256 d = market.supplyBalance(dave);
        // alice has 3x dave's shares => 3x the earnings (within a couple of wei of rounding).
        assertApproxEqAbs(a - 75_000e6, 3 * (d - 25_000e6), 3);
    }

    function test_supplyBalanceViewMatchesRealizedWithdrawal() public {
        _openStandardPosition();
        _skip(90 days);
        uint256 viewBalance = market.supplyBalance(alice);

        // Realize it: accrue then read again; the view must not have drifted.
        market.accrueInterest();
        assertEq(market.supplyBalance(alice), viewBalance);
    }

    function test_donationDoesNotChangeSharePrice() public {
        _supply(alice, 1000e6);
        usdc.mint(address(this), 1_000_000e6);
        usdc.transfer(address(market), 1_000_000e6); // direct "donation"

        assertEq(market.supplyBalance(alice), 1000e6, "donated tokens are not accounted");
        assertEq(market.totalSupplyAssets(), 1000e6);
        // A later depositor is priced as if the donation never happened.
        assertEq(_supply(dave, 1000e6), 1e15);
    }

    function test_firstDepositorInflationAttackFails() public {
        // Attacker deposits 1 wei, donates 1,000 USDC directly, victim then deposits 1,000 USDC.
        _supply(alice, 1);
        usdc.mint(address(this), 1000e6);
        usdc.transfer(address(market), 1000e6);

        uint256 victimShares = _supply(dave, 1000e6);
        assertGt(victimShares, 0);
        // The donation is not accounted, so the victim is priced as if it never happened.
        assertEq(market.supplyBalance(dave), 1000e6, "victim keeps everything");

        // Attacker's claim is their own 1 wei: the donation is simply lost to them.
        assertLe(market.supplyBalance(alice), 1);
    }
}
