# FPGAtten PetaLinux 2024.2

本目录用于从已验证的 Z19-P XSA 构建正式命名的 FPGAtten 板端系统。它只调整 PetaLinux、Device Tree 的 Linux 节点名称和用户态软件，不改动 RTL、寄存器地址、时钟或硬件 ABI。

## 固定配置

- 产品名：`FPGAtten`
- 主机名：`fpgatten-z19p`
- 串口账号：`FPGAteen`
- 串口密码：`root`
- RootFS：SD 卡第二分区 `/dev/mmcblk1p2`，EXT4，可读写
- Attention CSR：`0xA0010000`
- PL DDR 窗口：`0xB0000000`，大小 `0x10000000`
- 核心时钟：235 MHz
- DMA 时钟：300 MHz
- SSH：关闭

## 目录

```text
petalinux/
├── hardware/                  # 只读硬件输入副本与 bitstream
├── source/                    # meta-user 配方、设备树和真实案例
├── scripts/                   # 创建、配置、构建和验收脚本
├── docs/                      # 随 SD 产物发布的说明
└── archive/                   # 旧的独立输出，供回退
```

最终产物生成在：

```text
FPGAtten/FPGAtten_PetaLinux_SD/
```

若该目录已经存在，构建脚本会先把它整体移动到 `petalinux/archive/<UTC时间>_FPGAtten_PetaLinux_SD/`，不会覆盖旧产物。

## 构建顺序

在安装了 PetaLinux 2024.2 的 x86_64 Linux/WSL 环境中，以普通用户运行：

```bash
bash petalinux/scripts/create_project_from_xsa.sh
bash petalinux/scripts/configure_project.sh
bash petalinux/scripts/build_sd_image.sh
bash petalinux/scripts/verify_artifacts.sh
```

构建脚本会核对 XSA 与 bitstream SHA-256。任何哈希、配方、设备树、账号或案例校验失败都会停止，不会发布半成品目录。

## 不变与变化

不变：XSA、bitstream、RTL、CSR、IRQ、PL DDR 地址、235/300 MHz 时钟。

变化：系统身份、账号、用户态程序名、UIO 稳定设备名、SD EXT4 rootfs、随系统安装的真实 Llama3-8B Q/K/V 案例。
