#!/usr/bin/env python3
"""Per-model baseline from the dispatch records: how often a worker lands, what a run costs.

Reads every `<issue>.result.jsonl` under ~/.agents/state/records (and .agents/tasks), keeps
one row per (issue, dispatched_at, worker), and prints, per model: runs, outcomes, billed
USD (only rows OpenRouter billed — `cost.usd` is null when the price was not real), tokens,
turns, wall time. With `--endpoints <model>` it also prices the model's token mix on every
provider (modelled, NOT measured).

  .agents/bench/openrouter-models/baseline.py [--since 2026-09-18] [--model SUBSTR]
  .agents/bench/openrouter-models/baseline.py --endpoints deepseek/deepseek-v4.1-flash

Method and caveats: README.md in this directory.
"""
from __future__ import annotations

import argparse
import collections
import glob
import json
import os
import statistics as st
import sys
import urllib.request

HOME = os.path.expanduser("~")
GLOBS = [f"{HOME}/.agents/state/records/*.jsonl", f"{HOME}/.agents/tasks/*.result.jsonl"]


def load_rows(since: str = "") -> list[dict]:
    rows, seen = [], set()
    for pattern in GLOBS:
        for path in glob.glob(pattern):
            for line in open(path):
                try:
                    r = json.loads(line)
                except json.JSONDecodeError:
                    continue
                key = (r.get("issue"), r.get("dispatched_at"), r.get("worker"))
                if key in seen or (since and (r.get("dispatched_at") or "") < since):
                    continue
                seen.add(key)
                rows.append(r)
    return rows


def summarise(rows: list[dict], model_filter: str = "") -> None:
    by = collections.defaultdict(list)
    for r in rows:
        m = r.get("model") or "?"
        if model_filter in m:
            by[m].append(r)
    for m, rs in sorted(by.items(), key=lambda kv: -len(kv[1])):
        oc = collections.Counter(r.get("outcome") for r in rs)
        usd = [r["cost"]["usd"] for r in rs if (r.get("cost") or {}).get("usd") is not None]
        landed = [r for r in rs if r.get("outcome") == "landed"]
        landed_usd = [r["cost"]["usd"] for r in landed if (r.get("cost") or {}).get("usd") is not None]
        tok = lambda k: sum(((r.get("cost") or {}).get(k) or 0) for r in rs)
        print(f"\n{m}: {len(rs)} runs, landed {len(landed)} ({len(landed) / len(rs):.0%}), outcomes {dict(oc)}")
        if usd:
            print(f"  billed ${sum(usd):.2f} over {len(usd)} priced runs: ${sum(usd) / len(usd):.3f}/run"
                  + (f", ${sum(landed_usd) / len(landed_usd):.3f}/landed run" if landed_usd else "")
                  + f", ${sum(usd) - sum(landed_usd):.2f} on non-landed runs")
        i, c, o = tok("input_tokens"), tok("cached_input_tokens"), tok("output_tokens")
        if i + c:
            print(f"  tokens: uncached in {i / 1e6:.0f}M, cache reads {c / 1e6:.0f}M "
                  f"({c / (i + c):.0%} of input), out {o / 1e6:.1f}M")
        turns = [(r.get("runner") or {}).get("turns") or 0 for r in rs]
        wall = [r.get("wall_clock_s") or 0 for r in rs]
        print(f"  median turns {st.median(turns):.0f}, median wall {st.median(wall) / 60:.0f} min")


def model_endpoints(model: str, rows: list[dict]) -> None:
    rs = [r for r in rows if r.get("model") == model]
    if not rs:
        sys.exit(f"no recorded runs for {model}")
    t = lambda k: sum(((r.get("cost") or {}).get(k) or 0) for r in rs)
    i, c, o = t("input_tokens"), t("cached_input_tokens"), t("output_tokens")
    billed = sum(r["cost"]["usd"] for r in rs if (r.get("cost") or {}).get("usd") is not None)
    data = json.load(urllib.request.urlopen(
        f"https://openrouter.ai/api/v1/models/{model}/endpoints", timeout=40))["data"]["endpoints"]
    priced = []
    for e in data:
        p = e["pricing"]
        pin, pout = float(p["prompt"]), float(p["completion"])
        pcache = float(p.get("input_cache_read") or p["prompt"])
        priced.append((i * pin + c * pcache + o * pout, e["provider_name"]))
    priced.sort()
    print(f"{model}: {len(rs)} runs, billed ${billed:.2f}; the SAME token mix priced per provider "
          f"(modelled — token counts differ between models and providers):")
    for cost, name in priced[:5]:
        print(f"  ${cost:8.2f}  {name}")
    print(f"  median ${st.median(c for c, _ in priced):.2f}, max ${priced[-1][0]:.2f} ({priced[-1][1]})")


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--since", default="")
    ap.add_argument("--model", default="")
    ap.add_argument("--endpoints", metavar="MODEL")
    a = ap.parse_args()
    all_rows = load_rows(a.since)
    if a.endpoints:
        model_endpoints(a.endpoints, all_rows)
    else:
        print(f"{len(all_rows)} unique dispatch records")
        summarise(all_rows, a.model)
