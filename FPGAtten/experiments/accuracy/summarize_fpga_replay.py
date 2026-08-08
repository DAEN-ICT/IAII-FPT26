#!/usr/bin/env python3
"""Convert a GQAv7 real-Llama3 FPGA replay serial log into traceable results.

The parser deliberately records the measurement boundary.  It only treats a
case as passed when the board emitted the replay result and the wrapper command
returned success; data upload and host-side Golden comparison are excluded from
the reported hardware-cycle throughput.
"""

from __future__ import annotations

import argparse
import csv
import json
import re
from pathlib import Path


RESULT_PREFIX = "GQAV7_LLAMA3_REPLAY_RESULT"
TIMING_PREFIX = "GQAV7_LLAMA3_TIMING"
LEGACY_ITER_PREFIX = "GQAV7_LLAMA3_REPLAY_ITER"
FAIL_PREFIX = "GQAV7_LLAMA3_REPLAY_FAIL"


def key_values(text: str) -> dict[str, str]:
    return dict(re.findall(r"([A-Za-z0-9_]+)=([^\s]+)", text))


def read_records(log_text: str, prefix: str) -> list[dict[str, str]]:
    # Result lines are intentionally one line, but terminal captures can insert
    # carriage returns before the next `key=value` token.  Match through either
    # the next known marker or EOF.
    expression = (
        rf"{re.escape(prefix)}"
        rf"(?:(?!(?:GQAV7_LLAMA3_(?:REPLAY_(?:RESULT|ITER|FAIL|RC)|TIMING)"
        rf"|GQAV7_REPLAY_RC)).)*"
    )
    return [key_values(match.group(0)) for match in re.finditer(expression, log_text, re.DOTALL)]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--serial-log", required=True, type=Path)
    parser.add_argument("--replay-manifest", required=True, type=Path)
    parser.add_argument("--output-csv", required=True, type=Path)
    parser.add_argument("--output-json", required=True, type=Path)
    args = parser.parse_args()

    log_text = args.serial_log.read_text(encoding="utf-8", errors="replace")
    manifest = json.loads(args.replay_manifest.read_text(encoding="utf-8"))
    results = read_records(log_text, RESULT_PREFIX)
    iterations = read_records(log_text, TIMING_PREFIX) + read_records(log_text, LEGACY_ITER_PREFIX)
    failures = read_records(log_text, FAIL_PREFIX)
    wrapper_success = bool(
        re.search(r"(?:GQAV7_REPLAY_RC|GQAV7_LLAMA3_REPLAY_RC)=0", log_text)
    )
    summary: dict[str, object] = {
        "schema": "gqav7_fpga_real_llama3_replay_result_v1",
        "source": {
            "replay_manifest": str(args.replay_manifest.resolve()),
            "mode": manifest.get("mode"),
            "context": manifest.get("context"),
            "layer": manifest.get("layer"),
            "batch": manifest.get("batch"),
            "accelerator_boundary": manifest.get("accelerator_boundary"),
            "source_manifest_sha256": manifest.get("source_manifest_sha256"),
        },
        "measurement_scope": (
            "单层、device-resident、attention-only；Q/K/V 数据加载、串口传输、"
            "DDR 写入和 Golden 输出比对均不计入 tokens/s"
        ),
        "throughput_clock": "235 MHz core clock",
        "cycle_counter_method": "硬件周期计数器；32位回绕以主机耗时辅助消歧",
        "serial_log": str(args.serial_log.resolve()),
        "wrapper_success": wrapper_success,
        "replay_fail_markers": failures,
        "iteration_records": iterations,
        "result_records": results,
        "status": "PASS" if len(results) == 1 and wrapper_success and not failures else "FAIL",
    }
    args.output_json.parent.mkdir(parents=True, exist_ok=True)
    args.output_csv.parent.mkdir(parents=True, exist_ok=True)
    args.output_json.write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8")

    fieldnames = [
        "status", "mode", "context", "layer", "batch", "query_tokens", "repeats",
        "mean_tokens_per_second",
        "last_tokens_per_second", "mean_cycles", "last_cycles", "max_abs_error", "mae",
        "rmse", "mean_relative_error", "max_relative_error", "cosine_similarity",
        "compared", "finite_compared", "nan_or_inf",
        "violations_atol_0p02_rtol_0p002", "violations_atol_0p02_rtol_0p02",
        "counter_wraps", "measurement_scope", "serial_log",
    ]
    with args.output_csv.open("w", newline="", encoding="utf-8-sig") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        for result in results or [{}]:
            row = {
                "status": summary["status"],
                "mode": manifest.get("mode"),
                "context": manifest.get("context"),
                "layer": manifest.get("layer"),
                "batch": manifest.get("batch"),
                "measurement_scope": summary["measurement_scope"],
                "serial_log": str(args.serial_log.resolve()),
            }
            row.update(result)
            writer.writerow(row)
    print(json.dumps({"status": summary["status"], "results": len(results),
                      "output_csv": str(args.output_csv.resolve()),
                      "output_json": str(args.output_json.resolve())}, ensure_ascii=False))
    return 0 if summary["status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
