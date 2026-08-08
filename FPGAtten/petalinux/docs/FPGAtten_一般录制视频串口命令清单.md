# FPGAtten 一般录制视频串口命令清单

适用条件：SD 卡已经包含本版 FPGAtten 的 BOOT 和 RootFS 两个分区，板卡已从 SD 启动。以下内容全部直接输入 PetaLinux 串口 Shell，不使用 PC 端脚本、SSH、JTAG 数据预装或 `sudo`。

## 1. 登录

```text
login: FPGAteen
password: root
```

输入密码时不会显示字符。出现下面的提示符后开始录制：

```text
FPGAteen@fpgatten-z19p:~$
```

## 2. 镜头一：系统与硬件身份

逐行输入：

```sh
clear
whoami
hostname
fpgatten-info
ls -l /dev/fpgatten-attention /dev/fpgatten-memory
find /opt/fpgatten/cases -mindepth 3 -maxdepth 3 -type d | sort
```

看到以下内容才能继续：

```text
FPGAteen
fpgatten-z19p
ROOTFS=/dev/mmcblk1p2 ext4 rw,...
/dev/fpgatten-attention=READY
/dev/fpgatten-memory=READY
FPGATTEN_PLATFORM_CHECK=PASS
```

## 3. 镜头二：真实数据短案例

```sh
clear
echo "=== FPGAtten | Real Llama3-8B Q/K/V | Decode 128 | Layer 0 ==="
fpgatten-run decode 128 0 3
```

必须出现 `FPGATTEN_LLAMA3_REPLAY_RESULT` 和 `FPGATTEN_RUN_PASS`。

## 4. 镜头三：Decode 4096

```sh
clear
echo "=== FPGAtten | Decode | Context 4096 | Layer 15 | Batch 1 ==="
fpgatten-run decode 4096 15 20
```

## 5. 镜头四：Decode 8192

```sh
clear
echo "=== FPGAtten | Decode | Context 8192 | Layer 15 | Batch 1 ==="
fpgatten-run decode 8192 15 20
```

已有同硬件配置的结果只用于现场核对：Decode 4096 约 `615.999741 tokens/s`，Decode 8192 约 `314.851899 tokens/s`。视频必须使用本次串口实际输出值。

## 6. 镜头五：Prefill

```sh
clear
echo "=== FPGAtten | Prefill | Prompt 128 | Layer 15 | Batch 1 ==="
fpgatten-run prefill 128 15 1
```

## 7. 镜头六：查看最近结果

```sh
clear
ls -1t /home/FPGAteen/results/*.log | head
```

查看最近一次结果：

```sh
grep '^FPGATTEN_LLAMA3_REPLAY_RESULT' "$(ls -1t /home/FPGAteen/results/*.log | head -1)"
```

查看最近四次结果：

```sh
for log in $(ls -1t /home/FPGAteen/results/*.log | head -4); do
    grep '^FPGATTEN_LLAMA3_REPLAY_RESULT' "$log"
done
```

每条结果应满足：

```text
nan_or_inf=0
violations_atol_0p02_rtol_0p002=0
```

## 8. 可选：完整 Layer 0、15、31 证据版

短视频不必全部录制；未剪辑证据版可依次运行：

```sh
fpgatten-run decode 4096 0 3
fpgatten-run decode 4096 15 3
fpgatten-run decode 4096 31 3
fpgatten-run decode 8192 0 3
fpgatten-run decode 8192 15 3
fpgatten-run decode 8192 31 3
fpgatten-run prefill 128 0 1
fpgatten-run prefill 128 15 1
fpgatten-run prefill 128 31 1
```

## 9. 结束录制并关机

```sh
sync
systemctl poweroff
```

等待串口显示系统已停止，确认 SD 卡不再被访问后再断电。

## 10. 录制口径

屏幕或旁白应说明：

```text
Batch 1
BF16 GQA，32 Q Heads / 8 KV Heads，Head Dimension 128
单层、device-resident、attention-only
Q/K/V 加载、PL DDR 写入及 Golden 比对不计入 tokens/s
```

不要把单层 Attention tokens/s 表述为完整 Llama3-8B 端到端生成速度。
