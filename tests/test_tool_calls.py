import json
import tempfile
import unittest
from pathlib import Path

from dyno.serve import tool_calls as t

try:
    import mlx_lm.tokenizer_utils  # noqa: F401 - borrowing a template reads its tool format through mlx_lm
    HAS_MLX_LM = True
except ImportError:
    HAS_MLX_LM = False
needs_mlx_lm = unittest.skipUnless(HAS_MLX_LM, "needs mlx_lm (Apple Silicon)")

STRIPPED = """{%- for message in messages %}<|im_start|>{{ message.role }}
{{ message.content }}<|im_end|>
{%- endfor %}{%- if add_generation_prompt %}<|im_start|>assistant
{%- endif %}"""
FULL = """{%- if tools %}<|im_start|>system
{%- for tool in tools %}{{ tool | tojson }}{%- endfor %}<|im_end|>{%- endif %}
{%- for message in messages %}<|im_start|>{{ message.role }}
{%- if message.tool_calls %}<tool_call>
<function={{ message.tool_calls[0].function.name }}>
</function>
</tool_call>{%- endif %}{{ message.content }}<|im_end|>{%- endfor %}"""
TOOLS = [{"type": "function", "function": {"name": "search", "parameters": {"type": "object", "properties": {
    "q": {"type": "string"}, "limit": {"type": "integer"}}}}}]


def model(root: Path, name: str, kind: str, template: str | None, arch="Qwen3_5ForConditionalGeneration") -> Path:
    d = root / ("models--" + name.replace("/", "--")) / "snapshots" / "abc"
    d.mkdir(parents=True)
    (d / "config.json").write_text(json.dumps({"model_type": kind, "architectures": [arch]}))
    (d / "tokenizer_config.json").write_text(json.dumps({"chat_template": template} if template else {}))
    return d


class FakeTokenizer:
    """The parts of mlx_lm's TokenizerWrapper that ensure_tool_calling touches."""

    def __init__(self, template, vocab=("<|im_start|>", "<|im_end|>", "<tool_call>", "</tool_call>")):
        self.chat_template, self._chat_template, self._vocab = template, None, set(vocab)
        self._tool_call_start = None
        self._tokenizer = self
        self.rendered = None

    @property
    def has_tool_calling(self):
        return self._tool_call_start is not None

    def get_vocab(self):
        return {v: i for i, v in enumerate(self._vocab)}

    def encode(self, text, add_special_tokens=False):
        return [ord(c) for c in text]

    def apply_chat_template(self, messages, tokenize=False, **kwargs):
        self.rendered = messages
        return json.dumps(messages)


class ToolCallsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_a_template_without_tools_is_spotted(self):
        self.assertFalse(t.handles_tools(STRIPPED))
        self.assertTrue(t.handles_tools(FULL))
        self.assertFalse(t.handles_tools(None))

    @needs_mlx_lm
    def test_borrows_the_template_of_the_same_family_when_its_tokens_fit(self):
        own = model(self.root, "lab/abliterated", "qwen3_5", STRIPPED)
        model(self.root, "other/llama", "llama", FULL)  # another family: never
        model(self.root, "Qwen/Qwen3.8-27B", "qwen3_5", FULL)
        tok = FakeTokenizer(STRIPPED)
        self.assertEqual(t.ensure_tool_calling(tok, own, roots=[self.root]), "borrowed:Qwen/Qwen3.8-27B")
        self.assertEqual(tok.chat_template, FULL)
        self.assertTrue(tok.has_tool_calling)
        self.assertEqual(tok._tool_call_start, "<tool_call>")

    def test_a_template_with_tokens_the_model_lacks_is_not_borrowed(self):
        own = model(self.root, "lab/abliterated", "qwen3_5", STRIPPED)
        model(self.root, "Qwen/Qwen3.8-27B", "qwen3_5", FULL)
        tok = FakeTokenizer(STRIPPED, vocab=("<s>",))
        self.assertEqual(t.ensure_tool_calling(tok, own, roots=[self.root]), "built-in")

    def test_built_in_format_keeps_tools_calls_and_results_through_any_template(self):
        own = model(self.root, "lab/alone", "mystery", STRIPPED)
        tok = FakeTokenizer(STRIPPED)
        self.assertEqual(t.ensure_tool_calling(tok, own, roots=[self.root]), "built-in")
        tok._chat_template([
            {"role": "system", "content": "Be brief."},
            {"role": "user", "content": "Find cats."},
            {"role": "assistant", "content": "", "tool_calls": [{"id": "1", "function": {"name": "search", "arguments": '{"q": "cats"}'}}]},
            {"role": "tool", "name": "search", "content": "3 results"},
            {"role": "tool", "name": "search", "content": "more"},
            {"role": "user", "content": "And?"},
        ], tools=TOOLS, add_generation_prompt=True)
        roles = [m["role"] for m in tok.rendered]
        self.assertEqual(roles, ["system", "user", "assistant", "user"])  # tool results become one user turn
        self.assertIn('"name": "search"', tok.rendered[0]["content"])
        self.assertIn('<tool_call>\n{"name": "search", "arguments": {"q": "cats"}}\n</tool_call>', tok.rendered[2]["content"])
        self.assertIn("<tool_response>\nsearch: 3 results", tok.rendered[3]["content"])
        self.assertTrue(tok.rendered[3]["content"].endswith("And?"))
        self.assertEqual(tok._tool_parser('{"name": "search", "arguments": {"q": "x"}}'), {"name": "search", "arguments": {"q": "x"}})

    def test_reads_tool_calls_as_json_or_function_tags(self):
        self.assertEqual(t.parse_tool_call(' {"name": "search", "arguments": {"q": "x"}} '), {"name": "search", "arguments": {"q": "x"}})
        self.assertEqual(t.parse_tool_call('{"name": "search", "arguments": "{\\"q\\": \\"x\\"}"}')["arguments"], {"q": "x"})
        self.assertEqual(t.parse_tool_call("<function=search>\n<parameter=q>\ncats\n</parameter>\n<parameter=limit>\n5\n</parameter>\n</function>", TOOLS),
                         {"name": "search", "arguments": {"q": "cats", "limit": 5}})
        with self.assertRaises(ValueError):
            t.parse_tool_call("just words")

    def test_a_tool_call_that_crashes_a_parser_never_breaks_the_reply(self):
        def strict(text, tools=None): raise SyntaxError("literal_eval")  # what mlx_lm's Qwen parser does on a long JSON argument
        safe = t._safe(strict)
        call = safe('<function=save>\n<parameter=spec>\n{"id": "x", "note": "one\ntwo"}\n</parameter>\n</function>',
                    [{"function": {"name": "save", "parameters": {"properties": {"spec": {"type": "object"}}}}}])
        self.assertEqual(call, {"name": "save", "arguments": {"spec": {"id": "x", "note": "one\ntwo"}}})
        with self.assertRaises(ValueError):  # unreadable either way: mlx_lm drops it cleanly
            safe("garbage")

    def test_leaves_a_working_template_alone(self):
        tok = FakeTokenizer(FULL)
        tok._tool_call_start = "<tool_call>"
        self.assertEqual(t.ensure_tool_calling(tok, None), "own")
        self.assertIsNone(tok._chat_template)
        self.assertEqual(t.ensure_tool_calling(FakeTokenizer(None), None), "none")

    @needs_mlx_lm
    def test_a_model_with_no_template_borrows_one_from_its_family(self):
        own = model(self.root, "lab/no-template", "qwen3_5", None)
        model(self.root, "Qwen/Qwen3.8-27B", "qwen3_5", FULL)
        tok = FakeTokenizer(None)
        self.assertEqual(t.ensure_tool_calling(tok, own, roots=[self.root]), "borrowed:Qwen/Qwen3.8-27B")
        self.assertEqual(tok.chat_template, FULL)
        self.assertTrue(tok.has_chat_template and tok.has_tool_calling)


if __name__ == "__main__":
    unittest.main()
