# FPGAtten 一般录制视频串口命令清单

适用条件：SD 卡已经包含本版 FPGAtten 的 BOOT 和 RootFS 两个分区，板卡已从 SD 启动。以下内容全部直接输入 PetaLinux 串口 Shell，不使用 PC 端脚本、SSH、JTAG 数据预装或 `sudo`。

## 1. 登录

```text
login: FPGAteen
password: root
```

## 2. 系统与硬件身份

```sh
clear
whoami
hostname
fpgatten-info
ls -l /dev/fpgatten-attention /dev/fpgatten-memory
find /opt/fpgatten/cases -mindepth 3 -maxdepth 3 -type d | sort
```

确认出现 `ROOTFS=/dev/mmcblk1p2 ext4 rw,...` 和 `FPGATTEN_PLATFORM_CHECK=PASS`。

## 3. 真实数据短案例

```sh
clear
echo "=== FPGAtten | Real Llama3-8B Q/K/V | Decode 128 | Layer 0 ==="
fpgatten-run decode 128 0 3
```

## 4. Decode 4096 主镜头

```sh
clear
echo "=== FPGAtten | Decode | Context 4096 | Layer 15 | Batch 1 ==="
fpgatten-run decode 4096 15 20
```

## 5. Decode 8192 主镜头

```sh
clear
echo "=== FPGAtten | Decode | Context 8192 | Layer 15 | Batch 1 ==="
fpgatten-run decode 8192 15 20
```

## 6. Prefill 主镜头

```sh
clear
echo "=== FPGAtten | Prefill | Prompt 128 | Layer 15 | Batch 1 ==="
fpgatten-run prefill 128 15 1
```

## 7. 最近结果

```sh
clear
ls -1t /home/FPGAteen/results/*.log | head
grep '^FPGATTEN_LLAMA3_REPLAY_RESULT' "$(ls -1t /home/FPGAteen/results/*.log | head -1)"
```

结果应满足：

```text
nan_or_inf=0
violations_atol_0p02_rtol_0p002=0
```

## 8. 关机

```sh
sync
systemctl poweroff
```

所有性能均为 Batch 1、BF16 GQA、单层、device-resident、attention-only；Q/K/V 加载、PL DDR 写入和 Golden 比对不计入 tokens/s。
