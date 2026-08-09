# FPGAtten

本仓库包含面向 Llama3-8B BF16 GQA Attention 的 FPGA 加速器源码、Vivado 2024.2/2025.2 工程输入、板端软件、验证代码、实验代码与结果。

项目内容位于 [`FPGAtten/`](FPGAtten/README.md)。比赛正式工具版本为 Vivado 2025.2；Vivado 2024.2 内容作为兼容基线保留。

最终双版本比赛提交包及SHA-256校验文件位于 [`submission/`](submission/README.md)。

## 仓库范围

本仓库保留：

- RTL、filelist、Softmax ROM；
- Vivado 2024.2 与 2025.2 Tcl、XCI、XDC、bitstream、XSA 和签核报告；
- AArch64 板端软件、JTAG/PetaLinux 构建脚本；
- CPU、GPU、FPGA 性能与真实 Llama3-8B Q/K/V 回放代码；
- 跨平台实验数据和复现说明。

由于 GitHub 单文件与仓库存储限制，未提交可重新生成的大型文件，包括 WIC、rootfs、JTAG 系统镜像、PetaLinux 历史归档、Vivado runs/cache 以及 577 MB 的完整实现工程归档。排除规则见 [`.gitignore`](.gitignore)。
