#!/usr/bin/env python3
"""Host-only contract test for the real Llama3 Decode JTAG K/V preloader.

The test creates only temporary host files.  It neither launches XSDB nor
opens a serial port, so it can be run safely without a connected board.
"""

from __future__ import annotations

import hashlib
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
PREPARER = ROOT / "tool" / "Benchmark" / "prepare_llama3_jtag_kv_preload.py"
RUNNER = ROOT / "tool" / "Board" / "run_gqav7_jtag_kv_preload.ps1"

CONTEXT = 3
KV_HEADS = 8
BYTES_PER_TOKEN_PER_HEAD = 256
HEAD_BYTES = CONTEXT * BYTES_PER_TOKEN_PER_HEAD
K_BASE = 0xB4000000
V_BASE = 0xB5000000
HEAD_STRIDE = 0x00200000


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while block := handle.read(1024 * 1024):
            digest.update(block)
    return digest.hexdigest()


def powershell_executable() -> str:
    executable = shutil.which("powershell") or shutil.which("pwsh")
    if executable is None:
        raise RuntimeError("PowerShell executable is required for this test")
    return executable


def write_replay_payload(payload_dir: Path, *, corrupt_v_hash: bool = False) -> None:
    payload_dir.mkdir(parents=True, exist_ok=True)
    k_bytes = bytes(index % 251 for index in range(KV_HEADS * HEAD_BYTES))
    v_bytes = bytes((255 - index) % 251 for index in range(KV_HEADS * HEAD_BYTES))
    k_path = payload_dir / "k_bf16_le.bin"
    v_path = payload_dir / "v_bf16_le.bin"
    k_path.write_bytes(k_bytes)
    v_path.write_bytes(v_bytes)
    v_hash = sha256(v_path)
    if corrupt_v_hash:
        v_hash = "0" * 64
    (payload_dir / "replay_manifest.json").write_text(
        json.dumps(
            {
                "schema": "gqav7_llama3_fpga_replay_payload_v1",
                "mode": "decode",
                "context": CONTEXT,
                "batch": 1,
                "layer": 0,
                "q_heads": 32,
                "kv_heads": KV_HEADS,
                "head_dim": 128,
                "payloads": {
                    "k": {
                        "file": k_path.name,
                        "bytes": len(k_bytes),
                        "sha256": sha256(k_path),
                    },
                    "v": {
                        "file": v_path.name,
                        "bytes": len(v_bytes),
                        "sha256": v_hash,
                    },
                },
            },
            indent=2,
        ),
        encoding="utf-8",
    )


def run_preparer(payload_dir: Path, output_dir: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [
            sys.executable,
            str(PREPARER),
            "--payload-dir",
            str(payload_dir),
            "--output-dir",
            str(output_dir),
        ],
        text=True,
        capture_output=True,
        check=False,
    )


def verify_segments(payload_dir: Path, preload_dir: Path) -> None:
    manifest = json.loads((preload_dir / "jtag_kv_preload_manifest.json").read_text(encoding="utf-8"))
    assert manifest["schema"] == "gqav7_llama3_jtag_kv_preload_v1"
    assert manifest["mode"] == "decode"
    assert manifest["context"] == CONTEXT
    assert manifest["head_bytes"] == HEAD_BYTES
    assert len(manifest["segments"]) == KV_HEADS * 2

    for kind, base in (("k", K_BASE), ("v", V_BASE)):
        source = (payload_dir / f"{kind}_bf16_le.bin").read_bytes()
        records = [record for record in manifest["segments"] if record["kind"] == kind]
        assert len(records) == KV_HEADS
        for head, record in enumerate(records):
            assert record["head"] == head
            assert record["bytes"] == HEAD_BYTES
            assert record["physical_address"] == f"0x{base + head * HEAD_STRIDE:08X}"
            segment = preload_dir / record["file"]
            assert segment.read_bytes() == source[head * HEAD_BYTES : (head + 1) * HEAD_BYTES]
            assert sha256(segment) == record["sha256"]


def verify_runner_dry_run(preload_dir: Path, output_dir: Path) -> None:
    result = subprocess.run(
        [
            powershell_executable(),
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            str(RUNNER),
            "-ManifestPath",
            str(preload_dir / "jtag_kv_preload_manifest.json"),
            "-OutputDirectory",
            str(output_dir),
            "-DryRun",
        ],
        text=True,
        capture_output=True,
        check=False,
    )
    combined = result.stdout + result.stderr
    assert result.returncode == 0, combined
    assert "GQAV7_JTAG_KV_LOCAL_SHA256_OK=16" in combined, combined
    assert "GQAV7_JTAG_KV_PRELOAD_DRY_RUN=1" in combined, combined
    assert not (output_dir / "readbacks").exists(), combined


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="gqav7-jtag-kv-preload-") as temporary:
        root = Path(temporary)
        payload_dir = root / "payload"
        preload_dir = root / "preload"
        write_replay_payload(payload_dir)

        good = run_preparer(payload_dir, preload_dir)
        combined_good = good.stdout + good.stderr
        assert good.returncode == 0, combined_good
        assert "GQAV7_JTAG_KV_PREPARE_PASS" in combined_good, combined_good
        verify_segments(payload_dir, preload_dir)
        verify_runner_dry_run(preload_dir, root / "dry_run")

        corrupt_payload_dir = root / "corrupt"
        write_replay_payload(corrupt_payload_dir, corrupt_v_hash=True)
        bad = run_preparer(corrupt_payload_dir, root / "corrupt_preload")
        combined_bad = bad.stdout + bad.stderr
        assert bad.returncode != 0, combined_bad
        assert "SHA-256 mismatch" in combined_bad, combined_bad

    print("PASS: JTAG K/V preload preparation and host-only dry run are verified")


if __name__ == "__main__":
    try:
        main()
    except AssertionError as error:
        print(f"FAIL: {error}", file=sys.stderr)
        raise
