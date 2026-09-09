"""Publish GitHub Markdown as separate app, SDK, API and MCP website guides.
Run: uv run --with 'markdown>=3.7,<4' python scripts/build-docs.py --website-root ../dynolab-website
"""
from pathlib import Path
import argparse
import html
import re
import shutil
import markdown

parser = argparse.ArgumentParser()
parser.add_argument('--website-root', required=True, type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
target = args.website_root / 'public'
assert (target / 'index.html').is_file(), 'Expected website checkout with public/index.html'
pages = [
    ('app-guide.md', 'guide.html', 'App handbook', 'Download, install and use every Dyno Lab feature with real app examples.'),
    ('sdk-guide.md', 'sdk.html', 'Python SDK', 'Install the Dyno SDK, capture activations, run experiments and manage saved artifacts.'),
    ('http-api.md', 'api.html', 'HTTP API', 'Inference, research jobs, resident activations and execution endpoint reference.'),
    ('local-mcp.md', 'mcp.html', 'Local MCP', 'Connect local assistants to Dyno Lab through the stdio MCP bridge.'),
]
for source_name, filename, label, description in pages:
    source = (root / 'docs' / source_name).read_text()
    for other_source, other_page, _, _ in pages:
        source = source.replace('(' + other_source, '(' + other_page)
    source = source.replace('(https://dynolab.dev/', '(')
    md = markdown.Markdown(extensions=['fenced_code', 'tables', 'toc'], extension_configs={'toc': {'toc_depth': '2-3'}})
    body = md.convert(source)
    # Keep screenshots legible on small displays: open the original at full size.
    body = re.sub(r'<img ([^>]*?)src="([^"]+)"([^>]*?)/?>',
        lambda m: '<a class="screenshot" href="' + html.escape(m[2], quote=True) + '" aria-label="Open screenshot at full size"><img ' + m[1] + 'src="' + m[2] + '"' + m[3].rstrip('/ ') + ' loading="lazy" decoding="async"></a>', body)
    navigation = ''.join(f'<a href="{page}"' + (' aria-current="page"' if page == filename else '') + f'>{name}</a>' for _, page, name, _ in pages)
    page = f'''<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<link rel="canonical" href="https://dynolab.dev/{filename}"><link rel="icon" href="/favicon.svg">
<title>{label} — Dyno Lab documentation</title>
<meta name="description" content="{html.escape(description, quote=True)}">
<link rel="stylesheet" href="guide.css"></head><body>
<a class="skip-link" href="#content">Skip to content</a>
<header><a class="brand" href="index.html">dyno lab <span>DOCUMENTATION</span></a><a href="https://github.com/canivel/dynolab">GitHub ↗</a></header>
<nav class="docs-areas" aria-label="Documentation areas">{navigation}</nav>
<div class="layout"><aside><p class="version">DYNO 0.2 · MAC APP &amp; RESEARCH</p>
<details open><summary>On this page</summary><nav aria-label="On this page">{md.toc}</nav></details>
<a class="schema-link" href="openapi.json">Download research OpenAPI ↗</a></aside>
<script>if(matchMedia('(max-width:850px)').matches)document.querySelector('aside details').open=false;</script>
<main id="content">{body}<footer>Found something unclear? <a href="https://github.com/canivel/dynolab/issues">Report a documentation issue</a>.<br>
Source: <a href="https://github.com/canivel/dynolab/blob/main/docs/{source_name}">{label} on GitHub</a>. Research features are experimental.</footer></main></div></body></html>'''
    (target / filename).write_text(page)
    print(f'{source_name} → {filename}')
shutil.copyfile(root / 'src/dyno/lab/openapi.json', target / 'openapi.json')
shutil.copytree(root / 'docs/examples', target / 'examples', dirs_exist_ok=True)
