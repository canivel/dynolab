"""The multi-token-prediction (MTP) head that Qwen3.5/3.6/3.8 ship with their weights.

mlx_lm drops the `mtp.*` tensors on load. This module rebuilds the head next to an
already-loaded target so it can draft tokens for speculative decoding:

    h'   = norm(fc([norm_e(embed(x_{t+1})), norm_h(h_t)]))  -> one full-attention layer -> norm
    p    = lm_head(h')                                        (predicts x_{t+2})

`h_t` is the target's final normalised hidden state. The head's output feeds itself again
for deeper drafts. Embedding and lm_head are the target's own, so the head adds only
~425M parameters (about 0.45 GB at 8 bits).

Most MLX conversions strip the head, so it is extracted once into a small standalone folder:
from a local copy of the original checkpoint (see `extract_mtp_head`), or else by reading only
the `mtp.*` tensors of the original repository on Hugging Face (see `fetch_mtp_head`).
"""

from __future__ import annotations

import glob
import json
import logging
import os
import re
import struct
from pathlib import Path
from typing import Any, Optional

import mlx.core as mx
import mlx.nn as nn
from mlx_lm.models.cache import KVCache
from mlx_lm.models.qwen3_5 import DecoderLayer, TextModelArgs

HEAD_FILE = "mtp_head.safetensors"
DRAFT_VOCAB = int(os.environ.get("DYNO_MTP_DRAFT_VOCAB", 65536))
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

    def __init__(self, head: MTPHead, target: Any, draft_vocab: int = DRAFT_VOCAB):
        super().__init__()
        self.head = head
        # Plain attributes, not submodules: the target owns these weights.
        self._text = _text_model(target)
        self._draft_head = _vocab_prefix_head(self._text, draft_vocab)
        self.vocab_size = self._text.args.vocab_size

    def draft_logits(self, hidden: mx.array) -> mx.array:
        """Logits over the first `draft_vocab` ids only.

        Qwen's ids follow BPE merge order, so the prefix holds the frequent tokens; the full
        248k-row lm_head would cost a 0.64 GB read per drafted token. Tokens past the prefix
        are never drafted, which keeps sampling lossless (their q is zero).
        """
        if self._draft_head is None:
            return self.logits(hidden)
        return self._draft_head(hidden)

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


def _vocab_prefix_head(text: Any, rows: int) -> Optional[nn.Module]:
    """A view of the target's lm_head restricted to its first `rows` output ids."""
    full = text.model.embed_tokens if text.args.tie_word_embeddings else text.lm_head
    if not rows or rows >= text.args.vocab_size:
        return None
    if isinstance(full, (nn.QuantizedLinear, nn.QuantizedEmbedding)):
        head = nn.QuantizedLinear(full.group_size, 1, bias=False, group_size=full.group_size, bits=full.bits)
        head.weight, head.scales = full.weight[:rows], full.scales[:rows]
        if getattr(full, "biases", None) is not None:
            head.biases = full.biases[:rows]
        else:
            head.biases = None
        mx.eval(head.parameters())
        return head
    head = nn.Linear(1, 1, bias=False)
    head.weight = full.weight[:rows]
    mx.eval(head.parameters())
    return head


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
    return _save_head(weights, text_config, out_dir, bits)


def fetch_mtp_head(repo_id: str, out_dir: str | os.PathLike, bits: int = 8) -> Path:
    """Read just the `mtp.*` tensors of a Hugging Face checkpoint with range requests (~0.85 GB
    for a 27B model, instead of the whole 54 GB) and save the head like `extract_mtp_head`."""
    from huggingface_hub import HfFileSystem, hf_hub_download

    config = json.loads(Path(hf_hub_download(repo_id, "config.json")).read_text())
    text_config = config.get("text_config", config)
    index = json.loads(Path(hf_hub_download(repo_id, "model.safetensors.index.json")).read_text())
    shards: dict[str, list[str]] = {}
    for key, shard in index.get("weight_map", {}).items():
        if key.startswith("mtp."):
            shards.setdefault(shard, []).append(key)
    if not shards:
        raise ValueError(f"{repo_id} has no mtp.* tensors")
    fs = HfFileSystem()
    weights: dict[str, mx.array] = {}
    for shard, keys in shards.items():
        with fs.open(f"{repo_id}/{shard}", "rb") as handle:
            weights.update({k[len("mtp."):]: v for k, v in read_safetensors(handle, keys).items()})
    return _save_head(weights, text_config, out_dir, bits)


_DTYPES = {"BF16": (mx.bfloat16, 2), "F16": (mx.float16, 2), "F32": (mx.float32, 4)}


def read_safetensors(handle: Any, keys: list[str]) -> dict[str, mx.array]:
    """Read only `keys` from a seekable safetensors file."""
    (length,) = struct.unpack("<Q", handle.read(8))
    header = json.loads(handle.read(length))
    tensors = {}
    for key in sorted(keys, key=lambda k: header[k]["data_offsets"][0]):
        entry = header[key]
        if entry["dtype"] not in _DTYPES:
            raise ValueError(f"{key} has unsupported dtype {entry['dtype']}")
        dtype, size = _DTYPES[entry["dtype"]]
        begin, end = entry["data_offsets"]
        handle.seek(8 + length + begin)
        raw = handle.read(end - begin)
        words = mx.array(memoryview(raw).cast("H" if size == 2 else "I"))
        tensors[key] = words.view(dtype).reshape(entry["shape"])
    return tensors


def _save_head(weights: dict[str, mx.array], text_config: dict, out_dir: Path | str, bits: int) -> Path:
    out_dir = Path(out_dir)
    if not weights:
        raise ValueError("the checkpoint has no mtp.* tensors")
    for key, value in weights.items():
        if key.endswith(_SHIFTED_NORMS) and value.ndim == 1:
            weights[key] = value + 1.0

    head = MTPHead(TextModelArgs.from_dict(text_config))
    head.load_weights(list(weights.items()), strict=True)
    if bits:
        nn.quantize(head, group_size=64, bits=bits, class_predicate=lambda _, m: isinstance(m, nn.Linear))
    mx.eval(head.parameters())

    # Write next to the destination and rename, so an interrupted run never leaves a half head.
    partial = out_dir.with_name(out_dir.name + ".partial")
    partial.mkdir(parents=True, exist_ok=True)
    mx.save_safetensors(str(partial / HEAD_FILE), dict(_flatten(head.parameters())))
    (partial / "config.json").write_text(
        json.dumps({"text_config": text_config, "mtp_quantization": {"bits": bits, "group_size": 64}}, indent=1)
    )
    if out_dir.exists():
        import shutil

        shutil.rmtree(out_dir)
    partial.rename(out_dir)
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


CACHE_ROOT = Path(os.environ.get("DYNO_MTP_CACHE", Path.home() / ".cache" / "dyno" / "mtp"))
_BASE_NAME = re.compile(r"(Qwen3\.\d+-\d+B(?:-A\d+B)?)", re.IGNORECASE)


def base_name(model_ref: str) -> Optional[str]:
    """`lmstudio-community/Qwen3.8-27B-MLX-4bit` -> `Qwen3.8-27B`: heads are per base model."""
    match = _BASE_NAME.search(str(model_ref))
    return match.group(1) if match else None


def ships_mtp_head(model_dir: str | os.PathLike) -> bool:
    try:
        config = json.loads((Path(model_dir) / "config.json").read_text())
    except (OSError, ValueError):
        return False
    return bool(config.get("text_config", config).get("mtp_num_hidden_layers"))


def resolve_head(
    model_ref: str, model_dir: str | os.PathLike, explicit: Optional[str] = None, download: bool = True
) -> Optional[Path]:
    """Find an MTP head for this model, extracting one if needed.

    Order: an explicit folder; the per-base-model cache; a local Hugging Face snapshot of
    the same base model that still carries its `mtp.*` tensors; the `mtp.*` tensors of the
    original `Qwen/<base>` repository, read over the network when `download` is set.
    """
    if explicit:
        return Path(explicit).expanduser()
    if not ships_mtp_head(model_dir):
        return None
    name = base_name(model_ref) or base_name(str(model_dir))
    if not name:
        return None
    cached = CACHE_ROOT / name
    if (cached / HEAD_FILE).exists():
        return cached
    if not _dense(model_dir):
        return None  # the head of a mixture-of-experts model is not supported yet
    source = _local_full_checkpoint(name)
    if source is not None:
        logging.info("Extracting the MTP head for %s from %s", name, source)
        return extract_mtp_head(source, cached)
    if not download or os.environ.get("HF_HUB_OFFLINE") == "1":
        return None
    print(f"Speculative decoding: downloading the MTP head of Qwen/{name} (about 0.85 GB, once)...", flush=True)
    return fetch_mtp_head(f"Qwen/{name}", cached)


def _dense(model_dir: str | os.PathLike) -> bool:
    try:
        config = json.loads((Path(model_dir) / "config.json").read_text())
    except (OSError, ValueError):
        return False
    text = config.get("text_config", config)
    return not any(text.get(key) for key in ("num_experts", "n_routed_experts", "num_local_experts"))


def _local_full_checkpoint(name: str) -> Optional[Path]:
    hub = Path(os.environ.get("HF_HUB_CACHE", Path.home() / ".cache" / "huggingface" / "hub"))
    for snapshot in sorted(hub.glob(f"models--*--{name}*/snapshots/*")):
        index = snapshot / "model.safetensors.index.json"
        try:
            weight_map = json.loads(index.read_text()).get("weight_map", {})
        except (OSError, ValueError):
            continue
        if any(key.startswith("mtp.") for key in weight_map) and all(
            (snapshot / shard).exists() for shard in {v for k, v in weight_map.items() if k.startswith("mtp.")}
        ):
            return snapshot
    return None


def _flatten(tree: Any, prefix: str = ""):
    if isinstance(tree, dict):
        for key, value in tree.items():
            yield from _flatten(value, f"{prefix}{key}.")
    elif isinstance(tree, list):
        for index, value in enumerate(tree):
            yield from _flatten(value, f"{prefix}{index}.")
    else:
        yield prefix[:-1], tree
