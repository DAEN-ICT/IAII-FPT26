# FPGAtten Vivado 2025.2 迁移状态

## 隔离策略

- 新工程根目录：`FPGAtten/2025.2`
- 原 `FPGAtten/rtl`、`FPGAtten/vivado` 与 2024.2 产物：只读保留
- 原始文件基线：`original_2024.2_source_sha256.csv`
- 内部 `gqav5/gqav7` RTL、BD 与寄存器接口名称：保持不变

## 已确认的远程环境

- 主机：`DESKTOP-608D0QK`
- 系统：Windows 10.0.26100.3323
- Vivado：2025.2，SW Build 6299465
- 安装目录：`C:\AMDDesignTools\2025.2\Vivado`
- SSH Host Key：`ssh-ed25519 SHA256:gcytuWvLZGoUkDRYaz/BrG0qyL2E/8ycsmwl168Wm/U`

## 验证门禁

本地检查：原 2024.2 输入 SHA-256 差异数为 0；2025.2 PowerShell 入口可解析；当前 21 个 Tcl（20 个脚本与 1 个 preset）结构完整；全部 filelist 引用存在；创建与构建 Tcl 的输入路径自检通过。远程实测进一步完成了工程创建、重开、综合、实现和产物导出。

| 阶段 | 状态 | 证据 |
|---|---|---|
| 器件与 IP 环境探测 | 通过 | `FPGATTEN_2025_2_ENVIRONMENT_PASS=1` |
| 2025.2 工程创建 | 通过 | `FPGAtten_z19p.xpr` |
| IP 升级且 locked=0 | 通过 | 3 个种子 IP 与全部 BD IP 均 `locked=0` |
| Block Design 校验 | 通过 | 235/300 MHz 与四段地址映射逐项一致 |
| OOC 与顶层综合 | 通过 | OOC、`synth_1` 均为 0 error / 0 critical warning |
| 实现、DRC、时序 | 通过 | WNS `+0.017 ns`，WHS `+0.010 ns`，DRC error 0，`ROUTED` |
| bitstream / XSA | 通过 | `release/hardware/FPGAtten_2025_2_z19p.bit/.xsa` |
| 工程重新打开验证 | 通过 | `FPGATTEN_2025_2_PROJECT_VALIDATION_PASS=1` |
| 可移植工程归档 | 通过 | `release/FPGAtten_2025_2_project_with_runs.zip`，CRC 校验无错误 |

## 最终产物

- 完整构建结束时间：2026-08-08 17:33（北京时间）
- 可移植工程归档：577,348,298 字节，1,212 个 ZIP 条目，包含 1 个 XPR、30 个 DCP、实现 bitstream 和内部实现 Tcl hook
- 归档 SHA-256：`c396415b10759c6e7719bde09b4e4ab0fbe94b8d4505126fbb57aa62f72b7d17`
- 下载与验证：57 个文件、625,888,757 字节逐文件 SHA-256 一致
- 归档异机路径重开：工程/BD 校验通过，`impl_1` hook 位于归档内部并通过可移植性门禁
- 详细指标：`release/hardware/reports/physical_metrics.kv`
- 远程证据：`release/remote_logs/`

## 迁移原则

当前归档没有可升级的 `.xpr/.bd/.dcp`，因此 2025.2 版本必须从 RTL、XCI、XDC 和 Tcl 全新生成，不能把 2024.2 XSA 当作可编辑工程。三份旧 XCI 只作为迁移种子，在新工程副本中通过 Vivado `upgrade_ip` 升级，禁止手改 `SWVERSION`。
