# FPGAtten 串口 Shell 命令清单

本清单适用于本目录中的正式 SD 镜像。所有命令都在板卡的 PetaLinux 串口 Shell 中输入，不需要 PowerShell、SSH、JTAG 数据预装或 `sudo`。

## 1. 登录

串口参数：115200 bit/s、8-N-1、无流控。

```text
login: FPGAteen
password: root
```

账号区分大小写；输入密码时终端不回显字符。

## 2. 开机检查

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

## 3. 分阶段真实数据验证

程序自动校验并从 SD 读取真实 Q/K/V；数据加载、PL DDR 写入和 Golden 比对不计入 tokens/s。

```sh
fpgatten-run decode 128 0 3

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

## 4. 录屏主命令

```sh
clear
fpgatten-info
fpgatten-run decode 128 0 3
```

```sh
clear
fpgatten-run decode 4096 15 20
```

```sh
clear
fpgatten-run decode 8192 15 20
```

```sh
clear
fpgatten-run prefill 128 15 1
```

成功案例末尾应出现 `FPGATTEN_LLAMA3_REPLAY_RESULT` 和 `FPGATTEN_RUN_PASS`，且结果中应为：

```text
nan_or_inf=0
violations_atol_0p02_rtol_0p002=0
```

## 5. 日志与关机

```sh
ls -1t /home/FPGAteen/results/*.log | head
grep '^FPGATTEN_LLAMA3_REPLAY_RESULT' "$(ls -1t /home/FPGAteen/results/*.log | head -1)"
df -h /
sync
systemctl poweroff
```

等待系统停止且 SD 卡不再被访问后，再断电或取卡。完整排障说明见 `SD卡制作与启动说明.md` 和 PC 端 `petalinux/docs/FPGAtten_串口命令清单.md`。
