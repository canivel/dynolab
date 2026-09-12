"""Validate app/SDK/API documentation without the private website checkout."""
import ast
from html.parser import HTMLParser
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
from urllib.parse import unquote, urlsplit

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'src'))
from dyno.lab.server import validate

PAGES = ['pool-lab.html', 'pools.html', 'pool-api.html', 'research-tools.html', 'guide.html', 'sdk.html', 'api.html', 'mcp.html']
class Page(HTMLParser):
    def __init__(self, source):
        super().__init__()
        self.references, self.ids = [], set()
        self.feed(source)
    def handle_starttag(self, tag, attributes):
        attributes = dict(attributes)
        if 'id' in attributes:
            self.ids.add(attributes['id'])
        self.references.extend(attributes[key] for key in ('src', 'href') if key in attributes)

def main():
    for name in ('pool-guide.md', 'pool-api.md', 'research-tools.md', 'app-guide.md', 'sdk-guide.md', 'http-api.md', 'local-mcp.md'):
        source = (ROOT / 'docs' / name).read_text()
        for language, code in re.findall(r'```(\w+)\n(.*?)```', source, re.S):
            if language == 'python':
                ast.parse(code, filename=name)
            elif language == 'json':
                json.loads(code)
    for file in (ROOT / 'docs/examples').glob('*.json'):
        validate(dict(json.loads(file.read_text()), operation=file.stem,
                      model='mlx-community/Qwen1.5-0.5B-Chat-4bit'))
    with tempfile.TemporaryDirectory() as directory:
        website = Path(directory)
        public = website / 'public'
        public.mkdir()
        (public / 'index.html').write_text('<html></html>')
        subprocess.run([sys.executable, str(ROOT / 'scripts/build-docs.py'),
                        '--website-root', directory], check=True)
        documents = {name: Page((public / name).read_text()) for name in PAGES}
        for name, page in documents.items():
            assert 'content' in page.ids, name
            for reference in page.references:
                url = urlsplit(reference)
                if url.scheme or url.netloc:
                    continue
                filename = url.path.lstrip('/') or name
                if filename in documents:
                    if url.fragment:
                        assert unquote(url.fragment) in documents[filename].ids, (name, reference)
                elif filename == 'openapi.json' or filename.startswith('examples/'):
                    assert (public / filename).is_file(), (name, reference)
                else:
                    # These assets are maintained and browser-tested in the website repo.
                    assert filename in ('index.html', 'favicon.svg', 'guide.css') or filename.startswith(('assets/', 'screenshots/')), (name, reference)
        schema = json.loads((public / 'openapi.json').read_text())
        assert schema['openapi'].startswith('3.')
    print('Documentation generation, internal links, code syntax and example configurations passed.')

if __name__ == '__main__':
    main()
