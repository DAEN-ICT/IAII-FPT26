# -*- coding: utf-8 -*-
"""
config_attn.py

用途：
    专门保存 GQA Attention golden model 的配置参数。
    后续 Verilog/SystemVerilog testbench 也要尽量使用同一套参数，
    避免 Python 维度和 RTL 维度不一致。

设计原则：
    1. 先用小规模 smoke 配置验证 RTL 逻辑。
    2. 再切换到 Llama3-8B 的真实配置。
    3. 所有维度都集中在这里，golden_model.py 不直接写死参数。
"""

from dataclasses import dataclass
import torch


@dataclass
class AttnConfig:
    """
    GQA Attention 配置。

    hidden_size:
        Transformer hidden dimension。
        Llama3-8B 真实值是 4096。

    num_heads:
        Q head 数量。
        Llama3-8B 真实值是 32。

    num_kv_heads:
        K/V head 数量。
        Llama3-8B 使用 GQA，真实值是 8。

    head_dim:
        每个 attention head 的维度。
        Llama3-8B 真实值是 128。

    seq_len:
        当前 decode 要访问的 KV cache 长度。
        smoke test 先用 8，后续可改为 512/1024/4096/8192。

    rope_theta:
        RoPE 的 theta。
        Llama3-8B 使用 500000.0。

    dtype:
        存储数据类型。这里使用 torch.bfloat16，对应硬件 bf16。
    """

    hidden_size: int = 64
    num_heads: int = 4
    num_kv_heads: int = 2
    head_dim: int = 16
    seq_len: int = 8
    rope_theta: float = 500000.0
    dtype: torch.dtype = torch.bfloat16

    # 是否使用硬件友好的 online softmax 作为 attention 参考。
    # True：输出 attn_mid_online，便于对拍 softmax_osm.v / attn_core.v。
    # False：只使用 torch.softmax 参考。
    use_online_softmax: bool = True

    # 生成测试数据的随机种子。
    seed: int = 123

    # 当前 token 的 position id。
    # decode 时通常等于当前 token 在上下文中的位置。
    pos_id: int = 3

    # 输出 .mem 文件目录。
    dump_dir: str = "data/smoke"

    @property
    def q_dim(self) -> int:
        """Q 总维度 = num_heads * head_dim。"""
        return self.num_heads * self.head_dim

    @property
    def kv_dim(self) -> int:
        """K/V 总维度 = num_kv_heads * head_dim。"""
        return self.num_kv_heads * self.head_dim

    @property
    def gqa_group_size(self) -> int:
        """
        每个 KV head 被多少个 Q head 共享。
        Llama3-8B: 32 / 8 = 4。
        """
        assert self.num_heads % self.num_kv_heads == 0
        return self.num_heads // self.num_kv_heads

    def check(self) -> None:
        """检查配置是否合法。"""
        assert self.hidden_size == self.q_dim, (
            f"当前实现假设 hidden_size == num_heads * head_dim，"
            f"但 hidden_size={self.hidden_size}, q_dim={self.q_dim}"
        )
        assert self.num_heads % self.num_kv_heads == 0, (
            "GQA 要求 num_heads 必须能被 num_kv_heads 整除"
        )
        assert self.head_dim % 2 == 0, "RoPE 要求 head_dim 是偶数"
        assert self.seq_len >= 1, "seq_len 至少为 1"


def smoke_config() -> AttnConfig:
    """
    小规模配置：
        用于第一轮 RTL 验证。
        维度小，仿真快，适合先对拍 gemv/rope/attention。
    """
    return AttnConfig(
        hidden_size=64,
        num_heads=4,
        num_kv_heads=2,
        head_dim=16,
        seq_len=8,
        rope_theta=500000.0,
        seed=123,
        pos_id=3,
        dump_dir="data/smoke",
    )


def llama3_8b_config(seq_len: int = 512, pos_id: int = 511) -> AttnConfig:
    """
    Llama3-8B 真实 attention 维度配置：
        hidden_size = 4096
        num_heads = 32
        num_kv_heads = 8
        head_dim = 128

    注意：
        真实配置会生成很大的权重和 .mem 文件。
        第一次不要直接用真实配置跑全部 dump。
    """
    return AttnConfig(
        hidden_size=4096,
        num_heads=32,
        num_kv_heads=8,
        head_dim=128,
        seq_len=seq_len,
        rope_theta=500000.0,
        seed=123,
        pos_id=pos_id,
        dump_dir=f"data/llama3_seq{seq_len}",
    )
