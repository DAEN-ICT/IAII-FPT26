# FPGAtten FPGA 实时计算录屏制作指南

## 1. 录制目标

视频应展示 FPGAtten 在 Z19-P 实板上读取真实 Llama3-8B Q/K/V、执行 BF16 GQA Attention、报告 tokens/s，并与 Thor FP32 Golden 比对。

推荐表述：

> 真实 Llama3-8B 中间 Q/K/V 张量的 FPGA 单层 Attention 实时回放与 Thor FP32 Golden 验证。

不要表述为“完整 Llama3-8B 在 FPGA 上生成答案”。统一实验口径为：

```text
Batch = 1
BF16 GQA
32 Q Heads / 8 KV Heads
Head Dimension = 128
Single-layer / Device-resident / Attention-only
Core = 235 MHz / DMA = 300 MHz
Q/K/V 加载、PL DDR 写入和 Golden 比对不计入 tokens/s
```

## 2. 使用的正式系统

使用独立目录中的 SD 镜像：

```text
FPGAtten/FPGAtten_PetaLinux_SD/FPGAtten_Z19P.wic.xz
```

系统信息：

| 项目 | 值 |
|---|---|
| 主机名 | `fpgatten-z19p` |
| 串口账号 | `FPGAteen` |
| 密码 | `root` |
| RootFS | SD 第二分区、EXT4、读写 |
| SSH | 关闭 |
| sudo | 未安装，也不需要 |
| Attention 设备 | `/dev/fpgatten-attention` |
| PL DDR 设备 | `/dev/fpgatten-memory` |

镜像已内置板端程序以及 10 组真实数据案例。录制时不需要上传文件、使用 JTAG 预装 K/V 或运行 PC 端脚本。

## 3. SD 启动准备

1. 按 `FPGAtten_PetaLinux_SD/SD卡制作与启动说明.md` 把完整 `.wic.xz` 镜像写入 SD 卡。
2. 板卡断电后插卡。
3. 将 SW1 的 1、2、3、4 位设为 `ON、OFF、ON、OFF`，即 `MODE[3:0] = 0101`。
4. 串口设置为 115200 bit/s、8-N-1、无流控。
5. 上电并等待登录提示。
6. 使用 `FPGAteen / root` 登录。

录制正式素材前，应至少完成三次断电冷启动彩排。每次都确认系统从 `/dev/mmcblk1p2` 以 EXT4、读写模式启动。

## 4. 录制前实板检查

以下命令直接输入 PetaLinux 串口 Shell：

```sh
clear
whoami
hostname
fpgatten-info
id
ls -l /dev/fpgatten-attention /dev/fpgatten-memory
find /opt/fpgatten/cases -mindepth 3 -maxdepth 3 -type d | sort
df -h /
```

必须看到：

```text
USER=FPGAteen
HOSTNAME=fpgatten-z19p
ROOTFS=/dev/mmcblk1p2 ext4 rw,...
/dev/fpgatten-attention=READY
/dev/fpgatten-memory=READY
FPGATTEN_PLATFORM_CHECK=PASS
```

如有任何一项不符，先停止录制并排查，不要继续跑性能数据。

## 5. 分阶段验证命令

### 5.1 第一阶段：最短验证链路

先验证 Decode@128、Layer 0：

```sh
fpgatten-run decode 128 0 3
```

该命令自动完成案例 SHA-256、Q/K/V 加载、FPGA 运行和 Golden 比对。确认出现 `FPGATTEN_RUN_PASS` 后再继续。

### 5.2 第二阶段：Decode 长上下文三层覆盖

```sh
fpgatten-run decode 4096 0 3
fpgatten-run decode 4096 15 3
fpgatten-run decode 4096 31 3
```

```sh
fpgatten-run decode 8192 0 3
fpgatten-run decode 8192 15 3
fpgatten-run decode 8192 31 3
```

### 5.3 第三阶段：Prefill 真实数据

```sh
fpgatten-run prefill 128 0 1
fpgatten-run prefill 128 15 1
fpgatten-run prefill 128 31 1
```

## 6. 正式录屏命令

短开场先显示系统和短案例：

```sh
clear
fpgatten-info
fpgatten-run decode 128 0 3
```

主镜头一，Context 4096 / Layer 15：

```sh
clear
fpgatten-run decode 4096 15 20
```

主镜头二，Context 8192 / Layer 15：

```sh
clear
fpgatten-run decode 8192 15 20
```

Prefill 补充镜头：

```sh
clear
fpgatten-run prefill 128 15 1
```

每次运行均会把原始日志保存到：

```text
/home/FPGAteen/results/
```

显示最近结果：

```sh
ls -1t /home/FPGAteen/results/*.log | head
```

```sh
grep '^FPGATTEN_LLAMA3_REPLAY_RESULT' "$(ls -1t /home/FPGAteen/results/*.log | head -1)"
```

## 7. 精度与数值核对

成功结果必须满足：

```text
nan_or_inf=0
violations_atol_0p02_rtol_0p002=0
```

已有同一 235 MHz 硬件配置的真实 Layer 15 结果可作为彩排核对值：

| 案例 | 平均吞吐 | 硬件延迟 | Cosine Similarity | Max Abs Error |
|---|---:|---:|---:|---:|
| Decode / Context 4096 | 615.999741 tokens/s | 约 1.62 ms | 0.999999878862 | 4.191×10⁻⁴ |
| Decode / Context 8192 | 314.851899 tokens/s | 约 3.18 ms | 0.999999858181 | 4.163×10⁻⁴ |

录屏和论文引用应以本次串口原始日志为准。`314.851899 tokens/s` 是真实 Q/K/V Layer 15 回放；`314.595307 tokens/s` 是独立 Decode@8192 benchmark，不能把两者写成同一个实验结果。

## 8. 45–50 秒画面安排

| 时间 | 画面 | 屏幕信息 |
|---|---|---|
| 0–4 秒 | Z19-P 实物与串口终端 | `FPGAtten` |
| 4–8 秒 | `fpgatten-info` 输出 | `Real Llama3-8B Q/K/V · BF16 GQA · Context 8192` |
| 8–15 秒 | Decode 128 通过 | `Real-data chain verified` |
| 15–25 秒 | Decode 4096 / Layer 15 | 当次 tokens/s、延迟、精度 PASS |
| 25–38 秒 | Decode 8192 / Layer 15 | 当次 tokens/s、延迟、精度 PASS |
| 38–44 秒 | Prefill 128 / Layer 15 | `Prefill verified` |
| 44–50 秒 | FPGA 实物与结尾卡 | `Single-layer · Device-resident · Attention-only` |

建议旁白：

> 这是面向 Llama3-8B 的 FPGAtten BF16 GQA Attention 核。系统从 SD 卡独立启动，输入为真实模型层中提取的 Q、K、V。短案例首先验证完整回放链路，随后展示 Context 4096 和 8192 的长上下文 Decode，并实时给出吞吐、延迟和 Thor FP32 Golden 精度结果。所有性能仅统计 FPGA Attention 硬件执行，不包含数据加载和 Golden 比对。

## 9. 录制要求

- 终端字号建议 18–22，宽度至少 150 个字符，避免结果行换行。
- 实物画面要能辨认板卡、SD 卡、供电和串口连接。
- FPGA 计算过程保持原速；不要剪接或伪造运行行数。
- 可以剪短开机等待时间，但保留未剪辑冷启动证据版。
- 不展示其他设备 IP、个人文件、命令历史或无关窗口。
- 不声称跨平台绝对能效更高，除非功耗测量边界完全一致。
- 不把单层 Attention tokens/s 表述为端到端模型生成速度。

## 10. 异常排查命令

```sh
systemctl status fpgatten-devices.service --no-pager
journalctl -u fpgatten-devices.service --no-pager
dmesg | grep -i uio
awk '$2 == "/" {print $1, $3, $4}' /proc/mounts
df -h /
```

案例校验失败时手工复核，例如：

```sh
cd /opt/fpgatten/cases/decode/context_8192/layer_15
sha256sum -c SHA256SUMS
```

## 11. 结束与留档

录制完成后先保存日志并正常关机：

```sh
sync
systemctl poweroff
```

至少保留：

```text
video/
├── FPGAtten_竞赛展示_45s.mp4
├── FPGAtten_完整实板证据.mp4
├── raw/
│   ├── fpga_board_camera.mp4
│   ├── decode4096_screen.mkv
│   └── decode8192_screen.mkv
└── evidence/
    ├── decode4096_layer15.log
    ├── decode8192_layer15.log
    ├── prefill128_layer15.log
    └── 录屏口径说明.md
```

板端的逐条命令也单独保存在 `petalinux/docs/FPGAtten_串口命令清单.md`。
