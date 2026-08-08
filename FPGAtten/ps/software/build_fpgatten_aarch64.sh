#!/usr/bin/env bash
set -euo pipefail

project_root="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
source_dir="${project_root}/ps/software"
output_dir="${source_dir}/bin"
cc="${CC:-aarch64-linux-gnu-gcc}"

mkdir -p "${output_dir}"
common_flags=(-O2 -pipe -Wall -Wextra)

"${cc}" "${common_flags[@]}" \
  "${source_dir}/gqav5_uio_selftest.c" -lm \
  -o "${output_dir}/fpgatten-uio-selftest-core235-dma300"
"${cc}" "${common_flags[@]}" \
  "${source_dir}/gqav5_uio_benchmark.c" -lm \
  -o "${output_dir}/fpgatten-uio-benchmark-core235-dma300"
"${cc}" "${common_flags[@]}" \
  "${source_dir}/gqav5_experiment.c" \
  "${source_dir}/gqav5_custom_experiment.c" -lm \
  -o "${output_dir}/fpgatten-custom-experiment-core235-dma300"
"${cc}" "${common_flags[@]}" \
  "${source_dir}/gqav5_experiment.c" \
  "${source_dir}/gqav7_llama3_replay.c" -lm \
  -o "${output_dir}/fpgatten-llama3-replay-core235-dma300"

echo "PASS: built FPGAtten AArch64 Linux applications"
