"""Audit saved pilot artifacts and export every response for review."""
import hashlib
import json
import random
from run import ROOT, cases


def main():
    import numpy as np
    folder=ROOT/'run'
    manifest=json.loads((folder/'manifest.json').read_text())
    if hashlib.sha256(json.dumps(cases(),sort_keys=True).encode()).hexdigest()!=manifest['cases_sha256']:
        raise ValueError('Frozen dataset hash differs')
    rows=json.loads((folder/'answers.json').read_text())
    trials=json.loads((folder/'steering.json').read_text())
    if {r['id'] for r in rows}!={r['id'] for r in cases()} or len(rows)!=10:
        raise ValueError('Missing or duplicate generation rows')
    expected={f'eval-{i}-{c}' for i in range(2) for c in ('zero','negative','positive','random')}
    if {r['id'] for r in trials}!=expected or len(trials)!=8:
        raise ValueError('Missing or duplicate intervention rows')
    for row in rows:
        if len(row['token_ids'])!=row['prompt_tokens']+row['response_tokens']:
            raise ValueError('Invalid captured token span')
        with np.load(folder/row['artifact']) as vectors:
            if any(not np.isfinite(vectors[k]).all() for k in vectors.files):
                raise ValueError('Nonfinite capture')
    for trial in [t for t in trials if t['condition']=='zero']:
        baseline=next(r for r in rows if r['split']=='eval' and r['group']==trial['group'])
        if trial['answer']!=baseline['answer']:
            raise ValueError('Zero control failed')
    with np.load(folder/'directions.npz') as vectors:
        np.testing.assert_allclose(np.linalg.norm(vectors['response_direction']),np.linalg.norm(vectors['random_control']),rtol=1e-6)
    capped=[r['id'] for r in rows+trials if r['generated_tokens']>=160]
    summary=dict(extraction_pairs=4,baseline_evaluation_questions=2,generated_responses=18,
        zero_controls_exact_matches=2,output_cap_cases=capped,
        assessment='Unblinded model-assisted qualitative review: extraction instructions elicited clear agreement contrast; no clear directional behavioral shift on these two evaluation questions at coefficients -0.5 and +0.5.',
        limitation='Not an independent judge evaluation, population estimate, faithful paper replication, or evidence of safety improvement.')
    (folder/'summary.json').write_text(json.dumps(summary,indent=2))
    lines=['# Persona-vector pilot results','',summary['assessment'],'',summary['limitation'],'',
           'Four extraction pairs; two evaluation questions; eight intervention outputs. '
           'Both zero-strength controls exactly reproduced baseline text. '
           f'Output-cap cases: {capped}.','',
           '## Extraction and separate evaluation baselines','']
    for row in rows:
        lines += [f'### {row["id"]}','',row['question'],'','```text',row['answer'],'```','']
    lines += ['## Fixed-strength interventions','']
    for trial in trials:
        lines += [f'### {trial["id"]}', '', trial['question'],'','```text',trial['answer'],'```','']
    (folder/'REPORT.md').write_text('\n'.join(lines))
    shuffled=list(trials);random.Random(20260914).shuffle(shuffled)
    packet=[dict(id=f'review-{i+1:02}',question=t['question'],answer=t['answer']) for i,t in enumerate(shuffled)]
    key={f'review-{i+1:02}':t['id'] for i,t in enumerate(shuffled)}
    (folder/'review-packet.json').write_text(json.dumps(packet,indent=2))
    (folder/'review-key.json').write_text(json.dumps(key,indent=2))
    print(json.dumps(summary,indent=2))


if __name__=='__main__':
    main()
