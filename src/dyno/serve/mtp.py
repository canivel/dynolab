"""The multi-token-prediction (MTP) head that Qwen3.5/3.6/3.8 ship with their weights.

mlx_lm drops the `mtp.*` tensors on load. This module rebuilds the head next to an
already-loaded target so it can draft tokens for speculative decoding:

    h'   = norm(fc([norm_e(embed(x_{t+1})), norm_h(h_t)]))  -> one full-attention layer -> norm
    p    = lm_head(h')                                        (predicts x_{t+2})

`h_t` is the target's final normalised hidden state. The head's output feeds itself again
for deeper drafts. Embedding and lm_head are the target's own, so the head adds only
~425M parameters (about 0.45 GB at 8 bits).

Most MLX conversions strip the head, so it is extracted once from the original BF16
checkpoint into a small standalone folder (see `extract_mtp_head`).
"""

from __future__ import annotations

import glob
import json
import os
from pathlib import Path
from typing import Any

import mlx.core as mx
import mlx.nn as nn
from mlx_lm.models.cache import KVCache
from mlx_lm.models.qwen3_5 import DecoderLayer, TextModelArgs

HEAD_FILE = "mtp_head.safetensors"
# HF stores these RMSNorm weights as offsets from one (the model computes x * (1 + w)).
_SHIFTED_NORMS = (
    "pre_fc_norm_embedding.weight",
    "pre_fc_norm_hidden.weight",
    "norm.weight",
    "input_layernorm.weight",
    "post_attention_layernorm.weight",
    "q_norm.weight",
    "k_norm.weight",
)


class MTPHead(nn.Module):
    def __init__(self, args: TextModelArgs):
        super().__init__()
        hidden = args.hidden_size
        self.pre_fc_norm_embedding = nn.RMSNorm(hidden, eps=args.rms_norm_eps)
        self.pre_fc_norm_hidden = nn.RMSNorm(hidden, eps=args.rms_norm_eps)
        self.fc = nn.Linear(2 * hidden, hidden, bias=False)
        # Index the layer as a full-attention one (every `full_attention_interval`-th).
        self.layers = [DecoderLayer(args, layer_idx=args.full_attention_interval - 1)]
        self.norm = nn.RMSNorm(hidden, eps=args.rms_norm_eps)

    def __call__(self, hidden: mx.array, embeddings: mx.array, cache: KVCache) -> mx.array:
        x = mx.concatenate(
            [self.pre_fc_norm_embedding(embeddings), self.pre_fc_norm_hidden(hidden)], axis=-1
        )
        x = self.fc(x)
        mask = "causal" if x.shape[1] > 1 else None
        x = self.layers[0](x, mask=mask, cache=cache)
        return self.norm(x)


class MTPDrafter(nn.Module):
    """Stands in for mlx_lm's `draft_model`, so the server routes requests to the
    speculative path; `speculative.mtp_generate_step` does the actual work."""

    is_mtp_drafter = True

    def __init__(self, head: MTPHead, target: Any):
        super().__init__()
        self.head = head
        # Plain attributes, not submodules: the target owns these weights.
        self._text = _text_model(target)

    def make_cache(self) -> list[Any]:
        return [KVCache()]

    def embed(self, tokens: mx.array) -> mx.array:
        return self._text.model.embed_tokens(tokens)

    def logits(self, hidden: mx.array) -> mx.array:
        text = self._text
        if text.args.tie_word_embeddings:
            return text.model.embed_tokens.as_linear(hidden)
        return text.lm_head(hidden)

    def __call__(self, hidden: mx.array, tokens: mx.array, cache: KVCache) -> mx.array:
        """Hidden states for pairs (hidden[i], tokens[i]); feed to `logits`."""
        return self.head(hidden, self.embed(tokens), cache)


def _text_model(model: Any) -> Any:
    return getattr(model, "language_model", model)


def extract_mtp_head(source: str | os.PathLike, out_dir: str | os.PathLike, bits: int = 8) -> Path:
    """Copy the `mtp.*` tensors out of a full checkpoint into a small, quantised folder."""
    source, out_dir = Path(source), Path(out_dir)
    config = json.loads((source / "config.json").read_text())
    text_config = config.get("text_config", config)
    if not text_config.get("mtp_num_hidden_layers"):
        raise ValueError(f"{source} has no MTP head (mtp_num_hidden_layers is 0)")

    weights: dict[str, mx.array] = {}
    for path in sorted(glob.glob(str(source / "*.safetensors"))):
        shard = mx.load(path)
        weights.update({k[len("mtp."):]: v for k, v in shard.items() if k.startswith("mtp.")})
    if not weights:
        raise ValueError(f"{source} has no mtp.* tensors")
    for key, value in weights.items():
        if key.endswith(_SHIFTED_NORMS) and value.ndim == 1:
            weights[key] = value + 1.0

    head = MTPHead(TextModelArgs.from_dict(text_config))
    head.load_weights(list(weights.items()), strict=True)
    if bits:
        nn.quantize(head, group_size=64, bits=bits, class_predicate=lambda _, m: isinstance(m, nn.Linear))
    mx.eval(head.parameters())

    out_dir.mkdir(parents=True, exist_ok=True)
    flat = dict(_flatten(head.parameters()))
    mx.save_safetensors(str(out_dir / HEAD_FILE), flat)
    (out_dir / "config.json").write_text(
        json.dumps({"text_config": text_config, "mtp_quantization": {"bits": bits, "group_size": 64}}, indent=1)
    )
    return out_dir


def load_mtp_drafter(head_dir: str | os.PathLike, target: Any) -> MTPDrafter:
    head_dir = Path(head_dir)
    config = json.loads((head_dir / "config.json").read_text())
    head = MTPHead(TextModelArgs.from_dict(config["text_config"]))
    quant = config.get("mtp_quantization") or {}
    if quant.get("bits"):
        nn.quantize(
            head,
            group_size=quant.get("group_size", 64),
            bits=quant["bits"],
            class_predicate=lambda _, m: isinstance(m, nn.Linear),
        )
    head.load_weights(str(head_dir / HEAD_FILE), strict=True)
    mx.eval(head.parameters())
    return MTPDrafter(head, target)


def _flatten(tree: Any, prefix: str = ""):
    if isinstance(tree, dict):
        for key, value in tree.items():
            yield from _flatten(value, f"{prefix}{key}.")
    elif isinstance(tree, list):
        for index, value in enumerate(tree):
            yield from _flatten(value, f"{prefix}{index}.")
    else:
        yield prefix[:-1], tree
