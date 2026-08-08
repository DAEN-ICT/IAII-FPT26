# FPGAtten

面向 Llama3-8B BF16 GQA Attention 的 FPGA 实验源码与跨平台性能数据包。

## 目录结构

```text
FPGAtten/
├─ rtl/                         当前 FPGAtten 的 RTL、filelist 与 Softmax ROM
├─ ps/software/                 AArch64 板端 Benchmark / Llama3 回放源码与构建脚本
├─ vivado/                      Z19-P 工程创建输入、约束、IP 描述和时序构建入口
├─ experiments/
│  ├─ performance/              Thor / RTX 3090 / Orin / CPU / GPU token/s 基准代码
│  ├─ accuracy/                 真实 Llama3-8B Q/K/V Golden 与 FPGA 回放验证代码
│  └─ fpga_board/               FPGA 实板 Decode、Prefill、JTAG 与真实回放脚本
└─ data/                        跨平台吞吐汇总 Excel 与 FPGA 真实回放摘要 CSV
```

## 内容范围

- `rtl/`：当前可综合 RTL 闭包、filelist 和 Softmax ROM 初始化数据。
- `ps/software/`：AArch64 板端 Decode、Prefill 与真实 Llama3-8B 回放程序。
- `vivado/`：Z19-P 工程创建输入、约束、IP 描述与构建入口。
- `experiments/performance/`：CPU、Thor GPU、RTX 3090、Orin GPU 的 Decode/Prefill token/s 基准代码。
- `experiments/accuracy/`：真实 Llama3-8B Q/K/V、FP32 Golden、FPGA payload 与误差汇总代码。
- `experiments/fpga_board/`：FPGA 实板吞吐和真实回放脚本。
- `data/`：跨平台性能汇总 Excel 与 FPGA 真实回放摘要。

## 复现实验

### 跨平台 token/s

使用 `experiments/performance/benchmark_attention.py`。它统一支持 CPU、CUDA tiled-GQA、PyTorch Flash SDPA 与外部 `flash-attn` 后端，并覆盖 Decode 与 Prefill。

- PyTorch Flash SDPA：`--cuda-backend flash`
- FlashAttention 2：`--cuda-backend flash_attn`
- 非 Flash 的 CUDA tiled-GQA：`--cuda-backend tiled_math`

完整平台、功耗模式、硬件型号、后端和原始数据来源见 `data/FPGAtten_跨平台Decode_Prefill_token_s汇总.xlsx`。

### FPGA 实板与真实数据精度

1. 使用 `ps/software/build_fpgatten_aarch64.sh` 编译板端程序。
2. 使用 `experiments/accuracy/prepare_replay_payload.py` 生成 FPGA 回放 payload。
3. 使用 `experiments/fpga_board/run_fpgatten_jtag_kv_preload.ps1` 预装 Decode K/V。
4. 使用 `experiments/fpga_board/run_fpgatten_llama3_replay.ps1` 执行真实 Q/K/V 回放并对比 FP32 Golden。

板端脚本不会保存默认口令。需要时请设置当前进程环境变量 `FPGATTEN_BOARD_PASSWORD`，或按提示交互输入。

默认实板计时频率已统一为 Core 235 MHz、DMA 300 MHz；`build_fpgatten_aarch64.sh` 输出的可执行文件也以 `core235-dma300` 标识，避免与历史 230 MHz 文件混淆。

## 外部依赖

- Vivado 2024.2、对应 Z19-P 板卡/IP 支持。
- AArch64 Linux 交叉工具链。
- Python、PyTorch、CUDA、Transformers。
- Orin FlashAttention 结果的复现需要单独安装兼容版本的 `flash-attn`；其实现源码不随本包分发。
- 真实 Llama3-8B 权重和完整 Q/K/V Golden 原始张量为外部大文件，不在本包内。

## 命名兼容性

所有用户可见目录、脚本入口、数据文件和报表均使用 `FPGAtten`。RTL、AXI 协议标记与板端 C 源码中的 `gqav5/gqav7` 标识保留为内部编译接口，避免破坏既有 filelist、寄存器映射和实板通信协议。

真实回放摘要 CSV 中的 `release_identity` 与“原始串口日志”列保留了历史采集时的原始标识和路径，仅用于 SHA-256 与日志追溯；它们不是当前对外工程名称。
