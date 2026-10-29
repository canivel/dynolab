import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BANNED = re.compile(r'litellm', re.I)
SKIP = {'.git', '.venv', 'build', 'node_modules', '__pycache__'}


class BannedDependencyTests(unittest.TestCase):
    """Dyno never uses litellm, directly or as a transitive dependency (see CONTRIBUTING.md)."""

    def test_litellm_is_not_a_dependency(self):
        for name in ('pyproject.toml', 'uv.lock'):
            with self.subTest(file=name):
                self.assertIsNone(BANNED.search((ROOT / name).read_text()), f'litellm appears in {name}')

    def test_litellm_is_not_used_in_the_code(self):
        found = []
        for path in ROOT.rglob('*'):
            if not path.is_file() or SKIP & set(path.relative_to(ROOT).parts) or path == Path(__file__).resolve():
                continue
            if path.suffix not in ('.py', '.swift', '.sh', '.toml', '.txt', '.yml', '.yaml', '.json', '.cfg'): continue
            if BANNED.search(path.read_text(errors='ignore')): found.append(str(path.relative_to(ROOT)))
        self.assertEqual(found, [])


if __name__ == '__main__':
    unittest.main()
