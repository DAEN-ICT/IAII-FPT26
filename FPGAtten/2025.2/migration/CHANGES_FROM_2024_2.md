# 相对 2024.2 输入的变更

本次仅修改 `FPGAtten/2025.2` 副本。原 `FPGAtten/rtl` 和 `FPGAtten/vivado` 已通过 `original_2024.2_source_sha256.csv` 复核，未发生变化。

## 保持不变

- 全部 RTL、Softmax ROM 和 filelist
- Z19-P 引脚与 CDC 约束
- PS preset、MIG 参数和硬件地址映射
- 内部模块、BD、寄存器和层级中的 `gqav5/gqav7` 兼容名称
- Core 235 MHz、DMA 300 MHz、PL DDR4 参考时钟 200 MHz

## 2025.2 适配

- Vivado 版本门禁由 2024.2 改为精确要求 2025.2。
- 新工程名为 `FPGAtten_z19p.xpr`，发布文件为 `FPGAtten_2025_2_z19p.bit/.xsa`。
- 修复 Windows 构建入口的默认工程根目录推导。
- 构建入口自动查找 `C:\AMDDesignTools\2025.2\Vivado` 等标准路径，并验证实际版本。
- 仅允许当前真实配置 235 MHz，移除不可用的 240 MHz 参数入口。
- 新工程导入三份旧 XCI 后执行 `upgrade_ip`、重新生成 output products，并要求 locked IP 数为 0。
- 新增器件/IP环境探测和工程重新打开验证脚本。
- 新增 IP 状态报告、Vivado 版本和 IPDEF（VLNV 标识）到物理指标文件。
- 将 Vivado 2025.2 已移除的 IP 对象 `VLNV` 属性读取改为 `IPDEF`。
- 将 SystemVerilog 文件类型设置限制在显式导入的 RTL，避免误操作 MIG 管理文件。
- 适配 Vivado 2025.2 的 route status 报告格式，并在时序全部通过时明确记录 `TNS=0`、`THS=0`。
- 新增包含综合与实现结果的可移植工程归档脚本。
- 将实现阶段 reset/CDC Tcl hook 纳入 `utils_1`，使归档在其他路径重新打开后仍可重新启动实现。
- 2025.2 默认保留实现策略中的 post-route physical optimization；可用显式开关做旧流程兼容对比。

首次 2025.2 构建暂时保留 accelerator OOC DCP 的 scoped compatibility binding。待实际综合确认 2025.2 顶层不会再留下 black box 后，才可在后续独立版本中删除，不能在迁移同时盲目移除。

首次受控迁移构建使用 `-DisablePostRoutePhysOpt`，以保持与既有稳定流程一致；该构建已在 235 MHz Core / 300 MHz DMA 下通过 setup、hold、DRC 和完整布线。恢复 post-route physical optimization 应作为后续独立性能实验，不与本次版本迁移混合。
