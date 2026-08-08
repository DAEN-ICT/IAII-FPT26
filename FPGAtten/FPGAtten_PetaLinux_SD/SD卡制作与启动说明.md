# FPGAtten SD 卡制作与启动说明

## 1. 适用范围

本产物面向 Z19-P（Zynq UltraScale+ MPSoC），由同一份已验证硬件 XSA/bitstream 构建。PetaLinux、设备树的 Linux 节点名和用户态程序采用 FPGAtten 命名，RTL、地址映射和时钟没有修改。

系统信息：

| 项目 | 值 |
|---|---|
| PetaLinux | 2024.2 |
| 主机名 | `fpgatten-z19p` |
| 串口账号 | `FPGAteen` |
| 串口密码 | `root` |
| 串口参数 | 115200 bit/s、8 数据位、无校验、1 停止位、无流控 |
| 根文件系统 | SD 第二分区，EXT4，可读写 |
| Linux 根分区 | `/dev/mmcblk1p2` |
| SSH | 默认关闭 |

## 2. 产物说明

完整烧卡优先使用：

- `FPGAtten_Z19P.wic.xz`：压缩的完整 SD 镜像，推荐。
- `FPGAtten_Z19P.wic`：未压缩的完整 SD 镜像。

可追溯和手工分区使用：

- `BOOT.BIN`：FSBL、PMU firmware、bitstream、TF-A 和 U-Boot 启动包。
- `boot.scr`：U-Boot 启动脚本。
- `Image`：Linux 内核。
- `system.dtb`：设备树。
- `rootfs.tar.gz`：EXT4 根文件系统内容。
- `rootfs.ext4`：PetaLinux 生成的根文件系统镜像（存在时提供）。
- `BUILD_MANIFEST.txt`：构建环境、硬件哈希和固定参数。
- `BUILD_LOG.txt`：完整构建日志。
- `SHA256SUMS`：本目录文件校验值。
- `FPGAtten_串口命令清单.md`：开机后可直接逐行输入的板端验证与录屏命令。
- `FPGAtten_一般录制视频串口命令清单.md`：按实际拍摄镜头顺序整理的精简命令清单。

不要把 `image.ub`、`rootfs.cpio.gz.u-boot` 或 `ramdisk.cpio.gz.u-boot` 放入 BOOT 分区。本系统使用 SD 上的 EXT4 rootfs，不使用 RAM rootfs。

## 3. Windows 文件管理器手动更新 BOOT 分区

如果这张 SD 卡此前已经写入本目录的完整 FPGAtten WIC 镜像，并且现在能在 Windows 文件管理器中看到卷标为 `BOOT` 的分区，则只需要从本产物目录复制以下四个文件到 SD 卡 `BOOT` 分区的根目录：

```text
BOOT.BIN
boot.scr
Image
system.dtb
```

Windows 中的源目录为：

```text
C:\Users\Lenovo\Desktop\FPT\FPGAtten\FPGAtten_PetaLinux_SD
```

具体操作：

1. 确保 Z19-P 已完全断电，再把 SD 卡插入 Windows 读卡器。
2. 在文件管理器中确认目标盘卷标确实为 `BOOT`；不要选中系统盘或其他移动磁盘。
3. 打开上述源目录，选中 `BOOT.BIN`、`boot.scr`、`Image`、`system.dtb`。
4. 使用“复制”，不要使用“剪切”，将四个文件粘贴到 `BOOT` 盘符的最外层，不能放入子文件夹。
5. 若 Windows 提示同名文件已存在，四个文件全部选择“替换目标中的文件”，不能只替换其中一部分。
6. 复制结束后确认四个文件都存在且大小不为 0，然后使用 Windows 的“安全删除硬件并弹出媒体”。

不要复制到 `BOOT` 分区：

```text
FPGAtten_Z19P.wic
FPGAtten_Z19P.wic.xz
rootfs.ext4
rootfs.tar.gz
SHA256SUMS
BUILD_LOG.txt
BUILD_MANIFEST.txt
任何 .md 说明文件
```

重要前提：手动复制四个 BOOT 文件只是在更新启动分区。SD 卡第二分区必须已经是本版 FPGAtten 的 `RootFS` EXT4，并且其中已经包含 `/usr/bin/fpgatten-run` 和 `/opt/fpgatten/cases`。Windows 看不到 EXT4 属于正常现象，但可以在“磁盘管理”中看到约 379 MiB 的第二分区；不要格式化它。

如果 SD 卡只有一个 FAT32 BOOT 分区，或者第二分区是旧系统、空分区或不确定来源，仅复制这四个文件不能得到完整 FPGAtten 系统。此时必须按第 5 节重新写入完整 `FPGAtten_Z19P.wic.xz` 镜像。

## 4. 写卡前的安全检查

写入完整镜像会清空目标 SD 卡上的所有分区和数据。先完成以下检查：

1. 备份 SD 卡中需要保留的文件。
2. 拔掉其他不相关的 U 盘、移动硬盘和读卡器，减少选错盘的风险。
3. 记录 SD 卡容量和设备名称；容量必须足以容纳 `.wic` 镜像。
4. 在本目录核对 SHA-256。Windows 可使用 7-Zip 的“CRC SHA → SHA-256”，Linux 可运行 `sha256sum -c SHA256SUMS`。
5. 写卡前板卡必须完全断电。

## 5. 推荐写卡方法：完整镜像

可以使用 balenaEtcher 或 Raspberry Pi Imager：

1. 打开写卡软件，选择 `FPGAtten_Z19P.wic.xz`。若软件不识别压缩文件，先解压后选择 `FPGAtten_Z19P.wic`。
2. 选择目标 SD 卡。再次核对容量和设备名称，不要选择系统盘。
3. 开始写入，并启用写后校验。
4. 等待写入和校验均完成，再在操作系统中安全弹出 SD 卡。

写卡完成后应有两个分区：

```text
分区 1：BOOT   FAT32  约 512 MiB
分区 2：RootFS EXT4  约 379 MiB（按当前 rootfs 内容和构建余量生成）
```

完整镜像约 891 MiB，建议使用容量不小于 2 GB 的 SD 卡。更大 SD 卡的剩余容量保持未分配；这不会影响当前 10 组案例运行和日志保存，但本镜像不会在首次启动时自动扩展 RootFS 至整张卡。

BOOT 分区只应包含以下四个启动文件：

```text
BOOT.BIN
boot.scr
Image
system.dtb
```

Windows 不识别 EXT4 分区属于正常现象，不要按照系统提示格式化 RootFS 分区。

## 6. Linux 命令行写卡（可选）

先用 `lsblk -o NAME,SIZE,MODEL,TRAN,MOUNTPOINTS` 精确识别 SD 卡。以下把 `/dev/sdX` 作为占位符，必须替换为整张 SD 卡设备，不能写成分区 `/dev/sdX1`。

写入压缩镜像：

```bash
xzcat FPGAtten_Z19P.wic.xz | sudo dd of=/dev/sdX bs=16M status=progress conv=fsync
sync
```

或写入未压缩镜像：

```bash
sudo dd if=FPGAtten_Z19P.wic of=/dev/sdX bs=16M status=progress conv=fsync
sync
```

写入前后都应重新运行 `lsblk` 核对目标。若设备名称、容量或型号有任何疑问，立即停止，不要执行 `dd`。

## 7. 手工制作两分区 SD 卡（仅在不能写入 WIC 时使用）

1. 建立 MBR 分区表。
2. 从 4 MiB 对齐位置建立约 512 MiB 的 FAT32 主分区，卷标为 `BOOT`，设置 boot 标志。
3. 用剩余空间建立 EXT4 主分区，卷标为 `RootFS`。
4. 把且仅把 `BOOT.BIN`、`boot.scr`、`Image`、`system.dtb` 复制到 BOOT 分区根目录。
5. 在 Linux 上以 root 权限把 `rootfs.tar.gz` 解包到 RootFS 分区根目录，必须保留权限、所有者、符号链接和设备节点。
6. 执行 `sync`，卸载两个分区，再安全拔出 SD 卡。

手工解包示例中的挂载点需自行创建并替换：

```bash
sudo tar --numeric-owner -xpf rootfs.tar.gz -C /media/RootFS
sync
```

## 8. 板卡从 SD 启动

1. 板卡完全断电。
2. 插入写好的 SD 卡。
3. 将 Z19-P 的启动模式拨到 SD：SW1 的 1、2、3、4 位依次为 `ON、OFF、ON、OFF`，即 `MODE[3:0] = 0101`。若板卡修订版丝印或手册与此不同，以该修订版原理图/用户手册为准。
4. 连接 USB-UART，串口终端设置为 115200、8-N-1、无流控。
5. 上电，保持串口窗口打开，等待 Linux 登录提示。
6. 输入账号 `FPGAteen`，密码 `root`。Linux 输入密码时不回显字符，这是正常现象。

## 9. 首次启动核对

登录后直接在 PetaLinux shell 中逐行输入：

```sh
whoami
hostname
awk '$2 == "/" {print $1, $3, $4}' /proc/mounts
cat /etc/fpgatten-release
fpgatten-info
ls -l /dev/fpgatten-attention /dev/fpgatten-memory
find /opt/fpgatten/cases -mindepth 3 -maxdepth 3 -type d | sort
```

关键期望值：

```text
whoami                 -> FPGAteen
hostname               -> fpgatten-z19p
根文件系统设备         -> /dev/mmcblk1p2
根文件系统类型         -> ext4
挂载状态               -> rw
FPGATTEN_PLATFORM_CHECK -> PASS
```

建议完全断电再上电，连续验证三次。三次都应在不连接 JTAG 的情况下进入同一系统，并保持根文件系统为 `/dev/mmcblk1p2`、EXT4、可读写。

## 10. 真实数据快速验证

程序从 SD 读取 Q/K/V 并写入 PL DDR；数据加载、Golden 比对不计入 tokens/s。

先验证 Decode 128、Layer 0：

```sh
fpgatten-run decode 128 0 3
```

再验证长上下文：

```sh
fpgatten-run decode 4096 0 3
fpgatten-run decode 4096 15 3
fpgatten-run decode 4096 31 3
fpgatten-run decode 8192 0 3
fpgatten-run decode 8192 15 3
fpgatten-run decode 8192 31 3
```

Prefill 真实数据：

```sh
fpgatten-run prefill 128 0 1
fpgatten-run prefill 128 15 1
fpgatten-run prefill 128 31 1
```

更适合录屏的 Layer 15、20 次重复命令及排障命令见同目录 `FPGAtten_串口命令清单.md`。

每次运行都会先校验案例 SHA-256，并把完整日志写入：

```text
/home/FPGAteen/results/
```

## 11. 回退

本次构建不会覆盖原有工程或原启动介质。需要回退时：

1. 板卡完全断电。
2. 取出 FPGAtten SD 卡，换回原 SD 卡；或恢复原来的启动模式拨码。
3. 重新上电。

PC 上上一版独立构建产物保存在 `petalinux/archive/` 的 UTC 时间目录中。不要在板卡带电时插拔 SD 卡或改变启动模式拨码。

## 12. 常见问题

- 停在 U-Boot：检查 BOOT 分区是否为 FAT32、是否带 boot 标志、四个文件是否在分区根目录并通过 SHA-256。
- Kernel panic 且提示找不到 root：检查第二分区卷标/文件系统，确认是 EXT4，并确认串口内核参数含 `/dev/mmcblk1p2 rootwait rw rootfstype=ext4`。
- Windows 提示格式化第二分区：取消，不要格式化；这是 Windows 不识别 EXT4。
- `/dev/fpgatten-*` 不存在：运行 `systemctl status fpgatten-devices.service`，再检查 `/sys/class/uio/` 和 `dmesg | grep -i uio`。
- 账号登录失败：严格区分大小写，账号为 `FPGAteen`，不是 `fpgatten` 或 `FPGAtten`。
