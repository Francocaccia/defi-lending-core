// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {
    AggregatorV3Interface
} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

import {LendingMarket} from "../src/LendingMarket.sol";
import {ChainlinkOracle} from "../src/oracle/ChainlinkOracle.sol";
import {IOracle} from "../src/interfaces/IOracle.sol";
import {InterestRateModel} from "../src/libraries/InterestRateModel.sol";
import {RiskMath} from "../src/libraries/RiskMath.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";
import {MockAggregatorV3} from "../test/mocks/MockAggregatorV3.sol";

/// @title Demo
/// @notice A readable, end-to-end story of the protocol on a local chain:
///         supply -> borrow -> (a year of interest) -> ETH crash -> liquidation -> a deeper crash
///         -> bad debt. Everything runs on MOCK tokens and MOCK price feeds, so the price "crash"
///         is just the script writing a new price to the mock aggregator.
///
///         Two ways to run it (see README):
///           1. Against Anvil with real transactions (no time travel, the chain clock is real):
///                anvil
///                forge script script/Demo.s.sol --rpc-url http://127.0.0.1:8545 --broadcast --unlocked \
///                    --sender 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
///           2. In-process simulation that can also fast-forward a year to show interest:
///                forge script script/Demo.s.sol --sig "runWithInterest()"
///
///         Actors are Anvil's public development accounts (addresses only; no keys appear here).
contract Demo is Script {
    // Anvil's well-known development accounts 0..3 (public; pre-funded on every Anvil node).
    address internal constant DEPLOYER = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    address internal constant ALICE = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8; // supplier
    address internal constant BOB = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC; // borrower
    address internal constant CAROL = 0x90F79bf6EB2c4f870365E785982E1f101E93b906; // liquidator

    /// @notice Key numbers of the story, returned so a test can pin them.
    struct Result {
        uint256 bobHealthBefore; // WAD
        uint256 bobHealthAfterCrash; // WAD
        uint256 firstRepaid; // USDC base units
        uint256 firstSeized; // WETH base units
        uint256 bobHealthAfterLiquidation; // WAD
        uint256 badDebt; // USDC base units
        uint256 aliceBalanceAtEnd; // USDC base units
    }

    MockERC20 internal weth;
    MockERC20 internal usdc;
    MockAggregatorV3 internal ethFeed;
    MockAggregatorV3 internal usdcFeed;
    LendingMarket internal market;
    bool internal _broadcast;

    /// @notice Anvil mode: real transactions, no time travel.
    function run() external returns (Result memory) {
        return _story(true, false);
    }

    /// @notice Simulation mode: also fast-forwards 365 days to show interest accrual.
    function runWithInterest() external returns (Result memory) {
        return _story(false, true);
    }

    /*//////////////////////////////////////////////////////////////
                                  STORY
    //////////////////////////////////////////////////////////////*/

    function _story(bool broadcast, bool timeTravel) internal returns (Result memory r) {
        _broadcast = broadcast;

        _banner(
            "1. DEPLOY (mock WETH / USDC / Chainlink feeds + the real oracle wrapper and market)"
        );
        _as(DEPLOYER);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        ethFeed = new MockAggregatorV3(8, "ETH / USD", 2000e8);
        usdcFeed = new MockAggregatorV3(8, "USDC / USD", 1e8);
        market = new LendingMarket(
            LendingMarket.MarketParams({
                collateralToken: IERC20Metadata(address(weth)),
                borrowToken: IERC20Metadata(address(usdc)),
                collateralOracle: IOracle(
                    address(new ChainlinkOracle(AggregatorV3Interface(address(ethFeed)), 7 days))
                ),
                borrowOracle: IOracle(
                    address(new ChainlinkOracle(AggregatorV3Interface(address(usdcFeed)), 7 days))
                ),
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
        usdc.mint(ALICE, 1_000_000e6);
        weth.mint(BOB, 100e18);
        usdc.mint(BOB, 100_000e6); // so Bob can pay interest later
        usdc.mint(CAROL, 1_000_000e6);
        _stop();
        _approve(ALICE, usdc);
        _approve(BOB, weth);
        _approve(BOB, usdc);
        _approve(CAROL, usdc);
        _log("market", vm.toString(address(market)));
        _log("parameters", "max LTV 75% | liquidation threshold 80% | bonus 5% | close factor 50%");
        _log("rate model", "0% base, +4% up to the 80% kink, +75% above it");
        _log("prices", "ETH $2,000.00 | USDC $1.00");

        _banner("2. ALICE supplies 100,000 USDC");
        _as(ALICE);
        uint256 shares = market.supply(100_000e6);
        _stop();
        _log("shares minted", vm.toString(shares));
        _log("alice's balance", string.concat(_f(market.supplyBalance(ALICE), 6), " USDC"));

        _banner("3. BOB deposits 10 WETH ($20,000) and borrows 10,000 USDC");
        _as(BOB);
        market.depositCollateral(10e18);
        market.borrow(10_000e6);
        _stop();
        r.bobHealthBefore = market.healthFactor(BOB);
        _log("bob's debt", string.concat(_f(market.borrowBalance(BOB), 6), " USDC"));
        _log(
            "health factor", string.concat(_f(r.bobHealthBefore, 18), "  (liquidatable below 1.0)")
        );
        _log(
            "utilization",
            string.concat(
                _f(market.utilization(), 18), "  | borrow APR ", _f(market.currentBorrowRate(), 18)
            )
        );

        if (timeTravel) {
            _banner("4. ONE YEAR PASSES (feeds re-published at the same prices)");
            vm.warp(block.timestamp + 365 days);
            ethFeed.setAnswer(ethFeed.answer());
            usdcFeed.setAnswer(usdcFeed.answer());
            market.accrueInterest();
            _log(
                "bob's debt",
                string.concat(_f(market.borrowBalance(BOB), 6), " USDC  (interest accrued)")
            );
            _log(
                "alice's balance",
                string.concat(_f(market.supplyBalance(ALICE), 6), " USDC  (she earned it)")
            );
            _log("health factor", _f(market.healthFactor(BOB), 18));
        }

        _banner("5. ETH CRASHES from $2,000 to $1,200 (mock oracle updated)");
        _as(DEPLOYER);
        ethFeed.setAnswer(1200e8);
        _stop();
        r.bobHealthAfterCrash = market.healthFactor(BOB);
        _log(
            "health factor",
            string.concat(_f(r.bobHealthAfterCrash, 18), "  <- below 1.0: liquidatable")
        );

        _banner("6. CAROL liquidates Bob (close factor 50%, bonus 5%)");
        uint256 carolWethBefore = weth.balanceOf(CAROL);
        _as(CAROL);
        (r.firstRepaid, r.firstSeized) = market.liquidate(BOB, type(uint256).max);
        _stop();
        _log("carol repaid", string.concat(_f(r.firstRepaid, 6), " USDC of Bob's debt"));
        _log("carol received", string.concat(_f(r.firstSeized, 18), " WETH"));
        _log(
            "  worth",
            string.concat(
                "$", _f(r.firstSeized * 1200, 18), " at $1,200/ETH (5% more than she paid)"
            )
        );
        _log("bob's debt left", string.concat(_f(market.borrowBalance(BOB), 6), " USDC"));
        _log("bob's collateral", string.concat(_f(market.collateralOf(BOB), 18), " WETH"));
        r.bobHealthAfterLiquidation = market.healthFactor(BOB);
        _log(
            "health factor",
            string.concat(_f(r.bobHealthAfterLiquidation, 18), "  <- healthy again")
        );
        require(weth.balanceOf(CAROL) - carolWethBefore == r.firstSeized, "demo: bad accounting");

        _banner("7. ETH CRASHES AGAIN to $300: Bob's collateral can no longer cover his debt");
        _as(DEPLOYER);
        ethFeed.setAnswer(300e8);
        _stop();
        _log("health factor", _f(market.healthFactor(BOB), 18));
        _log(
            "position",
            string.concat(
                "collateral worth $",
                _f(market.collateralOf(BOB) * 300, 18),
                " vs debt ",
                _f(market.borrowBalance(BOB), 6),
                " USDC"
            )
        );

        _banner("8. CAROL liquidates again -> all collateral seized, the rest is BAD DEBT");
        _as(CAROL);
        (uint256 repaid2, uint256 seized2) = market.liquidate(BOB, type(uint256).max);
        _stop();
        _log("carol repaid", string.concat(_f(repaid2, 6), " USDC"));
        _log("carol received", string.concat(_f(seized2, 18), " WETH  (everything Bob had left)"));
        r.badDebt = market.totalBadDebt();
        _log("BAD DEBT recorded", string.concat(_f(r.badDebt, 6), " USDC, socialized to suppliers"));
        _log(
            "bob's debt now",
            string.concat(_f(market.borrowBalance(BOB), 6), " USDC  (written off)")
        );

        _banner("9. SUMMARY");
        r.aliceBalanceAtEnd = market.supplyBalance(ALICE);
        _log("alice supplied", "100000.000000 USDC");
        _log("alice can redeem", string.concat(_f(r.aliceBalanceAtEnd, 6), " USDC"));
        _log("note", "the shortfall is the bad debt; a production system would let an insurance");
        _log("", "fund absorb it first. In v1 the suppliers bear it (see docs/THREAT_MODEL.md).");
    }

    /*//////////////////////////////////////////////////////////////
                                 HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Act as `who`: a real transaction sender when broadcasting, a prank otherwise.
    function _as(address who) internal {
        if (_broadcast) vm.startBroadcast(who);
        else vm.startPrank(who);
    }

    function _stop() internal {
        if (_broadcast) vm.stopBroadcast();
        else vm.stopPrank();
    }

    function _approve(address who, MockERC20 token) internal {
        _as(who);
        token.approve(address(market), type(uint256).max);
        _stop();
    }

    /// @dev One aligned label  value line.
    function _log(string memory label, string memory value) internal pure {
        bytes memory pad = new bytes(bytes(label).length < 18 ? 18 - bytes(label).length : 1);
        for (uint256 i = 0; i < pad.length; i++) {
            pad[i] = " ";
        }
        console.log(string.concat(label, string(pad), value));
    }

    function _banner(string memory title) internal pure {
        console.log("");
        console.log(string.concat("== ", title));
    }

    /// @dev Fixed-point to string: `amount / 10**decimals` with up to `decimals` fractional digits,
    ///      at most 6 fractional digits shown, truncated (display only).
    function _f(uint256 amount, uint8 decimals) internal pure returns (string memory) {
        uint256 unit = 10 ** decimals;
        uint256 whole = amount / unit;
        if (decimals == 0) return vm.toString(whole);
        uint256 frac = amount % unit;
        uint8 shown = decimals > 6 ? 6 : decimals;
        frac = frac / (10 ** (decimals - shown));
        bytes memory digits = bytes(vm.toString(frac));
        bytes memory pad = new bytes(shown - digits.length);
        for (uint256 i = 0; i < pad.length; i++) {
            pad[i] = "0";
        }
        return string.concat(vm.toString(whole), ".", string(pad), string(digits));
    }
}
