#!/usr/bin/env python3
"""Export real Llama 3 attention tensors and FP32 golden outputs.

The exported accelerator boundary is intentionally narrower than a complete
Llama decoder layer:

* Q and K are captured after their projections and RoPE.
* V is captured after its projection.
* The golden output is softmax(Q K^T / sqrt(128)) V before o_proj.

BF16 tensors are stored as uint16 NumPy arrays containing the exact BF16 bit
patterns. The JSON manifest records logical dtypes, shapes, hashes, numerical
metrics, checkpoint metadata, and the causal/decode semantics.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import platform
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable

import numpy as np
import torch
import torch.nn.functional as F
from transformers import AutoModelForCausalLM, AutoTokenizer
from transformers.models.llama.modeling_llama import apply_rotary_pos_emb


Q_HEADS = 32
KV_HEADS = 8
HEAD_DIM = 128
Q_PER_KV = Q_HEADS // KV_HEADS
SCALE = 1.0 / math.sqrt(HEAD_DIM)

DEFAULT_PROMPT = """Grouped-query attention lets several query heads share a
smaller set of key and value heads. A hardware implementation must preserve
the causal mask, the rotary-positioned query and key vectors, online softmax
stability, and the final weighted sum while minimizing external memory traffic.
This deterministic paragraph is repeated only to construct exact requested
token lengths for accelerator validation."""


@dataclass
class CapturedAttentionInput:
    hidden_states: torch.Tensor
    position_ids: torch.Tensor | None
    cos: torch.Tensor | None
    sin: torch.Tensor | None


def parse_int_list(raw: str) -> list[int]:
    values = [int(item.strip()) for item in raw.split(",") if item.strip()]
    if not values or any(value < 0 for value in values):
        raise argparse.ArgumentTypeError("expected non-negative comma-separated integers")
    return values


def sha256_file(path: Path, block_bytes: int = 8 * 1024 * 1024) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while block := handle.read(block_bytes):
            digest.update(block)
    return digest.hexdigest()


def save_numpy(path: Path, array: np.ndarray) -> dict[str, Any]:
    path.parent.mkdir(parents=True, exist_ok=True)
    np.save(path, array, allow_pickle=False)
    actual_path = path if path.suffix == ".npy" else path.with_suffix(path.suffix + ".npy")
    return {
        "file": actual_path.name,
        "storage_dtype": str(array.dtype),
        "shape": list(array.shape),
        "bytes": actual_path.stat().st_size,
        "sha256": sha256_file(actual_path),
    }


def save_bf16_bits(path: Path, tensor: torch.Tensor) -> dict[str, Any]:
    value = tensor.detach().contiguous().cpu()
    if value.dtype != torch.bfloat16:
        raise TypeError(f"expected bfloat16 tensor, got {value.dtype}")
    result = save_numpy(path, value.view(torch.uint16).numpy())
    result["logical_dtype"] = "bfloat16"
    result["encoding"] = "IEEE-754 bfloat16 bit pattern stored as uint16"
    return result


def save_fp32(path: Path, tensor: torch.Tensor) -> dict[str, Any]:
    value = tensor.detach().contiguous().cpu().float().numpy()
    result = save_numpy(path, value)
    result["logical_dtype"] = "float32"
    return result


def tensor_metrics(actual: torch.Tensor, reference: torch.Tensor) -> dict[str, float | int]:
    actual64 = actual.detach().cpu().double()
    reference64 = reference.detach().cpu().double()
    error = actual64 - reference64
    abs_error = error.abs()
    finite = torch.isfinite(actual64) & torch.isfinite(reference64)
    denominator = reference64.abs().clamp_min(1.0e-8)
    relative = abs_error / denominator
    flat_actual = actual64.reshape(-1)
    flat_reference = reference64.reshape(-1)
    cosine = F.cosine_similarity(flat_actual, flat_reference, dim=0)
    return {
        "elements": int(actual64.numel()),
        "max_abs_error": float(abs_error.max()),
        "mae": float(abs_error.mean()),
        "rmse": float(torch.sqrt(torch.mean(error.square()))),
        "mean_relative_error": float(relative.mean()),
        "max_relative_error": float(relative.max()),
        "cosine_similarity": float(cosine),
        "nan_or_inf": int((~finite).sum()),
        "violations_atol_0p02_rtol_0p002": int(
            (abs_error > (0.02 + 0.002 * reference64.abs())).sum()
        ),
        "violations_atol_0p02_rtol_0p02": int(
            (abs_error > (0.02 + 0.02 * reference64.abs())).sum()
        ),
    }


def repeat_prompt_tokens(tokenizer: Any, text: str, context: int) -> torch.Tensor:
    if context <= 0:
        raise ValueError("context must be positive")
    body = tokenizer.encode(text, add_special_tokens=False)
    if not body:
        raise ValueError("prompt produced no tokens")
    bos_id = tokenizer.bos_token_id
    prefix = [bos_id] if bos_id is not None else []
    required = context - len(prefix)
    repeated = (body * math.ceil(max(0, required) / len(body)))[:required]
    token_ids = (prefix + repeated)[:context]
    if len(token_ids) != context:
        raise AssertionError(f"constructed {len(token_ids)} tokens, expected {context}")
    return torch.tensor([token_ids], dtype=torch.long)


def rotate_and_project(
    model: Any,
    layer_index: int,
    captured: CapturedAttentionInput,
    device: torch.device,
) -> tuple[torch.Tensor, torch.Tensor, torch.Tensor]:
    layer = model.model.layers[layer_index]
    attention = layer.self_attn
    hidden = captured.hidden_states.to(device=device, dtype=torch.bfloat16)
    batch, sequence, _ = hidden.shape

    q = attention.q_proj(hidden).view(batch, sequence, Q_HEADS, HEAD_DIM).transpose(1, 2)
    k = attention.k_proj(hidden).view(batch, sequence, KV_HEADS, HEAD_DIM).transpose(1, 2)
    v = attention.v_proj(hidden).view(batch, sequence, KV_HEADS, HEAD_DIM).transpose(1, 2)

    if captured.cos is not None and captured.sin is not None:
        cos = captured.cos.to(device=device, dtype=q.dtype)
        sin = captured.sin.to(device=device, dtype=q.dtype)
    else:
        if captured.position_ids is None:
            position_ids = torch.arange(sequence, device=device).unsqueeze(0)
        else:
            position_ids = captured.position_ids.to(device=device)
        cos, sin = model.model.rotary_emb(hidden, position_ids)
    q, k = apply_rotary_pos_emb(q, k, cos, sin)
    return q.contiguous(), k.contiguous(), v.contiguous()


def fp32_attention_reference(
    q: torch.Tensor,
    k: torch.Tensor,
    v: torch.Tensor,
    mode: str,
    query_chunk: int,
) -> torch.Tensor:
    """Compute a full FP32 reference without materializing the full LxL matrix."""
    if q.shape[0] != 1 or k.shape[0] != 1 or v.shape[0] != 1:
        raise ValueError("only batch=1 is supported")
    q_grouped = q.float().reshape(1, KV_HEADS, Q_PER_KV, q.shape[2], HEAD_DIM)
    k_float = k.float()
    v_float = v.float()
    key_length = k.shape[2]
    outputs: list[torch.Tensor] = []

    for begin in range(0, q.shape[2], query_chunk):
        end = min(q.shape[2], begin + query_chunk)
        q_part = q_grouped[..., begin:end, :]
        scores = torch.matmul(q_part, k_float[:, :, None].transpose(-2, -1)) * SCALE
        if mode == "prefill":
            query_positions = torch.arange(begin, end, device=q.device).view(1, 1, 1, -1, 1)
            key_positions = torch.arange(key_length, device=q.device).view(1, 1, 1, 1, -1)
            scores = scores.masked_fill(key_positions > query_positions, float("-inf"))
        probabilities = torch.softmax(scores, dim=-1)
        outputs.append(torch.matmul(probabilities, v_float[:, :, None]))

    grouped = torch.cat(outputs, dim=-2)
    return grouped.reshape(1, Q_HEADS, q.shape[2], HEAD_DIM).contiguous()


def flash_attention_reference(
    q: torch.Tensor, k: torch.Tensor, v: torch.Tensor, mode: str
) -> tuple[torch.Tensor, str]:
    from torch.nn.attention import SDPBackend, sdpa_kernel

    try:
        with sdpa_kernel(SDPBackend.FLASH_ATTENTION):
            output = F.scaled_dot_product_attention(
                q,
                k,
                v,
                dropout_p=0.0,
                is_causal=(mode == "prefill"),
                scale=SCALE,
                enable_gqa=True,
            )
        return output.float(), "flash"
    except Exception as error:
        with sdpa_kernel(SDPBackend.MATH):
            output = F.scaled_dot_product_attention(
                q,
                k,
                v,
                dropout_p=0.0,
                is_causal=(mode == "prefill"),
                scale=SCALE,
                enable_gqa=True,
            )
        return output.float(), f"math_fallback:{type(error).__name__}:{error}"


def checkpoint_metadata(model_dir: Path) -> dict[str, Any]:
    important = [
        model_dir / "config.json",
        model_dir / "model.safetensors.index.json",
        model_dir / "tokenizer.json",
        model_dir / "tokenizer_config.json",
    ]
    files = []
    for path in important:
        if path.exists():
            files.append(
                {
                    "file": path.name,
                    "bytes": path.stat().st_size,
                    "sha256": sha256_file(path),
                }
            )
    shards = sorted(model_dir.glob("model-*.safetensors"))
    return {
        "model_dir": str(model_dir),
        "metadata_files": files,
        "weight_shards": [{"file": path.name, "bytes": path.stat().st_size} for path in shards],
    }


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model-dir", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--mode", choices=["decode", "prefill"], required=True)
    parser.add_argument("--context", type=int, required=True)
    parser.add_argument("--layers", type=parse_int_list, default=[0, 15, 31])
    parser.add_argument("--prompt-file", type=Path)
    parser.add_argument("--reference-chunk", type=int, default=64)
    parser.add_argument("--save-flash-output", action="store_true")
    parser.add_argument("--attn-implementation", choices=["sdpa", "eager"], default="sdpa")
    return parser


def main() -> int:
    args = build_parser().parse_args()
    if args.context <= 0:
        raise SystemExit("--context must be positive")
    if args.reference_chunk <= 0:
        raise SystemExit("--reference-chunk must be positive")
    if not torch.cuda.is_available():
        raise SystemExit("CUDA is required")

    device = torch.device("cuda")
    torch.manual_seed(0)
    torch.cuda.manual_seed_all(0)
    model_dir = args.model_dir.resolve()
    output_root = args.output_dir.resolve()
    output_root.mkdir(parents=True, exist_ok=True)
    prompt_text = args.prompt_file.read_text(encoding="utf-8") if args.prompt_file else DEFAULT_PROMPT

    started = time.perf_counter()
    tokenizer = AutoTokenizer.from_pretrained(model_dir, local_files_only=True)
    input_ids_cpu = repeat_prompt_tokens(tokenizer, prompt_text, args.context)

    print(f"loading model from {model_dir}", flush=True)
    model = AutoModelForCausalLM.from_pretrained(
        model_dir,
        local_files_only=True,
        dtype=torch.bfloat16,
        device_map="cuda",
        low_cpu_mem_usage=True,
        attn_implementation=args.attn_implementation,
    )
    model.eval()

    config = model.config
    expected = {
        "num_attention_heads": Q_HEADS,
        "num_key_value_heads": KV_HEADS,
        "head_dim": HEAD_DIM,
        "hidden_size": Q_HEADS * HEAD_DIM,
    }
    observed = {
        "num_attention_heads": int(config.num_attention_heads),
        "num_key_value_heads": int(config.num_key_value_heads),
        "head_dim": int(getattr(config, "head_dim", config.hidden_size // config.num_attention_heads)),
        "hidden_size": int(config.hidden_size),
    }
    if observed != expected:
        raise SystemExit(f"model shape mismatch: expected {expected}, observed {observed}")
    if any(index >= config.num_hidden_layers for index in args.layers):
        raise SystemExit(f"layer index outside 0..{config.num_hidden_layers - 1}")

    captures: dict[int, CapturedAttentionInput] = {}
    handles = []

    def make_hook(layer_index: int):
        def hook(_module: torch.nn.Module, positional: tuple[Any, ...], kwargs: dict[str, Any]):
            hidden = kwargs.get("hidden_states")
            if hidden is None and positional:
                hidden = positional[0]
            if hidden is None:
                raise RuntimeError(f"layer {layer_index} hook did not receive hidden_states")
            position_embeddings = kwargs.get("position_embeddings")
            cos = sin = None
            if position_embeddings is not None:
                cos, sin = position_embeddings
            position_ids = kwargs.get("position_ids")
            captures[layer_index] = CapturedAttentionInput(
                hidden_states=hidden.detach().to("cpu"),
                position_ids=None if position_ids is None else position_ids.detach().to("cpu"),
                cos=None if cos is None else cos.detach().to("cpu"),
                sin=None if sin is None else sin.detach().to("cpu"),
            )
        return hook

    for layer_index in args.layers:
        handles.append(
            model.model.layers[layer_index].self_attn.register_forward_pre_hook(
                make_hook(layer_index), with_kwargs=True
            )
        )

    input_ids = input_ids_cpu.to(device)
    torch.cuda.reset_peak_memory_stats()
    forward_started = time.perf_counter()
    with torch.inference_mode():
        model(input_ids=input_ids, use_cache=False, return_dict=True)
    torch.cuda.synchronize()
    forward_seconds = time.perf_counter() - forward_started
    for handle in handles:
        handle.remove()

    missing = sorted(set(args.layers) - set(captures))
    if missing:
        raise RuntimeError(f"failed to capture layers {missing}")

    case_dir = output_root / f"{args.mode}_context_{args.context}"
    case_dir.mkdir(parents=True, exist_ok=True)
    token_file = save_numpy(case_dir / "input_ids.npy", input_ids_cpu.numpy())
    token_file["logical_dtype"] = "int64"

    manifest: dict[str, Any] = {
        "schema": "gqav7_llama3_attention_golden_v1",
        "created_utc": datetime.now(timezone.utc).isoformat(),
        "mode": args.mode,
        "context": args.context,
        "batch": 1,
        "q_heads": Q_HEADS,
        "kv_heads": KV_HEADS,
        "head_dim": HEAD_DIM,
        "scale": SCALE,
        "causal": args.mode == "prefill",
        "decode_semantics": (
            "q is the final prompt token; k/v contain positions 0..context-1; "
            "no additional top-left causal mask is applied"
            if args.mode == "decode"
            else None
        ),
        "accelerator_boundary": "post_projection_post_rope_qk_post_projection_v_pre_o_proj",
        "prompt": {
            "source": str(args.prompt_file) if args.prompt_file else "built_in_deterministic_prompt",
            "construction": "BOS followed by repeated tokenizer output truncated to exact context",
            "input_ids": token_file,
        },
        "model": checkpoint_metadata(model_dir),
        "model_config": {
            "architectures": list(getattr(config, "architectures", []) or []),
            "hidden_size": int(config.hidden_size),
            "num_hidden_layers": int(config.num_hidden_layers),
            "num_attention_heads": int(config.num_attention_heads),
            "num_key_value_heads": int(config.num_key_value_heads),
            "max_position_embeddings": int(config.max_position_embeddings),
            "rope_theta": float(config.rope_theta),
            "torch_dtype": str(config.torch_dtype),
        },
        "environment": {
            "hostname": platform.node(),
            "platform": platform.platform(),
            "python": platform.python_version(),
            "torch": torch.__version__,
            "torch_cuda": torch.version.cuda,
            "transformers": __import__("transformers").__version__,
            "cuda_device": torch.cuda.get_device_name(0),
            "cuda_capability": ".".join(map(str, torch.cuda.get_device_capability(0))),
            "pid": os.getpid(),
        },
        "timing": {
            "model_forward_seconds": forward_seconds,
            "peak_cuda_memory_bytes": int(torch.cuda.max_memory_allocated()),
        },
        "layers": [],
    }

    for layer_index in args.layers:
        print(f"exporting layer {layer_index}", flush=True)
        layer_started = time.perf_counter()
        captured = captures[layer_index]
        with torch.inference_mode():
            q_full, k, v = rotate_and_project(model, layer_index, captured, device)
            q = q_full[:, :, -1:, :] if args.mode == "decode" else q_full
            golden = fp32_attention_reference(q, k, v, args.mode, args.reference_chunk)
            flash, backend = flash_attention_reference(q, k, v, args.mode)
        torch.cuda.synchronize()

        layer_dir = case_dir / f"layer_{layer_index:02d}"
        layer_files = {
            "q": save_bf16_bits(layer_dir / "q_bf16_bits.npy", q),
            "k": save_bf16_bits(layer_dir / "k_bf16_bits.npy", k),
            "v": save_bf16_bits(layer_dir / "v_bf16_bits.npy", v),
            "golden_output": save_fp32(layer_dir / "o_fp32_golden.npy", golden),
        }
        if args.save_flash_output:
            layer_files["thor_flash_output"] = save_fp32(
                layer_dir / "o_fp32_from_thor_flash.npy", flash
            )

        layer_record = {
            "layer": layer_index,
            "files": layer_files,
            "thor_reference_backend": backend,
            "thor_flash_vs_fp32_golden": tensor_metrics(flash, golden),
            "export_seconds": time.perf_counter() - layer_started,
        }
        manifest["layers"].append(layer_record)
        del q_full, q, k, v, golden, flash
        torch.cuda.empty_cache()

    manifest["timing"]["total_seconds"] = time.perf_counter() - started
    manifest_path = case_dir / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2, ensure_ascii=False), encoding="utf-8")
    print(f"manifest={manifest_path}", flush=True)
    print(json.dumps({"layers": manifest["layers"], "timing": manifest["timing"]}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
