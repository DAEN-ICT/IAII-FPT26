# -*- coding: utf-8 -*-
"""
golden_model.py

用途：
    为 GQA Attention Accelerator 生成 Python golden reference。

覆盖的硬件子链：
    X_norm
      ↓
    Q/K/V Projection
      ↓
    RoPE(Q, K)
      ↓
    KV cache 更新
      ↓
    GQA Attention: QK^T + softmax + PV
      ↓
    Wo Projection
      ↓
    Attention Output

输出：
    data/smoke/*.mem
    每个 .mem 文件每行一个 16-bit bf16 hex，适合 Verilog $readmemh。
"""

from pathlib import Path
from typing import Dict, Tuple
import argparse
import math

import torch

from config_attn import AttnConfig, smoke_config, llama3_8b_config


# ============================================================
# 1. 基础工具函数：bf16、hex dump、误差统计
# ============================================================

def to_bf16(x: torch.Tensor) -> torch.Tensor:
    """转换为 torch.bfloat16。"""
    return x.to(torch.bfloat16)


def tensor_to_bf16_u16_list(x: torch.Tensor):
    """
    将 torch Tensor 转换为 bf16 的 uint16 bit pattern 列表。

    为什么要这么做：
        Verilog 里 bf16 是 16-bit 数据。
        $readmemh 读取的是十六进制文本。
        所以 Python 要把 bf16 的真实 bit pattern 写成 4 位 hex。
    """
    x_bf16 = x.detach().cpu().contiguous().to(torch.bfloat16)

    # PyTorch 的 bfloat16 可以 view 成 int16，从而拿到底层 16-bit。
    x_i16 = x_bf16.view(torch.int16).reshape(-1).numpy()

    # int16 可能显示成负数，这里用 & 0xffff 转成无符号 16-bit。
    return [(int(v) & 0xFFFF) for v in x_i16]


def write_bf16_mem(path: Path, x: torch.Tensor) -> None:
    """
    将 Tensor 写成 Verilog $readmemh 可读的 bf16 hex 文件。
    每行一个 16-bit bf16。
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    values = tensor_to_bf16_u16_list(x)

    with open(path, "w", encoding="utf-8") as f:
        for v in values:
            f.write(f"{v:04x}\n")


def print_tensor_summary(name: str, x: torch.Tensor) -> None:
    """打印 Tensor 的形状、类型、前几个值，方便检查。"""
    flat = x.detach().cpu().reshape(-1)
    preview = flat[: min(6, flat.numel())]
    print(f"{name:16s} shape={tuple(x.shape)!s:18s} dtype={str(x.dtype):14s} preview={preview}")


def error_report(name: str, a: torch.Tensor, b: torch.Tensor) -> None:
    """打印两个 Tensor 的误差。"""
    a32 = a.to(torch.float32)
    b32 = b.to(torch.float32)
    diff = (a32 - b32).abs()

    mae = diff.mean().item()
    maxe = diff.max().item()
    print(f"[误差] {name}: MAE={mae:.6e}, MaxErr={maxe:.6e}")


# ============================================================
# 2. RoPE 相关函数
# ============================================================

def build_rope_cache(cfg: AttnConfig, pos_id: int) -> Tuple[torch.Tensor, torch.Tensor]:
    """
    生成当前 position 的 RoPE cos/sin。

    采用 Llama 常见 half-rotate 形式：
        dim 0 和 dim half 配对
        dim 1 和 dim half+1 配对
        ...
        dim half-1 和 dim head_dim-1 配对

    这里的公式：
        inv_freq[i] = 1 / theta^(i / half)
    因为 half = head_dim / 2，所以等价于常见写法：
        1 / theta^(2i / head_dim)
    """
    half = cfg.head_dim // 2
    idx = torch.arange(half, dtype=torch.float32)

    inv_freq = 1.0 / (cfg.rope_theta ** (idx / half))
    angle = float(pos_id) * inv_freq

    cos = torch.cos(angle).to(torch.bfloat16)
    sin = torch.sin(angle).to(torch.bfloat16)

    return cos, sin


def apply_rope_one_head(x: torch.Tensor, cos: torch.Tensor, sin: torch.Tensor) -> torch.Tensor:
    """
    对单个 head 做 RoPE。

    输入：
        x:   [head_dim]
        cos: [head_dim/2]
        sin: [head_dim/2]

    输出：
        y: [head_dim]
    """
    half = x.shape[0] // 2

    x_first = x[:half].to(torch.float32)
    x_second = x[half:].to(torch.float32)

    cos32 = cos.to(torch.float32)
    sin32 = sin.to(torch.float32)

    y_first = x_first * cos32 - x_second * sin32
    y_second = x_first * sin32 + x_second * cos32

    return torch.cat([y_first, y_second], dim=0).to(torch.bfloat16)


def apply_rope(x: torch.Tensor, cos: torch.Tensor, sin: torch.Tensor) -> torch.Tensor:
    """对多个 head 做 RoPE。"""
    outs = []
    for h in range(x.shape[0]):
        outs.append(apply_rope_one_head(x[h], cos, sin))
    return torch.stack(outs, dim=0)


# ============================================================
# 3. Q/K/V Projection 与 Wo Projection
# ============================================================

def qkv_projection(
    x_norm: torch.Tensor,
    wq: torch.Tensor,
    wk: torch.Tensor,
    wv: torch.Tensor,
    cfg: AttnConfig,
) -> Tuple[torch.Tensor, torch.Tensor, torch.Tensor]:
    """
    对应硬件：
        gemv_engine.v 被调用 3 次：
            Q = X_norm × Wq
            K = X_norm × Wk
            V = X_norm × Wv
    """
    q = torch.matmul(x_norm.to(torch.float32), wq.to(torch.float32)).to(torch.bfloat16)
    k = torch.matmul(x_norm.to(torch.float32), wk.to(torch.float32)).to(torch.bfloat16)
    v = torch.matmul(x_norm.to(torch.float32), wv.to(torch.float32)).to(torch.bfloat16)

    q = q.view(cfg.num_heads, cfg.head_dim)
    k = k.view(cfg.num_kv_heads, cfg.head_dim)
    v = v.view(cfg.num_kv_heads, cfg.head_dim)

    return q, k, v


def wo_projection(attn_mid: torch.Tensor, wo: torch.Tensor, cfg: AttnConfig) -> torch.Tensor:
    """
    对应硬件：
        复用 gemv_engine.v 做 Output Projection。
    """
    flat = attn_mid.reshape(cfg.hidden_size)
    out = torch.matmul(flat.to(torch.float32), wo.to(torch.float32)).to(torch.bfloat16)
    return out


# ============================================================
# 4. KV cache 与 GQA 映射
# ============================================================

def update_kv_cache(
    k_cache: torch.Tensor,
    v_cache: torch.Tensor,
    k_new_rot: torch.Tensor,
    v_new: torch.Tensor,
    token_slot: int,
) -> Tuple[torch.Tensor, torch.Tensor]:
    """对应 kv_mgr.v 的追加写功能。"""
    k_cache = k_cache.clone()
    v_cache = v_cache.clone()

    k_cache[token_slot] = k_new_rot
    v_cache[token_slot] = v_new

    return k_cache, v_cache


def q_head_to_kv_head(q_head: int, cfg: AttnConfig) -> int:
    """
    GQA 映射：每 gqa_group_size 个 Q head 共享一个 KV head。
    """
    return q_head // cfg.gqa_group_size


# ============================================================
# 5. Attention：标准 torch.softmax 版本
# ============================================================

def gqa_attention_decode_torch(
    q_rot: torch.Tensor,
    k_cache: torch.Tensor,
    v_cache: torch.Tensor,
    cfg: AttnConfig,
) -> torch.Tensor:
    """标准 PyTorch 参考版本。"""
    scale = 1.0 / math.sqrt(cfg.head_dim)
    outputs = []

    for q_head in range(cfg.num_heads):
        kv_head = q_head_to_kv_head(q_head, cfg)

        q = q_rot[q_head].to(torch.float32)
        k = k_cache[:, kv_head, :].to(torch.float32)
        v = v_cache[:, kv_head, :].to(torch.float32)

        scores = torch.matmul(k, q) * scale
        probs = torch.softmax(scores, dim=0)

        out = torch.matmul(probs, v)
        outputs.append(out)

    return torch.stack(outputs, dim=0).to(torch.bfloat16)


# ============================================================
# 6. Attention：硬件友好 online softmax 版本
# ============================================================

def online_softmax_one_head(
    q: torch.Tensor,
    k_seq: torch.Tensor,
    v_seq: torch.Tensor,
    cfg: AttnConfig,
) -> torch.Tensor:
    """
    单个 Q head 的 online softmax。

    对应硬件：
        softmax_osm.v + attn_core.v 内部状态。

    状态变量：
        m: 当前最大 score
        l: 当前 exp 累加和
        o: 当前 PV 未归一化累加向量

    更新公式：
        score = dot(q, k_t) / sqrt(head_dim)
        m_new = max(m, score)
        alpha = exp(m - m_new)
        beta  = exp(score - m_new)
        l_new = l * alpha + beta
        o_new = o * alpha + beta * v_t

    最后：
        out = o / l
    """
    q32 = q.to(torch.float32)
    k32 = k_seq.to(torch.float32)
    v32 = v_seq.to(torch.float32)

    scale = 1.0 / math.sqrt(cfg.head_dim)

    m = torch.tensor(-float("inf"), dtype=torch.float32)
    l = torch.tensor(0.0, dtype=torch.float32)
    o = torch.zeros(cfg.head_dim, dtype=torch.float32)

    for t in range(cfg.seq_len):
        score = torch.dot(q32, k32[t]) * scale

        m_new = torch.maximum(m, score)

        alpha = torch.exp(m - m_new)
        beta = torch.exp(score - m_new)

        l = l * alpha + beta
        o = o * alpha + beta * v32[t]

        m = m_new

    out = o / l
    return out.to(torch.bfloat16)


def gqa_attention_decode_online(
    q_rot: torch.Tensor,
    k_cache: torch.Tensor,
    v_cache: torch.Tensor,
    cfg: AttnConfig,
) -> torch.Tensor:
    """多个 Q head 的 online softmax GQA attention。"""
    outputs = []

    for q_head in range(cfg.num_heads):
        kv_head = q_head_to_kv_head(q_head, cfg)

        q = q_rot[q_head]
        k_seq = k_cache[:, kv_head, :]
        v_seq = v_cache[:, kv_head, :]

        out = online_softmax_one_head(q, k_seq, v_seq, cfg)
        outputs.append(out)

    return torch.stack(outputs, dim=0).to(torch.bfloat16)


# ============================================================
# 7. 主流程：完整 attention 子链
# ============================================================

def generate_inputs(cfg: AttnConfig) -> Dict[str, torch.Tensor]:
    """
    生成随机输入与权重。

    第一版用随机数据，不直接加载真实 Llama3 权重，便于先验证 RTL 功能。
    """
    torch.manual_seed(cfg.seed)

    x_norm = torch.randn(cfg.hidden_size).to(torch.bfloat16)

    wq = torch.randn(cfg.hidden_size, cfg.q_dim).to(torch.bfloat16)
    wk = torch.randn(cfg.hidden_size, cfg.kv_dim).to(torch.bfloat16)
    wv = torch.randn(cfg.hidden_size, cfg.kv_dim).to(torch.bfloat16)
    wo = torch.randn(cfg.hidden_size, cfg.hidden_size).to(torch.bfloat16)

    k_cache_init = torch.randn(cfg.seq_len, cfg.num_kv_heads, cfg.head_dim).to(torch.bfloat16)
    v_cache_init = torch.randn(cfg.seq_len, cfg.num_kv_heads, cfg.head_dim).to(torch.bfloat16)

    return {
        "x_norm": x_norm,
        "wq": wq,
        "wk": wk,
        "wv": wv,
        "wo": wo,
        "k_cache_init": k_cache_init,
        "v_cache_init": v_cache_init,
    }


def run_attention_layer_decode(cfg: AttnConfig) -> Dict[str, torch.Tensor]:
    """完整 decode attention 子链，返回所有中间结果。"""
    cfg.check()

    inputs = generate_inputs(cfg)

    x_norm = inputs["x_norm"]
    wq = inputs["wq"]
    wk = inputs["wk"]
    wv = inputs["wv"]
    wo = inputs["wo"]
    k_cache_init = inputs["k_cache_init"]
    v_cache_init = inputs["v_cache_init"]

    # 1. Q/K/V Projection
    q, k, v = qkv_projection(x_norm, wq, wk, wv, cfg)

    # 2. RoPE
    cos, sin = build_rope_cache(cfg, cfg.pos_id)
    q_rot = apply_rope(q, cos, sin)
    k_rot = apply_rope(k, cos, sin)

    # 3. KV cache 更新
    token_slot = cfg.seq_len - 1
    k_cache, v_cache = update_kv_cache(k_cache_init, v_cache_init, k_rot, v, token_slot)

    # 4. GQA Attention
    attn_mid_torch = gqa_attention_decode_torch(q_rot, k_cache, v_cache, cfg)
    attn_mid_online = gqa_attention_decode_online(q_rot, k_cache, v_cache, cfg)

    # 默认给后续硬件对拍使用 online 版本，因为它更接近 RTL softmax_osm.v。
    attn_mid = attn_mid_online if cfg.use_online_softmax else attn_mid_torch

    # 5. Wo Projection
    out = wo_projection(attn_mid, wo, cfg)

    tensors = {
        "x_norm": x_norm,
        "wq": wq,
        "wk": wk,
        "wv": wv,
        "wo": wo,
        "q": q,
        "k": k,
        "v": v,
        "cos": cos,
        "sin": sin,
        "q_rot": q_rot,
        "k_rot": k_rot,
        "k_cache_init": k_cache_init,
        "v_cache_init": v_cache_init,
        "k_cache": k_cache,
        "v_cache": v_cache,
        "attn_mid_torch": attn_mid_torch,
        "attn_mid_online": attn_mid_online,
        "attn_mid": attn_mid,
        "out": out,
    }

    return tensors


# ============================================================
# 8. dump 与命令行入口
# ============================================================

def dump_all_bf16_mem(tensors: Dict[str, torch.Tensor], dump_dir: str) -> None:
    """将所有中间 Tensor dump 成 bf16 .mem 文件。"""
    dump_path = Path(dump_dir)
    dump_path.mkdir(parents=True, exist_ok=True)

    for name, tensor in tensors.items():
        write_bf16_mem(dump_path / f"{name}.mem", tensor)

    print(f"[OK] 已生成 .mem 文件到: {dump_path.resolve()}")


def print_all_summaries(tensors: Dict[str, torch.Tensor]) -> None:
    """打印所有中间 Tensor 概况。"""
    print("\n========== Tensor 概况 ==========")
    for name, tensor in tensors.items():
        print_tensor_summary(name, tensor)


def parse_args():
    parser = argparse.ArgumentParser(description="GQA Attention golden model")

    parser.add_argument(
        "--config",
        type=str,
        default="smoke",
        choices=["smoke", "llama3"],
        help="选择配置：smoke=小规模验证；llama3=Llama3-8B 真实 attention 维度",
    )

    parser.add_argument(
        "--seq-len",
        type=int,
        default=512,
        help="llama3 配置下的 seq_len",
    )

    parser.add_argument(
        "--pos-id",
        type=int,
        default=None,
        help="position id；如果不指定，使用 config 默认值",
    )

    parser.add_argument(
        "--no-dump",
        action="store_true",
        help="只运行并打印概况，不生成 .mem 文件",
    )

    return parser.parse_args()


def main():
    args = parse_args()

    if args.config == "smoke":
        cfg = smoke_config()
    else:
        cfg = llama3_8b_config(seq_len=args.seq_len, pos_id=args.seq_len - 1)

    if args.pos_id is not None:
        cfg.pos_id = args.pos_id

    print("========== 当前配置 ==========")
    print(cfg)

    tensors = run_attention_layer_decode(cfg)

    print_all_summaries(tensors)

    print("\n========== online softmax 与 torch.softmax 对比 ==========")
    error_report("attn_mid_online vs attn_mid_torch", tensors["attn_mid_online"], tensors["attn_mid_torch"])

    if not args.no_dump:
        dump_all_bf16_mem(tensors, cfg.dump_dir)


if __name__ == "__main__":
    main()
