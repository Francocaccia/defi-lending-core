#!/usr/bin/env python3
"""Independent cross-check of the C++ simulator's engine.

Re-runs a HISTORICAL experiment with a second implementation written from docs/DESIGN.md section 9 in
plain Python (arbitrary-precision integers, every operation range-checked to uint256) and compares the
per-combination counts with the CSV that `defi_sim` produced. It shares no code with the C++ engine or
with the reference model it links.

Deliberate differences from the C++ engine, so that a match is a real result:
  * no floating-point screen: EVERY hourly observation is inspected with exact integer math;
  * interest is accrued at every observation (the C++ engine accrues lazily, when it inspects).
A stray disagreement is therefore possible only on a razor-edge window (health factor within ~1e-5 of 1).

Usage:
    python crosscheck.py <config.json> <defi_sim_output.csv> <horizonDays> <fraction:latencyHours> ...
Example:
    python crosscheck.py ../configs/historical_baseline.json out/historical_baseline.csv 30 1.0:0 1.0:24

Uses only the Python standard library. Checks: n, unhealthy, liquidated, badDebt, stuck, stuckUnderwater
(exact equality) and the mean bad-debt fraction (to 1e-6).
"""
import concurrent.futures
import csv
import json
import os
import sys
from decimal import Decimal

M = 2**256
W = 10**18
RAY = 10**27
UINT_MAX = M - 1
SECONDS_PER_YEAR = 31_536_000
MAX_RATE = 10 * W
MAX_BONUS = 25 * 10**16
COLL_DEC, DEBT_DEC = 18, 6


class Fail(Exception):
    pass


def chk(x):
    if x < 0 or x >= M:
        raise Fail("uint256 range")
    return x


def mul_div(a, b, d):
    if d == 0:
        raise Fail("division by zero")
    return chk((a * b) // d)


def mul_div_up(a, b, d):
    if d == 0:
        raise Fail("division by zero")
    q, r = divmod(chk(a * b), d)
    return chk(q + (1 if r else 0))


# ---- DESIGN section 9 (only what an experiment needs) -----------------------------------------------
def borrow_rate_per_second(base, s1, s2, k, u):
    if k == 0 or k >= W or u > W:
        raise Fail("rate parameters")
    annual = base + (s1 * u) // k if u <= k else base + s1 + (s2 * (u - k)) // (W - k)
    return chk(annual * 10**9) // SECONDS_PER_YEAR


def accrue_index(index, rate, dt):
    return chk(index + mul_div_up(index, chk(rate * dt), RAY))


def debt_from_scaled(scaled, index):
    return mul_div_up(scaled, index, RAY)


def collateral_value(amount, price, dec):
    return mul_div(amount, price, 10**dec)


def debt_value(amount, price, dec):
    return mul_div_up(amount, price, 10**dec)


def health_factor(c, d, lt):
    return UINT_MAX if d == 0 else mul_div(c, lt, d)


def max_debt_value(c, ltv):
    return mul_div(c, ltv, W)


def seize_for_repay(repay, dp, dd, cp, cd, bonus):
    n1 = chk(repay * (W + bonus))
    n2 = chk(dp * 10**cd)
    den = chk(chk(cp * 10**dd) * W)
    return mul_div(n1, n2, den)


def repay_for_seize(seize, dp, dd, cp, cd, bonus):
    n = chk(chk(cp * 10**dd) * W)
    den = chk(chk(dp * (W + bonus)) * 10**cd)
    return mul_div_up(seize, n, den)


def liquidation_amounts(scaled, index, collateral, cp, dp, bonus, cf):
    debt = debt_from_scaled(scaled, index)
    repaid = mul_div_up(debt, cf, W)
    seized = seize_for_repay(repaid, dp, DEBT_DEC, cp, COLL_DEC, bonus)
    if seized > collateral:
        seized = collateral
        repaid = min(repaid, repay_for_seize(collateral, dp, DEBT_DEC, cp, COLL_DEC, bonus))
    burned = scaled if repaid >= debt else mul_div(repaid, RAY, index)
    return repaid, seized, burned


def bad_debt_loss(scaled, index):
    # the whole position's scaled debt is written off against a very large supply
    return debt_from_scaled(scaled, index)


# ---- config / data ------------------------------------------------------------------------------------
def wad_param(text):
    """'0.75' -> 0.75e18 exactly; plain digits are a raw WAD integer (the protocol-parameter convention)."""
    t = str(text)
    if "." in t:
        v = Decimal(t) * 10**18
        if v != v.to_integral_value():
            raise Fail(f"more than 18 decimals: {t}")
        return int(v)
    return int(t)


def scaled_decimal(text, decimals):
    v = Decimal(str(text)) * 10**decimals
    if v != v.to_integral_value():
        raise Fail(f"too many decimals: {text}")
    return int(v)


def load_csv(path):
    with open(path) as f:
        lines = f.read().split("\n")[1:]
    return [tuple(map(int, line.split(","))) for line in lines if line]


def build_grid(eth, usdc, step):
    t0 = ((eth[0][0] + step - 1) // step) * step
    n = (eth[-1][0] - t0) // step + 1
    ge, gu = [], []
    ie = iu = 0
    started = False
    for i in range(n):
        t = t0 + i * step
        while ie + 1 < len(eth) and eth[ie + 1][0] <= t:
            ie += 1
        ge.append(eth[ie][1])
        while iu < len(usdc) and usdc[iu][0] <= t:
            started = True
            iu += 1
        gu.append(usdc[iu - 1][1] if started else 100000000)  # same documented fallback as the simulator
    return ge, gu


# ---- one position over one window ---------------------------------------------------------------------
STATE = {}


def init_worker(setup):
    STATE.update(setup)


def run_window(task):
    start, frac, lat = task
    S = STATE
    H, step = S["H"], S["step"]
    e, u = S["ge"][start:start + H], S["gu"][start:start + H]
    p = S["protocol"]
    pc0, pb0 = e[0] * 10**10, u[0] * 10**10
    coll = S["collateral_wei"] if S["collateral_usd"] == 0 else mul_div(S["collateral_usd"], W, pc0)
    cv = collateral_value(coll, pc0, COLL_DEC)
    target = mul_div(max_debt_value(cv, p["maxLtv"]), frac, W)
    debt_assets = mul_div(target, 10**DEBT_DEC, pb0)
    while debt_assets and debt_value(debt_assets, pb0, DEBT_DEC) > max_debt_value(cv, p["maxLtv"]):
        debt_assets -= 1  # the market rejects a borrow above the limit
    if debt_assets == 0:
        return (False, False, False, False, False, 0.0)
    scaled = mul_div_up(debt_assets, RAY, RAY)
    index = RAY
    unhealthy = liquidated = bad = stuck = underwater = False
    bad_fraction = 0.0
    pending, pending_step = False, 0
    for k in range(1, H):
        index = accrue_index(index, S["rate"], step)
        if pending and k < pending_step:
            continue
        pc, pb = e[k] * 10**10, u[k] * 10**10
        debt = debt_from_scaled(scaled, index)
        cvk, dv = collateral_value(coll, pc, COLL_DEC), debt_value(debt, pb, DEBT_DEC)
        if not health_factor(cvk, dv, p["liquidationThreshold"]) < W:
            pending = False
            continue
        unhealthy = True
        if not pending:
            pending, pending_step = True, k + lat
        if k < pending_step:
            continue
        pending = False
        if S["min_debt_usd"] and dv < S["min_debt_usd"]:
            stuck = True
            underwater |= dv > cvk
            continue
        repaid, seized, burned = liquidation_amounts(scaled, index, coll, pc, pb, p["liquidationBonus"], p["closeFactor"])
        if repaid == 0 or seized == 0 or (burned == 0 and seized != coll):
            stuck = True
            underwater |= dv > cvk
            continue
        scaled -= burned
        coll -= seized
        liquidated = True
        if coll == 0 and scaled != 0:
            bad = True
            bad_fraction = bad_debt_loss(scaled, index) / debt_assets
            break
        if scaled == 0:
            break
    return (unhealthy, liquidated, bad, stuck, underwater, bad_fraction)


def main():
    if len(sys.argv) < 5:
        sys.exit(__doc__)
    cfg_path, sim_csv, horizon_days = sys.argv[1], sys.argv[2], int(sys.argv[3])
    combos = [tuple(c.split(":")) for c in sys.argv[4:]]
    cfg = json.load(open(cfg_path, encoding="utf-8-sig"))
    if cfg["source"]["type"] != "historical":
        sys.exit("only historical experiments can be cross-checked (bootstrap paths come from the C++ generator)")
    base = os.path.dirname(os.path.abspath(cfg_path))
    eth = load_csv(os.path.join(base, cfg["data"]["eth"]))
    usdc = load_csv(os.path.join(base, cfg["data"]["usdc"]))
    step = int(cfg.get("stepSeconds", 3600))
    ge, gu = build_grid(eth, usdc, step)

    variant = cfg["variants"][0]
    rate_cfg = variant.get("rate", cfg.get("defaultRate"))
    protocol = {k: wad_param(variant[k]) for k in ("maxLtv", "liquidationThreshold", "liquidationBonus", "closeFactor")}
    rate = borrow_rate_per_second(*(wad_param(rate_cfg[k]) for k in ("baseRate", "slope1", "slope2", "optimalUtilization")),
                                  wad_param(cfg["market"]["utilization"]))
    borrower, liquidator = cfg["borrower"], cfg["liquidator"]
    setup = dict(
        ge=ge, gu=gu, H=horizon_days * 86400 // step, step=step, protocol=protocol, rate=rate,
        collateral_wei=scaled_decimal(borrower["collateralEth"], 18) if "collateralEth" in borrower else 0,
        collateral_usd=scaled_decimal(borrower["collateralUsd"], 18) if "collateralUsd" in borrower else 0,
        min_debt_usd=scaled_decimal(liquidator.get("minDebtUsd", "0"), 18),
    )
    stride = int(cfg["source"].get("startStrideDays", 1)) * 86400 // step
    starts = list(range(0, len(ge) - setup["H"] + 1, stride))

    sim = {}
    with open(sim_csv) as f:
        for row in csv.DictReader(f):
            if int(row["horizonDays"]) == horizon_days and row["variant"] == variant.get("label", "variant"):
                sim[(row["ltvFraction"], row["latencyHours"])] = row

    all_ok = True
    with concurrent.futures.ProcessPoolExecutor(initializer=init_worker, initargs=(setup,)) as pool:
        for frac_text, lat_text in combos:
            frac, lat = wad_param(frac_text), int(lat_text) * 3600 // step
            res = list(pool.map(run_window, [(s, frac, lat) for s in starts], chunksize=8))
            mine = dict(n=len(res), unhealthy=sum(r[0] for r in res), liquidated=sum(r[1] for r in res),
                        badDebt=sum(r[2] for r in res), stuck=sum(r[3] for r in res),
                        stuckUnderwater=sum(r[4] for r in res), badMean=sum(r[5] for r in res) / len(res))
            row = sim[(frac_text, lat_text)]
            theirs = {k: int(row[k]) for k in ("n", "unhealthy", "liquidated", "badDebt", "stuck", "stuckUnderwater")}
            theirs["badMean"] = float(row["badMean"])
            same = all(mine[k] == theirs[k] for k in theirs if k != "badMean") and abs(mine["badMean"] - theirs["badMean"]) < 1e-6
            all_ok &= same
            print(f"fraction {frac_text} latency {lat_text} h: {'MATCH' if same else 'DIFFERENT'}\n"
                  f"   python: {mine}\n   c++   : {theirs}", flush=True)
    print("ALL MATCH" if all_ok else "SOME DIFFER")
    sys.exit(0 if all_ok else 1)


if __name__ == "__main__":
    main()
