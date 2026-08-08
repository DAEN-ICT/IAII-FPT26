#!/usr/bin/env python3
"""Measure eager, CUDA Graph, device-event, and host-dispatch attention latency.

This is a supplementary launch-overhead experiment. It intentionally uses a
resident input tensor so CUDA Graph replay has stable addresses. The primary
cross-platform result remains benchmark_gqa_attention.py with a rotating
working set.
"""

from __future__ import annotations

import argparse
import csv
import json
import math
import statistics
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable

import torch

import benchmark_gqa_attention as base


def percentile(samples: list[float], fraction: float) -> float:
    ordered = sorted(samples)
    index = min(len(ordered) - 1, max(0, math.ceil(fraction * len(ordered)) - 1))
    return ordered[index]


def event_samples(
    fn: Callable[[], torch.Tensor], repeats: int, inner_iterations: int
) -> tuple[list[float], torch.Tensor]:
    samples = []
    output = fn()
    for _ in range(repeats):
        begin = torch.cuda.Event(enable_timing=True)
        end = torch.cuda.Event(enable_timing=True)
        begin.record()
        for _ in range(inner_iterations):
            output = fn()
        end.record()
        end.synchronize()
        samples.append(float(begin.elapsed_time(end)) / inner_iterations)
    return samples, output


def host_samples(
    fn: Callable[[], torch.Tensor], repeats: int
) -> tuple[list[float], torch.Tensor]:
    samples = []
    output = fn()
    for _ in range(repeats):
        begin = time.perf_counter_ns()
        output = fn()
        torch.cuda.synchronize()
        samples.append((time.perf_counter_ns() - begin) / 1.0e6)
    return samples, output


def summarize(
    mode: str,
    context: int,
    batch: int,
    execution: str,
    timing_scope: str,
    samples: list[float],
    inner_iterations: int,
    output: torch.Tensor,
    pool: base.InputPool,
    atol: float,
    rtol: float,
) -> dict[str, object]:
    p50_ms = statistics.median(samples)
    query_tokens = 1 if mode == "decode" else context
    tokens = batch * query_tokens
    checks = base.correctness_metrics(
        output, pool, mode, context, batch, atol, rtol
    )
    return {
        "date": datetime.now().astimezone().isoformat(),
        "platform": "rtx3090_gpu",
        "device": torch.cuda.get_device_name(0),
        "mode": mode,
        "batch": batch,
        "context": context,
        "query_tokens": query_tokens,
        "total_query_tokens": tokens,
        "execution": execution,
        "timing_scope": timing_scope,
        "cache_mode": "resident",
        "backend": "flash",
        "output_dtype": str(output.dtype).replace("torch.", ""),
        "inner_iterations": inner_iterations,
        "repeats": len(samples),
        "min_ms": min(samples),
        "p50_ms": p50_ms,
        "p90_ms": percentile(samples, 0.90),
        "p99_ms": percentile(samples, 0.99),
        "max_ms": max(samples),
        "token_s": tokens * 1000.0 / p50_ms,
        "per_sequence_token_s": tokens * 1000.0 / p50_ms / batch,
        "sequences_s": batch * 1000.0 / p50_ms,
        **checks,
        "atol": atol,
        "rtol": rtol,
    }


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--modes", default="decode,prefill")
    parser.add_argument("--batches", type=base.parse_int_list, default=[1])
    parser.add_argument("--decode-contexts", type=base.parse_int_list, default=[1, 128, 1024, 8192])
    parser.add_argument("--prefill-contexts", type=base.parse_int_list, default=[128, 1024, 4096, 8192])
    parser.add_argument("--output-mode", choices=["native", "fp32"], default="fp32")
    parser.add_argument("--warmup", type=int, default=20)
    parser.add_argument("--repeats", type=int, default=30)
    parser.add_argument("--target-event-window-ms", type=float, default=25.0)
    parser.add_argument("--max-inner-iterations", type=int, default=1000)
    parser.add_argument("--atol", type=float, default=0.02)
    parser.add_argument("--rtol", type=float, default=0.02)
    parser.add_argument("--csv", type=Path, required=True)
    parser.add_argument("--metadata-json", type=Path, required=True)
    return parser


def main() -> int:
    args = build_parser().parse_args()
    if not torch.cuda.is_available():
        raise SystemExit("CUDA is unavailable")
    modes = base.parse_choices(args.modes, {"decode", "prefill"})
    args.csv.parent.mkdir(parents=True, exist_ok=True)
    args.metadata_json.parent.mkdir(parents=True, exist_ok=True)
    device = torch.device("cuda")
    rows: list[dict[str, object]] = []

    metadata = {
        "created_utc": datetime.now(timezone.utc).isoformat(),
        "torch": torch.__version__,
        "torch_cuda": torch.version.cuda,
        "device": torch.cuda.get_device_name(0),
        "compute_capability": ".".join(map(str, torch.cuda.get_device_capability(0))),
        "arguments": {key: str(value) if isinstance(value, Path) else value for key, value in vars(args).items()},
        "note": "Supplementary resident-input launch overhead experiment; not the rotating primary result.",
    }
    args.metadata_json.write_text(json.dumps(metadata, indent=2), encoding="utf-8")

    for mode in modes:
        contexts = args.decode_contexts if mode == "decode" else args.prefill_contexts
        for batch in args.batches:
            for context in contexts:
                print(f"running {mode} batch={batch} context={context}", flush=True)
                pool = base.make_input_pool(
                    device=device,
                    mode=mode,
                    context=context,
                    batch=batch,
                    cache_mode="resident",
                    streaming_bytes=1,
                    max_stream_slots=1,
                    seed=(
                        20260730 + context + batch * 1_000_000
                        + (0 if mode == "decode" else 100_000)
                    ),
                )
                backend = base.cuda_backend_context("flash")
                with torch.inference_mode(), backend:
                    eager_fn = lambda: base.run_one(pool, 0, mode, args.output_mode)
                    for _ in range(args.warmup):
                        output = eager_fn()
                    torch.cuda.synchronize()

                    pilot_ms, output = base.measure_cuda_once(eager_fn)
                    inner = max(
                        1,
                        min(
                            args.max_inner_iterations,
                            int(args.target_event_window_ms / max(pilot_ms, 1.0e-6)),
                        ),
                    )
                    samples, output = event_samples(eager_fn, args.repeats, inner)
                    rows.append(
                        summarize(
                            mode, context, batch, "eager", "device_event_batched",
                            samples, inner, output, pool, args.atol, args.rtol,
                        )
                    )
                    samples, output = host_samples(eager_fn, args.repeats)
                    rows.append(
                        summarize(
                            mode, context, batch, "eager", "host_dispatch_sync",
                            samples, 1, output, pool, args.atol, args.rtol,
                        )
                    )

                    side_stream = torch.cuda.Stream()
                    side_stream.wait_stream(torch.cuda.current_stream())
                    with torch.cuda.stream(side_stream):
                        for _ in range(3):
                            graph_output = eager_fn()
                    torch.cuda.current_stream().wait_stream(side_stream)
                    torch.cuda.synchronize()
                    graph = torch.cuda.CUDAGraph()
                    with torch.cuda.graph(graph):
                        graph_output = eager_fn()
                    graph.replay()
                    torch.cuda.synchronize()
                    graph_fn = lambda: (graph.replay(), graph_output)[1]

                    samples, output = event_samples(graph_fn, args.repeats, inner)
                    rows.append(
                        summarize(
                            mode, context, batch, "cuda_graph", "device_event_batched",
                            samples, inner, output, pool, args.atol, args.rtol,
                        )
                    )
                    samples, output = host_samples(graph_fn, args.repeats)
                    rows.append(
                        summarize(
                            mode, context, batch, "cuda_graph", "host_dispatch_sync",
                            samples, 1, output, pool, args.atol, args.rtol,
                        )
                    )

                del pool, graph, graph_output, output
                torch.cuda.empty_cache()

    with args.csv.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0].keys()))
        writer.writeheader()
        writer.writerows(rows)
    print(f"wrote {len(rows)} rows to {args.csv}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
