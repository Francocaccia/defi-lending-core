// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {RiskMath} from "../../src/libraries/RiskMath.sol";
import {WAD} from "../../src/libraries/Units.sol";
import {RiskMathHarness} from "../harness/RiskMathHarness.sol";

contract RiskMathFuzzTest is Test {
    RiskMathHarness internal h;

    // Plausible ranges: USD prices $0.001 .. $1,000,000 per token (WAD), amounts up to 1e24 base units.
    // Wider ranges only trip plain-uint256 intermediate products (e.g. repay * (1 + bonus)) that no
    // real market reaches; they revert (checked math) rather than return a wrong number.
    uint256 internal constant MIN_PRICE = 1e15;
    uint256 internal constant MAX_PRICE = 1e24;
    uint256 internal constant MAX_AMOUNT = 1e24;
    uint256 internal constant MAX_VALUE = 1e40;

    function setUp() public {
        h = new RiskMathHarness();
    }

    /*//////////////////////////////////////////////////////////////
                          HEALTH / LIMIT DECISIONS
    //////////////////////////////////////////////////////////////*/

    /// The "HF < 1" decision (computed from a FLOORED health factor) is exactly the
    /// division-free test c * LT < d * WAD.
    function testFuzz_isLiquidatable_matchesCrossMultiplication(
        uint256 collValue,
        uint256 debtValue,
        uint256 lt
    ) public pure {
        collValue = bound(collValue, 0, MAX_VALUE);
        debtValue = bound(debtValue, 1, MAX_VALUE);
        lt = bound(lt, 1, WAD - 1);

        bool viaHf = RiskMath.isLiquidatable(collValue, debtValue, lt);
        bool exact = collValue * lt < debtValue * WAD;
        assertEq(viaHf, exact);
    }

    /// `isWithinMaxLtv` is exactly d * WAD <= c * ltv.
    function testFuzz_isWithinMaxLtv_matchesCrossMultiplication(
        uint256 collValue,
        uint256 debtValue,
        uint256 ltv
    ) public pure {
        collValue = bound(collValue, 0, MAX_VALUE);
        debtValue = bound(debtValue, 0, MAX_VALUE);
        ltv = bound(ltv, 1, WAD - 1);

        assertEq(
            RiskMath.isWithinMaxLtv(collValue, debtValue, ltv), debtValue * WAD <= collValue * ltv
        );
    }

    /// HF rises with collateral and falls with debt.
    function testFuzz_healthFactor_monotone(
        uint256 c1,
        uint256 c2,
        uint256 d1,
        uint256 d2,
        uint256 lt
    ) public pure {
        c1 = bound(c1, 0, MAX_VALUE);
        c2 = bound(c2, 0, MAX_VALUE);
        d1 = bound(d1, 1, MAX_VALUE);
        d2 = bound(d2, 1, MAX_VALUE);
        lt = bound(lt, 1, WAD - 1);
        (uint256 cLo, uint256 cHi) = c1 <= c2 ? (c1, c2) : (c2, c1);
        (uint256 dLo, uint256 dHi) = d1 <= d2 ? (d1, d2) : (d2, d1);

        assertLe(RiskMath.healthFactor(cLo, dLo, lt), RiskMath.healthFactor(cHi, dLo, lt));
        assertGe(RiskMath.healthFactor(cLo, dLo, lt), RiskMath.healthFactor(cLo, dHi, lt));
    }

    /// Anyone allowed to borrow (within LTV) is not liquidatable, because LTV < LT.
    function testFuzz_withinMaxLtvImpliesHealthy(
        uint256 collValue,
        uint256 debtValue,
        uint256 ltv,
        uint256 lt
    ) public pure {
        lt = bound(lt, 2, WAD - 1);
        ltv = bound(ltv, 1, lt - 1);
        collValue = bound(collValue, 0, MAX_VALUE);
        debtValue = bound(debtValue, 1, MAX_VALUE);
        vm.assume(RiskMath.isWithinMaxLtv(collValue, debtValue, ltv));
        assertFalse(RiskMath.isLiquidatable(collValue, debtValue, lt));
    }

    /*//////////////////////////////////////////////////////////////
                               VALUATION
    //////////////////////////////////////////////////////////////*/

    /// Collateral is never over-valued and debt never under-valued: the two roundings differ by
    /// at most 1 wei and floor <= ceil.
    function testFuzz_valuationRoundingDirection(uint256 amount, uint256 price, uint8 decimals)
        public
        pure
    {
        amount = bound(amount, 0, MAX_AMOUNT);
        price = bound(price, MIN_PRICE, MAX_PRICE);
        decimals = uint8(bound(decimals, 0, 18));

        uint256 down = RiskMath.collateralValueUsd(amount, price, decimals);
        uint256 up = RiskMath.debtValueUsd(amount, price, decimals);
        assertLe(down, up);
        assertLe(up - down, 1);
    }

    /*//////////////////////////////////////////////////////////////
                              LIQUIDATION
    //////////////////////////////////////////////////////////////*/

    function _bounds(uint256 debtPrice, uint256 collPrice, uint256 bonus, uint8 dd, uint8 cd)
        internal
        pure
        returns (uint256, uint256, uint256, uint8, uint8)
    {
        return (
            bound(debtPrice, MIN_PRICE, MAX_PRICE),
            bound(collPrice, MIN_PRICE, MAX_PRICE),
            bound(bonus, 1, 0.25e18),
            uint8(bound(dd, 0, 18)),
            uint8(bound(cd, 0, 18))
        );
    }

    /// The collateral paid out is worth AT MOST repay * (1 + bonus) (rounding never overpays).
    function testFuzz_seize_neverExceedsBonusValue(
        uint256 repay,
        uint256 debtPrice,
        uint256 collPrice,
        uint256 bonus,
        uint8 dd,
        uint8 cd
    ) public pure {
        // Tighter ranges than the other tests: the REFERENCE expression below multiplies five
        // large factors in plain uint256 and must not overflow (the library itself uses a
        // 512-bit mulDiv and is exercised over the wider ranges elsewhere).
        repay = bound(repay, 0, 1e17);
        (debtPrice, collPrice, bonus, dd, cd) = _bounds(debtPrice, collPrice, bonus, dd, cd);
        debtPrice = bound(debtPrice, MIN_PRICE, 1e21);
        collPrice = bound(collPrice, MIN_PRICE, 1e21);

        uint256 seize = RiskMath.seizeForRepay(repay, debtPrice, dd, collPrice, cd, bonus);
        // seize * collPrice * 10^dd * WAD  <=  repay * (WAD + bonus) * debtPrice * 10^cd
        assertLe(seize * collPrice * 10 ** dd * WAD, repay * (WAD + bonus) * debtPrice * 10 ** cd);
    }

    /// seizeForRepay is non-decreasing in the repaid amount.
    function testFuzz_seize_monotoneInRepay(
        uint256 r1,
        uint256 r2,
        uint256 debtPrice,
        uint256 collPrice,
        uint256 bonus,
        uint8 dd,
        uint8 cd
    ) public pure {
        r1 = bound(r1, 0, MAX_AMOUNT);
        r2 = bound(r2, 0, MAX_AMOUNT);
        (debtPrice, collPrice, bonus, dd, cd) = _bounds(debtPrice, collPrice, bonus, dd, cd);
        (uint256 lo, uint256 hi) = r1 <= r2 ? (r1, r2) : (r2, r1);

        assertLe(
            RiskMath.seizeForRepay(lo, debtPrice, dd, collPrice, cd, bonus),
            RiskMath.seizeForRepay(hi, debtPrice, dd, collPrice, cd, bonus)
        );
    }

    /// The two directions are consistent in the protocol's favour:
    ///   repayForSeize(seizeForRepay(r)) <= r   (liquidator is never asked for more than r)
    ///   seizeForRepay(repayForSeize(s)) >= s   (paying the quoted repay always covers `s`)
    function testFuzz_seizeAndRepayAreConsistent(
        uint256 repay,
        uint256 seize,
        uint256 debtPrice,
        uint256 collPrice,
        uint256 bonus,
        uint8 dd,
        uint8 cd
    ) public pure {
        repay = bound(repay, 0, MAX_AMOUNT);
        seize = bound(seize, 0, MAX_AMOUNT);
        (debtPrice, collPrice, bonus, dd, cd) = _bounds(debtPrice, collPrice, bonus, dd, cd);

        uint256 s = RiskMath.seizeForRepay(repay, debtPrice, dd, collPrice, cd, bonus);
        assertLe(RiskMath.repayForSeize(s, debtPrice, dd, collPrice, cd, bonus), repay);

        uint256 r = RiskMath.repayForSeize(seize, debtPrice, dd, collPrice, cd, bonus);
        assertGe(RiskMath.seizeForRepay(r, debtPrice, dd, collPrice, cd, bonus), seize);
    }

    /// For a position that has just crossed the threshold (and with LT*(1+bonus) < 1), the
    /// collateral owed for repaying the max allowed debt never exceeds the collateral held.
    function testFuzz_atThreshold_seizeFitsInCollateral(
        uint256 debt,
        uint256 collPrice,
        uint256 debtPrice
    ) public pure {
        debt = bound(debt, 1e6, 1e24);
        collPrice = bound(collPrice, 1e18, 1e24);
        debtPrice = bound(debtPrice, 0.5e18, 2e18);
        uint256 lt = 0.8e18;
        uint256 bonus = 0.05e18;
        uint8 dd = 6;
        uint8 cd = 18;

        // Collateral exactly at the liquidation threshold (rounded UP so HF is just <= 1):
        // value = debtValue / LT  =>  amount = debtValue * 10^cd / (LT * collPrice) ...
        uint256 debtValue = RiskMath.debtValueUsd(debt, debtPrice, dd);
        uint256 collAmount = (debtValue * 1e18 / lt) * 10 ** cd / collPrice + 1;

        uint256 repay = RiskMath.maxRepayable(debt, 0.5e18);
        uint256 seize = RiskMath.seizeForRepay(repay, debtPrice, dd, collPrice, cd, bonus);
        assertLe(seize, collAmount, "no bad debt at the moment of becoming liquidatable");
    }

    /// maxRepayable is within [0, debt] and at least 1 for any positive debt.
    function testFuzz_maxRepayable_bounds(uint256 debt, uint256 closeFactor) public pure {
        debt = bound(debt, 0, type(uint128).max);
        closeFactor = bound(closeFactor, 1, WAD);
        uint256 m = RiskMath.maxRepayable(debt, closeFactor);
        assertLe(m, debt);
        if (debt > 0) assertGe(m, 1);
    }

    /// Parameter validation: the constraint set is exactly what the docs say.
    function testFuzz_validate_matchesSpec(
        uint256 ltv,
        uint256 lt,
        uint256 bonus,
        uint256 closeFactor
    ) public view {
        ltv = bound(ltv, 0, 2 * WAD);
        lt = bound(lt, 0, 2 * WAD);
        bonus = bound(bonus, 0, WAD);
        closeFactor = bound(closeFactor, 0, 2 * WAD);

        bool valid = ltv > 0 && ltv < lt && lt < WAD && bonus > 0 && bonus <= 0.25e18
            && lt * (WAD + bonus) < WAD * WAD && closeFactor > 0 && closeFactor <= WAD;

        try h.validate(
            RiskMath.RiskParams({
                maxLtv: ltv,
                liquidationThreshold: lt,
                liquidationBonus: bonus,
                closeFactor: closeFactor
            })
        ) {
            assertTrue(valid, "accepted invalid params");
        } catch {
            assertFalse(valid, "rejected valid params");
        }
    }
}
