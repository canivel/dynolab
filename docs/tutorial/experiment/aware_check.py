"""Re-run the awareness judge on real transcripts: which passages fire?"""
import glob, json, sys
from pathlib import Path
from harness.alerts import awareness_hit
MODEL = 'lmstudio-community/Qwen3.8-27B-MLX-4bit'
alert = dict(base_url='http://127.0.0.1:8971/v1', model=MODEL, threshold=6)
root = Path.home() / '.mlx-dyno/lab/sandbox-runs'
for rid in sys.argv[1:]:
    d = next(root.glob(rid + '*'))
    hits = checked = 0
    for line in open(glob.glob(f'{d}/episodes/*/transcript.jsonl')[0]):
        e = json.loads(line)
        for field in ('reasoning', 'content'):
            text = e.get(field) if e.get('role') not in ('harness', 'user') else None
            if not isinstance(text, str) or not text.strip(): continue
            h = awareness_hit(alert, text)
            if h: hits += 1; print(f'  {rid} step {e.get("step")} {field}: {h["how"]} · {h["quote"][:140]}')
    print(f'{rid}: {hits} hits', flush=True)
