#!/usr/bin/env python3
"""Validate the archived Orin 30W Batch=1 FlashAttention result contract."""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
from pathlib import Path


DECODE_CONTEXTS = [
    1, 2, 3, 4, 7, 8, 15, 16, 17, 31, 32, 33, 63, 64, 65,
    127, 128, 129, 255, 256, 257, 512, 1024, 2048, 3072, 4096,
    5120, 6144, 7168, 8192,
]
PREFILL_CONTEXTS = [
    1, 16, 32, 63, 64, 65, 127, 128, 129, 255, 256, 257, 512,
    1024, 2048, 3072, 4096, 5120, 6144, 7168, 8192,
]
BENCHMARK_SHA256 = "323e438c50400cdc4d5204fb287b2e5cbdbdd97d54ea23bf4b2bd45eb1c070c1"
RUNNER_SHA256 = "1fbcc68517468270796bdd85a6f37e902b75e77ed4c0d2f62a7b0936fbae3471"


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"VALIDATION FAILED: {message}")


def numeric(value: str) -> float:
    parsed = float(value)
    require(math.isfinite(parsed), f"non-finite numeric field: {value!r}")
    return parsed


def validate_code_hash(path: Path | None, expected: str, label: str) -> None:
    if path is None:
        return
    require(path.is_file(), f"{label} does not exist: {path}")
    actual = sha256_file(path)
    require(actual == expected, f"{label} SHA-256 differs: {actual}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--csv", type=Path, required=True)
    parser.add_argument("--metadata", type=Path, required=True)
    parser.add_argument("--benchmark", type=Path)
    parser.add_argument("--runner", type=Path)
    args = parser.parse_args()

    validate_code_hash(args.benchmark, BENCHMARK_SHA256, "benchmark")
    validate_code_hash(args.runner, RUNNER_SHA256, "runner")
    require(args.csv.is_file(), f"CSV does not exist: {args.csv}")
    require(args.metadata.is_file(), f"metadata does not exist: {args.metadata}")

    with args.csv.open("r", newline="", encoding="utf-8") as handle:
        rows = list(csv.DictReader(handle))
    require(len(rows) == len(DECODE_CONTEXTS) + len(PREFILL_CONTEXTS),
            f"expected 51 CSV rows, found {len(rows)}")

    by_mode: dict[str, list[dict[str, str]]] = {"decode": [], "prefill": []}
    for row in rows:
        mode = row.get("mode")
        require(mode in by_mode, f"unexpected mode: {mode!r}")
        by_mode[mode].append(row)
        require(row["backend"] == "flash_attn_2", "backend is not flash_attn_2")
        require(row["platform"] == "orin_agx_gpu_30w_flashattention", "unexpected platform")
        require(int(row["batch"]) == 1, "Batch is not 1")
        require(row["input_dtype"] == "bfloat16", "input dtype is not bf16")
        require(row["output_dtype"] == "float32", "output dtype is not fp32")
        require(row["cache_mode"] == "streaming", "cache mode is not streaming")
        require(row["timing_scope"] == "device_resident_attention_only", "unexpected timing scope")
        require(row["power_limit_w"] == "30W_nvpmodel+jetson_clocks", "unexpected power label")
        require(int(row["violations"]) == 0, "precision violation found")
        require(int(row["nan_or_inf"]) == 0, "NaN/Inf found")
        require(numeric(row["token_s"]) > 0.0, "non-positive token/s")
        require(numeric(row["p50_ms"]) > 0.0, "non-positive p50 latency")

    decode_contexts = [int(row["context"]) for row in by_mode["decode"]]
    prefill_contexts = [int(row["context"]) for row in by_mode["prefill"]]
    require(decode_contexts == DECODE_CONTEXTS, "Decode context matrix differs")
    require(prefill_contexts == PREFILL_CONTEXTS, "Prefill context matrix differs")

    metadata = json.loads(args.metadata.read_text(encoding="utf-8"))
    arguments = metadata.get("arguments", {})
    require(metadata.get("torch") == "2.1.0a0+41361538.nv23.06", "unexpected PyTorch version")
    require(metadata.get("torch_cuda") == "11.4", "unexpected CUDA version")
    require(metadata.get("flash_attn") == "2.1.1", "unexpected FlashAttention version")
    require(metadata.get("cuda_device", {}).get("compute_capability") == "8.7", "unexpected GPU capability")
    require(arguments.get("batches") == [1], "metadata Batch is not 1")
    require(arguments.get("cuda_backend") == "flash_attn", "metadata backend is not flash_attn")
    require(arguments.get("output_modes") == "fp32", "metadata output mode is not fp32")
    require(arguments.get("streaming_bytes") == 67_108_864, "metadata streaming size differs")

    summary = {
        "rows": len(rows),
        "decode_rows": len(by_mode["decode"]),
        "prefill_rows": len(by_mode["prefill"]),
        "decode_8192_token_s": numeric(by_mode["decode"][-1]["token_s"]),
        "prefill_8192_token_s": numeric(by_mode["prefill"][-1]["token_s"]),
        "benchmark_sha256": BENCHMARK_SHA256,
        "runner_sha256": RUNNER_SHA256,
    }
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    print("PASS: Orin FlashAttention Batch=1 result contract verified")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
