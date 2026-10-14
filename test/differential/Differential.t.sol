// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {DiffHarness} from "./DiffHarness.sol";

/// @title Differential tests: Solidity vs the independent C++ reference model
/// @notice Every test feeds the SAME inputs to a Solidity pure function (through `DiffHarness`)
///         and to the C++ command-line model, then demands IDENTICAL behaviour:
///           - both fail (Solidity reverts <=> the model exits with code 1), or
///           - both succeed and every returned 32-byte word is equal.
///         What this verifies: the MATH (formulas, units, rounding, overflow/revert conditions).
///         What it does NOT verify: the market's state machine, access control, token handling or
///         oracle behaviour (those are covered by the unit/invariant/fork tests).
///
/// @dev Why `vm.ffi` is safe here: it is only enabled in the dedicated `diff` Foundry profile
///      (`FOUNDRY_PROFILE=diff`); the command is ONE fixed binary built from this repository
///      (`reference-model/build/refmodel`) and the arguments are decimal numbers produced by
///      `vm.toString(uint256)`. No shell, no network, no user-controlled path or string.
///
///      Tests skip automatically when `ffi` is disabled or the binary is not built, so a plain
///      `forge test` never needs a C++ toolchain.
///
///      CLI contract (names, argument order, output encoding, exit codes): docs/M8_HANDOFF.md.
///        stdout (exit 0): `0x` + one 32-byte big-endian word per returned value, all on one line
///                         (Foundry decodes that hex into raw bytes for us).
///        exit 1         : the equivalent Solidity call would REVERT (stderr explains why).
///        exit 2         : usage error (unknown function, wrong argument count, unparsable
///                         argument). Treated as a test FAILURE: it means the harness is wrong.
contract DifferentialTest is Test {
    string internal constant BIN = "reference-model/build/refmodel";
    uint256 internal constant WAD = 1e18;
    uint256 internal constant RAY = 1e27;
    uint256 internal constant MAX = type(uint256).max;

    DiffHarness internal h;

    function setUp() public {
        // Skip (instead of failing) when ffi is off or the model has not been built.
        try this.probe() {}
        catch {
            vm.skip(true);
        }
        h = new DiffHarness();
    }

    /// @dev External so `setUp` can catch the cheatcode revert raised when ffi is disabled.
    function probe() external {
        string[] memory cmd = new string[](4);
        cmd[0] = BIN;
        cmd[1] = "utilization";
        cmd[2] = "1";
        cmd[3] = "2";
        Vm.FfiResult memory r = vm.tryFfi(cmd);
        require(r.exitCode == 0, "reference model unavailable");
    }

    /*//////////////////////////////////////////////////////////////
                                ENGINE
    //////////////////////////////////////////////////////////////*/

    /// @dev Runs the Solidity side. All harness functions return only static uint256 words.
    function _sol(bytes memory callData) internal returns (bool ok, uint256[] memory words) {
        bytes memory ret;
        (ok, ret) = address(h).call(callData);
        if (!ok) return (false, new uint256[](0));
        words = _words(ret);
    }

    function _words(bytes memory data) internal pure returns (uint256[] memory words) {
        words = new uint256[](data.length / 32);
        for (uint256 i = 0; i < words.length; i++) {
            uint256 w;
            assembly {
                w := mload(add(data, add(32, mul(i, 32))))
            }
            words[i] = w;
        }
    }

    /// @dev Runs the C++ side.
    function _ref(string memory fn, uint256[] memory args)
        internal
        returns (uint256 exitCode, uint256[] memory words, string memory err)
    {
        string[] memory cmd = new string[](args.length + 2);
        cmd[0] = BIN;
        cmd[1] = fn;
        for (uint256 i = 0; i < args.length; i++) {
            cmd[i + 2] = vm.toString(args[i]);
        }
        Vm.FfiResult memory r = vm.tryFfi(cmd);
        exitCode = r.exitCode < 0 ? 255 : uint256(uint32(r.exitCode));
        words = _words(r.stdout);
        err = string(r.stderr);
    }

    /// @dev The comparison. `label` is only used to make failures reproducible.
    function _diff(string memory fn, bytes memory solCall, uint256[] memory args) internal {
        (bool solOk, uint256[] memory solWords) = _sol(solCall);
        (uint256 code, uint256[] memory refWords, string memory err) = _ref(fn, args);

        string memory ctx = _ctx(fn, args);
        assertTrue(code != 2, string.concat("USAGE ERROR from reference model: ", err, " | ", ctx));
        bool refOk = code == 0;
        assertEq(
            solOk,
            refOk,
            string.concat(
                solOk
                    ? "Solidity OK but model FAILED: "
                    : "Solidity REVERTED but model succeeded: ",
                err,
                " | ",
                ctx
            )
        );
        if (solOk && refOk) {
            assertEq(refWords.length, solWords.length, string.concat("output arity | ", ctx));
            for (uint256 i = 0; i < solWords.length && i < refWords.length; i++) {
                assertEq(
                    refWords[i],
                    solWords[i],
                    string.concat("output word ", vm.toString(i), " differs | ", ctx)
                );
            }
        }
    }

    function _ctx(string memory fn, uint256[] memory args) internal pure returns (string memory s) {
        s = fn;
        for (uint256 i = 0; i < args.length; i++) {
            s = string.concat(s, " ", vm.toString(args[i]));
        }
    }

    /// @dev Either a realistic bounded value or the raw fuzz value (overflow / edge exploration).
    function _n(uint256 x, bool wide, uint256 hi) internal pure returns (uint256) {
        return wide ? x : bound(x, 0, hi);
    }

    function _dec(uint256 x, bool wide) internal pure returns (uint8) {
        return wide ? uint8(x) : uint8(bound(x, 0, 18));
    }

    function _a(uint256 a, uint256 b) internal pure returns (uint256[] memory r) {
        r = new uint256[](2);
        (r[0], r[1]) = (a, b);
    }

    function _a(uint256 a, uint256 b, uint256 c) internal pure returns (uint256[] memory r) {
        r = new uint256[](3);
        (r[0], r[1], r[2]) = (a, b, c);
    }

    function _a(uint256 a, uint256 b, uint256 c, uint256 d)
        internal
        pure
        returns (uint256[] memory r)
    {
        r = new uint256[](4);
        (r[0], r[1], r[2], r[3]) = (a, b, c, d);
    }

    function _a(uint256 a, uint256 b, uint256 c, uint256 d, uint256 e)
        internal
        pure
        returns (uint256[] memory r)
    {
        r = new uint256[](5);
        (r[0], r[1], r[2], r[3], r[4]) = (a, b, c, d, e);
    }

    function _a(uint256 a, uint256 b, uint256 c, uint256 d, uint256 e, uint256 f)
        internal
        pure
        returns (uint256[] memory r)
    {
        r = new uint256[](6);
        (r[0], r[1], r[2], r[3], r[4], r[5]) = (a, b, c, d, e, f);
    }

    /*//////////////////////////////////////////////////////////////
                  PLUMBING (runs with the model present)
    //////////////////////////////////////////////////////////////*/

    function test_plumbing_wordsDecoding() public pure {
        bytes memory raw = abi.encode(uint256(7), uint256(MAX), uint256(0));
        uint256[] memory w = _words(raw);
        assertEq(w.length, 3);
        assertEq(w[0], 7);
        assertEq(w[1], MAX);
        assertEq(w[2], 0);
    }

    function test_plumbing_revertsAreSeenAsFailures() public {
        (bool ok,) = _sol(abi.encodeCall(h.utilization, (1, 2)));
        assertTrue(ok);
        (ok,) = _sol(abi.encodeCall(h.annualBorrowRate, (0, 0, 0, 0, 0))); // K = 0, u = 0 -> divide by zero
        assertFalse(ok);
    }

    /*//////////////////////////////////////////////////////////////
                    HAND-VERIFIED VECTORS (DESIGN sections)
    //////////////////////////////////////////////////////////////*/

    /// Values computed independently in Python while writing docs/DESIGN.md. If one of these
    /// fails, start here: it is the smallest reproducer.
    function test_diff_vectors() public {
        // 3.5 rate model: base 0, slope1 4%, slope2 75%, kink 80%
        _diff(
            "annualBorrowRate",
            abi.encodeCall(h.annualBorrowRate, (0, 0.04e18, 0.75e18, 0.8e18, 0.9e18)),
            _a(0, 0.04e18, 0.75e18, 0.8e18, 0.9e18)
        );
        _diff(
            "borrowRatePerSecond",
            abi.encodeCall(h.borrowRatePerSecond, (0, 0.04e18, 0.75e18, 0.8e18, 0.8e18)),
            _a(0, 0.04e18, 0.75e18, 0.8e18, 0.8e18)
        );
        _diff("utilization", abi.encodeCall(h.utilization, (3, 1)), _a(3, 1));
        // 4. shares
        _diff(
            "toSharesDown",
            abi.encodeCall(h.toSharesDown, (100e6, 1050e6, 1e15)),
            _a(100e6, 1050e6, 1e15)
        );
        _diff(
            "toSharesUp",
            abi.encodeCall(h.toSharesUp, (100e6, 1050e6, 1e15)),
            _a(100e6, 1050e6, 1e15)
        );
        // 5. index
        _diff(
            "accrueIndex",
            abi.encodeCall(h.accrueIndex, (RAY, 1_268_391_679_350_583_460, 365 days)),
            _a(RAY, 1_268_391_679_350_583_460, 365 days)
        );
        // 5.2 worked example: one accrual of 365 days at 50% utilization
        _diff(
            "accrue",
            abi.encodeCall(
                h.accrue, (50_000e6, 100_000e6, RAY, 365 days, 0, 0.04e18, 0.75e18, 0.8e18)
            ),
            _acc(50_000e6, 100_000e6, RAY, 365 days)
        );
        // 7.2 liquidation numbers
        _diff(
            "seizeForRepay",
            abi.encodeCall(h.seizeForRepay, (5000e6, 1e18, 6, 1200e18, 18, 0.05e18)),
            _a(5000e6, 1e18, 6, 1200e18, 18, 0.05e18)
        );
        _diff(
            "repayForSeize",
            abi.encodeCall(h.repayForSeize, (10e18, 1e18, 6, 500e18, 18, 0.05e18)),
            _a(10e18, 1e18, 6, 500e18, 18, 0.05e18)
        );
        // 7.5 bad debt example
        _diff(
            "liquidationAmounts",
            abi.encodeCall(
                h.liquidationAmounts,
                (10_000e6, RAY, MAX, 10e18, 500e18, 1e18, 18, 6, 0.05e18, 0.5e18)
            ),
            _liq(10_000e6, RAY, MAX, 10e18, 500e18)
        );
        _diff(
            "badDebt",
            abi.encodeCall(h.badDebt, (5_238_095_238, 5_238_095_238, RAY, 100_000e6)),
            _a(5_238_095_238, 5_238_095_238, RAY, 100_000e6)
        );
        // 6.1 parameter validation: illustrative defaults accepted, LT*(1+b) = 1 rejected
        _diff(
            "validateRiskParams",
            abi.encodeCall(h.validateRiskParams, (0.75e18, 0.8e18, 0.05e18, 0.5e18)),
            _a(0.75e18, 0.8e18, 0.05e18, 0.5e18)
        );
        _diff(
            "validateRiskParams",
            abi.encodeCall(h.validateRiskParams, (0.75e18, 0.8e18, 0.25e18, 0.5e18)),
            _a(0.75e18, 0.8e18, 0.25e18, 0.5e18)
        );
    }

    function _acc(uint256 s, uint256 a, uint256 i, uint256 e)
        internal
        pure
        returns (uint256[] memory r)
    {
        r = new uint256[](8);
        (r[0], r[1], r[2], r[3]) = (s, a, i, e);
        (r[4], r[5], r[6], r[7]) = (0, 0.04e18, 0.75e18, 0.8e18);
    }

    function _liq(uint256 scaled, uint256 index, uint256 requested, uint256 collateral, uint256 cp)
        internal
        pure
        returns (uint256[] memory r)
    {
        r = new uint256[](10);
        (r[0], r[1], r[2], r[3], r[4]) = (scaled, index, requested, collateral, cp);
        (r[5], r[6], r[7], r[8], r[9]) = (1e18, 18, 6, 0.05e18, 0.5e18);
    }

    /*//////////////////////////////////////////////////////////////
                         FUZZ: INTEREST RATE MODEL
    //////////////////////////////////////////////////////////////*/

    function testFuzz_diff_utilization(uint256 supply, uint256 borrows, bool wide) public {
        supply = _n(supply, wide, 1e30);
        borrows = _n(borrows, wide, 1e30);
        _diff("utilization", abi.encodeCall(h.utilization, (supply, borrows)), _a(supply, borrows));
    }

    function testFuzz_diff_validateRateParams(
        uint256 base,
        uint256 s1,
        uint256 s2,
        uint256 k,
        bool wide
    ) public {
        base = _n(base, wide, 11e18);
        s1 = _n(s1, wide, 11e18);
        s2 = _n(s2, wide, 11e18);
        k = _n(k, wide, 2e18);
        _diff(
            "validateRateParams",
            abi.encodeCall(h.validateRateParams, (base, s1, s2, k)),
            _a(base, s1, s2, k)
        );
    }

    function testFuzz_diff_annualBorrowRate(
        uint256 base,
        uint256 s1,
        uint256 s2,
        uint256 k,
        uint256 u,
        bool wide
    ) public {
        base = _n(base, wide, 10e18);
        s1 = _n(s1, wide, 10e18);
        s2 = _n(s2, wide, 10e18);
        k = wide ? k : bound(k, 1, WAD - 1);
        u = _n(u, wide, WAD);
        _diff(
            "annualBorrowRate",
            abi.encodeCall(h.annualBorrowRate, (base, s1, s2, k, u)),
            _a(base, s1, s2, k, u)
        );
    }

    function testFuzz_diff_borrowRatePerSecond(
        uint256 base,
        uint256 s1,
        uint256 s2,
        uint256 k,
        uint256 u,
        bool wide
    ) public {
        base = _n(base, wide, 10e18);
        s1 = _n(s1, wide, 10e18);
        s2 = _n(s2, wide, 10e18);
        k = wide ? k : bound(k, 1, WAD - 1);
        u = _n(u, wide, WAD);
        _diff(
            "borrowRatePerSecond",
            abi.encodeCall(h.borrowRatePerSecond, (base, s1, s2, k, u)),
            _a(base, s1, s2, k, u)
        );
    }

    /*//////////////////////////////////////////////////////////////
                           FUZZ: BORROW INDEX
    //////////////////////////////////////////////////////////////*/

    function testFuzz_diff_accrueIndex(uint256 index, uint256 rate, uint256 dt, bool wide) public {
        index = wide ? index : bound(index, RAY, 100 * RAY);
        rate = _n(rate, wide, 1e21);
        dt = _n(dt, wide, 10 * 365 days);
        _diff("accrueIndex", abi.encodeCall(h.accrueIndex, (index, rate, dt)), _a(index, rate, dt));
    }

    function testFuzz_diff_scaledFromAssetsUp(uint256 assets, uint256 index, bool wide) public {
        assets = _n(assets, wide, 1e30);
        index = wide ? index : bound(index, RAY, 100 * RAY);
        _diff(
            "scaledFromAssetsUp",
            abi.encodeCall(h.scaledFromAssetsUp, (assets, index)),
            _a(assets, index)
        );
    }

    function testFuzz_diff_scaledFromAssetsDown(uint256 assets, uint256 index, bool wide) public {
        assets = _n(assets, wide, 1e30);
        index = wide ? index : bound(index, RAY, 100 * RAY);
        _diff(
            "scaledFromAssetsDown",
            abi.encodeCall(h.scaledFromAssetsDown, (assets, index)),
            _a(assets, index)
        );
    }

    function testFuzz_diff_debtFromScaled(uint256 scaled, uint256 index, bool wide) public {
        scaled = _n(scaled, wide, 1e30);
        index = wide ? index : bound(index, RAY, 100 * RAY);
        _diff(
            "debtFromScaled", abi.encodeCall(h.debtFromScaled, (scaled, index)), _a(scaled, index)
        );
    }

    /*//////////////////////////////////////////////////////////////
                              FUZZ: SHARES
    //////////////////////////////////////////////////////////////*/

    function testFuzz_diff_toSharesDown(uint256 x, uint256 a, uint256 s, bool wide) public {
        (x, a, s) = (_n(x, wide, 1e30), _n(a, wide, 1e30), _n(s, wide, 1e40));
        _diff("toSharesDown", abi.encodeCall(h.toSharesDown, (x, a, s)), _a(x, a, s));
    }

    function testFuzz_diff_toSharesUp(uint256 x, uint256 a, uint256 s, bool wide) public {
        (x, a, s) = (_n(x, wide, 1e30), _n(a, wide, 1e30), _n(s, wide, 1e40));
        _diff("toSharesUp", abi.encodeCall(h.toSharesUp, (x, a, s)), _a(x, a, s));
    }

    function testFuzz_diff_toAssetsDown(uint256 x, uint256 a, uint256 s, bool wide) public {
        (x, a, s) = (_n(x, wide, 1e40), _n(a, wide, 1e30), _n(s, wide, 1e40));
        _diff("toAssetsDown", abi.encodeCall(h.toAssetsDown, (x, a, s)), _a(x, a, s));
    }

    function testFuzz_diff_toAssetsUp(uint256 x, uint256 a, uint256 s, bool wide) public {
        (x, a, s) = (_n(x, wide, 1e40), _n(a, wide, 1e30), _n(s, wide, 1e40));
        _diff("toAssetsUp", abi.encodeCall(h.toAssetsUp, (x, a, s)), _a(x, a, s));
    }

    /*//////////////////////////////////////////////////////////////
                               FUZZ: RISK
    //////////////////////////////////////////////////////////////*/

    function testFuzz_diff_collateralValueUsd(uint256 amount, uint256 price, uint256 dec, bool wide)
        public
    {
        amount = _n(amount, wide, 1e30);
        price = _n(price, wide, 1e27);
        uint8 d = _dec(dec, wide);
        _diff(
            "collateralValueUsd",
            abi.encodeCall(h.collateralValueUsd, (amount, price, d)),
            _a(amount, price, d)
        );
    }

    function testFuzz_diff_debtValueUsd(uint256 amount, uint256 price, uint256 dec, bool wide)
        public
    {
        amount = _n(amount, wide, 1e30);
        price = _n(price, wide, 1e27);
        uint8 d = _dec(dec, wide);
        _diff(
            "debtValueUsd", abi.encodeCall(h.debtValueUsd, (amount, price, d)), _a(amount, price, d)
        );
    }

    function testFuzz_diff_healthFactor(uint256 c, uint256 d, uint256 lt, bool wide) public {
        c = _n(c, wide, 1e40);
        d = _n(d, wide, 1e40);
        lt = _n(lt, wide, WAD);
        _diff("healthFactor", abi.encodeCall(h.healthFactor, (c, d, lt)), _a(c, d, lt));
    }

    function testFuzz_diff_maxDebtValue(uint256 c, uint256 ltv, bool wide) public {
        c = _n(c, wide, 1e40);
        ltv = _n(ltv, wide, WAD);
        _diff("maxDebtValue", abi.encodeCall(h.maxDebtValue, (c, ltv)), _a(c, ltv));
    }

    function testFuzz_diff_isWithinMaxLtv(uint256 c, uint256 d, uint256 ltv, bool wide) public {
        c = _n(c, wide, 1e40);
        d = _n(d, wide, 1e40);
        ltv = _n(ltv, wide, WAD);
        _diff("isWithinMaxLtv", abi.encodeCall(h.isWithinMaxLtv, (c, d, ltv)), _a(c, d, ltv));
    }

    function testFuzz_diff_maxRepayable(uint256 debt, uint256 cf, bool wide) public {
        debt = _n(debt, wide, 1e30);
        cf = _n(cf, wide, WAD);
        _diff("maxRepayable", abi.encodeCall(h.maxRepayable, (debt, cf)), _a(debt, cf));
    }

    function testFuzz_diff_seizeForRepay(uint256[6] memory v, bool wide) public {
        uint256 repay = _n(v[0], wide, 1e24);
        uint256 dp = wide ? v[1] : bound(v[1], 1e15, 1e24);
        uint8 dd = _dec(v[2], wide);
        uint256 cp = wide ? v[3] : bound(v[3], 1e15, 1e24);
        uint8 cd = _dec(v[4], wide);
        uint256 bonus = _n(v[5], wide, 0.25e18);
        _diff(
            "seizeForRepay",
            abi.encodeCall(h.seizeForRepay, (repay, dp, dd, cp, cd, bonus)),
            _a(repay, dp, dd, cp, cd, bonus)
        );
    }

    function testFuzz_diff_repayForSeize(uint256[6] memory v, bool wide) public {
        uint256 seize = _n(v[0], wide, 1e24);
        uint256 dp = wide ? v[1] : bound(v[1], 1e15, 1e24);
        uint8 dd = _dec(v[2], wide);
        uint256 cp = wide ? v[3] : bound(v[3], 1e15, 1e24);
        uint8 cd = _dec(v[4], wide);
        uint256 bonus = _n(v[5], wide, 0.25e18);
        _diff(
            "repayForSeize",
            abi.encodeCall(h.repayForSeize, (seize, dp, dd, cp, cd, bonus)),
            _a(seize, dp, dd, cp, cd, bonus)
        );
    }

    function testFuzz_diff_validateRiskParams(
        uint256 ltv,
        uint256 lt,
        uint256 bonus,
        uint256 cf,
        bool wide
    ) public {
        ltv = _n(ltv, wide, 2e18);
        lt = _n(lt, wide, 2e18);
        bonus = _n(bonus, wide, 1e18);
        cf = _n(cf, wide, 2e18);
        _diff(
            "validateRiskParams",
            abi.encodeCall(h.validateRiskParams, (ltv, lt, bonus, cf)),
            _a(ltv, lt, bonus, cf)
        );
    }

    /*//////////////////////////////////////////////////////////////
                           FUZZ: MARKET KERNELS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_diff_accrue(uint256[8] memory v, bool wide) public {
        uint256 scaled = _n(v[0], wide, 1e30);
        uint256 supply = _n(v[1], wide, 1e30);
        uint256 index = wide ? v[2] : bound(v[2], RAY, 100 * RAY);
        uint256 elapsed = _n(v[3], wide, 10 * 365 days);
        uint256 base = _n(v[4], wide, 10e18);
        uint256 s1 = _n(v[5], wide, 10e18);
        uint256 s2 = _n(v[6], wide, 10e18);
        uint256 k = wide ? v[7] : bound(v[7], 1, WAD - 1);
        uint256[] memory args = new uint256[](8);
        (args[0], args[1], args[2], args[3]) = (scaled, supply, index, elapsed);
        (args[4], args[5], args[6], args[7]) = (base, s1, s2, k);
        _diff(
            "accrue",
            abi.encodeCall(h.accrue, (scaled, supply, index, elapsed, base, s1, s2, k)),
            args
        );
    }

    function testFuzz_diff_repayAmounts(uint256 assets, uint256 scaled, uint256 index, bool wide)
        public
    {
        assets = _n(assets, wide, 1e30);
        scaled = _n(scaled, wide, 1e30);
        index = wide ? index : bound(index, RAY, 100 * RAY);
        _diff(
            "repayAmounts",
            abi.encodeCall(h.repayAmounts, (assets, scaled, index)),
            _a(assets, scaled, index)
        );
    }

    function testFuzz_diff_liquidationAmounts(uint256[10] memory v, bool wide) public {
        uint256 scaled = _n(v[0], wide, 1e30);
        uint256 index = wide ? v[1] : bound(v[1], RAY, 100 * RAY);
        uint256 requested = wide ? v[2] : (v[2] % 2 == 0 ? MAX : bound(v[2], 0, 1e30));
        uint256 collateral = _n(v[3], wide, 1e30);
        uint256 cp = wide ? v[4] : bound(v[4], 1e15, 1e24);
        uint256 dp = wide ? v[5] : bound(v[5], 1e15, 1e24);
        uint8 cd = _dec(v[6], wide);
        uint8 dd = _dec(v[7], wide);
        uint256 bonus = _n(v[8], wide, 0.25e18);
        uint256 cf = _n(v[9], wide, WAD);
        uint256[] memory args = new uint256[](10);
        (args[0], args[1], args[2], args[3], args[4]) = (scaled, index, requested, collateral, cp);
        (args[5], args[6], args[7], args[8], args[9]) = (dp, cd, dd, bonus, cf);
        _diff(
            "liquidationAmounts",
            abi.encodeCall(
                h.liquidationAmounts,
                (scaled, index, requested, collateral, cp, dp, cd, dd, bonus, cf)
            ),
            args
        );
    }

    function testFuzz_diff_badDebt(
        uint256 total,
        uint256 borrower,
        uint256 index,
        uint256 supply,
        bool wide
    ) public {
        total = _n(total, wide, 1e30);
        borrower = wide ? borrower : bound(borrower, 0, total);
        index = wide ? index : bound(index, RAY, 100 * RAY);
        supply = _n(supply, wide, 1e30);
        _diff(
            "badDebt",
            abi.encodeCall(h.badDebt, (total, borrower, index, supply)),
            _a(total, borrower, index, supply)
        );
    }
}
