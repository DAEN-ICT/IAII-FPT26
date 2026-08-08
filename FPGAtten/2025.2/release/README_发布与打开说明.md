# FPGAtten Vivado 2025.2 发布与打开说明

## 直接打开已验证工程

1. 安装 Vivado 2025.2，并确保包含 `xczu19eg` / Zynq UltraScale+ MPSoC 器件支持及可用许可证。
2. 将 `FPGAtten_2025_2_project_with_runs.zip` 解压到较短的纯英文路径，例如 `D:\FPGAtten_2025_2`。
3. 用 Vivado 2025.2 打开 `FPGAtten_z19p\FPGAtten_z19p.xpr`。
4. 不要直接在 ZIP 内打开，不要用 Vivado 2024.2 保存工程。

归档包含已完成的综合与实现结果。ZIP 已执行完整 CRC 校验：1,212 个条目，无损坏项；归档在新的解压路径中重新打开并通过工程校验，`impl_1` 的 Tcl hook 也已确认位于归档内部。

## 正式硬件产物

`hardware/` 中包含：

- `FPGAtten_2025_2_z19p.bit`
- `FPGAtten_2025_2_z19p.xsa`
- `reports/` 下的 DRC、CDC、时序、利用率、拥塞、IP、时钟、路由和总线偏斜报告

关键结果：Core 235 MHz、DMA 300 MHz、`WNS=+0.017 ns`、`WHS=+0.010 ns`、DRC error 0、route `ROUTED`、locked IP 0。

## 完整性

- 可移植工程归档 SHA-256：`c396415b10759c6e7719bde09b4e4ab0fbe94b8d4505126fbb57aa62f72b7d17`
- bitstream SHA-256：`d57191bcd9d6d40658926473c08cf035e321e357df1336e2b23e8b5bd3b6895a`
- XSA SHA-256：`ca263eebc0bc760876374cbd9bd1085302ae742effc1b48654e4342f3676336b`
- `REMOTE_SHA256_MANIFEST.csv`：远程生成的逐文件清单，下载后已逐项复核通过
- `remote_logs/`：远程环境安装、探测、工程创建、验证、完整构建和归档日志

原 `FPGAtten/rtl`、`FPGAtten/vivado` 和全部 2024.2 产物未被覆盖或升级。
