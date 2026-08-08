# FPGAtten Vivado 2025.2 最终验证记录

验证日期：2026-08-08

## 隔离性

- 原 `FPGAtten/rtl` 与 `FPGAtten/vivado`：138 个文件
- 缺失：0
- 大小差异：0
- SHA-256 差异：0
- 额外文件：0
- 汇总：`ORIGINAL_2024_2_MISMATCHES=0`

## 本地结构检查

- PowerShell 解析错误：0
- Tcl：21 个，结构不完整：0
- XDC：3 个，结构不完整：0
- XCI：3 个，JSON 解析错误：0
- Markdown：全部可按 UTF-8 严格读取
- 可移植 ZIP：1,212 个条目，CRC 损坏项：0
- 异机路径重开：工程校验通过，归档内实现 Tcl hook 存在且不依赖原构建路径

## 远程 Vivado 2025.2 验证

- 主机：`DESKTOP-608D0QK`
- Vivado：2025.2，SW Build 6299465
- 器件：`xczu19eg-ffvc1760-2-i`
- 环境探测：通过
- 工程创建：通过
- 工程重新打开与 BD 校验：通过
- IP：全部 unlocked
- OOC 综合：通过
- 顶层综合：通过
- 实现与 bitstream：通过
- XSA：通过

最终指标：Core 235 MHz、DMA 300 MHz、`WNS=+0.017 ns`、`TNS=0`、`WHS=+0.010 ns`、`THS=0`、DRC error 0、route `ROUTED`。

## 产物完整性

- 可移植工程：`release/FPGAtten_2025_2_project_with_runs.zip`
- bitstream：`release/hardware/FPGAtten_2025_2_z19p.bit`
- XSA：`release/hardware/FPGAtten_2025_2_z19p.xsa`
- 远程逐文件清单：`release/REMOTE_SHA256_MANIFEST.csv`
- 本地最终清单：`migration/final_2025.2_sha256.csv`

本地最终清单覆盖 `FPGAtten/2025.2` 下除清单自身以外的全部文件。
