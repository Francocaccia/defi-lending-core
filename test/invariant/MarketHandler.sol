// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {LendingMarket} from "../../src/LendingMarket.sol";
import {IOracle} from "../../src/interfaces/IOracle.sol";
import {RiskMath} from "../../src/libraries/RiskMath.sol";
import {SharesMath} from "../../src/libraries/SharesMath.sol";
import {WAD} from "../../src/libraries/Units.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockAggregatorV3} from "../mocks/MockAggregatorV3.sol";

/// @notice Drives the market through random but VALID action sequences for invariant testing.
///
/// Design rules (so the invariants are meaningful and not vacuous):
///  - Handler functions never revert for avoidable reasons: arguments are bounded to what the
///    protocol accepts. `fail_on_revert = true` makes any unexpected revert a test failure.
///  - Only actions whose success genuinely depends on market state (borrow at the limit,
///    collateral withdrawal, liquidation, dust repay) use try/catch, and then ONLY the specific,
///    expected error selectors are tolerated. Any other revert is re-thrown.
///  - Every token flow through the market is mirrored in ghost variables so the invariants can
///    check exact conservation, including a "donation" action that sends tokens straight to
///    the market to prove donations change no accounting.
///  - Time warps and price moves keep both oracles fresh (the oracle's own staleness behaviour
///    has dedicated tests); prices swing widely so liquidations and bad debt actually occur.
contract MarketHandler is Test {
    LendingMarket public immutable MARKET;
    MockERC20 public immutable WETH;
    MockERC20 public immutable USDC;
    MockAggregatorV3 public immutable ETH_FEED;
    MockAggregatorV3 public immutable USDC_FEED;
    IOracle public immutable ETH_ORACLE;
    IOracle public immutable USDC_ORACLE;

    address[] public actors;
    address public immutable LIQUIDATOR;

    // ---- exact token-flow ghosts (borrow-asset side) ----
    uint256 public ghostUsdcIn; // supply + repay + liquidation repayments
    uint256 public ghostUsdcOut; // withdraw + redeem + borrow
    uint256 public ghostUsdcDonated;
    uint256 public ghostWethDonated;

    // ---- invariant-violation counters (must stay 0) ----
    uint256 public ghostLtvViolations; // (c) successful collateral withdrawal broke max LTV
    uint256 public ghostSharePriceViolations; // (d) share price fell without recorded bad debt
    uint256 public ghostIndexViolations; // borrow index decreased

    // ---- coverage counters: prove the interesting paths are reached ----
    uint256 public nLiquidations;
    uint256 public nBadDebtEvents;
    uint256 public nBorrows;
    uint256 public nCollateralWithdrawals;
    uint256 public nCollateralWithdrawalsWithDebt;
    uint256 public nWithdrawRejectedByLtv;

    // snapshot taken before every tracked action
    uint256 private _preAssets;
    uint256 private _preShares;
    uint256 private _preBadDebt;
    uint256 private _preIndex;

    constructor(
        LendingMarket market,
        MockERC20 weth,
        MockERC20 usdc,
        MockAggregatorV3 ethFeed,
        MockAggregatorV3 usdcFeed,
        IOracle ethOracle,
        IOracle usdcOracle,
        uint256 numActors
    ) {
        MARKET = market;
        WETH = weth;
        USDC = usdc;
        ETH_FEED = ethFeed;
        USDC_FEED = usdcFeed;
        ETH_ORACLE = ethOracle;
        USDC_ORACLE = usdcOracle;

        for (uint256 i = 0; i < numActors; i++) {
            address a = makeAddr(string.concat("actor", vm.toString(i)));
            actors.push(a);
            _fund(a);
        }
        LIQUIDATOR = makeAddr("liquidator");
        _fund(LIQUIDATOR);
    }

    function _fund(address who) private {
        WETH.mint(who, 1_000_000e18);
        USDC.mint(who, 1_000_000_000e6);
        vm.startPrank(who);
        WETH.approve(address(MARKET), type(uint256).max);
        USDC.approve(address(MARKET), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev Called once from the invariant setUp: every actor supplies liquidity and posts
    ///      collateral so that borrowing, price-driven liquidation and bad debt are reachable
    ///      from the very first fuzzed call instead of after a lucky sequence.
    function seedMarket(uint256 supplyEach, uint256 collateralEach) external {
        for (uint256 i = 0; i < actors.length; i++) {
            vm.startPrank(actors[i]);
            MARKET.supply(supplyEach);
            MARKET.depositCollateral(collateralEach);
            vm.stopPrank();
            ghostUsdcIn += supplyEach;
        }
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    /*//////////////////////////////////////////////////////////////
                         SNAPSHOT / POST-CHECKS
    //////////////////////////////////////////////////////////////*/

    modifier tracked() {
        _preAssets = MARKET.totalSupplyAssets();
        _preShares = MARKET.totalSupplyShares();
        _preBadDebt = MARKET.totalBadDebt();
        _preIndex = MARKET.borrowIndex();
        _;
        // Realize pending interest so that stored state == current state when invariants run.
        MARKET.accrueInterest();
        _postChecks();
    }

    function _postChecks() private {
        if (MARKET.borrowIndex() < _preIndex) ghostIndexViolations++;

        // Share price (A + VA) / (S + VS) may fall ONLY through recorded bad debt.
        uint256 a1 = MARKET.totalSupplyAssets() + SharesMath.VIRTUAL_ASSETS;
        uint256 s1 = MARKET.totalSupplyShares() + SharesMath.VIRTUAL_SHARES;
        uint256 a0 = _preAssets + SharesMath.VIRTUAL_ASSETS;
        uint256 s0 = _preShares + SharesMath.VIRTUAL_SHARES;
        bool badDebtThisStep = MARKET.totalBadDebt() > _preBadDebt;
        if (!badDebtThisStep && a1 * s0 < a0 * s1) ghostSharePriceViolations++;
    }

    function _actor(uint256 seed) private view returns (address) {
        return actors[seed % actors.length];
    }

    /// @dev Re-throws (failing the run) unless `err` carries exactly the expected selector.
    ///      Empty revert data never matches, so silent/unknown reverts are never tolerated.
    function _requireExpected(bytes memory err, bytes4 expected) private pure {
        if (err.length < 4 || bytes4(err) != expected) {
            assembly {
                revert(add(err, 32), mload(err))
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                              SUPPLY SIDE
    //////////////////////////////////////////////////////////////*/

    function supply(uint256 actorSeed, uint256 amount) external tracked {
        address who = _actor(actorSeed);
        amount = bound(amount, 1, 2_000_000e6);
        vm.prank(who);
        MARKET.supply(amount);
        ghostUsdcIn += amount;
    }

    function withdraw(uint256 actorSeed, uint256 amount) external tracked {
        address who = _actor(actorSeed);
        uint256 cap = MARKET.supplyBalance(who);
        uint256 liquid = MARKET.liquidity();
        if (liquid < cap) cap = liquid;
        if (cap == 0) return;
        amount = bound(amount, 1, cap);
        vm.prank(who);
        MARKET.withdraw(amount);
        ghostUsdcOut += amount;
    }

    function redeem(uint256 actorSeed, uint256 shares) external tracked {
        address who = _actor(actorSeed);
        uint256 owned = MARKET.supplyShares(who);
        if (owned == 0) return;
        shares = bound(shares, 1, owned);
        uint256 worth =
            SharesMath.toAssetsDown(shares, MARKET.totalSupplyAssets(), MARKET.totalSupplyShares());
        if (worth == 0 || worth > MARKET.liquidity()) return;
        vm.prank(who);
        uint256 assets = MARKET.redeem(shares);
        ghostUsdcOut += assets;
    }

    /// @dev Direct token transfers into the market. Must change no share price and no accounting.
    function donate(uint256 usdcAmount, uint256 wethAmount) external tracked {
        usdcAmount = bound(usdcAmount, 0, 1_000_000e6);
        wethAmount = bound(wethAmount, 0, 1000e18);
        if (usdcAmount > 0) {
            USDC.mint(address(this), usdcAmount);
            USDC.transfer(address(MARKET), usdcAmount);
            ghostUsdcDonated += usdcAmount;
        }
        if (wethAmount > 0) {
            WETH.mint(address(this), wethAmount);
            WETH.transfer(address(MARKET), wethAmount);
            ghostWethDonated += wethAmount;
        }
    }

    /*//////////////////////////////////////////////////////////////
                           COLLATERAL / BORROW
    //////////////////////////////////////////////////////////////*/

    function depositCollateral(uint256 actorSeed, uint256 amount) external tracked {
        address who = _actor(actorSeed);
        amount = bound(amount, 1, 500e18);
        vm.prank(who);
        MARKET.depositCollateral(amount);
    }

    function withdrawCollateral(uint256 actorSeed, uint256 amount) external tracked {
        address who = _actor(actorSeed);
        uint256 held = MARKET.collateralOf(who);
        if (held == 0) return;
        amount = bound(amount, 1, held);

        vm.prank(who);
        try MARKET.withdrawCollateral(amount) {
            nCollateralWithdrawals++;
            // INVARIANT (c): a SUCCESSFUL withdrawal must leave the position within max LTV
            // (and therefore healthy). Re-derive that from scratch with the oracle prices.
            if (MARKET.scaledDebt(who) != 0) {
                nCollateralWithdrawalsWithDebt++;
                if (!_withinMaxLtv(who) || MARKET.healthFactor(who) < WAD) ghostLtvViolations++;
            }
        } catch (bytes memory err) {
            _requireExpected(err, LendingMarket.Market__ExceedsMaxLtv.selector);
            nWithdrawRejectedByLtv++;
        }
    }

    /// @param bps Fraction (in basis points of the remaining capacity) to borrow: 1..10_000.
    function borrow(uint256 actorSeed, uint256 bps) external tracked {
        address who = _actor(actorSeed);
        bps = bound(bps, 1, 10_000);

        uint256 pc = ETH_ORACLE.price();
        uint256 pb = USDC_ORACLE.price();
        uint256 collValue = RiskMath.collateralValueUsd(MARKET.collateralOf(who), pc, 18);
        uint256 debtValue = RiskMath.debtValueUsd(MARKET.borrowBalance(who), pb, 6);
        uint256 limit = RiskMath.maxDebtValue(collValue, MARKET.MAX_LTV());
        if (limit <= debtValue) return;

        // remaining capacity in USD (WAD) -> borrow-asset base units
        uint256 assets = (limit - debtValue) * 1e6 / pb * bps / 10_000;
        uint256 liquid = MARKET.liquidity();
        if (assets > liquid) assets = liquid;
        if (assets == 0) return;

        vm.prank(who);
        try MARKET.borrow(assets) {
            nBorrows++;
            ghostUsdcOut += assets;
        } catch (bytes memory err) {
            // At exactly 100% of capacity rounding can tip one wei over the limit.
            _requireExpected(err, LendingMarket.Market__ExceedsMaxLtv.selector);
        }
    }

    function repay(uint256 actorSeed, uint256 amount, bool all) external tracked {
        address who = _actor(actorSeed);
        uint256 debt = MARKET.borrowBalance(who);
        if (debt == 0) return;
        amount = all ? type(uint256).max : bound(amount, 1, debt);

        vm.prank(who);
        try MARKET.repay(amount, who) returns (uint256 repaid) {
            ghostUsdcIn += repaid;
        } catch (bytes memory err) {
            // A 1-wei repay can burn no scaled debt once the index is above 1.0.
            _requireExpected(err, LendingMarket.Market__RepayTooSmall.selector);
        }
    }

    /*//////////////////////////////////////////////////////////////
                              LIQUIDATION
    //////////////////////////////////////////////////////////////*/

    function liquidate(uint256 victimSeed, uint256 amount, bool all) external tracked {
        address victim = _actor(victimSeed);
        if (MARKET.scaledDebt(victim) == 0) return;
        if (MARKET.healthFactor(victim) >= WAD) return; // only attempt real liquidations

        uint256 debt = MARKET.borrowBalance(victim);
        amount = all ? type(uint256).max : bound(amount, 1, debt);
        uint256 badBefore = MARKET.totalBadDebt();

        vm.prank(LIQUIDATOR);
        try MARKET.liquidate(victim, amount) returns (uint256 repaid, uint256) {
            ghostUsdcIn += repaid;
            nLiquidations++;
            if (MARKET.totalBadDebt() > badBefore) nBadDebtEvents++;
        } catch (bytes memory err) {
            // A tiny partial request may burn no scaled debt (documented behaviour).
            _requireExpected(err, LendingMarket.Market__NothingToLiquidate.selector);
        }
    }

    /*//////////////////////////////////////////////////////////////
                           ENVIRONMENT (TIME / PRICE)
    //////////////////////////////////////////////////////////////*/

    /// @dev Wide swings so liquidations and bad debt are actually reached.
    function setEthPrice(uint256 priceUsd) external tracked {
        priceUsd = bound(priceUsd, 150, 4500);
        ETH_FEED.setAnswer(int256(priceUsd * 1e8));
    }

    /// @dev Borrow asset between $0.90 and $1.10 (the oracle, not a hardcoded $1, is trusted).
    function setUsdcPrice(uint256 answer) external tracked {
        answer = bound(answer, 90_000_000, 110_000_000); // 0.90e8 .. 1.10e8 (feed has 8 decimals)
        USDC_FEED.setAnswer(int256(answer));
    }

    function warp(uint256 dt) external tracked {
        dt = bound(dt, 1, 45 days);
        vm.warp(vm.getBlockTimestamp() + dt);
        // keep both feeds fresh at their current answers
        ETH_FEED.setAnswer(ETH_FEED.answer());
        USDC_FEED.setAnswer(USDC_FEED.answer());
    }

    /*//////////////////////////////////////////////////////////////
                                 HELPERS
    //////////////////////////////////////////////////////////////*/

    function _withinMaxLtv(address who) private view returns (bool) {
        uint256 collValue =
            RiskMath.collateralValueUsd(MARKET.collateralOf(who), ETH_ORACLE.price(), 18);
        uint256 debtValue = RiskMath.debtValueUsd(MARKET.borrowBalance(who), USDC_ORACLE.price(), 6);
        return RiskMath.isWithinMaxLtv(collValue, debtValue, MARKET.MAX_LTV());
    }
}
