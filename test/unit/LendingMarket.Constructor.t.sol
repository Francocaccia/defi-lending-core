// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MarketBase} from "../utils/MarketBase.sol";
import {LendingMarket} from "../../src/LendingMarket.sol";
import {InterestRateModel} from "../../src/libraries/InterestRateModel.sol";
import {RiskMath} from "../../src/libraries/RiskMath.sol";
import {IOracle} from "../../src/interfaces/IOracle.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {RAY} from "../../src/libraries/Units.sol";

contract LendingMarketConstructorTest is MarketBase {
    function test_constructor_storesConfiguration() public view {
        assertEq(address(market.COLLATERAL_TOKEN()), address(weth));
        assertEq(address(market.BORROW_TOKEN()), address(usdc));
        assertEq(address(market.COLLATERAL_ORACLE()), address(ethOracle));
        assertEq(address(market.BORROW_ORACLE()), address(usdcOracle));
        assertEq(market.COLLATERAL_DECIMALS(), 18);
        assertEq(market.BORROW_DECIMALS(), 6);

        assertEq(market.RATE_BASE(), 0);
        assertEq(market.RATE_SLOPE1(), 0.04e18);
        assertEq(market.RATE_SLOPE2(), 0.75e18);
        assertEq(market.RATE_OPTIMAL_UTILIZATION(), 0.8e18);

        assertEq(market.MAX_LTV(), 0.75e18);
        assertEq(market.LIQUIDATION_THRESHOLD(), 0.8e18);
        assertEq(market.LIQUIDATION_BONUS(), 0.05e18);
        assertEq(market.CLOSE_FACTOR(), 0.5e18);
    }

    function test_constructor_initialState() public view {
        assertEq(market.borrowIndex(), RAY);
        assertEq(market.lastAccrual(), START_TIME);
        assertEq(market.totalSupplyAssets(), 0);
        assertEq(market.totalSupplyShares(), 0);
        assertEq(market.totalScaledDebt(), 0);
        assertEq(market.totalCollateral(), 0);
        assertEq(market.totalBadDebt(), 0);
        assertEq(market.totalBorrowAssets(), 0);
    }

    function test_constructor_revertsOnZeroTokens() public {
        LendingMarket.MarketParams memory p = _defaultParams();
        p.collateralToken = IERC20Metadata(address(0));
        vm.expectRevert(LendingMarket.Market__InvalidConfig.selector);
        new LendingMarket(p);

        p = _defaultParams();
        p.borrowToken = IERC20Metadata(address(0));
        vm.expectRevert(LendingMarket.Market__InvalidConfig.selector);
        new LendingMarket(p);
    }

    function test_constructor_revertsWhenTokensAreTheSame() public {
        LendingMarket.MarketParams memory p = _defaultParams();
        p.borrowToken = p.collateralToken;
        vm.expectRevert(LendingMarket.Market__InvalidConfig.selector);
        new LendingMarket(p);
    }

    function test_constructor_revertsOnZeroOracles() public {
        LendingMarket.MarketParams memory p = _defaultParams();
        p.collateralOracle = IOracle(address(0));
        vm.expectRevert(LendingMarket.Market__InvalidConfig.selector);
        new LendingMarket(p);

        p = _defaultParams();
        p.borrowOracle = IOracle(address(0));
        vm.expectRevert(LendingMarket.Market__InvalidConfig.selector);
        new LendingMarket(p);
    }

    function test_constructor_revertsOnTokenWithMoreThan18Decimals() public {
        LendingMarket.MarketParams memory p = _defaultParams();
        p.borrowToken = IERC20Metadata(address(new MockERC20("Weird", "WRD", 19)));
        vm.expectRevert(LendingMarket.Market__InvalidConfig.selector);
        new LendingMarket(p);
    }

    function test_constructor_revertsOnInvalidRateParams() public {
        LendingMarket.MarketParams memory p = _defaultParams();
        p.rate.optimalUtilization = 0;
        vm.expectRevert(
            abi.encodeWithSelector(
                InterestRateModel.InterestRateModel__InvalidOptimalUtilization.selector, 0
            )
        );
        new LendingMarket(p);
    }

    function test_constructor_revertsOnInvalidRiskParams() public {
        LendingMarket.MarketParams memory p = _defaultParams();
        p.risk.maxLtv = 0.8e18; // not below the liquidation threshold
        vm.expectRevert(
            abi.encodeWithSelector(
                RiskMath.RiskMath__InvalidLtvOrThreshold.selector, 0.8e18, 0.8e18
            )
        );
        new LendingMarket(p);
    }

    function test_constructor_acceptsTokensWithOtherDecimals() public {
        LendingMarket.MarketParams memory p = _defaultParams();
        p.collateralToken = IERC20Metadata(address(new MockERC20("WBTC", "WBTC", 8)));
        LendingMarket m = new LendingMarket(p);
        assertEq(m.COLLATERAL_DECIMALS(), 8);
    }
}
