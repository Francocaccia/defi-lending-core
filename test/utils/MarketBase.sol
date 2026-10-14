// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {
    AggregatorV3Interface
} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

import {LendingMarket} from "../../src/LendingMarket.sol";
import {ChainlinkOracle} from "../../src/oracle/ChainlinkOracle.sol";
import {InterestRateModel} from "../../src/libraries/InterestRateModel.sol";
import {RiskMath} from "../../src/libraries/RiskMath.sol";
import {IOracle} from "../../src/interfaces/IOracle.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {MockERC20} from "../mocks/MockERC20.sol";
import {MockAggregatorV3} from "../mocks/MockAggregatorV3.sol";

/// @notice Shared fixture: WETH (18 dec) as collateral, USDC (6 dec) as borrow asset, mock
///         Chainlink feeds behind the real `ChainlinkOracle`, and the illustrative parameters
///         (base 0%, slope1 4%, slope2 75%, kink 80%; LTV 75%, LT 80%, bonus 5%, close factor 50%).
///
///         Oracle heartbeat is the 7-day maximum so tests that move time for interest do not trip
///         staleness by accident; `_skip` also refreshes the feeds. Staleness itself is tested
///         explicitly by advancing time with `vm.warp` directly.
abstract contract MarketBase is Test {
    uint256 internal constant START_TIME = 1_700_000_000;
    uint256 internal constant HEARTBEAT = 7 days;

    MockERC20 internal weth;
    MockERC20 internal usdc;
    MockAggregatorV3 internal ethFeed;
    MockAggregatorV3 internal usdcFeed;
    ChainlinkOracle internal ethOracle;
    ChainlinkOracle internal usdcOracle;
    LendingMarket internal market;

    address internal alice = makeAddr("alice"); // supplier
    address internal bob = makeAddr("bob"); // borrower
    address internal carol = makeAddr("carol"); // liquidator
    address internal dave = makeAddr("dave"); // second borrower / second supplier

    function setUp() public virtual {
        vm.warp(START_TIME);

        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        ethFeed = new MockAggregatorV3(8, "ETH / USD", 2000e8);
        usdcFeed = new MockAggregatorV3(8, "USDC / USD", 1e8);
        ethOracle = new ChainlinkOracle(AggregatorV3Interface(address(ethFeed)), HEARTBEAT);
        usdcOracle = new ChainlinkOracle(AggregatorV3Interface(address(usdcFeed)), HEARTBEAT);

        market = new LendingMarket(_defaultParams());

        address[4] memory actors = [alice, bob, carol, dave];
        for (uint256 i = 0; i < actors.length; i++) {
            weth.mint(actors[i], 1000e18);
            usdc.mint(actors[i], 10_000_000e6);
            vm.startPrank(actors[i]);
            weth.approve(address(market), type(uint256).max);
            usdc.approve(address(market), type(uint256).max);
            vm.stopPrank();
        }
    }

    /*//////////////////////////////////////////////////////////////
                               PARAMETERS
    //////////////////////////////////////////////////////////////*/

    function _defaultRate() internal pure returns (InterestRateModel.Params memory) {
        return InterestRateModel.Params({
            baseRate: 0, slope1: 0.04e18, slope2: 0.75e18, optimalUtilization: 0.8e18
        });
    }

    function _defaultRisk() internal pure returns (RiskMath.RiskParams memory) {
        return RiskMath.RiskParams({
            maxLtv: 0.75e18,
            liquidationThreshold: 0.8e18,
            liquidationBonus: 0.05e18,
            closeFactor: 0.5e18
        });
    }

    function _defaultParams() internal view returns (LendingMarket.MarketParams memory) {
        return LendingMarket.MarketParams({
            collateralToken: IERC20Metadata(address(weth)),
            borrowToken: IERC20Metadata(address(usdc)),
            collateralOracle: IOracle(address(ethOracle)),
            borrowOracle: IOracle(address(usdcOracle)),
            rate: _defaultRate(),
            risk: _defaultRisk()
        });
    }

    /*//////////////////////////////////////////////////////////////
                                 HELPERS
    //////////////////////////////////////////////////////////////*/

    function _supply(address who, uint256 assets) internal returns (uint256 shares) {
        vm.prank(who);
        shares = market.supply(assets);
    }

    function _depositCollateral(address who, uint256 amount) internal {
        vm.prank(who);
        market.depositCollateral(amount);
    }

    function _borrow(address who, uint256 assets) internal {
        vm.prank(who);
        market.borrow(assets);
    }

    function _repayAll(address who) internal returns (uint256 repaid) {
        vm.prank(who);
        repaid = market.repay(type(uint256).max, who);
    }

    /// @dev Sets the ETH/USD feed to a whole-dollar price at the current block time.
    function _setEthPrice(uint256 usd) internal {
        ethFeed.setAnswer(int256(usd * 1e8));
    }

    /// @dev Advance time and re-publish both feeds' CURRENT answers so they are not stale.
    function _skip(uint256 secondsForward) internal {
        vm.warp(vm.getBlockTimestamp() + secondsForward);
        ethFeed.setAnswer(ethFeed.answer());
        usdcFeed.setAnswer(usdcFeed.answer());
    }

    /// @dev The standard starting position used by most tests:
    ///      alice supplies 100,000 USDC; bob deposits 10 WETH ($20,000) and borrows 10,000 USDC
    ///      (50% of his 75% limit; HF = 20,000 * 0.8 / 10,000 = 1.6).
    function _openStandardPosition() internal {
        _supply(alice, 100_000e6);
        _depositCollateral(bob, 10e18);
        _borrow(bob, 10_000e6);
    }

    /// @dev Core solvency identity, must hold after every action (up to dust in the protocol's favour).
    function _assertSolvencyIdentity() internal view {
        assertLe(
            market.totalSupplyAssets(),
            usdc.balanceOf(address(market)) + market.totalBorrowAssets(),
            "supply claims exceed cash + borrows"
        );
    }
}
