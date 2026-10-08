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


def _task(d, workdir, library=None, judge=None):
    from inspect_ai import Task
    from inspect_ai.dataset import MemoryDataset, Sample
    from inspect_ai import scorer as sc
    from inspect_ai import solver as so
    if d['kind'] == 'task_file':
        tf = d['task_file']
        path = Path(workdir) / tf['name']
        path.write_text(tf['code'])
        return f"{path}@{tf['task']}"
    if d['kind'] == 'library' and (library or {}).get('source'):
        return _from_source(library, judge, workdir)
    if d['kind'] == 'library':
        # inspect_evals registers its tasks by plain name (xstest, not inspect_evals/xstest): look the function up and
        # hand the judge to whatever parameter this benchmark uses for it.
        from inspect_ai._util.entrypoints import ensure_entry_points
        from inspect_ai._util.registry import registry_find
        ensure_entry_points()
        name = (library or {}).get('task') or d['library']['id'].split('/')[-1]
        found = registry_find(lambda i: i.type == 'task' and i.name == name)
        if not found: raise RuntimeError(f'{name} is not in the installed benchmark library')
        args = {a: judge for a in (library or {}).get('judge_args') or []} if judge is not None else {}
        return found[0](**args)
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


def _from_source(library, judge, workdir):
    """A benchmark built from its authors' openly licensed data (XSTest: CC BY 4.0 on GitHub), scored exactly as
    inspect_evals scores it, so no gated Hugging Face mirror or token is needed."""
    import csv
    import io
    import urllib.request
    from inspect_ai import Task
    from inspect_ai.dataset import MemoryDataset, Sample
    from inspect_ai.model import GenerateConfig
    from inspect_ai.scorer import model_graded_qa
    from inspect_ai.solver import generate, system_message
    from inspect_evals.xstest.xstest import refusal_rate, scorer_instructions, scorer_template
    cache = Path(workdir).parent.parent / 'datasets' / 'xstest_prompts.csv'
    if not cache.exists():
        cache.parent.mkdir(parents=True, exist_ok=True)
        with urllib.request.urlopen(library['source'], timeout=60) as r: cache.write_bytes(r.read())
    rows = [r for r in csv.DictReader(io.StringIO(cache.read_text())) if r.get('label') == library['subset']]
    samples = [Sample(input=r['prompt'], id=f"xstest-{r['id']}", metadata={k: r.get(k) for k in ('type', 'note', 'label', 'focus')}) for r in rows]
    return Task(dataset=MemoryDataset(samples, name=f"xstest_{library['subset']}"),
                solver=[system_message('You are a helpful assistant.'), generate()],
                scorer=model_graded_qa(model=judge, template=scorer_template, instructions=scorer_instructions),
                # 2,048 tokens, not the original 256: models that think first spend 256 on thinking and answer nothing.
                metrics=[refusal_rate()], config=GenerateConfig(temperature=0, max_tokens=2048), name=f"xstest_{library['subset']}")


def main(job_path):
    job = json.loads(Path(job_path).read_text())
    out = Path(job['result'])
    try:
        from inspect_ai import eval as inspect_eval
        from inspect_ai.hooks import Hooks, SampleEnd, TaskStart, hooks
        from inspect_ai.model import GenerateConfig, get_model

        progress = job['progress']

        @hooks(name='dyno_progress', description='Reports progress to Dyno')
        class DynoProgress(Hooks):
            async def on_task_start(self, data: TaskStart) -> None:
                spec = data.spec
                n = (spec.dataset.samples or 0) if spec.dataset else 0
                if job.get('limit'): n = min(n, job['limit'])  # a run limited to N samples shows N, not the dataset's size
                n *= spec.config.epochs or 1
                _progress(progress, event='start', total=n)

            async def on_sample_end(self, data: SampleEnd) -> None:
                _progress(progress, event='sample', id=str(data.sample.id))

        m = job['model']
        base = f"http://127.0.0.1:{m['port']}/v1"
        model = get_model(f"openai-api/dyno/{m['model']}", base_url=base, api_key='local')
        roles = {}
        if job.get('grader'):
            g = job['grader']
            # The judge grades without its own thinking phase (local reasoning models otherwise spend minutes, and
            # thousands of tokens, before every verdict), with room for the short reasoning the rubric asks for.
            roles['grader'] = get_model(f"openai-api/dyno/{g['model']}", base_url=f"http://127.0.0.1:{g['port']}/v1", api_key='local',
                                        config=GenerateConfig(temperature=0, max_tokens=2048,
                                                              extra_body={'chat_template_kwargs': {'enable_thinking': False}}))
        task = _task(job['definition'], job['workdir'], job.get('library'), roles.get('grader'))
        # Local servers default to short replies (mlx: 512 tokens). A model that thinks first spends them all on
        # thinking and answers nothing, so the eval would measure the token limit. Ask for room to answer.
        logs = inspect_eval(task, model=model, model_roles=roles or None, max_tokens=job.get('max_tokens') or 8192,
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
        passed = total = cut = 0  # cut: answers that hit the token limit or came back empty
        binary = True  # right/wrong scores (C/I/P, booleans, 0/1); dict or graded scores have no pass count
        samples = []
        for smp in (log.samples or []):
            score = next(iter((smp.scores or {}).values()), None)
            value = score.value if score else None
            ok = value in ('C', True) or (isinstance(value, (int, float)) and not isinstance(value, bool) and value >= 1)
            partial = value == 'P'
            if not (value in ('C', 'I', 'P', 'N', True, False) or (isinstance(value, (int, float)) and value in (0, 1))): binary = False
            total += 1; passed += 1 if ok else 0
            stop = getattr(smp.output, 'stop_reason', None) if smp.output else None
            empty = not (smp.output.completion if smp.output else '').strip()
            if stop == 'max_tokens' or empty: cut += 1
            if len(samples) < 500:
                inp = smp.input if isinstance(smp.input, str) else ' '.join(getattr(x, 'text', '') or '' for x in smp.input)
                samples.append(dict(id=str(smp.id), epoch=smp.epoch, input=inp[:2000],
                                    target=smp.target if isinstance(smp.target, str) else ' | '.join(smp.target)[:1000],
                                    output=(smp.output.completion if smp.output else '')[:4000],
                                    score=value if isinstance(value, (str, int, float, bool)) else str(value)[:40],
                                    passed=ok, partial=partial, explanation=(score.explanation or '')[:2000] if score else '',
                                    stop=str(stop) if stop else None, empty=empty))
        result.update(metrics=metrics, accuracy=accuracy, n=total, samples=samples, cut=cut, **{'pass': passed if binary else None})
    except Exception as error:  # report it to Dyno instead of dying silently
        import traceback
        result = dict(status='error', error=f'{type(error).__name__}: {error}'[:2000], trace=traceback.format_exc()[-3000:])
    tmp = out.with_suffix('.tmp'); tmp.write_text(json.dumps(result)); tmp.replace(out)


if __name__ == '__main__':
    main(sys.argv[1])
