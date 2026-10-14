// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IOracle} from "./interfaces/IOracle.sol";
import {InterestRateModel} from "./libraries/InterestRateModel.sol";
import {SharesMath} from "./libraries/SharesMath.sol";
import {BorrowMath} from "./libraries/BorrowMath.sol";
import {RiskMath} from "./libraries/RiskMath.sol";
import {RAY, WAD} from "./libraries/Units.sol";

/// @title LendingMarket
/// @notice A single over-collateralized lending market: ONE collateral asset (e.g. WETH),
///         ONE borrow/supply asset (e.g. USDC). Educational; not audited; never use with real funds.
/// @dev Roles: SUPPLIERS deposit the borrow asset and earn interest through shares. BORROWERS
///      lock collateral and borrow against it. LIQUIDATORS repay part of an unhealthy borrower's
///      debt and receive collateral plus a bonus.
///
///      All parameters are immutable and there is no owner/admin: nobody can pause, upgrade,
///      change a parameter or touch user funds.
///
///      Accounting identity (up to rounding dust, always in the protocol's favour):
///          totalSupplyAssets  <=  tokens held as idle cash  +  totalBorrowAssets()
///      Idle cash is NOT read from `balanceOf` (a direct donation to the contract cannot move any
///      price or share ratio); it is the accounting figure `totalSupplyAssets - totalBorrowAssets()`.
///
///      Ordering rule in every state-changing function: (1) accrue interest, (2) checks, (3) effects
///      on storage, (4) token transfers last (Checks-Effects-Interactions), plus `nonReentrant`.
///
///      Tokens are assumed to be plain ERC-20s: no fee-on-transfer, no rebasing, no transfer hooks.
contract LendingMarket is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                 TYPES
    //////////////////////////////////////////////////////////////*/

    /// @notice Everything fixed at deployment.
    struct MarketParams {
        IERC20Metadata collateralToken;
        IERC20Metadata borrowToken;
        IOracle collateralOracle;
        IOracle borrowOracle;
        InterestRateModel.Params rate;
        RiskMath.RiskParams risk;
    }

    /*//////////////////////////////////////////////////////////////
                           IMMUTABLE CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    IERC20 public immutable COLLATERAL_TOKEN;
    IERC20 public immutable BORROW_TOKEN;
    IOracle public immutable COLLATERAL_ORACLE;
    IOracle public immutable BORROW_ORACLE;
    uint8 public immutable COLLATERAL_DECIMALS;
    uint8 public immutable BORROW_DECIMALS;

    uint256 public immutable RATE_BASE;
    uint256 public immutable RATE_SLOPE1;
    uint256 public immutable RATE_SLOPE2;
    uint256 public immutable RATE_OPTIMAL_UTILIZATION;

    uint256 public immutable MAX_LTV;
    uint256 public immutable LIQUIDATION_THRESHOLD;
    uint256 public immutable LIQUIDATION_BONUS;
    uint256 public immutable CLOSE_FACTOR;

    /*//////////////////////////////////////////////////////////////
                                  STATE
    //////////////////////////////////////////////////////////////*/

    // --- supply side ---
    /// @notice Assets owed to suppliers (cash + borrows, interest included), as of `lastAccrual`.
    uint256 public totalSupplyAssets;
    /// @notice Supplier shares outstanding.
    uint256 public totalSupplyShares;
    /// @notice Supplier shares per account.
    mapping(address account => uint256 shares) public supplyShares;

    // --- borrow side ---
    /// @notice Sum of every borrower's scaled debt (exact; total debt is derived from it).
    uint256 public totalScaledDebt;
    /// @notice Global borrow index, RAY-scaled, starts at 1e27 and only grows.
    uint256 public borrowIndex = RAY;
    /// @notice Timestamp of the last interest accrual.
    uint256 public lastAccrual;
    /// @notice Borrower scaled debt: debt = ceil(scaled * borrowIndex / RAY).
    mapping(address account => uint256 scaled) public scaledDebt;

    // --- collateral ---
    /// @notice Collateral deposited per account (collateral base units).
    mapping(address account => uint256 amount) public collateralOf;
    /// @notice Total collateral held for borrowers.
    uint256 public totalCollateral;

    // --- bad debt ---
    /// @notice Cumulative supplier loss from written-off bad debt (borrow-asset base units).
    uint256 public totalBadDebt;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Interest was accrued: `interest` was added to total borrows and supplier assets.
    event InterestAccrued(uint256 interest, uint256 newBorrowIndex, uint256 elapsed);
    event Supply(address indexed supplier, uint256 assets, uint256 shares);
    event Withdraw(address indexed supplier, uint256 assets, uint256 shares);
    event CollateralDeposited(address indexed borrower, uint256 amount);
    event CollateralWithdrawn(address indexed borrower, uint256 amount);
    event Borrow(address indexed borrower, uint256 assets, uint256 scaledDebtAdded);
    event Repay(
        address indexed payer, address indexed borrower, uint256 assets, uint256 scaledDebtBurned
    );
    event Liquidate(
        address indexed liquidator,
        address indexed borrower,
        uint256 debtRepaid,
        uint256 collateralSeized
    );
    /// @notice A borrower with no collateral left still owed debt; it was written off and the
    ///         loss was socialized to suppliers by reducing `totalSupplyAssets`.
    event BadDebtRecorded(address indexed borrower, uint256 debtWrittenOff, uint256 supplierLoss);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error Market__ZeroAmount();
    error Market__InvalidConfig();
    error Market__ZeroShares();
    error Market__InsufficientShares(uint256 requested, uint256 available);
    error Market__InsufficientLiquidity(uint256 requested, uint256 available);
    error Market__InsufficientCollateral(uint256 requested, uint256 available);
    error Market__ExceedsMaxLtv();
    error Market__NoDebt(address borrower);
    error Market__RepayTooSmall();
    error Market__PositionHealthy(uint256 healthFactor);
    error Market__NothingToLiquidate();

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param params Collateral/borrow tokens, one oracle per token, rate model and risk parameters.
    ///        Rate and risk parameters are validated here and can never change afterwards.
    constructor(MarketParams memory params) {
        if (
            address(params.collateralToken) == address(0)
                || address(params.borrowToken) == address(0)
                || address(params.collateralToken) == address(params.borrowToken)
                || address(params.collateralOracle) == address(0)
                || address(params.borrowOracle) == address(0)
        ) revert Market__InvalidConfig();

        InterestRateModel.validate(params.rate);
        RiskMath.validate(params.risk);

        uint8 collDecimals = params.collateralToken.decimals();
        uint8 borrowDecimals = params.borrowToken.decimals();
        // 10**decimals is used inside mulDiv denominators/operands: bound it to stay far from overflow.
        if (collDecimals > 18 || borrowDecimals > 18) revert Market__InvalidConfig();

        COLLATERAL_TOKEN = params.collateralToken;
        BORROW_TOKEN = params.borrowToken;
        COLLATERAL_ORACLE = params.collateralOracle;
        BORROW_ORACLE = params.borrowOracle;
        COLLATERAL_DECIMALS = collDecimals;
        BORROW_DECIMALS = borrowDecimals;

        RATE_BASE = params.rate.baseRate;
        RATE_SLOPE1 = params.rate.slope1;
        RATE_SLOPE2 = params.rate.slope2;
        RATE_OPTIMAL_UTILIZATION = params.rate.optimalUtilization;

        MAX_LTV = params.risk.maxLtv;
        LIQUIDATION_THRESHOLD = params.risk.liquidationThreshold;
        LIQUIDATION_BONUS = params.risk.liquidationBonus;
        CLOSE_FACTOR = params.risk.closeFactor;

        lastAccrual = block.timestamp;
    }

    /*//////////////////////////////////////////////////////////////
                           INTEREST ACCRUAL
    //////////////////////////////////////////////////////////////*/

    /// @notice Bring the borrow index, total borrows and supplier assets up to the current block.
    /// @dev Anyone may call it. Every state-changing function already does so itself; this exists
    ///      so keepers/tests can refresh the stored totals without another action.
    function accrueInterest() external {
        _accrue();
    }

    /// @dev Interest for the elapsed interval is computed at the utilization in force at its START.
    ///      Suppliers are credited EXACTLY the increase in derived total debt, so the identity
    ///      `supply <= cash + debt` cannot be broken by rounding of the rate.
    function _accrue() internal {
        // Interest is a function of elapsed wall-clock time: using block.timestamp is the point.
        // forge-lint: disable-next-line(block-timestamp)
        uint256 elapsed = block.timestamp - lastAccrual;
        // Slither incorrect-equality: a zero-check on a value DERIVED from internal accounting
        // (not an ether/token balance an attacker can nudge), see docs/SLITHER_TRIAGE.md.
        // slither-disable-start incorrect-equality
        // forge-lint: disable-next-line(block-timestamp)
        if (elapsed == 0) return;
        // slither-disable-end incorrect-equality

        (uint256 newIndex, uint256 interest) = _previewAccrual(elapsed);
        lastAccrual = block.timestamp;
        borrowIndex = newIndex;
        totalSupplyAssets += interest;

        emit InterestAccrued(interest, newIndex, elapsed);
    }

    /// @dev Pure projection of an accrual over `elapsed` seconds from current storage.
    function _previewAccrual(uint256 elapsed)
        internal
        view
        returns (uint256 newIndex, uint256 interest)
    {
        uint256 oldDebt = BorrowMath.debtFromScaled(totalScaledDebt, borrowIndex);
        uint256 u = InterestRateModel.utilization(totalSupplyAssets, oldDebt);
        uint256 ratePerSecond = InterestRateModel.borrowRatePerSecond(_rateParams(), u);

        newIndex = BorrowMath.accrueIndex(borrowIndex, ratePerSecond, elapsed);
        interest = BorrowMath.debtFromScaled(totalScaledDebt, newIndex) - oldDebt;
    }

    /// @dev Borrow index as it would be if accrued right now (for views).
    function _currentIndex() internal view returns (uint256 index, uint256 pendingInterest) {
        // forge-lint: disable-next-line(block-timestamp)
        uint256 elapsed = block.timestamp - lastAccrual;
        // Slither incorrect-equality: a zero-check on a value DERIVED from internal accounting
        // (not an ether/token balance an attacker can nudge), see docs/SLITHER_TRIAGE.md.
        // slither-disable-start incorrect-equality
        // forge-lint: disable-next-line(block-timestamp)
        if (elapsed == 0) return (borrowIndex, 0);
        // slither-disable-end incorrect-equality
        return _previewAccrual(elapsed);
    }

    function _rateParams() internal view returns (InterestRateModel.Params memory) {
        return InterestRateModel.Params({
            baseRate: RATE_BASE,
            slope1: RATE_SLOPE1,
            slope2: RATE_SLOPE2,
            optimalUtilization: RATE_OPTIMAL_UTILIZATION
        });
    }

    /*//////////////////////////////////////////////////////////////
                               SUPPLY SIDE
    //////////////////////////////////////////////////////////////*/

    /// @notice Deposit `assets` of the borrow token and receive supplier shares.
    /// @dev Shares are rounded DOWN (the depositor gets slightly fewer). Reverts if that rounds to
    ///      zero shares, so a deposit can never be silently swallowed.
    /// @param assets Amount of borrow token to deposit (base units).
    /// @return shares Shares minted to the caller.
    function supply(uint256 assets) external nonReentrant returns (uint256 shares) {
        if (assets == 0) revert Market__ZeroAmount();
        _accrue();

        shares = SharesMath.toSharesDown(assets, totalSupplyAssets, totalSupplyShares);
        // Slither incorrect-equality: a zero-check on a value DERIVED from internal accounting
        // (not an ether/token balance an attacker can nudge), see docs/SLITHER_TRIAGE.md.
        // slither-disable-start incorrect-equality
        if (shares == 0) revert Market__ZeroShares();
        // slither-disable-end incorrect-equality

        totalSupplyAssets += assets;
        totalSupplyShares += shares;
        supplyShares[msg.sender] += shares;

        emit Supply(msg.sender, assets, shares);
        BORROW_TOKEN.safeTransferFrom(msg.sender, address(this), assets);
    }

    /// @notice Withdraw exactly `assets` of the borrow token, burning the shares that cover it.
    /// @dev Burned shares are rounded UP (the withdrawer pays slightly more). Limited by idle
    ///      liquidity: assets currently lent out cannot be withdrawn.
    /// @param assets Amount of borrow token to withdraw (base units).
    /// @return shares Shares burned from the caller.
    function withdraw(uint256 assets) external nonReentrant returns (uint256 shares) {
        if (assets == 0) revert Market__ZeroAmount();
        _accrue();

        shares = SharesMath.toSharesUp(assets, totalSupplyAssets, totalSupplyShares);
        _withdraw(assets, shares);
    }

    /// @notice Burn exactly `shares` and receive the assets they are worth.
    /// @dev Assets are rounded DOWN (the redeemer receives slightly less).
    /// @param shares Shares to burn.
    /// @return assets Borrow token sent to the caller (base units).
    function redeem(uint256 shares) external nonReentrant returns (uint256 assets) {
        if (shares == 0) revert Market__ZeroAmount();
        _accrue();

        assets = SharesMath.toAssetsDown(shares, totalSupplyAssets, totalSupplyShares);
        // Slither incorrect-equality: a zero-check on a value DERIVED from internal accounting
        // (not an ether/token balance an attacker can nudge), see docs/SLITHER_TRIAGE.md.
        // slither-disable-start incorrect-equality
        if (assets == 0) revert Market__ZeroAmount();
        // slither-disable-end incorrect-equality
        _withdraw(assets, shares);
    }

    function _withdraw(uint256 assets, uint256 shares) internal {
        uint256 owned = supplyShares[msg.sender];
        if (shares > owned) revert Market__InsufficientShares(shares, owned);

        uint256 available = _liquidity();
        if (assets > available) revert Market__InsufficientLiquidity(assets, available);

        supplyShares[msg.sender] = owned - shares;
        totalSupplyShares -= shares;
        totalSupplyAssets -= assets;

        emit Withdraw(msg.sender, assets, shares);
        BORROW_TOKEN.safeTransfer(msg.sender, assets);
    }

    /*//////////////////////////////////////////////////////////////
                           COLLATERAL MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /// @notice Deposit collateral. Needs no oracle, so it always works.
    /// @param amount Collateral token amount (base units).
    function depositCollateral(uint256 amount) external nonReentrant {
        if (amount == 0) revert Market__ZeroAmount();

        collateralOf[msg.sender] += amount;
        totalCollateral += amount;

        emit CollateralDeposited(msg.sender, amount);
        COLLATERAL_TOKEN.safeTransferFrom(msg.sender, address(this), amount);
    }

    /// @notice Withdraw collateral, allowed only if the remaining position stays within MAX_LTV.
    /// @dev Uses MAX_LTV (not the liquidation threshold) on purpose: withdrawing down to HF = 1
    ///      would hand the user a position that any price tick makes liquidatable. A user with no
    ///      debt skips the oracle entirely, so they can always exit even if a feed is down.
    /// @param amount Collateral token amount (base units).
    function withdrawCollateral(uint256 amount) external nonReentrant {
        if (amount == 0) revert Market__ZeroAmount();
        _accrue();

        uint256 held = collateralOf[msg.sender];
        if (amount > held) revert Market__InsufficientCollateral(amount, held);

        collateralOf[msg.sender] = held - amount;
        totalCollateral -= amount;

        // Effects are applied before the health check so the check sees the post-withdraw state;
        // a failing check reverts the whole call.
        if (scaledDebt[msg.sender] != 0) _requireWithinMaxLtv(msg.sender);

        emit CollateralWithdrawn(msg.sender, amount);
        COLLATERAL_TOKEN.safeTransfer(msg.sender, amount);
    }

    /*//////////////////////////////////////////////////////////////
                             BORROW / REPAY
    //////////////////////////////////////////////////////////////*/

    /// @notice Borrow `assets` of the borrow token against deposited collateral.
    /// @dev The assigned scaled debt is rounded UP and the post-borrow position must satisfy
    ///      debtValue <= collateralValue * MAX_LTV (collateral value down, debt value up).
    /// @param assets Amount of borrow token to receive (base units).
    function borrow(uint256 assets) external nonReentrant {
        if (assets == 0) revert Market__ZeroAmount();
        _accrue();

        uint256 available = _liquidity();
        if (assets > available) revert Market__InsufficientLiquidity(assets, available);

        uint256 scaled = BorrowMath.scaledFromAssetsUp(assets, borrowIndex);
        scaledDebt[msg.sender] += scaled;
        totalScaledDebt += scaled;

        _requireWithinMaxLtv(msg.sender);

        emit Borrow(msg.sender, assets, scaled);
        BORROW_TOKEN.safeTransfer(msg.sender, assets);
    }

    /// @notice Repay debt of `borrower` (anyone may repay for anyone).
    /// @dev `assets` is a CAP: pass `type(uint256).max` to repay exactly the full debt, which
    ///      avoids leaving dust when interest accrues between signing and inclusion. A partial
    ///      repay burns scaled debt rounded DOWN (repaying X reduces debt by at most X). Does not
    ///      use the oracle, so repaying always works.
    /// @param assets Max amount of borrow token to pay (base units).
    /// @param borrower Account whose debt is repaid.
    /// @return repaid Amount actually pulled from the caller.
    function repay(uint256 assets, address borrower)
        external
        nonReentrant
        returns (uint256 repaid)
    {
        if (assets == 0) revert Market__ZeroAmount();
        _accrue();

        uint256 scaled = scaledDebt[borrower];
        if (scaled == 0) revert Market__NoDebt(borrower);

        uint256 debt = BorrowMath.debtFromScaled(scaled, borrowIndex);
        uint256 burned;
        if (assets >= debt) {
            repaid = debt;
            burned = scaled;
        } else {
            repaid = assets;
            burned = BorrowMath.scaledFromAssetsDown(assets, borrowIndex);
            // Slither incorrect-equality: zero-check of a computed burn amount (docs/SLITHER_TRIAGE.md).
            // slither-disable-next-line incorrect-equality
            if (burned == 0) revert Market__RepayTooSmall();
        }

        scaledDebt[borrower] = scaled - burned;
        totalScaledDebt -= burned;

        emit Repay(msg.sender, borrower, repaid, burned);
        BORROW_TOKEN.safeTransferFrom(msg.sender, address(this), repaid);
    }

    /*//////////////////////////////////////////////////////////////
                              LIQUIDATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Repay part of an unhealthy borrower's debt and receive their collateral + bonus.
    /// @dev Requires HF < 1. The repaid amount is capped at CLOSE_FACTOR of the debt. The
    ///      collateral seized is `repaid * (1 + bonus)` in value, rounded DOWN, and capped at the
    ///      borrower's collateral; if the cap binds, the liquidator is only charged for what they
    ///      actually receive (repay rounded UP). If the borrower is left with debt but ZERO
    ///      collateral, the remainder is BAD DEBT: it is written off and the loss is socialized
    ///      to suppliers (`BadDebtRecorded`). A production system would first draw on an
    ///      insurance fund; this v1 only records and socializes (see docs/THREAT_MODEL.md).
    /// @param borrower The account to liquidate.
    /// @param maxRepay Max debt the liquidator is willing to repay (`type(uint256).max` = as much
    ///        as allowed).
    /// @return repaid Debt actually repaid by the caller (borrow-token base units).
    /// @return seized Collateral actually received by the caller (collateral base units).
    function liquidate(address borrower, uint256 maxRepay)
        external
        nonReentrant
        returns (uint256 repaid, uint256 seized)
    {
        if (maxRepay == 0) revert Market__ZeroAmount();
        _accrue();

        uint256 scaled = scaledDebt[borrower];
        if (scaled == 0) revert Market__NoDebt(borrower);
        uint256 debt = BorrowMath.debtFromScaled(scaled, borrowIndex);

        uint256 collPrice = COLLATERAL_ORACLE.price();
        uint256 debtPrice = BORROW_ORACLE.price();

        {
            uint256 collValue =
                RiskMath.collateralValueUsd(collateralOf[borrower], collPrice, COLLATERAL_DECIMALS);
            uint256 debtValue = RiskMath.debtValueUsd(debt, debtPrice, BORROW_DECIMALS);
            uint256 hf = RiskMath.healthFactor(collValue, debtValue, LIQUIDATION_THRESHOLD);
            if (hf >= WAD) revert Market__PositionHealthy(hf);
        }

        (repaid, seized) =
            _liquidationAmounts(debt, maxRepay, collateralOf[borrower], collPrice, debtPrice);
        uint256 burned =
            repaid >= debt ? scaled : BorrowMath.scaledFromAssetsDown(repaid, borrowIndex);
        // A repayment too small to burn any scaled debt is pointless and reverts, EXCEPT when it
        // seizes ALL remaining collateral: then the leftover debt is written off right below.
        // Without this exception, an extreme price collapse (collateral worth < ~1 unit of the
        // borrow asset against large debt) would make the position impossible to liquidate, and
        // its bad debt could never be cleared.
        // Slither incorrect-equality: a zero-check on a value DERIVED from internal accounting
        // (not an ether/token balance an attacker can nudge), see docs/SLITHER_TRIAGE.md.
        // slither-disable-start incorrect-equality
        bool takesAllCollateral = seized == collateralOf[borrower];
        if (repaid == 0 || seized == 0 || (burned == 0 && !takesAllCollateral)) {
            revert Market__NothingToLiquidate();
        }
        // slither-disable-end incorrect-equality

        scaledDebt[borrower] = scaled - burned;
        totalScaledDebt -= burned;
        collateralOf[borrower] -= seized;
        totalCollateral -= seized;

        emit Liquidate(msg.sender, borrower, repaid, seized);

        // Insolvent leftover: debt remains but there is nothing left to seize.
        // Slither incorrect-equality: a zero-check on a value DERIVED from internal accounting
        // (not an ether/token balance an attacker can nudge), see docs/SLITHER_TRIAGE.md.
        // slither-disable-start incorrect-equality
        if (collateralOf[borrower] == 0 && scaledDebt[borrower] != 0) _writeOffBadDebt(borrower);
        // slither-disable-end incorrect-equality

        BORROW_TOKEN.safeTransferFrom(msg.sender, address(this), repaid);
        COLLATERAL_TOKEN.safeTransfer(msg.sender, seized);
    }

    /// @dev Amounts for one liquidation, see `liquidate`.
    function _liquidationAmounts(
        uint256 debt,
        uint256 requested,
        uint256 collateral,
        uint256 collPrice,
        uint256 debtPrice
    ) internal view returns (uint256 repaid, uint256 seized) {
        repaid = RiskMath.maxRepayable(debt, CLOSE_FACTOR);
        if (requested < repaid) repaid = requested;

        seized = RiskMath.seizeForRepay(
            repaid, debtPrice, BORROW_DECIMALS, collPrice, COLLATERAL_DECIMALS, LIQUIDATION_BONUS
        );
        if (seized > collateral) {
            seized = collateral;
            uint256 forSeize = RiskMath.repayForSeize(
                collateral,
                debtPrice,
                BORROW_DECIMALS,
                collPrice,
                COLLATERAL_DECIMALS,
                LIQUIDATION_BONUS
            );
            // Rounding up can overshoot by <= 1 unit; never charge more than was asked/allowed.
            if (forSeize < repaid) repaid = forSeize;
        }
    }

    /// @dev Remove `borrower`'s remaining debt. The supplier loss is the DROP in derived total debt
    ///      (not the borrower's own ceil'd debt), which keeps `supply <= cash + debt` exact.
    function _writeOffBadDebt(address borrower) internal {
        uint256 scaled = scaledDebt[borrower];
        uint256 index = borrowIndex;
        uint256 debtBefore = BorrowMath.debtFromScaled(totalScaledDebt, index);

        scaledDebt[borrower] = 0;
        totalScaledDebt -= scaled;

        uint256 loss = debtBefore - BorrowMath.debtFromScaled(totalScaledDebt, index);
        // Saturate instead of reverting: a revert here would make liquidation impossible forever.
        totalSupplyAssets = loss >= totalSupplyAssets ? 0 : totalSupplyAssets - loss;
        totalBadDebt += loss;

        emit BadDebtRecorded(borrower, BorrowMath.debtFromScaled(scaled, index), loss);
    }

    /*//////////////////////////////////////////////////////////////
                              POSITION CHECKS
    //////////////////////////////////////////////////////////////*/

    /// @dev Reverts unless `account`'s CURRENT (post-effects) position satisfies the max-LTV rule.
    function _requireWithinMaxLtv(address account) internal view {
        uint256 debt = BorrowMath.debtFromScaled(scaledDebt[account], borrowIndex);
        uint256 collValue = RiskMath.collateralValueUsd(
            collateralOf[account], COLLATERAL_ORACLE.price(), COLLATERAL_DECIMALS
        );
        uint256 debtValue = RiskMath.debtValueUsd(debt, BORROW_ORACLE.price(), BORROW_DECIMALS);
        if (!RiskMath.isWithinMaxLtv(collValue, debtValue, MAX_LTV)) {
            revert Market__ExceedsMaxLtv();
        }
    }

    /*//////////////////////////////////////////////////////////////
                                  VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice Total outstanding debt as of the last accrual (derived from `totalScaledDebt`).
    function totalBorrowAssets() public view returns (uint256) {
        return BorrowMath.debtFromScaled(totalScaledDebt, borrowIndex);
    }

    /// @notice Idle liquidity available to withdraw or borrow (accounting figure, as of last accrual).
    function liquidity() external view returns (uint256) {
        return _liquidity();
    }

    function _liquidity() internal view returns (uint256) {
        uint256 debt = totalBorrowAssets();
        return totalSupplyAssets > debt ? totalSupplyAssets - debt : 0;
    }

    /// @notice Current utilization (WAD) as of the last accrual.
    function utilization() external view returns (uint256) {
        return InterestRateModel.utilization(totalSupplyAssets, totalBorrowAssets());
    }

    /// @notice Current annual borrow rate (WAD) at the current utilization.
    function currentBorrowRate() external view returns (uint256) {
        return InterestRateModel.annualBorrowRate(
            _rateParams(), InterestRateModel.utilization(totalSupplyAssets, totalBorrowAssets())
        );
    }

    /// @notice Assets `account` could withdraw right now ignoring liquidity, interest included.
    function supplyBalance(address account) external view returns (uint256) {
        (, uint256 pending) = _currentIndex();
        return SharesMath.toAssetsDown(
            supplyShares[account], totalSupplyAssets + pending, totalSupplyShares
        );
    }

    /// @notice Debt of `account` including interest accrued up to this block.
    function borrowBalance(address account) external view returns (uint256) {
        (uint256 index,) = _currentIndex();
        return BorrowMath.debtFromScaled(scaledDebt[account], index);
    }

    /// @notice Health factor of `account` (WAD; >= 1e18 is safe; `type(uint256).max` if no debt).
    /// @dev Reverts if an oracle price is unusable, so it can never report a stale-based number.
    function healthFactor(address account) external view returns (uint256) {
        uint256 scaled = scaledDebt[account];
        // Slither incorrect-equality: a zero-check on a value DERIVED from internal accounting
        // (not an ether/token balance an attacker can nudge), see docs/SLITHER_TRIAGE.md.
        // slither-disable-start incorrect-equality
        if (scaled == 0) return type(uint256).max;
        // slither-disable-end incorrect-equality
        (uint256 index,) = _currentIndex();

        uint256 collValue = RiskMath.collateralValueUsd(
            collateralOf[account], COLLATERAL_ORACLE.price(), COLLATERAL_DECIMALS
        );
        uint256 debtValue = RiskMath.debtValueUsd(
            BorrowMath.debtFromScaled(scaled, index), BORROW_ORACLE.price(), BORROW_DECIMALS
        );
        return RiskMath.healthFactor(collValue, debtValue, LIQUIDATION_THRESHOLD);
    }
}
