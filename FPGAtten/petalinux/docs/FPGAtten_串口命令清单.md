# FPGAtten 串口 Shell 命令清单

本清单适用于 `FPGAtten_PetaLinux_SD` 中的正式 SD 镜像。所有命令都在板卡的 PetaLinux 串口 Shell 中输入，不需要 PowerShell、SSH、JTAG 数据预装或 `sudo`。

## 1. 登录

串口参数：115200 bit/s、8-N-1、无流控。

```text
login: FPGAteen
password: root
```

账号区分大小写；输入密码时终端不回显字符。

## 2. 开机检查

登录后逐行输入：

```sh
clear
whoami
hostname
fpgatten-info
id
ls -l /dev/fpgatten-attention /dev/fpgatten-memory
find /opt/fpgatten/cases -mindepth 3 -maxdepth 3 -type d | sort
```

关键输出应包括：

```text
FPGAteen
fpgatten-z19p
FPGATTEN_PLATFORM_CHECK=PASS
ROOTFS=/dev/mmcblk1p2 ext4 rw,...
/dev/fpgatten-attention=READY
/dev/fpgatten-memory=READY
```

需要显示底层 UIO 地址时输入：

```sh
for u in /sys/class/uio/uio*; do
    [ -d "$u" ] || continue
    printf '%s  name=' "$(basename "$u")"
    cat "$u/name"
    printf '  addr='
    cat "$u/maps/map0/addr"
done
```

应能找到 Attention CSR `0xA0010000` 和 PL DDR `0xB0000000`。稳定设备名已经由系统建立，因此运行实验时不使用易变化的 `/dev/uio4`、`/dev/uio5`。

## 3. 分阶段真实数据验证

以下每个案例都会自动完成：案例 SHA-256 校验、从 SD 读取真实 Q/K/V、写入 PL DDR、启动 FPGA、读取输出、与 Thor FP32 Golden 比较并保存日志。Q/K/V 加载、DDR 写入和 Golden 比对均不计入 tokens/s。

### 阶段一：Decode 128 / Layer 0

```sh
fpgatten-run decode 128 0 3
```

只有该案例通过后，再执行长上下文案例。

### 阶段二：Decode 4096 / Layer 0、15、31

```sh
fpgatten-run decode 4096 0 3
fpgatten-run decode 4096 15 3
fpgatten-run decode 4096 31 3
```

### 阶段三：Decode 8192 / Layer 0、15、31

```sh
fpgatten-run decode 8192 0 3
fpgatten-run decode 8192 15 3
fpgatten-run decode 8192 31 3
```

### 阶段四：Prefill 128 / Layer 0、15、31

```sh
fpgatten-run prefill 128 0 1
fpgatten-run prefill 128 15 1
fpgatten-run prefill 128 31 1
```

## 4. 录屏推荐命令

正式录屏前先运行一次短案例：

```sh
clear
fpgatten-info
fpgatten-run decode 128 0 3
```

主展示使用真实 Layer 15，重复 20 次：

```sh
clear
fpgatten-run decode 4096 15 20
```

```sh
clear
fpgatten-run decode 8192 15 20
```

最后补充 Prefill：

```sh
clear
fpgatten-run prefill 128 15 1
```

已有同硬件、同 235 MHz 回放结果可用于核对，不应硬编码成当次实测值：

```text
Decode / Context 4096 / Layer 15：约 615.999741 tokens/s
Decode / Context 8192 / Layer 15：约 314.851899 tokens/s
```

每次录屏以本次串口输出为准。`314.851899 tokens/s` 是真实 Q/K/V Layer 15 回放结果；`314.595307 tokens/s` 是独立 Decode@8192 benchmark，二者不能混用。

## 5. 判断 PASS

成功案例末尾应出现：

```text
FPGATTEN_LLAMA3_REPLAY_RESULT ...
FPGATTEN_RUN_PASS log=/home/FPGAteen/results/...
```

并检查结果行中：

```text
nan_or_inf=0
violations_atol_0p02_rtol_0p002=0
```

只查看最近保存的结果：

```sh
ls -1t /home/FPGAteen/results/*.log | head
```

```sh
grep '^FPGATTEN_LLAMA3_REPLAY_RESULT' "$(ls -1t /home/FPGAteen/results/*.log | head -1)"
```

## 6. 异常时停止并检查

设备节点缺失：

```sh
systemctl status fpgatten-devices.service --no-pager
journalctl -u fpgatten-devices.service --no-pager
dmesg | grep -i uio
```

根文件系统不是 SD EXT4 或不是可写状态：

```sh
awk '$2 == "/" {print $1, $3, $4}' /proc/mounts
```

案例文件校验失败时，不要继续运行该案例。手工复核示例：

```sh
cd /opt/fpgatten/cases/decode/context_8192/layer_15
sha256sum -c SHA256SUMS
```

查看剩余空间：

```sh
df -h /
```

## 7. 关机

实验和日志保存完成后输入：

```sh
sync
systemctl poweroff
```

等待串口显示系统已停止并确认板卡不再访问 SD 卡后，再断电或取卡。
