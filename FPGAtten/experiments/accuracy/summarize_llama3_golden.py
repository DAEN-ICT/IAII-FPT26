#!/usr/bin/env python3
"""Verify exported Llama 3 attention Golden files and write a compact summary."""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
from pathlib import Path
from typing import Any

import numpy as np


def sha256_file(path: Path, block_bytes: int = 8 * 1024 * 1024) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while block := handle.read(block_bytes):
            digest.update(block)
    return digest.hexdigest()


def verify_numpy(path: Path, record: dict[str, Any]) -> list[str]:
    errors: list[str] = []
    if not path.exists():
        return [f"missing:{path}"]
    if path.stat().st_size != int(record["bytes"]):
        errors.append(f"size:{path}:{path.stat().st_size}!={record['bytes']}")
    digest = sha256_file(path)
    if digest != record["sha256"]:
        errors.append(f"sha256:{path}:{digest}!={record['sha256']}")
    array = np.load(path, mmap_mode="r", allow_pickle=False)
    if list(array.shape) != list(record["shape"]):
        errors.append(f"shape:{path}:{list(array.shape)}!={record['shape']}")
    if str(array.dtype) != record["storage_dtype"]:
        errors.append(f"dtype:{path}:{array.dtype}!={record['storage_dtype']}")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--output-csv", type=Path, required=True)
    parser.add_argument("--output-json", type=Path, required=True)
    args = parser.parse_args()

    manifests = sorted(args.root.glob("*_context_*/manifest.json"))
    if not manifests:
        raise SystemExit(f"no manifests under {args.root}")

    rows: list[dict[str, object]] = []
    errors: list[str] = []
    total_bytes = 0
    for manifest_path in manifests:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        case_dir = manifest_path.parent
        prompt_file = manifest["prompt"]["input_ids"]
        input_path = case_dir / prompt_file["file"]
        errors.extend(verify_numpy(input_path, prompt_file))
        total_bytes += input_path.stat().st_size if input_path.exists() else 0

        for layer in manifest["layers"]:
            layer_dir = case_dir / f"layer_{int(layer['layer']):02d}"
            layer_bytes = 0
            hashes: dict[str, str] = {}
            for name, record in layer["files"].items():
                path = layer_dir / record["file"]
                errors.extend(verify_numpy(path, record))
                if path.exists():
                    layer_bytes += path.stat().st_size
                hashes[f"{name}_sha256"] = record["sha256"]
            total_bytes += layer_bytes
            metrics = layer["thor_flash_vs_fp32_golden"]
            rows.append(
                {
                    "mode": manifest["mode"],
                    "context": int(manifest["context"]),
                    "layer": int(layer["layer"]),
                    "batch": int(manifest["batch"]),
                    "q_heads": int(manifest["q_heads"]),
                    "kv_heads": int(manifest["kv_heads"]),
                    "head_dim": int(manifest["head_dim"]),
                    "reference_backend": layer["thor_reference_backend"],
                    "elements": int(metrics["elements"]),
                    "max_abs_error": float(metrics["max_abs_error"]),
                    "mae": float(metrics["mae"]),
                    "rmse": float(metrics["rmse"]),
                    "mean_relative_error": float(metrics["mean_relative_error"]),
                    "max_relative_error": float(metrics["max_relative_error"]),
                    "cosine_similarity": float(metrics["cosine_similarity"]),
                    "nan_or_inf": int(metrics["nan_or_inf"]),
                    "violations_atol_0p02_rtol_0p002": int(
                        metrics["violations_atol_0p02_rtol_0p002"]
                    ),
                    "violations_atol_0p02_rtol_0p02": int(
                        metrics["violations_atol_0p02_rtol_0p02"]
                    ),
                    "case_forward_seconds": float(
                        manifest["timing"]["model_forward_seconds"]
                    ),
                    "layer_export_seconds": float(layer["export_seconds"]),
                    "layer_file_bytes": layer_bytes,
                    **hashes,
                }
            )

    args.output_csv.parent.mkdir(parents=True, exist_ok=True)
    args.output_json.parent.mkdir(parents=True, exist_ok=True)
    with args.output_csv.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)

    summary = {
        "schema": "gqav7_llama3_attention_golden_summary_v1",
        "root": str(args.root.resolve()),
        "cases": len(manifests),
        "layer_records": len(rows),
        "total_verified_bytes": total_bytes,
        "max_abs_error": max(float(row["max_abs_error"]) for row in rows),
        "max_mae": max(float(row["mae"]) for row in rows),
        "max_rmse": max(float(row["rmse"]) for row in rows),
        "min_cosine_similarity": min(float(row["cosine_similarity"]) for row in rows),
        "nan_or_inf": sum(int(row["nan_or_inf"]) for row in rows),
        "violations_atol_0p02_rtol_0p002": sum(
            int(row["violations_atol_0p02_rtol_0p002"]) for row in rows
        ),
        "violations_atol_0p02_rtol_0p02": sum(
            int(row["violations_atol_0p02_rtol_0p02"]) for row in rows
        ),
        "verification_errors": errors,
    }
    args.output_json.write_text(
        json.dumps(summary, indent=2, ensure_ascii=False), encoding="utf-8"
    )
    print(json.dumps(summary, indent=2, ensure_ascii=False))
    if errors:
        raise SystemExit(f"verification failed with {len(errors)} errors")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
