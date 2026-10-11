"""Tool calling for models whose chat template can't do it.

Some models ship a chat template that only knows system, user and assistant turns (abliterated and merged models
often do). Through such a template the tool list never reaches the model, tool results are dropped, and whatever tool
call the model writes comes back as plain text, so an agent stops after its first step.

When the loaded template doesn't handle tools, `dyno serve` fixes that, in this order:

1. The template of another downloaded model of the same family (same `model_type`), when every special token it uses
   is in this model's vocabulary: the model sees tools the way it was trained to.
2. Otherwise a built-in format that works through any template: the tools are described in the system message, earlier
   calls and results are written into the turns as text, and `<tool_call>` blocks in the reply are read back as calls
   (JSON, or the `<function=...>` form Qwen models use).

Nothing changes for a model whose own template handles tools.
"""

from __future__ import annotations

import json
import logging
import os
import re
from pathlib import Path
from typing import Any

TOOL_CALL_START, TOOL_CALL_END = "<tool_call>", "</tool_call>"

FALLBACK_INSTRUCTIONS = """# Tools

You can call these tools. Each is described as a JSON schema:
{tools}

To call a tool, reply with a block like this (one block per call, nothing inside it but the JSON):
<tool_call>
{{"name": "tool_name", "arguments": {{"argument": "value"}}}}
</tool_call>
The result comes back in a <tool_response> block. Call tools only when they help; otherwise answer normally."""


def handles_tools(template: Any) -> bool:
    """Whether a chat template renders the tool list itself."""
    return isinstance(template, str) and re.search(r"\btools\b", template) is not None


def model_type(config: dict) -> str | None:
    return config.get("model_type") or (config.get("text_config") or {}).get("model_type")


def _read_json(path: Path) -> dict:
    try:
        value = json.loads(path.read_text())
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError):
        return {}


def template_of(model_dir: Path) -> str | None:
    """A model folder's chat template: chat_template.jinja, else the one in tokenizer_config.json."""
    jinja = model_dir / "chat_template.jinja"
    if jinja.is_file():
        try:
            return jinja.read_text()
        except OSError:
            return None
    template = _read_json(model_dir / "tokenizer_config.json").get("chat_template")
    if isinstance(template, list):  # named templates: [{"name": "default", "template": ...}]
        named = {t.get("name"): t.get("template") for t in template if isinstance(t, dict)}
        template = named.get("tool_use") or named.get("default")
    return template if isinstance(template, str) else None


def default_roots() -> list[Path]:
    home = Path.home()
    hub = os.environ.get("HF_HUB_CACHE") or str(Path(os.environ.get("HF_HOME") or home / ".cache" / "huggingface") / "hub")
    return [Path(hub), home / ".cache" / "lm-studio" / "models", home / "models", home / "Documents" / "models"]


def _model_dirs(root: Path):
    if not root.is_dir():
        return
    for entry in sorted(root.iterdir()):
        if entry.name.startswith("."):
            continue
        if entry.name.startswith("models--"):
            yield from sorted(p for p in (entry / "snapshots").glob("*") if p.is_dir())
        elif entry.is_dir():
            yield entry
            for child in sorted(entry.iterdir()):  # LM Studio: publisher/model
                if child.is_dir() and (child / "config.json").is_file():
                    yield child


def find_donor(model_dir: Path, vocab: set[str], roots: list[Path] | None = None) -> tuple[Path, str] | None:
    """A downloaded model of the same family whose template handles tools and uses only tokens this model has.

    Same architecture first, then the same model_type."""
    config = _read_json(model_dir / "config.json")
    kind = model_type(config)
    if not kind:
        return None
    architectures = config.get("architectures")
    best = None
    try:
        own = model_dir.resolve()
    except OSError:
        own = model_dir
    for root in roots if roots is not None else default_roots():
        for candidate in _model_dirs(root):
            try:
                if candidate.resolve() == own:
                    continue
            except OSError:
                continue
            other = _read_json(candidate / "config.json")
            if model_type(other) != kind:
                continue
            template = template_of(candidate)
            if not handles_tools(template) or not _parser_kind(template):
                continue
            special = set(re.findall(r"<\|[^|<>\s]+\|>|<tool_call>|</tool_call>|<tool_response>|</tool_response>|<think>|</think>", template))
            if not special <= vocab:
                continue
            if other.get("architectures") == architectures:
                return candidate, template
            best = best or (candidate, template)
    return best


def _parser_kind(template: str) -> str | None:
    try:
        from mlx_lm.tokenizer_utils import _infer_tool_parser
    except ImportError:
        return None
    return _infer_tool_parser(template)


# The built-in format


def _tool_text(call: dict) -> str:
    function = call.get("function") or call
    arguments = function.get("arguments") or {}
    if isinstance(arguments, str):
        try:
            arguments = json.loads(arguments)
        except ValueError:
            pass
    return TOOL_CALL_START + "\n" + json.dumps({"name": function.get("name"), "arguments": arguments}, ensure_ascii=False) + "\n" + TOOL_CALL_END


def fallback_messages(messages: list[dict], tools: list | None) -> list[dict]:
    """The conversation rewritten so a template that knows only system, user and assistant turns keeps everything:
    the tools in the system message, calls in the assistant's text, results as user turns. Turns of the same role are
    merged, since many templates insist that user and assistant alternate."""
    out: list[dict] = []

    def add(role: str, content: str):
        if out and out[-1]["role"] == role and role != "system":
            out[-1]["content"] = (out[-1]["content"] + "\n\n" + content).strip()
        else:
            out.append({"role": role, "content": content})

    for message in messages:
        role, content = message.get("role"), message.get("content") or ""
        if not isinstance(content, str):
            content = str(content)
        if role == "assistant" and message.get("tool_calls"):
            add("assistant", "\n".join([content.strip()] + [_tool_text(c) for c in message["tool_calls"]]).strip())
        elif role == "tool":
            name = message.get("name")
            add("user", "<tool_response>\n" + (f"{name}: " if name else "") + content + "\n</tool_response>")
        elif role in ("system", "user", "assistant"):
            add(role, content)
        else:
            add("user", content)
    if tools:
        described = "\n".join(json.dumps(t.get("function", t), ensure_ascii=False) for t in tools)
        instructions = FALLBACK_INSTRUCTIONS.format(tools=described)
        if out and out[0]["role"] == "system":
            out[0]["content"] = (out[0]["content"] + "\n\n" + instructions).strip()
        else:
            out.insert(0, {"role": "system", "content": instructions})
    return out


_FUNCTION = re.compile(r"<function=([^>\n]+)>(.*?)(?:</function>|$)", re.S)
_PARAMETER = re.compile(r"<parameter=([^>\n]+)>\n?(.*?)\n?(?:</parameter>|(?=<parameter=)|$)", re.S)


def _typed(value: str, schema: dict):
    kind = str((schema or {}).get("type") or "string").lower()
    if kind in ("string", "str", "text"):
        return value
    try:
        return json.loads(value)
    except ValueError:
        return value


def parse_tool_call(text: str, tools: list | None = None):
    """A tool call written in the built-in format: JSON, or <function=name><parameter=x>v</parameter></function>."""
    text = text.strip()
    if text.startswith("{"):
        call = json.loads(text)
        if not isinstance(call, dict) or not call.get("name"):
            raise ValueError("A tool call needs a name.")
        arguments = call.get("arguments", call.get("parameters", {}))
        if isinstance(arguments, str):
            arguments = json.loads(arguments) if arguments.strip().startswith("{") else {"input": arguments}
        return {"name": call["name"], "arguments": arguments or {}}
    calls = []
    for name, body in _FUNCTION.findall(text):
        name = name.strip()
        schema = next(((t.get("function") or t).get("parameters", {}).get("properties", {})
                       for t in tools or [] if (t.get("function") or t).get("name") == name), {})
        calls.append({"name": name, "arguments": {k.strip(): _typed(v, schema.get(k.strip(), {})) for k, v in _PARAMETER.findall(body)}})
    if not calls:
        raise ValueError("Not a tool call.")
    return calls[0] if len(calls) == 1 else calls


# Installing it on a loaded tokenizer (mlx_lm's TokenizerWrapper)


def _vocab(tokenizer) -> set[str]:
    try:
        return set(tokenizer.get_vocab())
    except Exception:  # noqa: BLE001
        return set()


def _set_tool_format(tokenizer, start, end, parser):
    tokenizer._tool_call_start, tokenizer._tool_call_end, tokenizer._tool_parser = start, end, parser
    tokenizer._tool_call_start_tokens = tuple(tokenizer.encode(start, add_special_tokens=False)) if start else None
    tokenizer._tool_call_end_tokens = tuple(tokenizer.encode(end, add_special_tokens=False)) if end else None


def ensure_tool_calling(tokenizer, model_dir: Path | None, roots: list[Path] | None = None) -> str:
    """Make a loaded tokenizer handle tools, and say how: "own", "borrowed:<model>", "built-in" or "none"."""
    if getattr(tokenizer, "_dyno_tools", None):
        return tokenizer._dyno_tools
    how = "own"
    template = getattr(tokenizer, "chat_template", None)
    custom = getattr(tokenizer, "_chat_template", None) is not None
    if custom or (handles_tools(template) and tokenizer.has_tool_calling):
        pass
    elif handles_tools(template) and TOOL_CALL_START in template:
        # It renders the tools but in a form mlx_lm doesn't recognise: keep it, and read the calls back ourselves.
        _set_tool_format(tokenizer, TOOL_CALL_START, TOOL_CALL_END, parse_tool_call)
        how = "own+parser"
    elif not isinstance(template, str):
        # No chat template at all (some uploads leave it out): mlx_lm would fall back to a plain "USER:/ASSISTANT:"
        # prompt the model wasn't trained on, with no tools. A same-family template fixes both; else leave it.
        donor = find_donor(model_dir, _vocab(tokenizer), roots) if model_dir else None
        if donor:
            import importlib
            module = importlib.import_module(f"mlx_lm.tool_parsers.{_parser_kind(donor[1])}")
            tokenizer.chat_template = donor[1]
            tokenizer.has_chat_template = True
            _set_tool_format(tokenizer, module.tool_call_start, module.tool_call_end, module.parse_tool_call)
            how = "borrowed:" + _display(donor[0])
        else:
            how = "none"
    else:
        donor = find_donor(model_dir, _vocab(tokenizer), roots) if model_dir else None
        if donor:
            import importlib
            module = importlib.import_module(f"mlx_lm.tool_parsers.{_parser_kind(donor[1])}")
            tokenizer.chat_template = donor[1]
            _set_tool_format(tokenizer, module.tool_call_start, module.tool_call_end, module.parse_tool_call)
            how = "borrowed:" + _display(donor[0])
        if how == "own":
            original = tokenizer._tokenizer

            def render(messages, tools=None, **kwargs):
                kwargs.pop("tokenize", None)
                kwargs.pop("return_dict", None)
                rewritten = fallback_messages(messages, tools)
                try:
                    return original.apply_chat_template(rewritten, tokenize=False, **kwargs)
                except Exception:  # noqa: BLE001 - a template without a system turn: fold it into the first user turn
                    if rewritten and rewritten[0]["role"] == "system":
                        system = rewritten.pop(0)["content"]
                        if rewritten and rewritten[0]["role"] == "user":
                            rewritten[0] = {"role": "user", "content": system + "\n\n" + rewritten[0]["content"]}
                        else:
                            rewritten.insert(0, {"role": "user", "content": system})
                    return original.apply_chat_template(rewritten, tokenize=False, **kwargs)

            tokenizer._chat_template = render
            _set_tool_format(tokenizer, TOOL_CALL_START, TOOL_CALL_END, parse_tool_call)
            how = "built-in"
    if how.startswith("borrowed:") or how == "built-in":
        logging.warning("This model's chat template doesn't handle tools; tool calling uses %s.",
                        "the template of " + how.split(":", 1)[1] if how != "built-in" else "Dyno's built-in format")
    tokenizer._dyno_tools = how
    return how


def _display(path: Path) -> str:
    for part in path.parts:
        if part.startswith("models--"):
            return part[len("models--"):].replace("--", "/")
    return path.name


def resolve_model_dir(model_path: str) -> Path | None:
    """The folder a model was loaded from: the path itself, or the Hugging Face cache snapshot of a repo id."""
    path = Path(model_path).expanduser()
    if path.is_dir():
        return path
    try:
        from huggingface_hub import snapshot_download
        return Path(snapshot_download(model_path, local_files_only=True))
    except Exception:  # noqa: BLE001
        return None
