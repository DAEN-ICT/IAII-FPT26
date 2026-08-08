# Vivado 2024.2 硬件基线

本文件只记录迁移前产物，不复制或修改原产物。

| 产物 | 字节数 | SHA-256 |
|---|---:|---|
| `FPGAtten/jtag_runtime/images/system.bit` | 36,343,243 | `243ac8c0ec7ca12b4ee9bb4d6f63e7984ae760816c8b70697c7095725d8643dc` |
| `FPGAtten/petalinux/hardware/FPGAtten_Z19P.bit` | 36,343,243 | `5ec632e213613c23c6ed2a7fcb90989d0799ee77e7427710dfe6757306d08f81` |
| `FPGAtten/petalinux/hardware/FPGAtten_Z19P.xsa` | 7,770,578 | `ec93c372b368b92949e9fe99df502f18f604c38153726759c20179753d89a655` |

两份 `.bit` 的完整 SHA-256 因头部时间戳不同而不同，但从偏移 `0x80` 开始的配置 payload SHA-256 相同：

```text
9c655a42935a06736866c973771d4263e32454033ac1c2f16563ea2ba0b97020
```

旧 XSA 内嵌的 `GQAv7_z19p.bit` 与 JTAG `system.bit` 完全一致，XSA 元数据显示其生成工具为 Vivado 2024.2。迁移后不能要求 2025.2 bitstream 与旧 payload SHA 相同；应比较 RTL 输入、时钟、地址映射、资源、DRC/时序和实板功能。
