#!/usr/bin/env python3
"""Throughput and cost benchmark for the models behind the LiteLLM gateway.

Measures, per model and concurrency level:
  - time to first token (p50 / p95)
  - output tokens per second for a single request (p50)
  - aggregate output tokens per second across all concurrent requests

and turns that into cost per 1M output tokens at a given hourly price and
utilization, plus the throughput needed to break even with an API price.

Standard library only. Talks to the OpenAI-compatible endpoint, so it works
against LiteLLM (default) or any vLLM server directly.

Example:
    make port-forward   # in another terminal
    python3 scripts/benchmark.py --models small,medium \\
        --price small=11 --price medium=23 \\
        --api-price "Sonnet 5.5=10" --api-price "Haiku 5.5=0.5"
"""

from __future__ import annotations

import argparse
import concurrent.futures as cf
import json
import os
import statistics
import subprocess
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, asdict
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

PROMPT = (
    "Write a detailed, {n}-word technical explanation of how a Kubernetes "
    "scheduler places a pod that requests GPUs onto a node with taints. "
    "Use plain prose, no lists."
)


@dataclass
class RequestResult:
    ttft: float  # seconds until the first output token
    decode_tps: float  # output tokens / second after the first token
    output_tokens: int
    seconds: float  # total wall time for the request


@dataclass
class LevelResult:
    model: str
    concurrency: int
    requests: int
    failed: int
    ttft_p50: float
    ttft_p95: float
    decode_tps_p50: float
    aggregate_tps: float
    output_tokens: int
    wall_seconds: float


def master_key_from_tofu() -> str | None:
    """Read the LiteLLM master key from the platform stack's outputs."""
    try:
        out = subprocess.run(
            ["tofu", f"-chdir={REPO_ROOT / 'platform'}", "output", "-raw", "litellm_master_key"],
            capture_output=True, text=True, timeout=60, check=True,
        )
        key = out.stdout.strip()
        return key if key.startswith("sk-") else None
    except (OSError, subprocess.SubprocessError):
        return None


def stream_chat(base_url: str, key: str, model: str, max_tokens: int, seq: int) -> RequestResult:
    body = json.dumps({
        "model": model,
        "stream": True,
        "stream_options": {"include_usage": True},
        "max_tokens": max_tokens,
        "temperature": 0.7,
        # Vary the prompt slightly so prefix caching doesn't flatter the numbers.
        "messages": [{"role": "user", "content": PROMPT.format(n=300 + seq % 50)}],
    }).encode()
    req = urllib.request.Request(
        f"{base_url.rstrip('/')}/v1/chat/completions",
        data=body,
        headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"},
    )

    start = time.perf_counter()
    first = None
    chunks = 0
    usage_tokens = None
    with urllib.request.urlopen(req, timeout=600) as resp:
        for raw in resp:
            line = raw.decode("utf-8", "replace").strip()
            if not line.startswith("data: ") or line == "data: [DONE]":
                continue
            event = json.loads(line[6:])
            if event.get("usage"):
                usage_tokens = event["usage"].get("completion_tokens")
            for choice in event.get("choices") or []:
                delta = choice.get("delta") or {}
                # Reasoning models stream thinking separately; it's still output we pay for.
                if delta.get("content") or delta.get("reasoning_content") or delta.get("reasoning"):
                    chunks += 1
                    if first is None:
                        first = time.perf_counter()
    end = time.perf_counter()

    if first is None:
        raise RuntimeError("no output tokens received")
    tokens = usage_tokens or chunks
    decode_window = max(end - first, 1e-6)
    return RequestResult(
        ttft=first - start,
        decode_tps=max(tokens - 1, 0) / decode_window,
        output_tokens=tokens,
        seconds=end - start,
    )


def percentile(values: list[float], p: float) -> float:
    if not values:
        return float("nan")
    ordered = sorted(values)
    k = (len(ordered) - 1) * p
    lo, hi = int(k), min(int(k) + 1, len(ordered) - 1)
    return ordered[lo] + (ordered[hi] - ordered[lo]) * (k - lo)


def run_level(args, model: str, concurrency: int) -> LevelResult:
    total = concurrency * args.requests_per_worker
    results: list[RequestResult] = []
    failed = 0
    start = time.perf_counter()
    with cf.ThreadPoolExecutor(max_workers=concurrency) as pool:
        futures = [
            pool.submit(stream_chat, args.base_url, args.key, model, args.max_tokens, i)
            for i in range(total)
        ]
        for fut in cf.as_completed(futures):
            try:
                results.append(fut.result())
            except (urllib.error.URLError, RuntimeError, OSError, json.JSONDecodeError) as exc:
                failed += 1
                print(f"    request failed: {exc}", file=sys.stderr)
    wall = time.perf_counter() - start
    tokens = sum(r.output_tokens for r in results)
    return LevelResult(
        model=model,
        concurrency=concurrency,
        requests=len(results),
        failed=failed,
        ttft_p50=percentile([r.ttft for r in results], 0.5),
        ttft_p95=percentile([r.ttft for r in results], 0.95),
        decode_tps_p50=statistics.median([r.decode_tps for r in results]) if results else float("nan"),
        aggregate_tps=tokens / wall if wall > 0 else 0.0,
        output_tokens=tokens,
        wall_seconds=wall,
    )


def cost_per_million(price_per_hour: float, tps: float, utilization: float) -> float:
    """USD per 1M output tokens: price ÷ (tokens/s × 3600 × utilization) × 1M."""
    if tps <= 0 or utilization <= 0:
        return float("inf")
    return price_per_hour / (tps * 3600 * utilization) * 1_000_000


def break_even_tps(price_per_hour: float, api_usd_per_million: float) -> float:
    """Tokens/s needed around the clock to cost the same as the API."""
    return price_per_hour / api_usd_per_million * 1_000_000 / 3600


def parse_pairs(pairs: list[str], what: str) -> dict[str, float]:
    parsed = {}
    for pair in pairs:
        name, sep, value = pair.rpartition("=")
        if not sep or not name:
            sys.exit(f"--{what} expects NAME=NUMBER, got {pair!r}")
        parsed[name.strip()] = float(value)
    return parsed


def fmt(x: float, digits: int = 0) -> str:
    if x != x or x == float("inf"):  # NaN or inf
        return "–"
    return f"{x:,.{digits}f}".replace(",", " ")


def print_report(levels: list[LevelResult], prices: dict[str, float], api_prices: dict[str, float],
                 utilizations: list[float]) -> None:
    print("\n## Throughput\n")
    print("| Model | Concurrency | Requests | TTFT p50 | TTFT p95 | Tokens/s per request | Tokens/s total |")
    print("|---|---|---|---|---|---|---|")
    for lv in levels:
        failed = f" ({lv.failed} failed)" if lv.failed else ""
        print(f"| {lv.model} | {lv.concurrency} | {lv.requests}{failed} | {lv.ttft_p50:.2f} s | "
              f"{lv.ttft_p95:.2f} s | {fmt(lv.decode_tps_p50)} | {fmt(lv.aggregate_tps)} |")

    priced = [lv for lv in levels if lv.model in prices]
    if priced:
        print("\n## Cost per 1M output tokens\n")
        header = " | ".join(f"{u:.0%} utilization" for u in utilizations)
        print(f"| Model | Hourly price | Concurrency | Tokens/s total | {header} |")
        print("|---|---|---|---|" + "---|" * len(utilizations))
        for lv in priced:
            cells = " | ".join(
                f"{fmt(cost_per_million(prices[lv.model], lv.aggregate_tps, u), 2)} USD" for u in utilizations
            )
            print(f"| {lv.model} | {fmt(prices[lv.model], 2)} USD | {lv.concurrency} | "
                  f"{fmt(lv.aggregate_tps)} | {cells} |")

    if prices and api_prices:
        print("\n## Break-even against API prices (output tokens, 24/7, 100 % utilization)\n")
        print("| Model | Hourly price | API | API USD / 1M | Needed tokens/s | Best measured tokens/s |")
        print("|---|---|---|---|---|---|")
        for model, price in prices.items():
            best = max((lv.aggregate_tps for lv in levels if lv.model == model), default=float("nan"))
            for api, api_price in api_prices.items():
                print(f"| {model} | {fmt(price, 2)} USD | {api} | {fmt(api_price, 2)} | "
                      f"{fmt(break_even_tps(price, api_price))} | {fmt(best)} |")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--base-url", default=os.environ.get("LITELLM_URL", "http://localhost:4000"),
                        help="OpenAI-compatible endpoint (default: LiteLLM via make port-forward)")
    parser.add_argument("--key", default=os.environ.get("LITELLM_KEY"),
                        help="API key (default: $LITELLM_KEY, else the LiteLLM master key from tofu)")
    parser.add_argument("--models", default="small,medium", help="Comma-separated model names or aliases")
    parser.add_argument("--concurrency", default="1,4,8,16", help="Comma-separated concurrency levels")
    parser.add_argument("--requests-per-worker", type=int, default=2,
                        help="Sequential requests per concurrent worker (default: 2)")
    parser.add_argument("--max-tokens", type=int, default=512, help="Output tokens per request")
    parser.add_argument("--price", action="append", default=[], metavar="MODEL=USD_PER_HOUR",
                        help="Hourly price for a model's hardware, e.g. medium=23 (repeatable)")
    parser.add_argument("--api-price", action="append", default=[], metavar="NAME=USD_PER_1M",
                        help="API output price to compare against, e.g. 'Sonnet 5.5=10' (repeatable)")
    parser.add_argument("--utilization", default="1,0.25,0.05",
                        help="Utilization levels for the cost table (default: 1,0.25,0.05)")
    parser.add_argument("--json", type=Path, help="Also write raw results to this JSON file")
    args = parser.parse_args()

    args.key = args.key or master_key_from_tofu()
    if not args.key:
        sys.exit("No API key: set LITELLM_KEY or run from the repo with the platform stack applied.")

    models = [m.strip() for m in args.models.split(",") if m.strip()]
    levels = [int(c) for c in args.concurrency.split(",")]
    utilizations = [float(u) for u in args.utilization.split(",")]
    prices = parse_pairs(args.price, "price")
    api_prices = parse_pairs(args.api_price, "api-price")

    results: list[LevelResult] = []
    for model in models:
        print(f"==> {model}: warming up", file=sys.stderr)
        try:
            stream_chat(args.base_url, args.key, model, 32, 0)
        except (urllib.error.URLError, RuntimeError, OSError) as exc:
            print(f"    skipping {model}: {exc}", file=sys.stderr)
            continue
        for concurrency in levels:
            print(f"    concurrency {concurrency} ...", file=sys.stderr)
            lv = run_level(args, model, concurrency)
            print(f"    {fmt(lv.aggregate_tps)} tokens/s total, TTFT p50 {lv.ttft_p50:.2f} s", file=sys.stderr)
            results.append(lv)

    if not results:
        sys.exit("No results: is the gateway reachable and are the models awake?")

    print_report(results, prices, api_prices, utilizations)

    if args.json:
        args.json.write_text(json.dumps({
            "base_url": args.base_url,
            "max_tokens": args.max_tokens,
            "prices_usd_per_hour": prices,
            "api_prices_usd_per_million": api_prices,
            "results": [asdict(r) for r in results],
        }, indent=2))
        print(f"\nRaw results written to {args.json}", file=sys.stderr)


if __name__ == "__main__":
    main()
