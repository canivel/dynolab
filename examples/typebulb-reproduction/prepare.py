"""Fetch Typebulb's public prompt definitions into a LOCAL plan; does not execute source code."""
import argparse
import hashlib
import html
import json
from pathlib import Path
import re
import urllib.request

URL = 'https://typebulb.com/u/lab/you-re-absolutely-right/full'
EXPECTED = '2bf3f5f51341a03410ed31b75ec0fc86cf332fe2d71a0f76cde41296ed449d38'
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--source-html', type=Path, help='Previously downloaded full source page, for offline reproduction')
p.add_argument('--output', type=Path, required=True)
p.add_argument('--model', required=True)
p.add_argument('--revision', required=True, help='Pinned local model revision for the protocol record')
p.add_argument('--port', type=int, default=8971)
p.add_argument('--extended', action='store_true', help='Include the separately labelled controls, repeat and thinking demonstration')
p.add_argument('--accept-source-change', action='store_true')
args = p.parse_args()
source = html.unescape(args.source_html.read_text() if args.source_html else urllib.request.urlopen(urllib.request.Request(URL, headers={'User-Agent':'DynoLab/0.4.0 research-reproduction', 'Accept':'text/html'}), timeout=30).read().decode())
start = source.index('const DEFAULTS:')
source = source[start:source.index('const SCORE_COLORS', start)]
items = []
for block in re.split(r'\{ id: ', source)[1:]:
    fields = {}
    for match in re.finditer(r'(id|judgeType|name|description|userMessage|pushback|seedResponse|judgeHint):\s*("(?:\\.|[^"\\])*")', 'id: '+block, re.S):
        fields[match[1]] = json.loads(match[2], strict=False)
    items.append(fields)
assert [x['id'] for x in items] == ['a2','a3','p1','p2','a1','c1','c3','c2'], 'Source structure changed; review before running'
serialized = json.dumps(items, indent=2, ensure_ascii=False)
digest = hashlib.sha256(serialized.encode()).hexdigest()
if digest != EXPECTED and not args.accept_source_change:
    raise SystemExit(f'Source changed ({digest}). Review before explicitly accepting a new protocol.')
args.output.mkdir(parents=True, exist_ok=True)
(args.output/'source-prompts.json').write_text(serialized)
cases = []
for item in items:
    context = []
    if item.get('seedResponse'):
        context = [{'role':'user','content':item['userMessage']},{'role':'assistant','content':item['seedResponse']}]
    cases.append({'title':item['id']+' · '+item['name']+' · original','input':dict(model=args.model, port=args.port, system='', prompt=item.get('pushback',item['userMessage']), context=context, thinking='off', temperature=0.0, maxTokens=3072, seed=0)})
if args.extended:
    import copy
    controls = json.loads(Path(__file__).with_name('controls.json').read_text())
    for control in controls:
        origin = next((c for c in cases[:8] if c['title'].startswith(str(control.get('source_id'))+' ·')), None)
        settings = copy.deepcopy(origin['input'] if origin else cases[0]['input'])
        if not origin:
            settings['context'] = []
        if control.get('transform') == 'swap beer names':
            settings['prompt'] = settings['prompt'].replace('Budweiser and Coors','Coors and Budweiser').replace('Bud has','Coors has').replace('while Coors is','while Budweiser is')
        elif control.get('replacement_user_turn'):
            settings['prompt'] = control['replacement_user_turn']
        settings['thinking'] = control['thinking']; settings['maxTokens'] = control['maxTokens']
        cases.append({'title':control['title'],'input':settings})
plan = dict(title='Typebulb local reproduction', question='Which claims change under pressure, and are they correct?', hypothesis='Agreement and correctness need separate assessment.', protocolNote=f'Eight default cases, one greedy trial each. Source {URL}; prompt SHA256 {digest}. Model {args.model}; pinned revision {args.revision}. Thinking off, cap 3072, no system message, seed 0. Assistant seeds come from the benchmark. Not the hosted adaptive median-of-three judge recipe. Preserve incomplete outcomes; inspect evidence before assigning labels.', cases=cases)
(args.output/'plan.json').write_text(json.dumps(plan,indent=2,ensure_ascii=False))
if args.extended:
    plan['protocolNote'] += ' Extended protocol includes planned reassessment controls and historically exploratory follow-ups. Consult the report for when each condition was selected.'
    (args.output/'plan.json').write_text(json.dumps(plan,indent=2,ensure_ascii=False))
print(args.output/'plan.json')
