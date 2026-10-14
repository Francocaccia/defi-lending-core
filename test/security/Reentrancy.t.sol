// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {
    AggregatorV3Interface
} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

import {LendingMarket} from "../../src/LendingMarket.sol";
import {ChainlinkOracle} from "../../src/oracle/ChainlinkOracle.sol";
import {IOracle} from "../../src/interfaces/IOracle.sol";
import {InterestRateModel} from "../../src/libraries/InterestRateModel.sol";
import {RiskMath} from "../../src/libraries/RiskMath.sol";
import {HookERC20, IHookReceiver} from "../mocks/HookERC20.sol";
import {MockAggregatorV3} from "../mocks/MockAggregatorV3.sol";

/// @notice An actor that is a CONTRACT, so hostile tokens can call back into it mid-transfer.
///         When armed, its hook tries to re-enter the market with a prepared call and records
///         whether that succeeded and (if not) the error selector. It also snapshots the market's
///         public views at the moment of the callback, to check read-only reentrancy.
contract Attacker is IHookReceiver {
    LendingMarket public immutable MARKET;

    bytes public armedCall;
    bool public armed;
    bool public attempted;
    bool public reentrySucceeded;
    bytes4 public errorSelector;

    // views observed DURING the callback
    uint256 public seenTotalSupplyAssets;
    uint256 public seenTotalScaledDebt;
    uint256 public seenSupplyBalance;
    uint256 public seenCollateral;

    constructor(LendingMarket market) {
        MARKET = market;
    }

    function arm(bytes calldata data) external {
        armedCall = data;
        armed = true;
        attempted = false;
        reentrySucceeded = false;
        errorSelector = bytes4(0);
    }

    function onTokenHook(address, address, address, uint256) external {
        if (!armed) return;
        armed = false; // fire once

        seenTotalSupplyAssets = MARKET.totalSupplyAssets();
        seenTotalScaledDebt = MARKET.totalScaledDebt();
        seenSupplyBalance = MARKET.supplyBalance(address(this));
        seenCollateral = MARKET.collateralOf(address(this));

        attempted = true;
        (bool ok, bytes memory ret) = address(MARKET).call(armedCall);
        reentrySucceeded = ok;
        if (!ok && ret.length >= 4) errorSelector = bytes4(ret);
    }

    // ---- the attacker's own legitimate calls ----
    function approveAll(address token) external {
        IERC20Metadata(token).approve(address(MARKET), type(uint256).max);
    }

    function supply(uint256 a) external {
        MARKET.supply(a);
    }

    function withdraw(uint256 a) external {
        MARKET.withdraw(a);
    }

    function redeem(uint256 s) external {
        MARKET.redeem(s);
    }

    function depositCollateral(uint256 a) external {
        MARKET.depositCollateral(a);
    }

    function withdrawCollateral(uint256 a) external {
        MARKET.withdrawCollateral(a);
    }

    function borrow(uint256 a) external {
        MARKET.borrow(a);
    }

    function repay(uint256 a) external {
        MARKET.repay(a, address(this));
    }

    function liquidate(address victim, uint256 a) external {
        MARKET.liquidate(victim, a);
    }
}

contract ReentrancyTest is Test {
    HookERC20 internal weth;
    HookERC20 internal usdc;
    MockAggregatorV3 internal ethFeed;
    MockAggregatorV3 internal usdcFeed;
    LendingMarket internal market;
    Attacker internal attacker;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    bytes4 internal immutable REENTRANT = ReentrancyGuard.ReentrancyGuardReentrantCall.selector;

    function setUp() public {
        vm.warp(1_700_000_000);
        weth = new HookERC20("Wrapped Ether", "WETH", 18);
        usdc = new HookERC20("USD Coin", "USDC", 6);
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

        attacker = new Attacker(market);
        // Honest counterparties.
        for (uint256 i = 0; i < 2; i++) {
            address u = i == 0 ? alice : bob;
            weth.mint(u, 1000e18);
            usdc.mint(u, 10_000_000e6);
            vm.startPrank(u);
            weth.approve(address(market), type(uint256).max);
            usdc.approve(address(market), type(uint256).max);
            vm.stopPrank();
        }
        // The attacker is a contract with funds and approvals.
        weth.mint(address(attacker), 1000e18);
        usdc.mint(address(attacker), 10_000_000e6);
        attacker.approveAll(address(weth));
        attacker.approveAll(address(usdc));

        // Switch the hostile behaviour ON for both tokens.
        weth.setHooks(true);
        usdc.setHooks(true);

        // Liquidity for borrowing tests.
        vm.prank(alice);
        market.supply(1_000_000e6);
    }

    function _assertBlocked() internal view {
        assertTrue(attacker.attempted(), "the hook must have fired");
        assertFalse(attacker.reentrySucceeded(), "re-entry must NOT succeed");
        assertEq(attacker.errorSelector(), REENTRANT, "blocked by the reentrancy guard");
    }

    function _assertSolvent() internal view {
        assertLe(
            market.totalSupplyAssets(), usdc.balanceOf(address(market)) + market.totalBorrowAssets()
        );
        assertEq(weth.balanceOf(address(market)), market.totalCollateral());
    }

    /*//////////////////////////////////////////////////////////////
                  RE-ENTRY DURING OUTGOING TRANSFERS
    //////////////////////////////////////////////////////////////*/

    function test_reentrancy_withdraw_cannotWithdrawTwice() public {
        attacker.supply(10_000e6);
        attacker.arm(abi.encodeCall(LendingMarket.withdraw, (10_000e6)));

        uint256 before = usdc.balanceOf(address(attacker));
        attacker.withdraw(10_000e6);

        _assertBlocked();
        assertEq(usdc.balanceOf(address(attacker)) - before, 10_000e6, "paid out exactly once");
        _assertSolvent();
    }

    function test_reentrancy_redeem_cannotRedeemTwice() public {
        attacker.supply(10_000e6);
        uint256 shares = market.supplyShares(address(attacker));
        attacker.arm(abi.encodeCall(LendingMarket.redeem, (shares)));

        attacker.redeem(shares);

        _assertBlocked();
        assertEq(market.supplyShares(address(attacker)), 0);
        _assertSolvent();
    }

    function test_reentrancy_borrow_cannotBorrowAgainBeforeDebtIsFinal() public {
        attacker.depositCollateral(10e18);
        attacker.arm(abi.encodeCall(LendingMarket.borrow, (5000e6)));

        attacker.borrow(10_000e6);

        _assertBlocked();
        assertEq(market.borrowBalance(address(attacker)), 10_000e6, "only one borrow took place");
        _assertSolvent();
    }

    function test_reentrancy_withdrawCollateral_cannotDrainCollateral() public {
        attacker.depositCollateral(10e18);
        attacker.arm(abi.encodeCall(LendingMarket.withdrawCollateral, (10e18)));

        attacker.withdrawCollateral(4e18);

        _assertBlocked();
        assertEq(market.collateralOf(address(attacker)), 6e18);
        _assertSolvent();
    }

    /*//////////////////////////////////////////////////////////////
                    RE-ENTRY DURING INCOMING TRANSFERS
    //////////////////////////////////////////////////////////////*/

    function test_reentrancy_supply_hookOnPullCannotReenter() public {
        // The hook fires on the attacker as SENDER (tokensToSend) while supply() pulls tokens.
        attacker.arm(abi.encodeCall(LendingMarket.supply, (1e6)));
        attacker.supply(10_000e6);
        _assertBlocked();
        _assertSolvent();
    }

    function test_reentrancy_repay_hookOnPullCannotReenter() public {
        attacker.depositCollateral(10e18);
        attacker.borrow(10_000e6);
        attacker.arm(abi.encodeCall(LendingMarket.repay, (1000e6, address(attacker))));

        attacker.repay(5000e6);

        _assertBlocked();
        assertEq(market.borrowBalance(address(attacker)), 5000e6, "single repayment applied");
        _assertSolvent();
    }

    function test_reentrancy_depositCollateral_hookOnPullCannotReenter() public {
        attacker.arm(abi.encodeCall(LendingMarket.withdrawCollateral, (1)));
        attacker.depositCollateral(5e18);
        _assertBlocked();
        assertEq(market.collateralOf(address(attacker)), 5e18);
    }

    /*//////////////////////////////////////////////////////////////
                         LIQUIDATION RE-ENTRY
    //////////////////////////////////////////////////////////////*/

    function test_reentrancy_liquidate_receivingSeizedCollateralCannotLiquidateAgain() public {
        // Bob borrows; ETH crashes; the ATTACKER liquidates and gets WETH (hook fires on receipt).
        vm.prank(bob);
        market.depositCollateral(10e18);
        vm.prank(bob);
        market.borrow(10_000e6);
        ethFeed.setAnswer(1200e8);

        attacker.arm(abi.encodeCall(LendingMarket.liquidate, (bob, type(uint256).max)));
        attacker.liquidate(bob, type(uint256).max);

        _assertBlocked();
        // Exactly one 50% liquidation happened.
        assertEq(market.borrowBalance(bob), 5000e6);
        assertEq(weth.balanceOf(address(attacker)), 1000e18 + 4.375e18);
        _assertSolvent();
    }

    /*//////////////////////////////////////////////////////////////
                        READ-ONLY REENTRANCY
    //////////////////////////////////////////////////////////////*/

    /// Effects are applied BEFORE tokens move, so a view called from inside the token callback
    /// already shows the final state (no stale/half-updated numbers for other protocols to read).
    function test_readOnlyReentrancy_withdraw_viewsAlreadyShowFinalState() public {
        attacker.supply(10_000e6);
        attacker.arm(abi.encodeCall(LendingMarket.accrueInterest, ()));

        attacker.withdraw(4000e6);

        assertTrue(attacker.attempted());
        assertEq(
            attacker.seenTotalSupplyAssets(), market.totalSupplyAssets(), "assets already final"
        );
        assertEq(
            attacker.seenSupplyBalance(), market.supplyBalance(address(attacker)), "balance final"
        );
    }

    function test_readOnlyReentrancy_borrow_viewsAlreadyShowFinalDebt() public {
        attacker.depositCollateral(10e18);
        attacker.arm(abi.encodeCall(LendingMarket.accrueInterest, ()));

        attacker.borrow(7000e6);

        assertTrue(attacker.attempted());
        assertEq(attacker.seenTotalScaledDebt(), market.totalScaledDebt(), "debt already recorded");
    }

    function test_readOnlyReentrancy_withdrawCollateral_viewsAlreadyShowFinalCollateral() public {
        attacker.depositCollateral(10e18);
        attacker.arm(abi.encodeCall(LendingMarket.accrueInterest, ()));

        attacker.withdrawCollateral(3e18);

        assertTrue(attacker.attempted());
        assertEq(attacker.seenCollateral(), 7e18, "collateral already reduced");
    }
}
