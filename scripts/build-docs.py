"""Build the static website guide from the GitHub Markdown sources.
Run: uv run --with 'markdown>=3.7,<4' python scripts/build-docs.py
"""
from pathlib import Path
import shutil
import markdown

root = Path(__file__).resolve().parents[1]
docs = root / 'docs'
source = (docs/'research-api.md').read_text() + '\n\n---\n\n' + (docs/'local-mcp.md').read_text()
source = source.replace('(local-mcp.md)', '(#local-mcp-server)')
md = markdown.Markdown(extensions=['fenced_code', 'tables', 'toc'])
body = md.convert(source)
page = '''<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Dyno Docs — Lab, SDK, API &amp; MCP</title>
<meta name="description" content="Set up Dyno Research Lab, run experiments through Python and HTTP, and connect agents through a local MCP server.">
<link rel="stylesheet" href="guide.css"></head><body>
<header><a class="brand" href="index.html">dyno <span>DOCUMENTATION</span></a><a href="https://github.com/canivel/mlx-dyno">GitHub ↗</a></header>
<div class="layout"><aside><nav aria-label="Documentation sections">'''+md.toc+'''</nav><a href="openapi.json">Download OpenAPI JSON ↗</a></aside>
<main>'''+body+'''<footer>Generated from <a href="https://github.com/canivel/mlx-dyno/blob/main/docs/research-api.md">the GitHub documentation</a>. Research features are experimental.</footer></main></div></body></html>'''
(docs/'guide.html').write_text(page)
shutil.copyfile(root/'src/dyno/lab/openapi.json', docs/'openapi.json')
