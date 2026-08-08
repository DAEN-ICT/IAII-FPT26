#!/usr/bin/env bash
# Batch=1 full-context FlashAttention 2 benchmark for Jetson AGX Orin.
set -euo pipefail

ROOT="${FPGATTEN_ORIN_ROOT:-/home/user/gqav7_benchmark}"
PY="${FPGATTEN_ORIN_PYTHON:-/home/user/anaconda3/envs/py38/bin/python}"
BENCH="${FPGATTEN_ORIN_BENCH:-${ROOT}/fpgatten_benchmark_attention.py}"
FLASH_SRC="${FPGATTEN_FLASH_SRC:-/home/user/tools/flash-attention-2.1.1}"
OUT="${FPGATTEN_ORIN_OUT:-${ROOT}/results/fpgatten_orin_flashattention_30w_b1_$(date +%Y%m%d_%H%M%S)}"
CLOCK_STATE="/tmp/fpgatten_orin_clocks_${USER}_$$.conf"

DECODE_CONTEXTS="1,2,3,4,7,8,15,16,17,31,32,33,63,64,65,127,128,129,255,256,257,512,1024,2048,3072,4096,5120,6144,7168,8192"
PREFILL_CONTEXTS="1,16,32,63,64,65,127,128,129,255,256,257,512,1024,2048,3072,4096,5120,6144,7168,8192"

if [[ -z "${FPGATTEN_SUDO_PASSWORD:-}" ]]; then
  IFS= read -r FPGATTEN_SUDO_PASSWORD
fi
if [[ -z "${FPGATTEN_SUDO_PASSWORD:-}" ]]; then
  echo "FPGATTEN_SUDO_PASSWORD or one password line on stdin is required." >&2
  exit 2
fi

sudo_run() {
  printf '%s\n' "$FPGATTEN_SUDO_PASSWORD" | sudo -S -p '' "$@"
}

cleanup() {
  if [[ -f "$CLOCK_STATE" ]]; then
    sudo_run jetson_clocks --restore "$CLOCK_STATE" >/dev/null 2>&1 || true
    sudo_run rm -f "$CLOCK_STATE" >/dev/null 2>&1 || true
  fi
  unset FPGATTEN_SUDO_PASSWORD
}
trap cleanup EXIT INT TERM

mkdir -p "$OUT"
echo "OUT=$OUT"
date --iso-8601=seconds | tee "$OUT/start.txt"
uname -a > "$OUT/system.txt"
cat /etc/nv_tegra_release >> "$OUT/system.txt"
sha256sum "$BENCH" > "$OUT/benchmark_sha256.txt"

# MODE_30W is nvpmodel ID 2 on this Orin image. It was recorded before launch.
sudo_run nvpmodel -m 2
sleep 4
sudo_run nvpmodel -q > "$OUT/nvpmodel_30w_locked.txt" 2>&1 || true
sudo_run jetson_clocks --store "$CLOCK_STATE"
sudo_run jetson_clocks > "$OUT/jetson_clocks_enable.log" 2>&1
sudo_run jetson_clocks --show > "$OUT/jetson_clocks_locked.txt" 2>&1 || true

PYTHONPATH="$FLASH_SRC" "$PY" - <<'PY' > "$OUT/flashattention_environment.txt"
import torch
import flash_attn
import flash_attn_2_cuda
from flash_attn import flash_attn_func

print("torch=" + torch.__version__)
print("torch_cuda=" + str(torch.version.cuda))
print("gpu=" + torch.cuda.get_device_name(0))
print("capability=" + str(torch.cuda.get_device_capability(0)))
print("flash_attn=" + flash_attn.__version__)
print("extension=" + flash_attn_2_cuda.__file__)
q = torch.randn(1, 1, 32, 128, device="cuda", dtype=torch.bfloat16)
k = torch.randn(1, 64, 8, 128, device="cuda", dtype=torch.bfloat16)
v = torch.randn(1, 64, 8, 128, device="cuda", dtype=torch.bfloat16)
o = flash_attn_func(q, k, v, dropout_p=0.0, causal=False)
torch.cuda.synchronize()
print("smoke_shape=" + str(tuple(o.shape)))
print("smoke_dtype=" + str(o.dtype))
print("smoke_nonfinite=" + str(int((~torch.isfinite(o)).sum())))
PY

PYTHONPATH="$FLASH_SRC" "$PY" "$BENCH" \
  --device cuda \
  --cuda-backend flash_attn \
  --batches 1 \
  --modes decode,prefill \
  --decode-contexts "$DECODE_CONTEXTS" \
  --prefill-contexts "$PREFILL_CONTEXTS" \
  --cache-modes streaming \
  --output-modes fp32 \
  --cuda-warmup 10 \
  --warmup-budget-ms 300 \
  --case-budget-ms 700 \
  --decode-repeats 4000 \
  --prefill-repeats 400 \
  --min-repeats 5 \
  --streaming-bytes 67108864 \
  --max-stream-slots 64 \
  --platform-name "orin_agx_gpu_30w_flashattention" \
  --power-limit-w "30W_nvpmodel+jetson_clocks" \
  --notes "FPGAtten; FlashAttention 2.1.1 SM87; BF16 GQA 32Q/8KV/128; FP32 output; batch=1" \
  --csv "$OUT/attention.csv" \
  --metadata-json "$OUT/attention_metadata.json" \
  --case-events-jsonl "$OUT/case_events.jsonl" \
  2>&1 | tee "$OUT/benchmark.log"

date --iso-8601=seconds | tee "$OUT/complete.txt"
echo "PASS: OUT=$OUT"
