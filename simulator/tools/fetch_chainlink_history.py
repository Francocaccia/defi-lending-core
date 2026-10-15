#!/usr/bin/env python3
"""Download the full public round history of a Chainlink price feed straight from Ethereum mainnet.

Why on-chain data: the protocol's oracle wrapper reads exactly this feed, so the simulator replays
the prices the protocol would really have seen (with their real update granularity: heartbeat plus
deviation triggers), and the data is public blockchain state: no vendor account, no third-party
redistribution terms. Round data lives in contract storage, so no archive node is needed.

Usage:
    python fetch_chainlink_history.py <proxy_address> <out.csv> [--rpc URL ...]

Endpoint selection (first match wins):
  1. --rpc URL ...            explicit endpoints, in order of preference
  2. $MAINNET_RPC_URL         YOUR OWN endpoint (for example a free Alchemy / Infura key). It is the
                              ONLY endpoint used when set, and it is never printed, logged or written
                              anywhere: error text is redacted and the metadata records only the
                              provider's domain, never the URL.
  3. free key-less public RPCs, used politely (global delay that backs off on HTTP 429)

Uses ONLY the Python standard library. Read-only: it issues `eth_call` requests and nothing else.

Resuming: finished phases are cached, and so is the progress INSIDE a phase (every ~1000 rounds), so an
interrupted run continues where it stopped. With your own endpoint, persistent 429s or a quota error
stop the run with a message instead of retrying for hours.

Output CSV (no header comments, one header line):  updatedAt,answer
  updatedAt : unix seconds of the round
  answer    : the feed's integer answer (8 decimals for the USD feeds used here)
A sidecar `<out>.meta.json` records provenance (proxy, aggregator phases, round ranges, fetch time,
provider domain, overlap cross-check and the sha256 of the CSV).
"""
import argparse
import datetime
import hashlib
import json
import os
import sys
import time
import urllib.error
import urllib.request

ENV_VAR = "MAINNET_RPC_URL"
DEFAULT_RPCS = ["https://ethereum-rpc.publicnode.com", "https://eth.llamarpc.com", "https://eth.drpc.org"]
UA = "defi-lending-core-research/1.0 (read-only Chainlink history fetch)"
SEL_GET_ROUND = "9a6fc8f5"  # getRoundData(uint80)
SEL_LATEST = "feaf968c"  # latestRoundData()
SEL_PHASE_AGG = "c1597304"  # phaseAggregators(uint16)

PUBLIC_BATCH, PUBLIC_MIN_DELAY = 100, 0.4
KEYED_BATCH, KEYED_MIN_DELAY = 20, 0.15  # smaller batches: free keyed tiers cap compute units per second
MAX_DELAY = 60.0
KEYED_MAX_CONSECUTIVE_429 = 8  # with the doubling delay this is roughly four minutes of trying
SAVE_EVERY = 1000  # rounds between partial-progress saves
PROGRESS_EVERY = 30.0  # seconds
RATE_LIMIT_CODES = (429, -32005, -32029)  # JSON-RPC "limit exceeded" variants


class Stop(SystemExit):
    """A deliberate, explained stop (never a retry loop)."""


def redact(text, secrets):
    """Remove every endpoint URL and its path/query (where API keys live) from a message."""
    out = str(text)
    for url in secrets:
        out = out.replace(url, "<rpc-url>")
        rest = url.split("://", 1)[-1]
        tail = rest.split("/", 1)[1] if "/" in rest else ""
        for piece in [tail] + [p for p in tail.replace("?", "/").replace("&", "/").split("/") if len(p) >= 8]:
            if piece:
                out = out.replace(piece, "<redacted>")
    return out


def provider_label(url):
    """Registered domain only (last two labels), e.g. 'alchemy.com'. Never the path or sub-domain."""
    host = url.split("://", 1)[-1].split("/", 1)[0].split(":")[0]
    labels = host.split(".")
    return ".".join(labels[-2:]) if len(labels) >= 2 else host


class Rpc:
    """JSON-RPC client. One GLOBAL delay is shared by all requests: it doubles on every rate-limit
    answer or network error and decays after successes."""

    def __init__(self, urls, proxy, keyed):
        self.urls, self.proxy, self.keyed = list(urls), proxy, keyed
        self.batch = KEYED_BATCH if keyed else PUBLIC_BATCH
        self.min_delay = KEYED_MIN_DELAY if keyed else PUBLIC_MIN_DELAY
        self.delay = self.min_delay
        self.cur = 0
        self.fail_streak = 0
        self.rate_streak = 0
        self.calls = 0  # eth_call items sent (successfully answered)
        self.n429 = 0
        self.started = time.time()

    def _fail(self, what, rate_limited, quota=False):
        self.fail_streak += 1
        self.delay = min(MAX_DELAY, max(2.0, self.delay * 2))
        if rate_limited:
            self.n429 += 1
            self.rate_streak += 1
        if self.keyed and (quota or self.rate_streak >= KEYED_MAX_CONSECUTIVE_429):
            raise Stop(
                "STOP: your RPC endpoint is rate limiting or out of quota "
                f"({what}; {self.rate_streak} consecutive rate-limit answers, {self.n429} in total). "
                "Finished chunks are cached. Check the provider's dashboard / try later, or fetch fewer "
                "points (one reading per hour). Not retrying."
            )
        if self.fail_streak == 1 or self.fail_streak % 5 == 0:
            print(f"  rpc problem ({what}); delay now {self.delay:.0f}s", flush=True)
        if not self.keyed and self.fail_streak % 6 == 0 and len(self.urls) > 1:
            self.cur = (self.cur + 1) % len(self.urls)
            print(f"  switching to another public endpoint ({provider_label(self.urls[self.cur])})", flush=True)
        time.sleep(self.delay)

    def _post(self, payload):
        data = json.dumps(payload).encode()
        for _attempt in range(40):
            url = self.urls[self.cur]
            try:
                req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json", "User-Agent": UA})
                with urllib.request.urlopen(req, timeout=90) as r:
                    body = json.loads(r.read())
            except urllib.error.HTTPError as exc:
                if self.keyed and exc.code in (401, 403):
                    raise Stop(f"STOP: the endpoint rejected the credentials (HTTP {exc.code}). Check {ENV_VAR}.")
                text = ""
                try:
                    text = exc.read()[:2000].decode("utf-8", "ignore").lower()
                except Exception:
                    pass
                quota = exc.code == 429 and any(w in text for w in ("monthly", "quota", "daily"))
                self._fail(f"HTTP {exc.code}", exc.code == 429, quota)
                continue
            except Exception as exc:  # network hiccup
                self._fail(f"{type(exc).__name__}: {redact(exc, self.urls)}", False)
                continue
            # A 200 answer can still be a JSON-RPC rate-limit error (whole object or per batch item).
            items = body if isinstance(body, list) else [body]
            limited = [i for i in items if isinstance(i, dict) and isinstance(i.get("error"), dict)
                       and i["error"].get("code") in RATE_LIMIT_CODES]
            if limited:
                self._fail("rate limited (JSON-RPC)", True)
                continue
            if not isinstance(body, list):
                self._fail("unexpected response", False)
                continue
            self.fail_streak = 0
            self.rate_streak = 0
            self.delay = max(self.min_delay, self.delay * 0.85)
            time.sleep(self.delay)
            return body
        raise Stop("STOP: the RPC kept failing; finished chunks are cached, re-run later.")

    def call_many(self, datas):
        """Batch of eth_call to the proxy -> list of hex results (None if the call reverted)."""
        out = []
        for i in range(0, len(datas), self.batch):
            chunk = datas[i : i + self.batch]
            payload = [
                {"jsonrpc": "2.0", "id": k, "method": "eth_call", "params": [{"to": self.proxy, "data": d}, "latest"]}
                for k, d in enumerate(chunk)
            ]
            resp = self._post(payload)
            self.calls += len(chunk)
            by_id = {r["id"]: r for r in resp}
            for k in range(len(chunk)):
                r = by_id.get(k, {"error": "missing"})
                out.append(None if "error" in r or r.get("result") in (None, "0x") else r["result"])
        return out


class Progress:
    """Prints rounds done / total, calls per second and the 429 count about every 30 s."""

    def __init__(self, rpc, label, total, done=0):
        self.rpc, self.label, self.total, self.done = rpc, label, total, done
        self.last_t, self.last_calls = time.time(), rpc.calls

    def tick(self, done, force=False):
        self.done = done
        now = time.time()
        if not force and now - self.last_t < PROGRESS_EVERY:
            return
        dt = max(1e-9, now - self.last_t)
        rate = (self.rpc.calls - self.last_calls) / dt
        pct = 100.0 * done / self.total if self.total else 100.0
        print(f"  [{self.label}] {done}/{self.total} rounds ({pct:.1f}%), {rate:.1f} calls/s, "
              f"429s so far: {self.rpc.n429}", flush=True)
        self.last_t, self.last_calls = now, self.rpc.calls


def words(hexstr):
    h = hexstr[2:]
    return [int(h[i : i + 64], 16) for i in range(0, len(h), 64)]


def decode_round(hexstr):
    w = words(hexstr)
    ans = w[1] if w[1] < 2**255 else w[1] - 2**256
    return {"round": w[0], "answer": ans, "updated": w[3]}


def exists(rec):
    # An empty round returns all zeros instead of reverting.
    return rec is not None and rec["updated"] != 0


def get_rounds(rpc, round_ids):
    datas = ["0x" + SEL_GET_ROUND + format(r, "064x") for r in round_ids]
    return [decode_round(h) if h else None for h in rpc.call_many(datas)]


def last_round_in_phase(rpc, phase):
    base = phase << 64
    if not exists(get_rounds(rpc, [base + 1])[0]):
        return 0
    hi = 1
    while exists(get_rounds(rpc, [base + hi * 2])[0]):
        hi *= 2
    lo, up = hi, hi * 2
    while lo + 1 < up:
        mid = (lo + up) // 2
        if exists(get_rounds(rpc, [base + mid])[0]):
            lo = mid
        else:
            up = mid
    return lo


def fetch_phase_rounds(rpc, phase, n, partial_path):
    """Rounds 1..n of a phase, resuming from the partial-progress file (rounds are immutable)."""
    state = {"next": 1, "recs": []}
    if os.path.exists(partial_path):
        with open(partial_path) as f:
            state = json.load(f)
        if state["next"] > 1:
            print(f"  phase {phase}: resuming from round {state['next']} ({len(state['recs'])} rounds already cached)", flush=True)
    progress = Progress(rpc, f"phase {phase}", n, state["next"] - 1)
    base = phase << 64
    k = state["next"]
    while k <= n:
        last = min(n, k + SAVE_EVERY - 1)
        recs = get_rounds(rpc, [base + j for j in range(k, last + 1)])
        state["recs"].extend(r for r in recs if exists(r))
        state["next"] = last + 1
        with open(partial_path, "w") as f:
            json.dump(state, f)
        k = last + 1
        progress.tick(last)
    progress.tick(n, force=True)
    return state["recs"]


def iso(t):
    return datetime.datetime.fromtimestamp(t, datetime.timezone.utc).strftime("%Y-%m-%d %H:%M")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("proxy")
    ap.add_argument("out")
    ap.add_argument("--rpc", action="append", help="endpoint URL (repeatable; first is preferred)")
    args = ap.parse_args()

    env_url = os.environ.get(ENV_VAR, "").strip()
    if args.rpc:
        urls, keyed = args.rpc, False
    elif env_url:
        urls, keyed = [env_url], True
    else:
        urls, keyed = DEFAULT_RPCS, False
    print("endpoint: " + (f"your own ({ENV_VAR}, provider {provider_label(env_url)})" if keyed
                          else "public key-less endpoints"), flush=True)
    rpc = Rpc(urls, args.proxy, keyed)
    cache_dir = os.path.join(os.path.dirname(os.path.abspath(args.out)), ".cache")
    os.makedirs(cache_dir, exist_ok=True)

    try:
        latest = decode_round(rpc.call_many(["0x" + SEL_LATEST])[0])
    except TypeError:
        raise Stop("STOP: could not read latestRoundData from the endpoint (wrong chain or bad credentials?).")
    top_phase = latest["round"] >> 64
    print(f"proxy {args.proxy}: {top_phase} phases, latest update {iso(latest['updated'])}", flush=True)

    rows, phases_meta = [], []
    for phase in range(1, top_phase + 1):
        agg = rpc.call_many(["0x" + SEL_PHASE_AGG + format(phase, "064x")])[0]
        agg_addr = "0x" + agg[-40:] if agg else None
        # Finished (non-latest) phases never change, so they are cached; the live phase is re-read
        # (its already-fetched prefix comes from the partial-progress file).
        cache_path = os.path.join(cache_dir, f"{args.proxy.lower()}_phase{phase}.json")
        partial_path = os.path.join(cache_dir, f"{args.proxy.lower()}_phase{phase}_partial.json")
        if phase < top_phase and os.path.exists(cache_path):
            with open(cache_path) as f:
                recs = json.load(f)
            print(f"  phase {phase}: {len(recs)} rounds (cached, not downloaded again)", flush=True)
        else:
            n = last_round_in_phase(rpc, phase)
            if n == 0:
                print(f"  phase {phase}: no data", flush=True)
                phases_meta.append({"phase": phase, "aggregator": agg_addr, "rounds": 0})
                continue
            print(f"  phase {phase}: {n} rounds to fetch", flush=True)
            recs = fetch_phase_rounds(rpc, phase, n, partial_path)
            if phase < top_phase:
                with open(cache_path, "w") as f:
                    json.dump(recs, f)
                if os.path.exists(partial_path):
                    os.remove(partial_path)
        for r in recs:
            rows.append((r["updated"], r["answer"], phase))
        print(f"  phase {phase}: {len(recs)} rounds, {iso(recs[0]['updated'])} .. {iso(recs[-1]['updated'])}", flush=True)
        phases_meta.append(
            {"phase": phase, "aggregator": agg_addr, "rounds": len(recs),
             "first": iso(recs[0]["updated"]), "last": iso(recs[-1]["updated"])}
        )

    # Merge all phases by time. Newer aggregators were "pre-warmed" before the proxy switched to
    # them, so phases overlap in time; keep one point per timestamp (highest phase wins) and
    # require strictly increasing time and a positive answer.
    rows.sort(key=lambda x: (x[0], x[2]))
    merged, dropped = [], 0
    for t, a, p in rows:
        if a <= 0:
            dropped += 1
            continue
        if merged and t == merged[-1][0]:
            merged[-1] = (t, a, p)
            dropped += 1
            continue
        merged.append((t, a, p))

    # Cross-check overlaps: for each point from a phase, compare with the previous point of ANOTHER
    # phase; report the largest relative gap among points less than 10 minutes apart.
    worst = 0.0
    last_by_phase = {}
    for t, a, p in merged:
        for q, (tq, aq) in last_by_phase.items():
            if q != p and t - tq < 600:
                worst = max(worst, abs(a - aq) / aq)
        last_by_phase[p] = (t, a)

    with open(args.out, "w", newline="\n") as f:
        f.write("updatedAt,answer\n")
        for t, a, _ in merged:
            f.write(f"{t},{a}\n")
    with open(args.out, "rb") as f:
        sha = hashlib.sha256(f.read()).hexdigest()
    hosts = [provider_label(env_url)] if keyed else sorted({provider_label(u) for u in urls})
    meta = {
        "proxy": args.proxy,
        "chainId": 1,
        "fetchedAtUtc": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M"),
        "rpcProviders": hosts,
        "rows": len(merged),
        "first": iso(merged[0][0]),
        "last": iso(merged[-1][0]),
        "droppedDuplicatesOrInvalid": dropped,
        "phases": phases_meta,
        "overlapMaxRelativeGapWithin10min": worst,
        "csvSha256": sha,
    }
    with open(args.out + ".meta.json", "w", newline="\n") as f:
        json.dump(meta, f, indent=2)
        f.write("\n")
    print(f"wrote {len(merged)} rows to {args.out} ({iso(merged[0][0])} .. {iso(merged[-1][0])}); "
          f"worst cross-phase gap within 10 min: {worst:.4%}; sha256 {sha[:16]}...; "
          f"{rpc.calls} calls, {rpc.n429} rate-limit answers, {time.time() - rpc.started:.0f}s", flush=True)


if __name__ == "__main__":
    try:
        main()
    except Stop as stop:
        print(str(stop), file=sys.stderr, flush=True)
        sys.exit(2)
