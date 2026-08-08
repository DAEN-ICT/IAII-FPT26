#!/usr/bin/env python3
"""Benchmark Llama 3 8B single-layer GQA attention on CPU or CUDA.

The timed operator covers QK, scale, causal masking for prefill, softmax, PV,
and all 32 query heads. Input creation and host/device copies are outside the
timed window.
"""

from __future__ import annotations

import argparse
import contextlib
import csv
import json
import math
import os
import platform
import statistics
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable, Iterable

import torch
import torch.nn.functional as F
import numpy as np


Q_HEADS = 32
KV_HEADS = 8
HEAD_DIM = 128
INPUT_DTYPE = torch.bfloat16
SCALE = 1.0 / math.sqrt(HEAD_DIM)
QUERY_TILE = 256
DEFAULT_DECODE_CONTEXTS = [
    1, 2, 3, 4, 7, 8, 15, 16, 17, 31, 32, 33,
    64, 128, 256, 512, 1024, 2048, 4096, 8192,
]
DEFAULT_PREFILL_CONTEXTS = [1, 16, 32, 64, 128, 256, 512, 1024, 2048, 4096, 8192]
_FLASH_ATTN_FUNC = None
_SDPA_SUPPORTS_ENABLE_GQA = "enable_gqa" in (
    getattr(F.scaled_dot_product_attention, "__doc__", "") or ""
)


@dataclass
class InputPool:
    q: torch.Tensor
    k: torch.Tensor
    v: torch.Tensor
    q_ref: torch.Tensor
    k_ref: torch.Tensor
    v_ref: torch.Tensor
    slots: int
    working_set_bytes: int


def parse_int_list(raw: str) -> list[int]:
    values = [int(item.strip()) for item in raw.split(",") if item.strip()]
    if not values or any(value <= 0 for value in values):
        raise argparse.ArgumentTypeError("contexts must be positive comma-separated integers")
    return values


def parse_choices(raw: str, allowed: set[str]) -> list[str]:
    values = [item.strip() for item in raw.split(",") if item.strip()]
    if not values or any(item not in allowed for item in values):
        raise argparse.ArgumentTypeError(f"expected comma-separated values from {sorted(allowed)}")
    return values


def percentile(samples: list[float], fraction: float) -> float:
    ordered = sorted(samples)
    index = min(len(ordered) - 1, max(0, math.ceil(fraction * len(ordered)) - 1))
    return ordered[index]


def tensor_bytes(shape: Iterable[int], element_size: int = 2) -> int:
    count = 1
    for value in shape:
        count *= value
    return count * element_size


def make_input_pool(
    device: torch.device,
    mode: str,
    context: int,
    batch: int,
    cache_mode: str,
    streaming_bytes: int,
    max_stream_slots: int,
    seed: int,
) -> InputPool:
    query_tokens = 1 if mode == "decode" else context
    q_shape = (batch, Q_HEADS, query_tokens, HEAD_DIM)
    kv_shape = (batch, KV_HEADS, context, HEAD_DIM)
    one_case_bytes = tensor_bytes(q_shape) + 2 * tensor_bytes(kv_shape)
    slots = 1 if cache_mode == "resident" else max(
        2, min(max_stream_slots, math.ceil(streaming_bytes / one_case_bytes))
    )
    generator = torch.Generator(device="cpu").manual_seed(seed)
    q_cpu = torch.randn((slots,) + q_shape, generator=generator, dtype=INPUT_DTYPE)
    k_cpu = torch.randn((slots,) + kv_shape, generator=generator, dtype=INPUT_DTYPE)
    v_cpu = torch.randn((slots,) + kv_shape, generator=generator, dtype=INPUT_DTYPE)
    q_ref, k_ref, v_ref = q_cpu[0].clone(), k_cpu[0].clone(), v_cpu[0].clone()
    if device.type == "cuda":
        q, k, v = q_cpu.to(device), k_cpu.to(device), v_cpu.to(device)
        del q_cpu, k_cpu, v_cpu
    else:
        q, k, v = q_cpu, k_cpu, v_cpu
    return InputPool(q, k, v, q_ref, k_ref, v_ref, slots, slots * one_case_bytes)


def ensure_flash_attn() -> None:
    global _FLASH_ATTN_FUNC
    if _FLASH_ATTN_FUNC is None:
        from flash_attn import flash_attn_func
        _FLASH_ATTN_FUNC = flash_attn_func


def attention(
    q: torch.Tensor, k: torch.Tensor, v: torch.Tensor, mode: str, backend: str,
) -> torch.Tensor:
    if backend == "flash_attn":
        if _FLASH_ATTN_FUNC is None:
            raise RuntimeError("flash_attn backend was not initialized")
        output = _FLASH_ATTN_FUNC(
            q.transpose(1, 2), k.transpose(1, 2), v.transpose(1, 2),
            dropout_p=0.0, softmax_scale=SCALE, causal=(mode == "prefill"),
        )
        return output.transpose(1, 2)
    if backend == "tiled_math":
        # Exact, memory-bounded GQA for Jetson builds without fused SDPA.
        batch, _, query_tokens, _ = q.shape
        groups = Q_HEADS // KV_HEADS
        q_grouped = q.reshape(batch, KV_HEADS, groups, query_tokens, HEAD_DIM)
        k_t = k[:, :, None].transpose(-2, -1)
        v_grouped = v[:, :, None]
        if mode == "decode":
            scores = torch.matmul(q_grouped, k_t) * SCALE
            return torch.matmul(torch.softmax(scores, dim=-1), v_grouped).reshape(
                batch, Q_HEADS, query_tokens, HEAD_DIM
            )
        outputs = []
        key_pos = torch.arange(k.shape[-2], device=q.device)[None, :]
        for start in range(0, query_tokens, QUERY_TILE):
            end = min(query_tokens, start + QUERY_TILE)
            scores = torch.matmul(q_grouped[..., start:end, :], k_t) * SCALE
            query_pos = torch.arange(start, end, device=q.device)[:, None]
            scores.masked_fill_(key_pos > query_pos, float("-inf"))
            outputs.append(torch.matmul(torch.softmax(scores, dim=-1), v_grouped))
        return torch.cat(outputs, dim=-2).reshape(
            batch, Q_HEADS, query_tokens, HEAD_DIM
        )
    if _SDPA_SUPPORTS_ENABLE_GQA:
        return F.scaled_dot_product_attention(
            q, k, v, dropout_p=0.0, is_causal=(mode == "prefill"),
            scale=SCALE, enable_gqa=True,
        )
    # JetPack 5 / NVIDIA PyTorch 2.1 exposes fused SDPA but predates the
    # public enable_gqa argument. Materialize the four-to-one GQA mapping so
    # that the same operator can still be measured on Jetson AGX Orin.
    groups = Q_HEADS // KV_HEADS
    k_expanded = k.repeat_interleave(groups, dim=1)
    v_expanded = v.repeat_interleave(groups, dim=1)
    return F.scaled_dot_product_attention(
        q, k_expanded, v_expanded, dropout_p=0.0,
        is_causal=(mode == "prefill"),
    )


def run_one(
    pool: InputPool, slot: int, mode: str, output_mode: str, backend: str,
) -> torch.Tensor:
    value = attention(pool.q[slot], pool.k[slot], pool.v[slot], mode, backend)
    return value.float() if output_mode == "fp32" else value


def cuda_backend_context(backend: str):
    if backend in {"flash_attn", "tiled_math"}:
        return contextlib.nullcontext()
    try:
        from torch.nn.attention import SDPBackend, sdpa_kernel
    except ImportError:
        return torch.backends.cuda.sdp_kernel(
            enable_flash=False,
            enable_math=(backend == "math"),
            # JetPack 5's NVIDIA PyTorch build does not ship the flash SDPA
            # kernel, but it does expose the fused memory-efficient kernel.
            enable_mem_efficient=(backend == "flash"),
        )
    return sdpa_kernel({"flash": SDPBackend.FLASH_ATTENTION, "math": SDPBackend.MATH}[backend])


def measure_cuda_once(fn: Callable[[], torch.Tensor]) -> tuple[float, torch.Tensor]:
    begin = torch.cuda.Event(enable_timing=True)
    end = torch.cuda.Event(enable_timing=True)
    begin.record()
    output = fn()
    end.record()
    end.synchronize()
    return float(begin.elapsed_time(end)), output


def measure_cpu_once(fn: Callable[[], torch.Tensor]) -> tuple[float, torch.Tensor]:
    begin = time.perf_counter_ns()
    output = fn()
    return (time.perf_counter_ns() - begin) / 1.0e6, output


def selected_fp32_reference(
    q: torch.Tensor, k: torch.Tensor, v: torch.Tensor, mode: str, context: int,
    batch: int,
) -> tuple[list[int], torch.Tensor]:
    indices = [0] if mode == "decode" else sorted({0, context // 2, context - 1})
    q_grouped = q.float().numpy().reshape(
        batch, KV_HEADS, Q_HEADS // KV_HEADS, -1, HEAD_DIM
    )
    q_selected = q_grouped[..., indices, :]
    k_float, v_float = k.float().numpy(), v.float().numpy()
    # NumPy is intentionally used for the independent sampled Golden path.
    # JetPack 5/aarch64 showed rare non-finite results in otherwise finite
    # large PyTorch CPU matmul/einsum calls, even with one CPU thread.
    scores = np.einsum(
        "bhgqd,bhkd->bhgqk", q_selected, k_float, optimize=True
    ) * SCALE
    if mode == "prefill":
        queries = np.asarray(indices).reshape(1, 1, 1, -1, 1)
        keys = np.arange(context).reshape(1, 1, 1, 1, -1)
        scores = np.where(keys > queries, -np.inf, scores)
    shifted = scores - np.max(scores, axis=-1, keepdims=True)
    weights = np.exp(shifted)
    weights /= np.sum(weights, axis=-1, keepdims=True)
    output = np.einsum(
        "bhgqk,bhkd->bhgqd", weights, v_float, optimize=True
    )
    return indices, torch.from_numpy(
        output.reshape(batch, Q_HEADS, len(indices), HEAD_DIM)
    )


def correctness_metrics(
    output: torch.Tensor, pool: InputPool, mode: str, context: int, batch: int,
    atol: float, rtol: float,
) -> dict[str, float | int]:
    # NVIDIA's JetPack 5 CPU softmax can produce rare nondeterministic NaNs
    # for the large sampled Golden tensor when many ARM threads are active.
    # Golden generation is outside the timed region, so force one CPU thread.
    previous_threads = torch.get_num_threads()
    torch.set_num_threads(1)
    try:
        indices, reference = selected_fp32_reference(
            pool.q_ref, pool.k_ref, pool.v_ref, mode, context, batch
        )
    finally:
        torch.set_num_threads(previous_threads)
    selected = output.detach().cpu().float()[:, :, indices, :]
    error = (selected - reference).abs()
    threshold = atol + rtol * reference.abs()
    reference_nonfinite = int((~torch.isfinite(reference)).sum())
    selected_nonfinite = int((~torch.isfinite(selected)).sum())
    return {
        "checked_elements": int(error.numel()),
        "max_abs_error": float(error.max()),
        "mae": float(error.mean()),
        "violations": int((error > threshold).sum()) + reference_nonfinite + selected_nonfinite,
        "nan_or_inf": selected_nonfinite,
        "reference_nan_or_inf": reference_nonfinite,
    }


def useful_metrics(
    mode: str, context: int, batch: int, output_bytes: int, p50_ms: float
):
    if mode == "decode":
        query_tokens = 1
        macs = batch * 8192 * context
        logical_bytes = batch * (
            8192 + 4096 * context + Q_HEADS * HEAD_DIM * output_bytes
        )
    else:
        query_tokens = context
        macs = batch * 4096 * context * (context + 1)
        logical_bytes = batch * (
            Q_HEADS * context * HEAD_DIM * 2
            + 2 * KV_HEADS * context * HEAD_DIM * 2
            + Q_HEADS * context * HEAD_DIM * output_bytes
        )
    total_tokens = batch * query_tokens
    return (
        query_tokens,
        total_tokens,
        macs / (p50_ms * 1.0e6),
        logical_bytes / (p50_ms * 1.0e6),
        total_tokens * 1000.0 / p50_ms,
        batch * 1000.0 / p50_ms,
    )


def write_event(handle, event: str, **payload: object) -> None:
    if handle is None:
        return
    record = {
        "event": event,
        "time_ns": time.time_ns(),
        "monotonic_ns": time.perf_counter_ns(),
        **payload,
    }
    handle.write(json.dumps(record, ensure_ascii=False) + "\n")
    handle.flush()


def environment_metadata(args: argparse.Namespace, device: torch.device) -> dict[str, object]:
    metadata: dict[str, object] = {
        "timestamp_utc": datetime.now(timezone.utc).isoformat(),
        "hostname": platform.node(), "platform": platform.platform(),
        "python": platform.python_version(), "torch": torch.__version__,
        "torch_cuda": torch.version.cuda, "cudnn": torch.backends.cudnn.version(),
        "device_type": device.type, "cpu_count": os.cpu_count(),
        "torch_num_threads": torch.get_num_threads(),
        "torch_num_interop_threads": torch.get_num_interop_threads(),
        "arguments": vars(args),
    }
    if device.type == "cuda":
        prop = torch.cuda.get_device_properties(0)
        metadata["cuda_device"] = {
            "name": prop.name, "compute_capability": f"{prop.major}.{prop.minor}",
            "total_memory_bytes": prop.total_memory,
            "multiprocessors": prop.multi_processor_count,
        }
        if args.cuda_backend == "flash_attn":
            import flash_attn
            metadata["flash_attn"] = flash_attn.__version__
    return metadata


def benchmark_case(
    args: argparse.Namespace, device: torch.device, mode: str, context: int,
    batch: int, cache_mode: str, output_mode: str, event_handle=None,
) -> dict[str, object]:
    if device.type == "cuda" and args.cuda_backend == "flash_attn":
        ensure_flash_attn()
    pool = make_input_pool(
        device, mode, context, batch, cache_mode, args.streaming_bytes,
        args.max_stream_slots,
        args.seed + context + batch * 1_000_000 + (0 if mode == "decode" else 100_000),
    )
    measure_once = measure_cuda_once if device.type == "cuda" else measure_cpu_once
    operator_backend = args.cuda_backend if device.type == "cuda" else "torch_sdpa"
    backend = "flash_attn_2" if operator_backend == "flash_attn" else (
        "cuda_tiled_math_gqa" if operator_backend == "tiled_math" else (
        (
            "pytorch_fused_sdpa_kv_expand"
            if device.type == "cuda" and not _SDPA_SUPPORTS_ENABLE_GQA
            else args.cuda_backend
        ) if device.type == "cuda" else "pytorch_math_gqa"
        )
    )
    backend_context = cuda_backend_context(args.cuda_backend) if device.type == "cuda" else contextlib.nullcontext()

    with torch.inference_mode(), backend_context:
        output = run_one(pool, 0, mode, output_mode, operator_backend)
        if device.type == "cuda":
            torch.cuda.synchronize()
        pilot_ms, output = measure_once(
            lambda: run_one(pool, 0, mode, output_mode, operator_backend)
        )
        warmup_limit = args.cuda_warmup if device.type == "cuda" else args.cpu_warmup
        warmup = max(1, min(warmup_limit, int(args.warmup_budget_ms / max(pilot_ms, 1.0e-6))))
        for index in range(warmup):
            output = run_one(
                pool, index % pool.slots, mode, output_mode, operator_backend
            )
        if device.type == "cuda":
            torch.cuda.synchronize()
        repeat_limit = args.decode_repeats if mode == "decode" else args.prefill_repeats
        repeats = max(args.min_repeats, min(repeat_limit, int(args.case_budget_ms / max(pilot_ms, 1.0e-6))))
        samples = []
        case_id = f"{mode}_b{batch}_c{context}_{cache_mode}_{output_mode}_{backend}"
        write_event(
            event_handle,
            "measurement_start",
            case_id=case_id,
            mode=mode,
            batch=batch,
            context=context,
            cache_mode=cache_mode,
            output_mode=output_mode,
            backend=backend,
            repeats=repeats,
        )
        for index in range(repeats):
            elapsed_ms, output = measure_once(
                lambda slot=index % pool.slots: run_one(
                    pool, slot, mode, output_mode, operator_backend
                )
            )
            samples.append(elapsed_ms)
        if device.type == "cuda":
            torch.cuda.synchronize()
        write_event(
            event_handle,
            "measurement_end",
            case_id=case_id,
            mode=mode,
            batch=batch,
            context=context,
            repeats=repeats,
        )
        output = run_one(pool, 0, mode, output_mode, operator_backend)
        if device.type == "cuda":
            torch.cuda.synchronize()

    p50_ms = statistics.median(samples)
    query_tokens, total_query_tokens, useful_gmac_s, logical_gb_s, token_s, sequences_s = useful_metrics(
        mode, context, batch, output.element_size(), p50_ms
    )
    checks = correctness_metrics(
        output, pool, mode, context, batch, args.atol, args.rtol
    )
    row: dict[str, object] = {
        "date": datetime.now().astimezone().isoformat(),
        "platform": args.platform_name or ("cuda_gpu" if device.type == "cuda" else "cpu"),
        "device": torch.cuda.get_device_name(0) if device.type == "cuda" else platform.machine(),
        "software": f"torch-{torch.__version__}", "backend": backend, "mode": mode,
        "batch": batch, "context": context, "query_tokens": query_tokens,
        "total_query_tokens": total_query_tokens,
        "hidden_size": Q_HEADS * HEAD_DIM, "q_heads": Q_HEADS, "kv_heads": KV_HEADS,
        "head_dim": HEAD_DIM, "input_dtype": "bfloat16",
        "accum_dtype": "backend-dependent",
        "output_dtype": str(output.dtype).replace("torch.", ""),
        "timing_scope": "device_resident_attention_only", "cache_mode": cache_mode,
        "stream_slots": pool.slots, "stream_working_set_bytes": pool.working_set_bytes,
        "warmup": warmup, "repeats": repeats, "pilot_ms": pilot_ms,
        "min_ms": min(samples), "p50_ms": p50_ms,
        "p90_ms": percentile(samples, 0.90), "p99_ms": percentile(samples, 0.99),
        "max_ms": max(samples), "token_s": token_s,
        "per_sequence_token_s": token_s / batch,
        "sequences_s": sequences_s,
        "useful_gmac_s": useful_gmac_s, "logical_gb_s": logical_gb_s,
        **checks, "atol": args.atol, "rtol": args.rtol,
        "power_limit_w": args.power_limit_w, "notes": args.notes,
    }
    del pool, output
    if device.type == "cuda":
        torch.cuda.empty_cache()
    return row


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", choices=["cpu", "cuda"], required=True)
    parser.add_argument("--batches", type=parse_int_list, default=[1])
    parser.add_argument("--modes", default="decode,prefill")
    parser.add_argument("--decode-contexts", type=parse_int_list, default=DEFAULT_DECODE_CONTEXTS)
    parser.add_argument("--prefill-contexts", type=parse_int_list, default=DEFAULT_PREFILL_CONTEXTS)
    parser.add_argument("--cache-modes", default="resident")
    parser.add_argument("--output-modes", default="native")
    parser.add_argument(
        "--cuda-backend", choices=["flash", "math", "flash_attn", "tiled_math"],
        default="flash",
    )
    parser.add_argument("--cpu-threads", type=int, default=14)
    parser.add_argument("--cpu-interop-threads", type=int, default=1)
    parser.add_argument("--cuda-warmup", type=int, default=30)
    parser.add_argument("--cpu-warmup", type=int, default=5)
    parser.add_argument("--warmup-budget-ms", type=float, default=500.0)
    parser.add_argument("--case-budget-ms", type=float, default=2000.0)
    parser.add_argument("--decode-repeats", type=int, default=100)
    parser.add_argument("--prefill-repeats", type=int, default=50)
    parser.add_argument("--min-repeats", type=int, default=5)
    parser.add_argument("--streaming-bytes", type=int, default=256 * 1024 * 1024)
    parser.add_argument("--max-stream-slots", type=int, default=8192)
    parser.add_argument("--seed", type=int, default=20260730)
    parser.add_argument("--atol", type=float, default=0.02)
    parser.add_argument("--rtol", type=float, default=0.02)
    parser.add_argument("--power-limit-w", default="120W_nvpmodel")
    parser.add_argument(
        "--platform-name",
        default="",
        help="CSV platform label, for example thor_gpu or rtx3090_gpu",
    )
    parser.add_argument("--notes", default="")
    parser.add_argument("--csv", type=Path, required=True)
    parser.add_argument("--metadata-json", type=Path, required=True)
    parser.add_argument(
        "--case-events-jsonl",
        type=Path,
        help="Optional host-timestamped measurement start/end events for power alignment",
    )
    return parser


def main() -> int:
    args = build_parser().parse_args()
    modes = parse_choices(args.modes, {"decode", "prefill"})
    cache_modes = parse_choices(args.cache_modes, {"resident", "streaming"})
    output_modes = parse_choices(args.output_modes, {"native", "fp32"})
    if args.device == "cuda" and not torch.cuda.is_available():
        raise SystemExit("CUDA requested but torch.cuda.is_available() is false")
    device = torch.device(args.device)
    torch.set_num_threads(args.cpu_threads)
    torch.set_num_interop_threads(args.cpu_interop_threads)
    args.csv.parent.mkdir(parents=True, exist_ok=True)
    args.metadata_json.parent.mkdir(parents=True, exist_ok=True)
    if args.case_events_jsonl:
        args.case_events_jsonl.parent.mkdir(parents=True, exist_ok=True)
    metadata = environment_metadata(args, device)
    metadata["arguments"] = {key: str(value) if isinstance(value, Path) else value for key, value in vars(args).items()}
    args.metadata_json.write_text(json.dumps(metadata, indent=2, ensure_ascii=False), encoding="utf-8")

    rows: list[dict[str, object]] = []
    event_context = (
        args.case_events_jsonl.open("w", encoding="utf-8")
        if args.case_events_jsonl else contextlib.nullcontext(None)
    )
    with event_context as event_handle:
        for mode in modes:
            contexts = args.decode_contexts if mode == "decode" else args.prefill_contexts
            for batch in args.batches:
                for cache_mode in cache_modes:
                    for output_mode in output_modes:
                        for context in contexts:
                            write_event(
                                event_handle,
                                "case_start",
                                mode=mode,
                                batch=batch,
                                context=context,
                                cache_mode=cache_mode,
                                output_mode=output_mode,
                            )
                            row = benchmark_case(
                                args, device, mode, context, batch, cache_mode,
                                output_mode, event_handle,
                            )
                            rows.append(row)
                            # Persist after every case so an OOM or remote
                            # interruption does not discard completed results.
                            with args.csv.open("w", newline="", encoding="utf-8") as handle:
                                writer = csv.DictWriter(handle, fieldnames=list(rows[0]))
                                writer.writeheader()
                                writer.writerows(rows)
                            write_event(
                                event_handle,
                                "case_end",
                                mode=mode,
                                batch=batch,
                                context=context,
                                token_s=row["token_s"],
                                p50_ms=row["p50_ms"],
                            )
                            print(json.dumps(row, ensure_ascii=False), flush=True)
    with args.csv.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)
    print(f"PASS: wrote {len(rows)} rows to {args.csv}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
