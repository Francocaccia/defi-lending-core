// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {
    AggregatorV3Interface
} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

import {LendingMarket} from "../../src/LendingMarket.sol";
import {ChainlinkOracle} from "../../src/oracle/ChainlinkOracle.sol";
import {IOracle} from "../../src/interfaces/IOracle.sol";
import {InterestRateModel} from "../../src/libraries/InterestRateModel.sol";
import {RiskMath} from "../../src/libraries/RiskMath.sol";
import {Addresses} from "../../script/Addresses.sol";

/// @notice Runs the real protocol code against REAL mainnet state: the real Chainlink ETH/USD and
///         USDC/USD feeds, real WETH9 and real (proxy) USDC. Read-only: a fork never touches the
///         real chain.
///
///         Skipped automatically when `MAINNET_RPC_URL` is not set, so CI and fresh clones stay
///         green without any secret:
///             MAINNET_RPC_URL=<any free public mainnet RPC> forge test --match-path "test/fork/*"
///
///         The fork is taken at the LATEST block (a public free RPC is rarely an archive node), so
///         absolute prices vary between runs; assertions are written to hold at any realistic
///         price. To simulate time passing or a price crash on a live feed we `vm.mockCall` the
///         feed's `latestRoundData` (the real oracle wrapper and tokens are still used).
contract MainnetForkTest is Test {
    IERC20Metadata internal constant WETH = IERC20Metadata(Addresses.MAINNET_WETH);
    IERC20Metadata internal constant USDC = IERC20Metadata(Addresses.MAINNET_USDC);
    AggregatorV3Interface internal constant ETH_FEED =
        AggregatorV3Interface(Addresses.MAINNET_ETH_USD_FEED);
    AggregatorV3Interface internal constant USDC_FEED =
        AggregatorV3Interface(Addresses.MAINNET_USDC_USD_FEED);

    ChainlinkOracle internal ethOracle;
    ChainlinkOracle internal usdcOracle;
    LendingMarket internal market;

    address internal alice = makeAddr("alice"); // supplier
    address internal bob = makeAddr("bob"); // borrower
    address internal carol = makeAddr("carol"); // liquidator

    function setUp() public {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true); // no RPC configured: skip every test in this contract
        }
        // Fork a few blocks BEHIND the head: free public RPCs load-balance across nodes and the
        // very newest block is often not yet known to every backend ("block not found"). 25
        // blocks (~5 min) is old enough for all of them, and still within the recent-state window
        // of non-archive nodes.
        vm.selectFork(vm.createFork(rpc));
        vm.rollFork(block.number - 25);

        // Staleness bounds = heartbeat + a deliberate margin (evidence in Addresses.sol).
        ethOracle = new ChainlinkOracle(ETH_FEED, Addresses.MAINNET_ETH_USD_ORACLE_MAX_AGE);
        usdcOracle = new ChainlinkOracle(USDC_FEED, Addresses.MAINNET_USDC_USD_ORACLE_MAX_AGE);

        market = new LendingMarket(
            LendingMarket.MarketParams({
                collateralToken: WETH,
                borrowToken: USDC,
                collateralOracle: IOracle(address(ethOracle)),
                borrowOracle: IOracle(address(usdcOracle)),
                rate: InterestRateModel.Params({
                    baseRate: 0, slope1: 0.04e18, slope2: 0.75e18, optimalUtilization: 0.8e18
                }),
                risk: RiskMath.RiskParams({
                    maxLtv: 0.75e18,
                    liquidationThreshold: 0.8e18,
                    liquidationBonus: 0.05e18,
                    closeFactor: 0.5e18
                })
            })
        );

        deal(address(USDC), alice, 5_000_000e6);
        deal(address(USDC), carol, 5_000_000e6);
        deal(address(USDC), bob, 1_000_000e6);
        deal(address(WETH), bob, 1000e18);
        address[3] memory users = [alice, bob, carol];
        for (uint256 i = 0; i < users.length; i++) {
            vm.startPrank(users[i]);
            WETH.approve(address(market), type(uint256).max);
            // Real USDC (a proxy) accepts the standard approve.
            USDC.approve(address(market), type(uint256).max);
            vm.stopPrank();
        }
    }

    /*//////////////////////////////////////////////////////////////
                           ADDRESS SANITY
    //////////////////////////////////////////////////////////////*/

    /// Guards `script/Addresses.sol`: the constants must be the assets they claim to be.
    function test_fork_addressesAreWhatTheyClaimToBe() public view {
        assertEq(block.chainid, 1, "must be Ethereum mainnet");

        assertEq(ETH_FEED.description(), "ETH / USD");
        assertEq(ETH_FEED.decimals(), 8);
        assertEq(USDC_FEED.description(), "USDC / USD");
        assertEq(USDC_FEED.decimals(), 8);

        assertEq(WETH.symbol(), "WETH");
        assertEq(WETH.decimals(), 18);
        assertEq(USDC.symbol(), "USDC");
        assertEq(USDC.decimals(), 6);
    }

    /*//////////////////////////////////////////////////////////////
                         ORACLE ON REAL FEEDS
    //////////////////////////////////////////////////////////////*/

    function test_fork_oraclePricesMatchTheRawFeeds() public view {
        (, int256 ethAnswer,, uint256 ethUpdated,) = ETH_FEED.latestRoundData();
        (, int256 usdcAnswer,,,) = USDC_FEED.latestRoundData();

        assertEq(ethOracle.price(), uint256(ethAnswer) * 1e10, "8 -> 18 decimals, exact");
        assertEq(usdcOracle.price(), uint256(usdcAnswer) * 1e10);
        assertLe(ethUpdated, block.timestamp);
    }

    function test_fork_oraclePricesArePlausible() public view {
        uint256 eth = ethOracle.price();
        uint256 usdc = usdcOracle.price();
        assertGt(eth, 100e18, "ETH > $100");
        assertLt(eth, 100_000e18, "ETH < $100,000");
        // The oracle returns the feed's real value, not a hardcoded $1: it is merely close.
        assertGt(usdc, 0.98e18);
        assertLt(usdc, 1.02e18);
    }

    function test_fork_realFeedGoesStaleWithoutUpdates() public {
        // On a fork nothing updates the feed, so time alone makes the REAL feed stale.
        vm.warp(block.timestamp + ethOracle.HEARTBEAT() + 1);
        vm.expectPartialRevert(ChainlinkOracle.Oracle__StalePrice.selector);
        ethOracle.price();
    }

    function test_fork_staleRealFeedBlocksBorrowing() public {
        _supply(alice, 1_000_000e6);
        _deposit(bob, 10e18);
        vm.warp(block.timestamp + ethOracle.HEARTBEAT() + 1);
        vm.prank(bob);
        vm.expectPartialRevert(ChainlinkOracle.Oracle__StalePrice.selector);
        market.borrow(1000e6);
    }

    /*//////////////////////////////////////////////////////////////
                    FULL FLOW WITH REAL WETH AND USDC
    //////////////////////////////////////////////////////////////*/

    function test_fork_lifecycleWithRealTokens() public {
        _supply(alice, 1_000_000e6);
        _deposit(bob, 50e18);

        // Borrow 50% of the limit at the live price.
        uint256 limit = _borrowLimitUsdc(50e18);
        uint256 amount = limit / 2;
        uint256 bobUsdcBefore = USDC.balanceOf(bob);
        vm.prank(bob);
        market.borrow(amount);
        assertEq(USDC.balanceOf(bob) - bobUsdcBefore, amount, "real USDC arrived");
        assertGt(market.healthFactor(bob), 1.5e18, "50% of max LTV is comfortably healthy");

        // 90 days later (feeds re-published at the same prices so the oracle stays valid).
        _republishAtCurrentPrices(90 days);
        uint256 owed = market.borrowBalance(bob);
        assertGt(owed, amount, "interest accrued");

        vm.startPrank(bob);
        market.repay(type(uint256).max, bob);
        market.withdrawCollateral(50e18);
        vm.stopPrank();
        assertEq(market.scaledDebt(bob), 0);
        assertEq(WETH.balanceOf(address(market)), 0, "all real WETH returned");

        uint256 aliceShares = market.supplyShares(alice);
        vm.prank(alice);
        uint256 out = market.redeem(aliceShares);
        assertGe(out, 1_000_000e6, "supplier made whole plus interest");
        assertApproxEqAbs(out - 1_000_000e6, owed - amount, 2, "supplier got the interest paid");
    }

    function test_fork_liquidationAfterCrashWithRealTokens() public {
        _supply(alice, 2_000_000e6);
        _deposit(bob, 100e18);

        // Borrow 95% of the limit, then ETH falls 35%.
        uint256 amount = _borrowLimitUsdc(100e18) * 95 / 100;
        vm.prank(bob);
        market.borrow(amount);
        assertGe(market.healthFactor(bob), 1e18);

        uint256 livePrice = ethOracle.price();
        uint256 crashed = livePrice * 65 / 100;
        _mockFeed(ETH_FEED, int256(crashed / 1e10), block.timestamp);
        _mockFeed(USDC_FEED, int256(usdcOracle.price() / 1e10), block.timestamp);
        assertLt(market.healthFactor(bob), 1e18, "35% crash makes a 95%-of-limit loan unhealthy");

        uint256 carolUsdc = USDC.balanceOf(carol);
        uint256 carolWeth = WETH.balanceOf(carol);
        vm.prank(carol);
        (uint256 repaid, uint256 seized) = market.liquidate(bob, type(uint256).max);

        assertEq(carolUsdc - USDC.balanceOf(carol), repaid, "real USDC paid");
        assertEq(WETH.balanceOf(carol) - carolWeth, seized, "real WETH received");
        assertApproxEqAbs(repaid, amount / 2, 2, "close factor 50%");

        // Seized value at the crashed price == repaid * 1.05 (to within one wei of rounding).
        uint256 seizedValueUsd = seized * (crashed / 1e10 * 1e10) / 1e18; // 18-dec USD
        // The repaid USDC is valued at the REAL USDC/USD feed (about $0.9998), not at a flat $1.
        uint256 expectedUsd = repaid * 1e12 * usdcOracle.price() / 1e18 * 105 / 100;
        assertApproxEqRel(seizedValueUsd, expectedUsd, 1e9); // within 1e-9 relative (rounding only)
        assertEq(market.totalBadDebt(), 0);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _supply(address who, uint256 assets) internal {
        vm.prank(who);
        market.supply(assets);
    }

    function _deposit(address who, uint256 amount) internal {
        vm.prank(who);
        market.depositCollateral(amount);
    }

    /// Max borrow (USDC base units) for `collateral` WETH at the live prices.
    function _borrowLimitUsdc(uint256 collateral) internal view returns (uint256) {
        uint256 collValue = RiskMath.collateralValueUsd(collateral, ethOracle.price(), 18);
        uint256 maxDebtUsd = RiskMath.maxDebtValue(collValue, 0.75e18);
        return maxDebtUsd * 1e6 / usdcOracle.price();
    }

    function _mockFeed(AggregatorV3Interface feed, int256 answer, uint256 updatedAt) internal {
        vm.mockCall(
            address(feed),
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), answer, updatedAt, updatedAt, uint80(1))
        );
    }

    /// Advance time and re-publish both feeds at their CURRENT values with a fresh timestamp.
    function _republishAtCurrentPrices(uint256 dt) internal {
        int256 eth = int256(ethOracle.price() / 1e10);
        int256 usdc = int256(usdcOracle.price() / 1e10);
        uint256 later = vm.getBlockTimestamp() + dt;
        vm.warp(later);
        _mockFeed(ETH_FEED, eth, later);
        _mockFeed(USDC_FEED, usdc, later);
    }
}
