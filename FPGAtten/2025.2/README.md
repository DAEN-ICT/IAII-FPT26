# FPGAtten Vivado 2025.2 工程

本目录是从现有 FPGAtten RTL 与板级 Tcl 输入建立的独立 Vivado 2025.2 工程包。上级目录中的 2024.2 工程和产物不被打开、升级或覆盖。

本目录已经在远程 Vivado 2025.2 实际完成工程创建、IP 升级、工程重开验证、全部综合、实现、bitstream、XSA 和可移植工程归档，不是仅做了文本版本替换。

## 固定配置

- 器件：`xczu19eg-ffvc1760-2-i`
- Attention 核心：235 MHz
- DMA / PL DDR4 UI：300 MHz
- PL DDR4 参考时钟：200 MHz
- CSR：`0xA0010000 / 4 KiB`
- PS PL-DDR 窗口：`0xB0000000 / 256 MiB`
- 两路 Attention PL-DDR 地址空间：`0x00000000 / 2 GiB`

内部 RTL、filelist、BD 和层级中的 `gqav5/gqav7` 是兼容接口，本次工具迁移不改名。用户可见工程和发布文件使用 `FPGAtten`。

## 环境检查

```powershell
& 'C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat' -mode batch -notrace `
  -source .\vivado\board\scripts\probe_2025_2_environment.tcl
```

成功标志：`FPGATTEN_2025_2_ENVIRONMENT_PASS=1`。

## 创建并完整构建

在本目录执行：

```bat
.\vivado\build_fpgatten_2025_2.cmd -CoreMHz 235 -Jobs 4
```

脚本会精确检查 Vivado 2025.2，从源码新建 `FPGAtten_z19p.xpr`，升级新工程副本中的 IP，校验 BD、时钟和地址映射，并完成综合、实现、DRC、时序、bitstream 与 XSA 导出。

仅做与旧流程的受控对比时才关闭 post-route physical optimization：

```bat
.\vivado\build_fpgatten_2025_2.cmd -CoreMHz 235 -Jobs 4 -DisablePostRoutePhysOpt
```

## 验证与打开

最快的打开方式是解压：

`release/FPGAtten_2025_2_project_with_runs.zip`

建议解压到较短的纯英文路径（例如 `D:\FPGAtten_2025_2`），然后用 Vivado 2025.2 打开：

`FPGAtten_z19p/FPGAtten_z19p.xpr`

该归档包含已完成的综合与实现结果。不要直接在 ZIP 内打开工程，也不要用 Vivado 2024.2 保存该工程。

从本目录源码重新创建工程后，可用下列命令验证：

```powershell
& 'C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat' -mode batch -notrace `
  -source .\vivado\board\scripts\validate_project_2025_2.tcl `
  -tclargs .\vivado\project\<构建目录>\FPGAtten_z19p.xpr
```

成功标志：`FPGATTEN_2025_2_PROJECT_VALIDATION_PASS=1`。

## 发布产物

已验证产物位于 `release/hardware/`：

- `FPGAtten_2025_2_z19p.bit`
- `FPGAtten_2025_2_z19p.xsa`
- `reports/physical_metrics.kv`
- IP、DRC、CDC、时序、利用率、拥塞和总线偏斜报告

本次实测结果：

- Vivado：2025.2，SW Build 6299465
- 器件：`xczu19eg-ffvc1760-2-i`
- Core / DMA：235 MHz / 300 MHz
- Setup：`WNS=+0.017 ns`、`TNS=0`
- Hold：`WHS=+0.010 ns`、`THS=0`
- DRC error：0
- Route：`ROUTED`
- Locked IP：0
- `FPGAtten_2025_2_z19p.bit`：36,343,259 字节
- `FPGAtten_2025_2_z19p.xsa`：7,666,720 字节

`release/REMOTE_SHA256_MANIFEST.csv` 是远程生成并在下载后逐文件复核的清单；`release/remote_logs/` 保存环境、工程创建、验证、构建和归档日志。

迁移完成以远程 Vivado 2025.2 实际生成并验证的工程、报告和产物为准，不能只以 Tcl 语法通过判断。
