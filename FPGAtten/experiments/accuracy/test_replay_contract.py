#!/usr/bin/env python3
"""Static contract checks for the real Llama3 FPGA replay application."""

from __future__ import annotations

from pathlib import Path


def main() -> int:
    root = Path(__file__).resolve().parents[2]
    source = (root / "ps" / "software" / "gqav7_llama3_replay.c").read_text(encoding="utf-8")
    build = (root / "ps" / "software" / "build_gqav7_r25_aarch64.sh").read_text(encoding="utf-8")
    source_required = (
        "q_bf16_le.bin",
        "k_bf16_le.bin",
        "v_bf16_le.bin",
        "o_fp32_golden_le.bin",
        "gqav5_ddr_write",
        "GQAV7_LLAMA3_REPLAY_RESULT",
        "violations_atol_0p02_rtol_0p002",
        "finite_compared",
        "--preloaded-kv",
        "preloaded_kv",
    )
    for token in source_required:
        assert token in source, f"missing replay source contract: {token}"
    build_required = (
        "gqav7_llama3_replay.c",
        "gqav7-llama3-replay-r25-core235-dma300",
    )
    for token in build_required:
        assert token in build, f"missing build integration: {token}"
    print("PASS: replay source and AArch64 build-script contracts are present")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
