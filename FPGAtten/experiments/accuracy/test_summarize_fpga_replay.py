#!/usr/bin/env python3
"""Small contract test for the real-Llama3 replay result parser."""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
from pathlib import Path


def main() -> int:
    script = Path(__file__).with_name("summarize_fpga_llama3_replay.py")
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        manifest = root / "replay_manifest.json"
        log = root / "serial.log"
        output_csv = root / "result.csv"
        output_json = root / "result.json"
        manifest.write_text(
            json.dumps({"mode": "decode", "context": 128, "layer": 0, "batch": 1}),
            encoding="utf-8",
        )
        log.write_text(
            "GQAV7_LLAMA3_REPLAY_ITER iteration=1 cycles=123\n"
            "GQAV7_LLAMA3_REPLAY_RESULT mode=decode context=128 "
            "mean_tokens_per_second=456.0 max_abs_error=0.01 "
            "finite_compared=4096 nan_or_inf=0\n"
            "GQAV7_LLAMA3_REPLAY_RC=0\n",
            encoding="utf-8",
        )
        subprocess.run(
            [sys.executable, str(script), "--serial-log", str(log), "--replay-manifest", str(manifest),
             "--output-csv", str(output_csv), "--output-json", str(output_json)],
            check=True,
        )
        parsed = json.loads(output_json.read_text(encoding="utf-8"))
        assert parsed["status"] == "PASS", parsed
        assert parsed["result_records"][0]["mean_tokens_per_second"] == "456.0", parsed
        assert "Q/K/V" in parsed["measurement_scope"], parsed
    print("PASS: FPGA real-Llama3 replay result parser contract")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
