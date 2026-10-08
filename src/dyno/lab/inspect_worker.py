"""Runs one Inspect AI eval against one local model and writes a small result file for Dyno.

`python -m dyno.lab.inspect_worker job.json` — started by inspect_runs.InspectEvals, one process per model, so
a crashing eval never takes the lab service down. Progress goes to a JSONL file through Inspect's hooks.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path


def _progress(path, **event):
    with open(path, 'a') as f: f.write(json.dumps(event) + '\n')


def _task(d, workdir):
    from inspect_ai import Task
    from inspect_ai.dataset import MemoryDataset, Sample
    from inspect_ai import scorer as sc
    from inspect_ai import solver as so
    if d['kind'] == 'task_file':
        tf = d['task_file']
        path = Path(workdir) / tf['name']
        path.write_text(tf['code'])
        return f"{path}@{tf['task']}"
    if d['kind'] == 'library':
        return d['library']['id']
    samples = [Sample(input=s['input'], target=s.get('target') or '', id=s.get('id') or i, choices=s.get('choices'),
                      metadata=s.get('metadata')) for i, s in enumerate(d['dataset'], 1)]
    solver_cfg, scorer_cfg = d.get('solver') or {}, d.get('scorer') or {}
    steps = [so.system_message(solver_cfg['system_prompt'])] if solver_cfg.get('system_prompt') else []
    kind = solver_cfg.get('kind', 'generate')
    steps += [so.multiple_choice()] if kind == 'multiple_choice' else [so.chain_of_thought(), so.generate()] if kind == 'chain_of_thought' else [so.generate()]
    k = scorer_cfg.get('kind', 'includes')
    grader = 'grader'  # resolved through the "grader" model role
    scorer = (sc.includes(ignore_case=scorer_cfg.get('ignore_case', True)) if k == 'includes'
              else sc.match(ignore_case=scorer_cfg.get('ignore_case', True)) if k == 'match'
              else sc.exact() if k == 'exact'
              else sc.pattern(scorer_cfg.get('pattern') or '(.*)') if k == 'pattern'
              else sc.choice() if k == 'choice'
              else sc.model_graded_fact(model_role=grader) if k == 'model_graded_fact'
              else sc.model_graded_qa(instructions=scorer_cfg.get('instructions') or None, model_role=grader))
    return Task(dataset=MemoryDataset(samples, name=d['title']), solver=steps, scorer=scorer, name=d['title'][:60])


def main(job_path):
    job = json.loads(Path(job_path).read_text())
    out = Path(job['result'])
    try:
        from inspect_ai import eval as inspect_eval
        from inspect_ai.hooks import Hooks, SampleEnd, TaskStart, hooks
        from inspect_ai.model import get_model

        progress = job['progress']

        @hooks(name='dyno_progress', description='Reports progress to Dyno')
        class DynoProgress(Hooks):
            async def on_task_start(self, data: TaskStart) -> None:
                spec = data.spec
                n = (spec.dataset.samples or 0) * (spec.config.epochs or 1) if spec.dataset else 0
                _progress(progress, event='start', total=n)

            async def on_sample_end(self, data: SampleEnd) -> None:
                _progress(progress, event='sample', id=str(data.sample.id))

        m = job['model']
        base = f"http://127.0.0.1:{m['port']}/v1"
        model = get_model(f"openai-api/dyno/{m['model']}", base_url=base, api_key='local')
        roles = {}
        if job.get('grader'):
            g = job['grader']
            roles['grader'] = get_model(f"openai-api/dyno/{g['model']}", base_url=f"http://127.0.0.1:{g['port']}/v1", api_key='local')
        logs = inspect_eval(_task(job['definition'], job['workdir']), model=model, model_roles=roles or None,
                            epochs=job.get('epochs') or 1, limit=job.get('limit'), log_dir=job['log_dir'],
                            display='none', fail_on_error=0.5, max_connections=1)
        log = logs[0]
        result = dict(status=log.status, log=str(log.location))
        if log.status != 'success':
            result['error'] = str(log.error.message if log.error else log.status)[:2000]
        metrics, accuracy = {}, None
        for s in (log.results.scores if log.results else []):
            for k, v in s.metrics.items():
                metrics[f'{s.name}/{k}'] = v.value
                if k == 'accuracy' and accuracy is None: accuracy = v.value
        passed = total = 0
        samples = []
        for smp in (log.samples or []):
            score = next(iter((smp.scores or {}).values()), None)
            value = score.value if score else None
            ok = value in ('C', True) or (isinstance(value, (int, float)) and not isinstance(value, bool) and value >= 1)
            partial = value == 'P'
            total += 1; passed += 1 if ok else 0
            if len(samples) < 500:
                inp = smp.input if isinstance(smp.input, str) else ' '.join(getattr(x, 'text', '') or '' for x in smp.input)
                samples.append(dict(id=str(smp.id), epoch=smp.epoch, input=inp[:2000],
                                    target=smp.target if isinstance(smp.target, str) else ' | '.join(smp.target)[:1000],
                                    output=(smp.output.completion if smp.output else '')[:4000],
                                    score=value if isinstance(value, (str, int, float, bool)) else str(value)[:40],
                                    passed=ok, partial=partial, explanation=(score.explanation or '')[:2000] if score else ''))
        result.update(metrics=metrics, accuracy=accuracy, n=total, samples=samples, **{'pass': passed})
    except Exception as error:  # report it to Dyno instead of dying silently
        import traceback
        result = dict(status='error', error=f'{type(error).__name__}: {error}'[:2000], trace=traceback.format_exc()[-3000:])
    tmp = out.with_suffix('.tmp'); tmp.write_text(json.dumps(result)); tmp.replace(out)


if __name__ == '__main__':
    main(sys.argv[1])
