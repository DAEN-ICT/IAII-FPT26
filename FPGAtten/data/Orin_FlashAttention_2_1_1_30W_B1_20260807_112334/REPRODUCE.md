# Orin FlashAttention 2.1.1：30W、Batch=1 复现说明

本目录冻结了 2026-08-07 的实际测试代码、原始 CSV、环境元数据、功耗模式和锁频记录。`reproducibility_code/` 中的两个运行脚本与本次实测时的 SHA-256 一致；请不要修改后再将结果称为本轮复现。

## 必需环境

- Jetson AGX Orin，计算能力 SM87。
- JetPack R35.4.1、CUDA 11.4。
- `/home/user/anaconda3/envs/py38/bin/python`，Python 3.8.20、PyTorch `2.1.0a0+41361538.nv23.06`。
- FlashAttention `2.1.1`，已为 SM87 编译；扩展文件路径记录在 `flashattention_environment.txt`。
- `nvpmodel` 的 MODE_30W 为 ID 2，执行用户具有 `sudo` 权限。

`conda_py38_explicit.txt` 是本轮 py38 环境的精确 Conda 包清单；`flashattention_extension.sha256` 固定了实际加载的 SM87 扩展二进制。该 FlashAttention 源目录不是 Git worktree，因此以包版本、安装位置和扩展 SHA-256 作为可用的版本锚点。

## 运行步骤

将 `reproducibility_code/` 中的 `benchmark_attention.py` 与 `run_orin_flashattention_b1_30w.sh` 复制到 Orin。以下命令不保存口令；runner 在退出时会恢复运行前的 `jetson_clocks` 状态。

```bash
export FPGATTEN_ORIN_ROOT=/home/user/gqav7_benchmark
export FPGATTEN_ORIN_PYTHON=/home/user/anaconda3/envs/py38/bin/python
export FPGATTEN_FLASH_SRC=/home/user/tools/flash-attention-2.1.1
export FPGATTEN_ORIN_BENCH=/absolute/path/to/benchmark_attention.py

read -rs -p 'sudo password: ' FPGATTEN_SUDO_PASSWORD; echo
export FPGATTEN_SUDO_PASSWORD
bash /absolute/path/to/run_orin_flashattention_b1_30w.sh
unset FPGATTEN_SUDO_PASSWORD
```

该入口固定为 Batch=1、Decode 30 个 Context 点、Prefill 21 个 Prompt 点、BF16 GQA、FP32 输出、FlashAttention 2.1.1、30W 和锁频。Q/K/V 是以 `seed=20260730` 生成的 `torch.randn` 合成输入，属于 Llama3-8B GQA 形状/算子性能基准，不是“真实 Llama3 Q/K/V 回放”。

`--streaming-bytes=64MiB` 是 stream pool 的目标参数而非每例严格上限；实现至少使用双槽，长 Prompt 的实际 `stream_working_set_bytes` 请以 `attention.csv` 为准（Prefill@8192 为 201,326,592 B）。当前 FP32 输出转换也位于 CUDA event 计时区间内，跨平台比较时必须保持这个口径。

## 一致性校验

运行完成后，用被冻结的验证器检查代码哈希、环境、参数矩阵、51 条记录、精度和数值有效性：

```bash
/home/user/anaconda3/envs/py38/bin/python validate_orin_flashattention_b1_result.py \
  --csv /path/to/attention.csv \
  --metadata /path/to/attention_metadata.json \
  --benchmark /absolute/path/to/benchmark_attention.py \
  --runner /absolute/path/to/run_orin_flashattention_b1_30w.sh
```

基线为 Decode@8192 `351.451345` tokens/s、Prefill@8192 `92201.883088` tokens/s。相同软件和锁频条件下应接近该量级；温度、后台负载和板卡状态可能造成小幅吞吐波动，因此以验证器通过和原始 P50 延迟为主，不应要求逐位相同。
