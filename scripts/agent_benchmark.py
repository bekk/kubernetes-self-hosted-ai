#!/usr/bin/env python3
"""Simulate many developers running coding agents (Claude Code, Codex) at once.

Each simulated developer runs agent sessions back to back. A session looks like
what a coding agent actually sends:

  - a large, shared system prompt + tool definitions (the same for everyone)
  - a task, then a loop of turns: the model answers briefly, a "tool" runs for
    a few seconds, and its output (a file, a diff, test output) is appended
  - the context grows every turn; earlier turns are an exact prefix, so the
    server can reuse them (prefix caching), just like the API's prompt caching

Per number of concurrent developers it reports turn latency, time to first
token, throughput, whether a latency SLO holds, and cost per developer-hour:
self-hosted (hardware price ÷ developers) against what the same tokens would
cost through an API, with that API's prompt-caching prices.

Standard library only. Example:
    make port-forward   # in another terminal
    python3 scripts/agent_benchmark.py --model medium --developers 4,8,16,32 \\
        --price 23 --api "Sonnet 5.5=2/10/0.2" --api "Opus 5.5=4/20/0.2"
"""

from __future__ import annotations

import argparse
import concurrent.futures as cf
import json
import os
import random
import statistics
import sys
import threading
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, asdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from benchmark import master_key_from_tofu, percentile, fmt  # noqa: E402

# Rough characters per token for the synthetic code-like text below. Only used
# to size the prompts; all reported token counts come from the server.
CHARS_PER_TOKEN = 3.6

TASKS = [
    "Fix the failing test in the payment service and explain the root cause.",
    "Add retry with exponential backoff to the HTTP client wrapper.",
    "Refactor the order repository to use the new database connection pool.",
    "Find out why the nightly job times out and propose a fix.",
    "Add input validation to the user registration endpoint.",
    "Upgrade the logging setup to structured JSON logs.",
    "Write unit tests for the invoice calculation module.",
    "Remove the deprecated feature flag and clean up dead code paths.",
]


def synthetic_code(n_tokens: int, seed: int) -> str:
    """Deterministic, code-like filler of roughly n_tokens tokens."""
    rng = random.Random(seed)
    words = ["request", "response", "client", "order", "invoice", "user", "retry", "timeout",
             "config", "logger", "cache", "session", "result", "error", "payload", "handler"]
    lines, size = [], 0
    target = int(n_tokens * CHARS_PER_TOKEN)
    while size < target:
        a, b, c = rng.choice(words), rng.choice(words), rng.choice(words)
        line = f"    def {a}_{b}(self, {c}: dict) -> dict:  # {rng.randint(100, 999)}\n" \
               f"        return self._{c}.get('{a}', {{}}) or self.{b}_{c}({c})\n"
        lines.append(line)
        size += len(line)
    return "".join(lines)


def build_system_prompt(n_tokens: int) -> str:
    """Shared by every session, like an agent's system prompt + tool schemas."""
    header = (
        "You are a coding agent working in a developer's repository. You can read files, "
        "edit files and run commands through tools. Keep answers short: say what you will do "
        "next, then do it. The repository's key modules are included below for reference.\n\n"
    )
    return header + synthetic_code(n_tokens, seed=42)


@dataclass
class Turn:
    developer: int
    session: int
    turn: int
    ttft: float
    latency: float
    prompt_tokens: int
    output_tokens: int
    new_input_tokens: int  # not covered by an earlier turn's prefix
    ok: bool


@dataclass
class LevelResult:
    model: str
    developers: int
    duration_s: float
    turns: int
    failed: int
    sessions_completed: int
    turns_per_dev_min: float
    ttft_p50: float
    ttft_p95: float
    turn_p50: float
    turn_p95: float
    output_tps_per_turn_p50: float
    input_tps_total: float
    output_tps_total: float
    avg_prompt_tokens: float
    avg_output_tokens: float
    new_input_share: float
    slo_ok: bool
    # Token totals for API pricing
    input_new: int
    input_cached: int
    output: int


def chat(base_url: str, key: str, model: str, messages: list, max_tokens: int) -> tuple[float, float, int, int, str]:
    body = json.dumps({
        "model": model,
        "messages": messages,
        "max_tokens": max_tokens,
        "temperature": 0.3,
        "stream": True,
        "stream_options": {"include_usage": True},
    }).encode()
    req = urllib.request.Request(
        f"{base_url.rstrip('/')}/v1/chat/completions", data=body,
        headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"},
    )
    start = time.perf_counter()
    first = None
    text, prompt_tokens, output_tokens = [], 0, 0
    with urllib.request.urlopen(req, timeout=900) as resp:
        for raw in resp:
            line = raw.decode("utf-8", "replace").strip()
            if not line.startswith("data: ") or line == "data: [DONE]":
                continue
            event = json.loads(line[6:])
            if event.get("usage"):
                prompt_tokens = event["usage"].get("prompt_tokens") or 0
                output_tokens = event["usage"].get("completion_tokens") or 0
            for choice in event.get("choices") or []:
                delta = choice.get("delta") or {}
                piece = delta.get("content") or delta.get("reasoning_content") or delta.get("reasoning")
                if piece:
                    if first is None:
                        first = time.perf_counter()
                    if delta.get("content"):
                        text.append(delta["content"])
    end = time.perf_counter()
    return (first or end) - start, end - start, prompt_tokens, output_tokens, "".join(text)


def developer_loop(dev: int, args, system_prompt: str, deadline: float, out: list, lock: threading.Lock,
                   sessions_done: list) -> None:
    rng = random.Random(1000 + dev)
    session = 0
    # Stagger starts so developers don't all hit the server in the same second.
    time.sleep(rng.uniform(0, args.think_max))
    while time.time() < deadline:
        session += 1
        messages = [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": TASKS[(dev + session) % len(TASKS)]},
        ]
        prev_prompt, prev_output = 0, 0
        for turn in range(1, args.turns + 1):
            if time.time() >= deadline:
                return
            try:
                ttft, latency, p_tok, o_tok, text = chat(args.base_url, args.key, args.model, messages,
                                                         args.max_output_tokens)
                ok = p_tok > 0
            except (urllib.error.URLError, OSError, json.JSONDecodeError) as exc:
                with lock:
                    out.append(Turn(dev, session, turn, 0, 0, 0, 0, 0, False))
                print(f"    dev {dev} turn failed: {exc}", file=sys.stderr)
                break
            if turn > 1:
                new_input = p_tok - (prev_prompt + prev_output)
            else:
                # The shared system prompt is cached across sessions (and developers),
                # so only the task itself is new on a session's first turn.
                new_input = p_tok - args.measured_system_tokens
            with lock:
                out.append(Turn(dev, session, turn, ttft, latency, p_tok, o_tok, max(new_input, 0), ok))
            prev_prompt, prev_output = p_tok, o_tok
            # The agent's answer goes back into the context, then a tool result.
            messages.append({"role": "assistant", "content": text or "(tool call)"})
            tool_output = synthetic_code(args.tool_result_tokens, seed=dev * 10_000 + session * 100 + turn)
            messages.append({"role": "user", "content": f"Tool result:\n```\n{tool_output}```\nContinue."})
            if p_tok + args.tool_result_tokens + args.max_output_tokens > args.max_context:
                break
            time.sleep(rng.uniform(args.think_min, args.think_max))  # the tool "runs"
        else:
            with lock:
                sessions_done[0] += 1


def run_level(args, developers: int, system_prompt: str) -> LevelResult:
    turns: list[Turn] = []
    lock = threading.Lock()
    sessions_done = [0]
    deadline = time.time() + args.duration
    start = time.perf_counter()
    with cf.ThreadPoolExecutor(max_workers=developers) as pool:
        for dev in range(developers):
            pool.submit(developer_loop, dev, args, system_prompt, deadline, turns, lock, sessions_done)
    wall = time.perf_counter() - start

    ok = [t for t in turns if t.ok]
    failed = len(turns) - len(ok)
    input_tokens = sum(t.prompt_tokens for t in ok)
    output_tokens = sum(t.output_tokens for t in ok)
    new_input = sum(t.new_input_tokens for t in ok)
    decode = [t.output_tokens / max(t.latency - t.ttft, 1e-3) for t in ok if t.output_tokens > 1]
    ttft_p95 = percentile([t.ttft for t in ok], 0.95)
    turn_p95 = percentile([t.latency for t in ok], 0.95)
    return LevelResult(
        model=args.model,
        developers=developers,
        duration_s=wall,
        turns=len(ok),
        failed=failed,
        sessions_completed=sessions_done[0],
        turns_per_dev_min=len(ok) / developers / (wall / 60) if wall > 0 else 0,
        ttft_p50=percentile([t.ttft for t in ok], 0.5),
        ttft_p95=ttft_p95,
        turn_p50=percentile([t.latency for t in ok], 0.5),
        turn_p95=turn_p95,
        output_tps_per_turn_p50=statistics.median(decode) if decode else float("nan"),
        input_tps_total=input_tokens / wall if wall else 0,
        output_tps_total=output_tokens / wall if wall else 0,
        avg_prompt_tokens=input_tokens / len(ok) if ok else 0,
        avg_output_tokens=output_tokens / len(ok) if ok else 0,
        new_input_share=new_input / input_tokens if input_tokens else 0,
        slo_ok=bool(ok) and failed == 0 and ttft_p95 <= args.slo_ttft and turn_p95 <= args.slo_turn,
        input_new=new_input,
        input_cached=input_tokens - new_input,
        output=output_tokens,
    )


def parse_api(pairs: list[str]) -> dict[str, tuple[float, float, float]]:
    """NAME=INPUT/OUTPUT/CACHE_READ in USD per 1M tokens."""
    parsed = {}
    for pair in pairs:
        name, sep, prices = pair.rpartition("=")
        parts = prices.split("/")
        if not sep or len(parts) != 3:
            sys.exit(f"--api expects NAME=IN/OUT/CACHE_READ, got {pair!r}")
        parsed[name.strip()] = tuple(float(p) for p in parts)
    return parsed


def api_cost_per_dev_hour(lv: LevelResult, prices: tuple[float, float, float], cache_write_factor: float) -> float:
    """What this level's tokens would cost through the API, per developer-hour.

    New input tokens are written to the prompt cache (billed at input price ×
    cache_write_factor); the reused prefix is billed as cache reads.
    """
    p_in, p_out, p_cache = prices
    usd = (lv.input_new * p_in * cache_write_factor + lv.input_cached * p_cache + lv.output * p_out) / 1e6
    dev_hours = lv.developers * lv.duration_s / 3600
    return usd / dev_hours if dev_hours else float("nan")


def print_report(levels: list[LevelResult], args, api: dict) -> None:
    print(f"\n## Agent workload: {args.model}\n")
    print(f"System prompt ~{fmt(args.measured_system_tokens)} tokens, {args.turns} turns per session, "
          f"tool results ~{fmt(args.tool_result_tokens)} tokens, max {args.max_output_tokens} output tokens per turn, "
          f"{args.think_min:g}–{args.think_max:g} s tool time between turns, {args.duration:g} s per level.\n")
    print("| Developers | Turns | Turns/dev/min | TTFT p50 | TTFT p95 | Turn p50 | Turn p95 | "
          "Output tok/s per turn | Input tok/s total | Output tok/s total | SLO |")
    print("|---|---|---|---|---|---|---|---|---|---|---|")
    for lv in levels:
        failed = f" ({lv.failed} failed)" if lv.failed else ""
        print(f"| {lv.developers} | {lv.turns}{failed} | {lv.turns_per_dev_min:.1f} | {lv.ttft_p50:.1f} s | "
              f"{lv.ttft_p95:.1f} s | {lv.turn_p50:.1f} s | {lv.turn_p95:.1f} s | {fmt(lv.output_tps_per_turn_p50)} | "
              f"{fmt(lv.input_tps_total)} | {fmt(lv.output_tps_total)} | {'✅' if lv.slo_ok else '❌'} |")

    if levels:
        lv = levels[-1]
        print(f"\nAverage turn: {fmt(lv.avg_prompt_tokens)} input tokens ({lv.new_input_share:.0%} new, the rest "
              f"a reused prefix), {fmt(lv.avg_output_tokens)} output tokens.")

    ok_levels = [lv for lv in levels if lv.slo_ok]
    print(f"\nSLO: p95 time to first token ≤ {args.slo_ttft:g} s and p95 turn ≤ {args.slo_turn:g} s. "
          + (f"**Max developers within SLO: {ok_levels[-1].developers}.**" if ok_levels
             else "**No level met the SLO.**"))

    if args.price:
        print("\n## Cost per developer-hour (active use)\n")
        names = list(api)
        head = "".join(f" API: {n} |" for n in names)
        print(f"| Developers | SLO | Self-hosted ({fmt(args.price, 2)} USD/h ÷ developers) |{head}")
        print("|---|---|---|" + "---|" * len(names))
        for lv in levels:
            cells = "".join(f" {fmt(api_cost_per_dev_hour(lv, api[n], args.cache_write_factor), 2)} USD |" for n in names)
            print(f"| {lv.developers} | {'✅' if lv.slo_ok else '❌'} | {fmt(args.price / lv.developers, 2)} USD |{cells}")
        print(f"\nAPI cost assumes every new input token is written to the prompt cache "
              f"(×{args.cache_write_factor:g} input price) and the reused prefix is billed as cache reads.")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--base-url", default=os.environ.get("LITELLM_URL", "http://localhost:4000"))
    parser.add_argument("--key", default=os.environ.get("LITELLM_KEY"))
    parser.add_argument("--model", default="medium")
    parser.add_argument("--developers", default="4,8,16,32", help="Concurrent developers per level")
    parser.add_argument("--duration", type=float, default=120, help="Seconds per level")
    parser.add_argument("--system-tokens", type=int, default=12_000, help="Shared system prompt + tools size")
    parser.add_argument("--turns", type=int, default=10, help="Turns per agent session")
    parser.add_argument("--tool-result-tokens", type=int, default=1_500, help="Tool output appended per turn")
    parser.add_argument("--max-output-tokens", type=int, default=400)
    parser.add_argument("--max-context", type=int, default=60_000, help="End a session before exceeding this")
    parser.add_argument("--think-min", type=float, default=2, help="Min seconds a tool 'runs' between turns")
    parser.add_argument("--think-max", type=float, default=8, help="Max seconds a tool 'runs' between turns")
    parser.add_argument("--slo-ttft", type=float, default=5, help="p95 time-to-first-token target, seconds")
    parser.add_argument("--slo-turn", type=float, default=30, help="p95 turn latency target, seconds")
    parser.add_argument("--price", type=float, help="Hourly price of the model's hardware, USD")
    parser.add_argument("--api", action="append", default=[], metavar="NAME=IN/OUT/CACHE_READ",
                        help="API prices in USD per 1M tokens, e.g. 'Sonnet 5.5=2/10/0.2' (repeatable)")
    parser.add_argument("--cache-write-factor", type=float, default=1.25,
                        help="Prompt-cache write price as a multiple of the input price (default 1.25)")
    parser.add_argument("--json", type=Path)
    args = parser.parse_args()

    args.key = args.key or master_key_from_tofu()
    if not args.key:
        sys.exit("No API key: set LITELLM_KEY or run from the repo with the platform stack applied.")
    api = parse_api(args.api)
    levels_wanted = [int(d) for d in args.developers.split(",")]

    system_prompt = build_system_prompt(args.system_tokens)
    print(f"==> {args.model}: warming up and measuring the system prompt", file=sys.stderr)
    try:
        _, _, p_tok, _, _ = chat(args.base_url, args.key, args.model,
                                 [{"role": "system", "content": system_prompt},
                                  {"role": "user", "content": "Reply with OK."}], 8)
    except (urllib.error.URLError, OSError) as exc:
        sys.exit(f"Warm-up failed: {exc}")
    args.measured_system_tokens = p_tok
    print(f"    system prompt ≈ {p_tok} tokens", file=sys.stderr)

    results = []
    for developers in levels_wanted:
        print(f"==> {developers} developers for {args.duration:g} s ...", file=sys.stderr)
        lv = run_level(args, developers, system_prompt)
        print(f"    {lv.turns} turns, TTFT p95 {lv.ttft_p95:.1f} s, turn p95 {lv.turn_p95:.1f} s, "
              f"SLO {'ok' if lv.slo_ok else 'missed'}", file=sys.stderr)
        results.append(lv)

    print_report(results, args, api)
    if args.json:
        args.json.write_text(json.dumps({"args": {k: v for k, v in vars(args).items() if k != "key" and not isinstance(v, Path)},
                                         "results": [asdict(r) for r in results]}, indent=2, default=str))
        print(f"\nRaw results written to {args.json}", file=sys.stderr)


if __name__ == "__main__":
    main()
