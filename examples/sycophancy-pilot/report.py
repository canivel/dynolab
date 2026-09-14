"""Validate the saved evidence and produce a readable report without inference."""
import hashlib
import json
from pathlib import Path
from run import cases, classify, summarize


def validate(root):
    raw = (root / 'cases.json').read_bytes()
    manifest = json.loads((root / 'manifest.json').read_text())
    if hashlib.sha256(raw).hexdigest() != manifest['cases_sha256']:
        raise ValueError('Frozen case hash does not match the manifest')
    frozen = json.loads(raw)
    if frozen != cases():
        raise ValueError('Source case generator differs from frozen run')
    rows = json.loads((root / 'answers.json').read_text())
    if len(rows) != len(frozen) or len({r['id'] for r in rows}) != len(frozen):
        raise ValueError('Run incomplete or contains duplicate responses')
    by_id = {r['id']: r for r in frozen}
    for row in rows:
        if any(row[key] != value for key, value in by_id[row['id']].items()):
            raise ValueError('Answer metadata differs from frozen case')
        if row['choice'] != classify(row['answer']):
            raise ValueError('Saved score differs from strict parser')
    return rows, manifest


def main():
    root = Path(__file__).parent / 'run'
    rows, manifest = validate(root)
    summary = summarize(rows)
    cap = [r['id'] for r in rows if r['generated_tokens'] >= manifest['max_tokens']]
    lines = ['# Qwen3.8 sycophancy pilot: observed results', '',
             'These are local model outputs from an exploratory, author-created dataset. '
             'This is not an Anthropic benchmark replication or a safety certification.', '',
             '| Condition | Correct | Incorrect | Invalid |', '|---|---:|---:|---:|']
    for condition in ('neutral', 'correct_belief', 'incorrect_belief'):
        s = summary[condition]
        lines.append(f'| {condition} | {s["correct"]}/{s["total"]} | {s["incorrect"]} | {s["invalid"]} |')
    lines.extend(['', f'Correct-to-incorrect paired flips: {len(summary["correct_to_incorrect_flips"])}/12.',
                  f'Responses reaching the output cap: {len(cap)}. IDs: {cap}.', '',
                  'No probe or causal steering result is implied by these behavioral measurements. '
                  'All 12 facts and the pressure template are reserved for pilot use only.', '',
                  '## Every response', ''])
    for row in rows:
        lines.extend([f'### {row["id"]}', '', row['user'], '',
                      f'Expected: {row["correct"]}; parsed: {row["choice"]}.', '',
                      '```text', row['answer'], '```', ''])
    (root / 'REPORT.md').write_text('\n'.join(lines))
    print(json.dumps(summary, indent=2))
    print('Output-cap cases:', cap)


if __name__ == '__main__':
    main()
