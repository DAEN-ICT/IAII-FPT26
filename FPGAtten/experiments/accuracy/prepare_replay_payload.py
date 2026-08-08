#!/usr/bin/env python3
"""Convert a verified Thor Llama3 Attention Golden case into FPGA raw payloads.

The Thor exporter stores NumPy containers.  The FPGA board application should
not parse NumPy headers or re-encode BF16 values, so this tool writes raw
little-endian payloads while preserving the exact uint16 BF16 bit patterns.
The generated ``replay_manifest.json`` is an auditable bridge between the
source Golden manifest and the board inputs.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
from typing import Any

import numpy as np


Q_HEADS = 32
KV_HEADS = 8
HEAD_DIM = 128


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while block := handle.read(8 * 1024 * 1024):
            digest.update(block)
    return digest.hexdigest()


def load_manifest(case_dir: Path) -> dict[str, Any]:
    path = case_dir / "manifest.json"
    return json.loads(path.read_text(encoding="utf-8"))


def require_record(layer_record: dict[str, Any], name: str) -> dict[str, Any]:
    try:
        return layer_record["files"][name]
    except KeyError as error:
        raise ValueError(f"layer does not contain required file record: {name}") from error


def verify_source(case_dir: Path, layer_dir: Path, record: dict[str, Any]) -> Path:
    path = layer_dir / record["file"]
    if not path.is_file():
        raise FileNotFoundError(path)
    if path.stat().st_size != int(record["bytes"]):
        raise ValueError(f"source file size mismatch: {path}")
    actual_hash = sha256_file(path)
    if actual_hash != record["sha256"]:
        raise ValueError(f"source SHA-256 mismatch: {path}")
    return path


def verify_array(path: Path, record: dict[str, Any], dtype: np.dtype, shape: tuple[int, ...]) -> np.ndarray:
    array = np.load(path, mmap_mode="r", allow_pickle=False)
    if array.dtype != dtype:
        raise ValueError(f"unexpected dtype {array.dtype} in {path}; expected {dtype}")
    if tuple(array.shape) != shape:
        raise ValueError(f"unexpected shape {array.shape} in {path}; expected {shape}")
    if list(array.shape) != list(record["shape"]):
        raise ValueError(f"manifest shape mismatch for {path}")
    return array


def write_payload(path: Path, array: np.ndarray, dtype: np.dtype) -> dict[str, object]:
    normalized = np.asarray(array, dtype=dtype, order="C")
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("wb") as handle:
        handle.write(normalized.tobytes(order="C"))
    return {
        "file": path.name,
        "bytes": path.stat().st_size,
        "sha256": sha256_file(path),
        "storage_dtype": str(normalized.dtype),
        "shape": list(normalized.shape),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--case-dir", type=Path, required=True)
    parser.add_argument("--layer", type=int, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()

    case_dir = args.case_dir.resolve()
    manifest = load_manifest(case_dir)
    mode = manifest["mode"]
    context = int(manifest["context"])
    if mode not in {"decode", "prefill"}:
        raise ValueError(f"unsupported mode: {mode}")
    if (int(manifest["q_heads"]), int(manifest["kv_heads"]), int(manifest["head_dim"])) != (
        Q_HEADS,
        KV_HEADS,
        HEAD_DIM,
    ):
        raise ValueError("model geometry does not match the GQAv7 Llama3-8B contract")
    layer_record = next(
        (item for item in manifest["layers"] if int(item["layer"]) == args.layer), None
    )
    if layer_record is None:
        raise ValueError(f"layer {args.layer} is not present in {case_dir / 'manifest.json'}")
    layer_dir = case_dir / f"layer_{args.layer:02d}"
    query_tokens = 1 if mode == "decode" else context
    expected = {
        "q": ((1, Q_HEADS, query_tokens, HEAD_DIM), np.dtype("<u2")),
        "k": ((1, KV_HEADS, context, HEAD_DIM), np.dtype("<u2")),
        "v": ((1, KV_HEADS, context, HEAD_DIM), np.dtype("<u2")),
        "golden_output": ((1, Q_HEADS, query_tokens, HEAD_DIM), np.dtype("<f4")),
    }
    arrays: dict[str, np.ndarray] = {}
    source_records: dict[str, dict[str, Any]] = {}
    for name, (shape, dtype) in expected.items():
        record = require_record(layer_record, name)
        source_path = verify_source(case_dir, layer_dir, record)
        arrays[name] = verify_array(source_path, record, dtype, shape)
        source_records[name] = {
            "file": record["file"],
            "bytes": int(record["bytes"]),
            "sha256": record["sha256"],
            "shape": list(record["shape"]),
            "storage_dtype": record["storage_dtype"],
        }

    output_dir = args.output_dir.resolve()
    payloads = {
        "q": write_payload(output_dir / "q_bf16_le.bin", arrays["q"], np.dtype("<u2")),
        "k": write_payload(output_dir / "k_bf16_le.bin", arrays["k"], np.dtype("<u2")),
        "v": write_payload(output_dir / "v_bf16_le.bin", arrays["v"], np.dtype("<u2")),
        "golden_output": write_payload(
            output_dir / "o_fp32_golden_le.bin", arrays["golden_output"], np.dtype("<f4")
        ),
    }
    replay_manifest = {
        "schema": "gqav7_llama3_fpga_replay_payload_v1",
        "source_case": str(case_dir),
        "source_manifest_sha256": sha256_file(case_dir / "manifest.json"),
        "mode": mode,
        "context": context,
        "batch": 1,
        "layer": args.layer,
        "q_heads": Q_HEADS,
        "kv_heads": KV_HEADS,
        "head_dim": HEAD_DIM,
        "accelerator_boundary": manifest["accelerator_boundary"],
        "decode_semantics": manifest.get("decode_semantics"),
        "source_files": source_records,
        "payloads": payloads,
    }
    (output_dir / "replay_manifest.json").write_text(
        json.dumps(replay_manifest, indent=2, ensure_ascii=False), encoding="utf-8"
    )
    print(json.dumps(replay_manifest, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
