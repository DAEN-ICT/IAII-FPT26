#!/usr/bin/env python3
"""Prepare verified real-Llama3 Decode K/V payloads for JTAG PL-DDR preload.

This host-only tool never opens JTAG, COM ports, or a network connection.  It
checks the K/V records in an existing FPGA replay manifest, then preserves the
raw BF16 byte order while splitting each K/V tensor into the eight physical
PL-DDR head apertures used by the GQAv7 data layout.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path
from typing import Any


SCHEMA = "gqav7_llama3_jtag_kv_preload_v1"
REPLAY_SCHEMA = "gqav7_llama3_fpga_replay_payload_v1"
KV_HEADS = 8
HEAD_DIM = 128
BYTES_PER_TOKEN_PER_HEAD = HEAD_DIM * 2  # BF16 = 2 bytes
K_BASE = 0xB4000000
V_BASE = 0xB5000000
HEAD_STRIDE = 0x00200000


def sha256_file(path: Path) -> str:
    """Return the lowercase SHA-256 digest for ``path`` without loading it all."""

    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while block := handle.read(8 * 1024 * 1024):
            digest.update(block)
    return digest.hexdigest()


def read_json(path: Path) -> dict[str, Any]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as error:
        raise ValueError(f"invalid JSON: {path}: {error}") from error
    if not isinstance(data, dict):
        raise ValueError(f"JSON root must be an object: {path}")
    return data


def require_mapping_value(mapping: dict[str, Any], key: str) -> Any:
    value = mapping.get(key)
    if value is None:
        raise ValueError(f"manifest is missing required field: {key}")
    return value


def safe_payload_path(payload_dir: Path, filename: Any) -> Path:
    if not isinstance(filename, str) or not filename:
        raise ValueError("K/V manifest file name must be a non-empty string")
    if Path(filename).name != filename:
        raise ValueError(f"K/V manifest file name must be a plain file name: {filename}")
    path = (payload_dir / filename).resolve()
    if path.parent != payload_dir:
        raise ValueError(f"K/V payload must remain in payload directory: {filename}")
    return path


def validate_kv_payload(
    payload_dir: Path,
    payloads: dict[str, Any],
    kind: str,
    expected_bytes: int,
) -> tuple[Path, dict[str, Any]]:
    entry = payloads.get(kind)
    if not isinstance(entry, dict):
        raise ValueError(f"replay manifest is missing payload record: {kind}")
    path = safe_payload_path(payload_dir, require_mapping_value(entry, "file"))
    if not path.is_file():
        raise FileNotFoundError(f"K/V payload does not exist: {path}")
    declared_bytes = int(require_mapping_value(entry, "bytes"))
    if declared_bytes != expected_bytes:
        raise ValueError(
            f"unexpected {kind} byte count in replay manifest: "
            f"expected {expected_bytes}, got {declared_bytes}"
        )
    actual_bytes = path.stat().st_size
    if actual_bytes != expected_bytes:
        raise ValueError(
            f"{kind} payload byte count mismatch: expected {expected_bytes}, got {actual_bytes}"
        )
    expected_hash = str(require_mapping_value(entry, "sha256")).lower()
    actual_hash = sha256_file(path)
    if actual_hash != expected_hash:
        raise ValueError(
            f"SHA-256 mismatch for {path.name}: expected {expected_hash}, got {actual_hash}"
        )
    return path, {
        "file": path.name,
        "bytes": actual_bytes,
        "sha256": actual_hash,
    }


def write_segment(source: Path, destination: Path, offset: int, size: int) -> dict[str, Any]:
    with source.open("rb") as reader:
        reader.seek(offset)
        content = reader.read(size)
    if len(content) != size:
        raise ValueError(f"short read while splitting {source}")
    destination.write_bytes(content)
    return {
        "file": destination.name,
        "bytes": destination.stat().st_size,
        "sha256": sha256_file(destination),
    }


def prepare(payload_dir: Path, output_dir: Path) -> dict[str, Any]:
    """Validate one Decode replay payload and write its 16 K/V head segments."""

    payload_dir = payload_dir.resolve()
    manifest_path = payload_dir / "replay_manifest.json"
    if not manifest_path.is_file():
        raise FileNotFoundError(f"replay manifest does not exist: {manifest_path}")
    replay_manifest = read_json(manifest_path)
    if replay_manifest.get("schema") != REPLAY_SCHEMA:
        raise ValueError(f"unsupported replay manifest schema: {replay_manifest.get('schema')}")
    if replay_manifest.get("mode") != "decode":
        raise ValueError("JTAG K/V preload is restricted to Decode payloads")
    context = int(require_mapping_value(replay_manifest, "context"))
    if not 1 <= context <= 8192:
        raise ValueError(f"unsupported Decode context: {context}")
    if int(require_mapping_value(replay_manifest, "kv_heads")) != KV_HEADS:
        raise ValueError(f"expected {KV_HEADS} KV heads")
    if int(require_mapping_value(replay_manifest, "head_dim")) != HEAD_DIM:
        raise ValueError(f"expected head dimension {HEAD_DIM}")
    if int(replay_manifest.get("batch", 1)) != 1:
        raise ValueError("JTAG K/V preload currently supports batch=1 only")
    if int(require_mapping_value(replay_manifest, "layer")) < 0:
        raise ValueError("replay manifest layer must be non-negative")
    payloads = require_mapping_value(replay_manifest, "payloads")
    if not isinstance(payloads, dict):
        raise ValueError("replay manifest payloads must be an object")

    head_bytes = context * BYTES_PER_TOKEN_PER_HEAD
    total_bytes = KV_HEADS * head_bytes
    source_files: dict[str, dict[str, Any]] = {}
    for kind in ("k", "v"):
        source, record = validate_kv_payload(payload_dir, payloads, kind, total_bytes)
        source_files[kind] = {"path": source, "record": record}

    output_dir = output_dir.resolve()
    if output_dir.exists() and any(output_dir.iterdir()):
        raise FileExistsError(f"refusing to mix preload artifacts into non-empty directory: {output_dir}")
    output_dir.mkdir(parents=True, exist_ok=True)

    segments: list[dict[str, Any]] = []
    for kind, base in (("k", K_BASE), ("v", V_BASE)):
        source = source_files[kind]["path"]
        for head in range(KV_HEADS):
            destination = output_dir / f"{kind}_head_{head:02d}_bf16_le.bin"
            segment = write_segment(source, destination, head * head_bytes, head_bytes)
            physical_address = base + head * HEAD_STRIDE
            segments.append(
                {
                    "kind": kind,
                    "head": head,
                    **segment,
                    "source_offset_bytes": head * head_bytes,
                    "physical_address": f"0x{physical_address:08X}",
                    "physical_address_u64": physical_address,
                    "words": head_bytes // 4,
                }
            )

    preload_manifest = {
        "schema": SCHEMA,
        "source_replay_manifest": {
            "file": manifest_path.name,
            "sha256": sha256_file(manifest_path),
            "payload_directory": str(payload_dir),
        },
        "mode": "decode",
        "context": context,
        "batch": 1,
        "layer": int(replay_manifest["layer"]),
        "q_heads": int(replay_manifest.get("q_heads", 32)),
        "kv_heads": KV_HEADS,
        "head_dim": HEAD_DIM,
        "bytes_per_token_per_head": BYTES_PER_TOKEN_PER_HEAD,
        "head_bytes": head_bytes,
        "source_kv_payloads": {
            kind: record["record"] for kind, record in source_files.items()
        },
        "jtag_access_contract": {
            "target": "APU",
            "force_mem_accesses": 1,
            "physical_memmap_base": "0xB0000000",
            "physical_memmap_bytes": 0x10000000,
            "k_base": f"0x{K_BASE:08X}",
            "v_base": f"0x{V_BASE:08X}",
            "head_stride_bytes": HEAD_STRIDE,
        },
        "segments": segments,
    }
    manifest_output = output_dir / "jtag_kv_preload_manifest.json"
    manifest_output.write_text(
        json.dumps(preload_manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    return preload_manifest


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--payload-dir", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()
    manifest = prepare(args.payload_dir, args.output_dir)
    print(
        "GQAV7_JTAG_KV_PREPARE_PASS "
        f"context={manifest['context']} layer={manifest['layer']} "
        f"segments={len(manifest['segments'])} head_bytes={manifest['head_bytes']} "
        f"manifest={args.output_dir / 'jtag_kv_preload_manifest.json'}"
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (FileNotFoundError, FileExistsError, ValueError, OSError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        raise SystemExit(2)
