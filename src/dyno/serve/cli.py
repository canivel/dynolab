"""`dyno serve` entry point.

This is not a fork of `mlx_lm.server`. It imports it, swaps two classes for
instrumented subclasses, and hands control back -- so every flag, and every
future improvement to mlx_lm's batching and caching, keeps working. The only
additions are the timing hooks and two new endpoints.
"""

from __future__ import annotations

import logging
import os
import sys
import time
from typing import Any, Optional

from . import tool_calls
from .instrument import InstrumentedAPIHandler, InstrumentedResponseGenerator, registry

from .. import __version__

BANNER = """\
MLX Dyno {version}  ·  serving with live metrics
  OpenAI API   http://{host}:{port}/v1
  Anthropic    http://{host}:{port}/v1/messages    (Claude Code: dyno launch claude --model <name>)
  Responses    http://{host}:{port}/v1/responses   (Codex: dyno launch codex --model <name>)
  Metrics      http://{host}:{port}/metrics   (Prometheus)
  Stats        http://{host}:{port}/stats     (JSON)
"""


MLX_MISSING = """\
`dyno serve` needs MLX, which is not installed.

    pip install 'mlx-dyno[serve]'

`dyno top` works without it.
"""


class UnsupportedMLXLM(RuntimeError):
    pass


def _patch(server_module: Any) -> None:
    """Swap in the instrumented classes.

    Each seam is checked before use: if a future mlx_lm reshapes the server,
    this should fail loudly at start-up rather than silently serve without
    metrics.
    """
    required = ("ResponseGenerator", "APIHandler", "_run_http_server", "ModelProvider", "main")
    missing = [name for name in required if not hasattr(server_module, name)]
    if missing:
        raise UnsupportedMLXLM(
            "This mlx_lm build is missing "
            + ", ".join(missing)
            + ". MLX Dyno needs mlx-lm >= 0.28; upgrade with `pip install -U mlx-lm`."
        )

    if not hasattr(server_module.ResponseGenerator, '_next_request'):
        raise UnsupportedMLXLM('Serving activation capture requires the mlx_lm generation scheduler hook. Upgrade mlx-lm.')

    # `run()` looks this up on the module at call time, so replacing it works.
    server_module.ResponseGenerator = InstrumentedResponseGenerator

    # `_run_http_server` binds its handler as a default argument, so the module
    # global cannot be swapped; wrap the function instead.
    original_run_http = server_module._run_http_server

    def run_http(host, port, response_generator, *args, **kwargs):
        kwargs["handler_class"] = InstrumentedAPIHandler
        return original_run_http(host, port, response_generator, *args, **kwargs)

    server_module._run_http_server = run_http

    # Time model loading and record which model is resident.
    provider = server_module.ModelProvider
    original_load = provider.load

    def load(self, model_path, *args, **kwargs):
        started = time.perf_counter()
        try:
            result = original_load(self, model_path, *args, **kwargs)
        except Exception as error:  # noqa: BLE001
            if model_path != "default_model":
                raise
            # mlx_lm loads the model in its generation thread: if that fails the server keeps answering /health and
            # every request waits forever. Stop instead, with one line the app can show.
            print(f"Could not load the model: {_first_line(error)}", file=sys.stderr, flush=True)
            os._exit(1)
        elapsed = time.perf_counter() - started
        # `load` is also called for an already-resident model, which returns
        # instantly; reporting that as the load time would be misleading.
        registry.note_model_loaded(
            name=str(model_path), load_seconds=elapsed if elapsed > 0.05 else None
        )
        # A chat template that can't do tools would leave every agent stuck after its first step.
        try:
            folder = tool_calls.resolve_model_dir(str(self._model_map.get(model_path, model_path)))
            registry.tool_calls = tool_calls.ensure_tool_calling(result[1], folder)
        except Exception as error:  # noqa: BLE001 - never stop a model from serving over this
            logging.warning("Could not check tool calling: %s", error)
        return result

    provider.load = load


SPECULATIVE_HELP = """\
Speculative decoding (Dyno):
  --speculative {auto,mtp,off}  auto (default): draft with the model's own MTP head when it
                                ships one and decode concurrency is 1. Output is unchanged;
                                generation is ~1.5-2x faster.
  --mtp-head PATH               an extracted MTP head folder (default: ~/.cache/dyno/mtp,
                                taken from a local full checkpoint or downloaded once, ~0.85 GB)
"""


def _take_speculative_flags(argv: list[str]) -> tuple[list[str], dict[str, Any]]:
    """Strip Dyno's own flags before mlx_lm's parser sees them."""
    options: dict[str, Any] = {"mode": "auto", "head": None}
    rest: list[str] = []
    values = iter(argv)
    for argument in values:
        name, _, inline = argument.partition("=")
        if name in ("--speculative", "--mtp-head"):
            value = inline or next(values, "")
            options["mode" if name == "--speculative" else "head"] = value
        else:
            rest.append(argument)
    if options["mode"] not in ("auto", "mtp", "off"):
        raise SystemExit(f"--speculative must be auto, mtp or off, not {options['mode']!r}")
    return rest, options


def _explicit_concurrency(argv: list[str]) -> Optional[int]:
    for index, argument in enumerate(argv):
        if argument == "--decode-concurrency" and index + 1 < len(argv):
            return int(argv[index + 1])
        if argument.startswith("--decode-concurrency="):
            return int(argument.split("=", 1)[1])
    return None


def _enable_speculative(server_module: Any, options: dict[str, Any], argv: list[str]) -> None:
    """Attach an MTP drafter to every loaded model that ships a head.

    mlx_lm routes requests with a draft model through its single-stream path and calls
    `speculative_generate_step`, which `speculative.install` points at the MTP loop.
    """
    import importlib

    from . import mtp, speculative

    concurrency = _explicit_concurrency(argv)
    if options["mode"] == "off":
        return
    if options["mode"] == "auto" and concurrency is not None and concurrency > 1:
        print("Speculative decoding off: --decode-concurrency > 1 batches requests instead.", flush=True)
        return

    speculative.install(importlib.import_module("mlx_lm.generate"))
    _enable_nax_verify(speculative, argv)
    server_module._make_sampler = speculative.wrap_sampler_factory(server_module._make_sampler)

    provider = server_module.ModelProvider
    loaded = provider.load

    def load(self, model_path, adapter_path=None, draft_model_path=None):
        result = loaded(self, model_path, adapter_path, draft_model_path)
        if self.draft_model is None and getattr(self, "_dyno_mtp_for", None) is not self.model:
            self._dyno_mtp_for = self.model
            self._dyno_mtp = _load_drafter(self, mtp, options)
        if self.draft_model is None and getattr(self, "_dyno_mtp", None) is not None:
            self.draft_model = self._dyno_mtp
            self.is_batchable = False
        return result

    provider.load = load


def _load_drafter(provider: Any, mtp: Any, options: dict[str, Any]) -> Any:
    model_ref = str(provider.model_key[0]) if provider.model_key else ""
    try:
        model_dir = tool_calls.resolve_model_dir(model_ref)
        head = mtp.resolve_head(model_ref, model_dir, options["head"])
        if head is None:
            if options["mode"] == "mtp" or mtp.ships_mtp_head(model_dir):
                print(
                    "Speculative decoding off: no MTP head for this model "
                    "(pass --mtp-head, or allow Dyno to download it from Hugging Face).",
                    flush=True,
                )
            return None
        drafter = mtp.load_mtp_drafter(head, provider.model)
    except Exception as error:  # noqa: BLE001 - a missing head must never stop serving
        print(f"Speculative decoding off: {_first_line(error)}", flush=True)
        return None
    registry.speculative = "mtp"
    print(f"Speculative decoding: MTP head from {head}", flush=True)
    return drafter


def _first_line(error: Exception) -> str:
    text = " ".join(str(error).split()) or type(error).__name__
    if text.startswith("Missing") and "parameters" in text:
        text = text.split(":", 1)[0] + " (a weight file is missing or incomplete: download the model again)"
    return text[:300]


def _announce(argv: list[str]) -> None:
    """Print where the endpoints live, before mlx_lm's own logging starts."""
    host, port = "127.0.0.1", "8080"
    for index, argument in enumerate(argv):
        if argument == "--host" and index + 1 < len(argv):
            host = argv[index + 1]
        elif argument.startswith("--host="):
            host = argument.split("=", 1)[1]
        elif argument == "--port" and index + 1 < len(argv):
            port = argv[index + 1]
        elif argument.startswith("--port="):
            port = argument.split("=", 1)[1]
    print(BANNER.format(version=__version__, host=host, port=port), flush=True)


NAX_DRAFT_TOKENS = 7


def _enable_nax_verify(speculative: Any, argv: list[str]) -> None:
    """On GPUs with neural accelerators, checking 8 drafted tokens costs little more than 4:
    let the draft-length policy go deeper unless --num-draft-tokens was given."""
    from . import nax_matmul

    if not nax_matmul.install():
        return
    speculative.DraftPolicy.PRIOR = speculative.DraftPolicy.NAX_PRIOR
    if not any(a == "--num-draft-tokens" or a.startswith("--num-draft-tokens=") for a in argv):
        argv += ["--num-draft-tokens", str(NAX_DRAFT_TOKENS)]
    print("Speculative decoding: drafts are verified on the GPU's neural accelerators.", flush=True)


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)

    try:
        import mlx_lm.server as server_module
    except ImportError:
        print(MLX_MISSING, file=sys.stderr, end="")
        return 1

    argv, speculative_options = _take_speculative_flags(argv)

    try:
        _patch(server_module)
    except UnsupportedMLXLM as error:
        print(str(error), file=sys.stderr)
        return 1

    if "--help" in argv or "-h" in argv:
        print(SPECULATIVE_HELP)
    else:
        _announce(argv)
        _enable_speculative(server_module, speculative_options, argv)

    # mlx_lm's main() reads sys.argv directly.
    sys.argv = [sys.argv[0] + " serve"] + argv
    try:
        server_module.main()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
