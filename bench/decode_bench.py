#!/usr/bin/env python3
"""Decode-speed benchmark against a vLLM OpenAI-compatible endpoint.

Streams chat completions for a fixed set of coding prompts and measures, per
request, the time to first token (TTFT) and the decode rate (output tokens per
second after the first token). Runs every prompt set at concurrency 1 and 3,
with greedy and sampled decoding, and prints a JSON summary per scenario.
"""
import json
import statistics
import sys
import threading
import time
import urllib.request

URL = sys.argv[1] if len(sys.argv) > 1 else "http://hyperstack1.wg1:11434/v1/chat/completions"
LABEL = sys.argv[2] if len(sys.argv) > 2 else "run"
MODEL = "Qwen/Qwen3.8-27B-FP8"

PROMPTS = [
    "Write a Go package implementing an LRU cache with generics, Get/Put/Len methods, and table-driven unit tests.",
    "Write a Go HTTP server with handlers for creating, listing and deleting todo items stored in memory, with a mutex, JSON encoding and proper status codes.",
    "Write a Go command-line tool that recursively walks a directory, counts lines per file extension, and prints a sorted table. Include error handling.",
    "Write a Go function that parses and evaluates arithmetic expressions with + - * / and parentheses using a recursive descent parser, plus tests.",
    "Write a Go worker pool that processes jobs from a channel with a configurable number of workers, context cancellation, and result collection.",
    "Refactor this into idiomatic Go with an interface and two implementations: a Shape type that can be Circle, Rectangle or Triangle, each with Area and Perimeter. Add tests.",
]


def one_request(prompt, sampling, results):
    """Send one streaming request and append its timing record to results."""
    body = {
        "model": MODEL,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": 700,
        "stream": True,
        "stream_options": {"include_usage": True},
        # Thinking off: measure answer decoding only, with comparable lengths.
        "chat_template_kwargs": {"enable_thinking": False},
    }
    body.update(sampling)
    req = urllib.request.Request(URL, data=json.dumps(body).encode(), headers={"Content-Type": "application/json"})
    start = time.perf_counter()
    first = None
    tokens = 0
    with urllib.request.urlopen(req, timeout=600) as resp:
        for raw in resp:
            line = raw.decode().strip()
            if not line.startswith("data: ") or line == "data: [DONE]":
                continue
            chunk = json.loads(line[6:])
            if chunk.get("choices") and chunk["choices"][0]["delta"].get("content") and first is None:
                first = time.perf_counter()
            if chunk.get("usage"):
                tokens = chunk["usage"]["completion_tokens"]
    end = time.perf_counter()
    results.append({"ttft": first - start, "tokens": tokens, "decode_tps": (tokens - 1) / (end - first), "wall": end - start})


def scenario(name, sampling, concurrency):
    """Run all prompts in batches of `concurrency` parallel requests."""
    results = []
    t0 = time.perf_counter()
    for i in range(0, len(PROMPTS), concurrency):
        threads = [threading.Thread(target=one_request, args=(p, sampling, results)) for p in PROMPTS[i:i + concurrency]]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
    total_wall = time.perf_counter() - t0
    total_tokens = sum(r["tokens"] for r in results)
    return {
        "label": LABEL, "scenario": name, "concurrency": concurrency,
        "per_request_decode_tps_median": round(statistics.median(r["decode_tps"] for r in results), 1),
        "aggregate_tps": round(total_tokens / total_wall, 1),
        "ttft_median_s": round(statistics.median(r["ttft"] for r in results), 2),
        "avg_tokens": round(total_tokens / len(results)),
    }


def main():
    # Warm-up request so CUDA graphs and caches are hot before measuring.
    one_request("Say hello in Go.", {"temperature": 0}, [])
    for name, sampling in (("greedy", {"temperature": 0}), ("sampled", {"temperature": 0.7, "top_p": 0.8})):
        for conc in (1, 3):
            print(json.dumps(scenario(name, sampling, conc)), flush=True)


if __name__ == "__main__":
    main()
