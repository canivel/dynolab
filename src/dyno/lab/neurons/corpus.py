"""Text to run through a model: local files or Hugging Face datasets, split by document before anything is computed.

A Hugging Face source is fetched through the datasets-server rows API (JSON; no `datasets` or `pyarrow` needed) and
cached as JSONL under the Lab's data folder, with the dataset's commit recorded. The same configuration always gives
the same documents in the same order, and the same train/held-out split.
"""
from __future__ import annotations

import hashlib
import json
import os
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

ROWS = 'https://datasets-server.huggingface.co/rows'
PAGE = 100

# A broad default: the essay found neurons that looked arbitrary until the data was broadened.
PRESETS = {
    'web-mix': [
        dict(hf='HuggingFaceFW/fineweb-edu', config='sample-10BT', split='train', text_field='text', share=0.7),
        dict(hf='codeparrot/codeparrot-clean-valid', config='default', split='train', text_field='content', share=0.15),
        dict(hf='HuggingFaceFW/fineweb-2', config='spa_Latn', split='train', text_field='text', share=0.05),
        dict(hf='HuggingFaceFW/fineweb-2', config='cmn_Hani', split='train', text_field='text', share=0.05),
        dict(hf='HuggingFaceFW/fineweb-2', config='rus_Cyrl', split='train', text_field='text', share=0.05),
    ],
    'fineweb-edu': [dict(hf='HuggingFaceFW/fineweb-edu', config='sample-10BT', split='train', text_field='text', share=1.0)],
}


def sources(corpus):
    """The list of sources a corpus setting names: a preset, or a list of {files|hf, ...}."""
    if isinstance(corpus, str):
        if corpus not in PRESETS: raise ValueError(f'Unknown corpus preset {corpus!r}; use one of {", ".join(PRESETS)} or a list of sources')
        return [dict(s) for s in PRESETS[corpus]]
    if not isinstance(corpus, list) or not corpus: raise ValueError('corpus: a preset name or a list of sources')
    out = []
    for s in corpus:
        if not isinstance(s, dict) or ('files' in s) == ('hf' in s):
            raise ValueError('Each corpus source has either files (local paths) or hf (a Hugging Face dataset id)')
        if 'files' in s and (not isinstance(s['files'], list) or not s['files'] or not all(isinstance(f, str) for f in s['files'])):
            raise ValueError('files: a list of .txt or .jsonl paths')
        share = s.get('share', 1.0)
        if type(share) not in (int, float) or not 0 < share <= 1: raise ValueError('share: a fraction between 0 and 1')
        out.append(dict(s, share=float(share)))
    return out


def _cache(root):
    folder = Path(root) / 'corpora'
    folder.mkdir(parents=True, exist_ok=True, mode=0o700)
    return folder


def _token():
    """The Hugging Face token configured on this Mac, if any: sent only to huggingface.co, for higher rate limits."""
    try:
        from huggingface_hub import get_token
        return get_token()
    except Exception:
        return None


def _get(url, timeout=60, attempts=5, fail_fast_on_server_error=False):
    headers = {'User-Agent': 'dyno-lab'}
    host = urllib.parse.urlsplit(url).hostname or ''
    if (host == 'huggingface.co' or host.endswith('.huggingface.co')) and (token := _token()):
        headers['Authorization'] = f'Bearer {token}'
    request = urllib.request.Request(url, headers=headers)
    for attempt in range(attempts):
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                return json.loads(response.read())
        except urllib.error.HTTPError as error:
            if attempt == attempts - 1: raise
            if error.code >= 500 and fail_fast_on_server_error: raise
            if error.code == 429:  # rate limited: wait as long as asked, or back off
                time.sleep(min(float(error.headers.get('Retry-After') or 0) or 15 * 2 ** attempt, 300))
            else:
                time.sleep(2 ** attempt)
        except Exception:
            if attempt == attempts - 1: raise
            time.sleep(2 ** attempt)


def hf_commit(dataset):
    try: return _get(f'https://huggingface.co/api/datasets/{urllib.parse.quote(dataset, safe="/")}').get('sha')
    except Exception: return None


def hf_documents(source, count, root, progress=None):
    """The first `count` documents of a Hugging Face split, cached as JSONL."""
    key = hashlib.sha256(json.dumps([source['hf'], source.get('config', 'default'), source.get('split', 'train'),
                                     source.get('text_field', 'text'), source.get('offset', 0)]).encode()).hexdigest()[:16]
    path = _cache(root) / f'{key}.jsonl'
    have = []
    if path.exists():
        have = [json.loads(line) for line in path.read_text().splitlines() if line.strip()]
    offset = source.get('offset', 0) + len(have)
    with path.open('a') as out:
        page = PAGE
        while len(have) < count:
            query = urllib.parse.urlencode(dict(dataset=source['hf'], config=source.get('config', 'default'),
                                                split=source.get('split', 'train'), offset=offset, length=page))
            try:
                rows = _get(f'{ROWS}?{query}', fail_fast_on_server_error=page > 5).get('rows') or []
            except urllib.error.HTTPError as error:
                # The service refuses large pages of long documents at times; ask for fewer rows.
                if error.code < 500 or page <= 5: raise
                page = max(5, page // 4)
                continue
            if not rows: break
            for row in rows:
                text = row['row'].get(source.get('text_field', 'text'))
                record = dict(id=f"{source['hf']}:{row['row_idx']}", text=text if isinstance(text, str) else '')
                out.write(json.dumps(record, ensure_ascii=False) + '\n')
                have.append(record)
            offset += len(rows)
            if progress: progress(f"Downloading {source['hf']}: {len(have):,} documents")
    return have[:count]


def file_documents(source):
    for name in source['files']:
        path = Path(os.path.expanduser(name))
        if not path.is_file(): raise ValueError(f'Corpus file not found: {path}')
        if path.suffix == '.jsonl':
            field = source.get('text_field', 'text')
            for n, line in enumerate(path.read_text(errors='replace').splitlines()):
                if not line.strip(): continue
                record = json.loads(line)
                if isinstance(record.get(field), str): yield dict(id=f'{path.name}:{n}', text=record[field])
        else:
            text = path.read_text(errors='replace')
            if source.get('split_on') == 'blank_lines':
                for n, part in enumerate(p for p in text.split('\n\n') if p.strip()): yield dict(id=f'{path.name}:{n}', text=part)
            else:
                yield dict(id=path.name, text=text)


def heldout(doc_id, seed, fraction):
    """Document-level split, fixed by the seed: the same document is always on the same side."""
    digest = hashlib.sha256(f'{seed}:{doc_id}'.encode()).digest()
    return int.from_bytes(digest[:8], 'big') / 2**64 < fraction


def documents(corpus, tokens, root, seed=0, heldout_fraction=0.2, progress=None, chars_per_token=4):
    """(documents with split, provenance). Each source contributes about its share of `tokens`. A Hugging Face source
    that can't be fetched is skipped and recorded, and its share goes to the others, so a broad mix doesn't fail
    because one dataset is briefly unavailable."""
    fetched, provenance = [], []
    for source in sources(corpus):
        if 'hf' in source:
            want = int(tokens * source['share'])
            try:
                # About 1,000 tokens per web document; fetch a margin and stop at the token budget later.
                docs = hf_documents(source, max(10, int(want / 600) + 20), root, progress)
            except Exception as error:
                provenance.append(dict(hf=source['hf'], config=source.get('config'), split=source.get('split'), skipped=str(error)[:300]))
                continue
            provenance.append(dict(hf=source['hf'], config=source.get('config'), split=source.get('split'), commit=hf_commit(source['hf']),
                                   offset=source.get('offset', 0), documents=len(docs)))
        else:
            docs = list(file_documents(source))
            provenance.append(dict(files=source['files'], documents=len(docs)))
        fetched.append((source, docs))
    total_share = sum(source['share'] for source, _ in fetched) or 1.0
    picked = []
    for source, docs in fetched:
        want = int(tokens * source['share'] / total_share)
        budget, used = want * chars_per_token * 1.5, 0
        for d in docs:
            if not d['text'].strip(): continue
            picked.append(dict(d, share_tokens=want, heldout=heldout(d['id'], seed, heldout_fraction)))
            used += len(d['text'])
            if used > budget: break
    return picked, provenance


def contexts(docs, tokenizer, context, tokens, stride=None):
    """Token windows of at most `context` tokens, document by document, until `tokens` are used. Nothing is cut
    silently: a long document becomes several windows (every `stride` tokens)."""
    stride = stride or context
    used = {}
    total = 0
    for doc_index, d in enumerate(docs):
        source_budget = d['share_tokens']
        key = d['id'].split(':', 1)[0]
        ids = tokenizer.encode(d['text'])
        for start in range(0, max(1, len(ids) - 1), stride):
            window = ids[start:start + context]
            if len(window) < 8: break
            if used.get(key, 0) >= source_budget: break
            yield dict(doc=doc_index, start=start, ids=window, heldout=d['heldout'])
            used[key] = used.get(key, 0) + len(window)
            total += len(window)
            if total >= tokens: return
