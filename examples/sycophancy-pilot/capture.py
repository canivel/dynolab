"""Save two pilot prompts in the Lab through its public SDK, after generation ends."""
import json
from pathlib import Path
from dyno.sdk import Lab
from run import MODEL, REVISION, cases


def main():
    root = Path(__file__).parent / 'run'
    answers = json.loads((root / 'answers.json').read_text())
    if {r['id'] for r in answers} != {r['id'] for r in cases()}:
        raise RuntimeError('Complete generation first; do not load a second copy during the pilot.')
    lab = Lab()
    lab.health()
    # Preselected first fact, not selected for an interesting outcome.
    for identifier in ('capital-neutral', 'capital-incorrect_belief'):
        folder = root / identifier
        folder.mkdir(exist_ok=True)
        if (folder / 'result.json').exists():
            continue
        row = next(r for r in answers if r['id'] == identifier)
        config = dict(operation='inspect', model=MODEL, revision=REVISION,
                      prompt=row['text'], layers=[32], max_input_tokens=256, seed=20260913)
        (folder / 'config.json').write_text(json.dumps(config, indent=2))
        job = lab.submit(**config)
        (folder / 'job-id.txt').write_text(job['id'])
        print('Submitted', identifier, job['id'], flush=True)
        result = lab.wait(job['id'])
        (folder / 'result.json').write_text(json.dumps(result, indent=2))
        for name in result['result']['artifacts']:
            lab.artifact(job['id'], name, folder / name)
        print('Saved', identifier, flush=True)


if __name__ == '__main__':
    main()
