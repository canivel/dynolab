"""The neuron operations, run by the Lab worker: one per process, with progress written for the Lab service."""
from __future__ import annotations

import hashlib
import importlib.metadata
import json
import time
from pathlib import Path

OPERATIONS = ('capture', 'atlas', 'sae_train', 'ablate', 'units', 'autointerp')
# Hours a job may run before the service stops it.
LIMITS = dict(capture=48, atlas=4, sae_train=48, ablate=12, units=4, autointerp=48)


def progress_writer(folder):
    path = Path(folder) / 'progress.json'
    started = time.time()
    last = [0.0]

    def write(message, fraction=None):
        now = time.time()
        if now - last[0] < 0.5 and fraction not in (0.0, 1.0): return
        last[0] = now
        eta = None
        if fraction and 0 < fraction < 1: eta = (now - started) * (1 - fraction) / fraction
        temporary = path.with_suffix('.tmp')
        temporary.write_text(json.dumps(dict(message=message, fraction=fraction, eta_seconds=eta, updated=now)))
        temporary.replace(path)
    return write


def loader(config):
    """load_model(hook, layers): the model with hooks installed, checked on a real prompt."""
    def load_model(hook, layers):
        from mlx_lm import load
        from . import hooks
        model, tokenizer, model_config = load(config['model'], tokenizer_config={'trust_remote_code': False}, return_config=True,
                                              revision=config.get('revision'))
        captured, active, collecting = {}, {}, [True]
        info = hooks.install(model, layers, hook, captured, active, collecting, model_config)
        info['reconstruction_error'] = hooks.check(model, tokenizer, layers, hook)
        info['model_layers'] = len(hooks.layers_of(model)[0])
        load_model.state = dict(model=model, tokenizer=tokenizer, model_config=model_config, active=active, captured=captured)
        return model, tokenizer, model_config, captured, collecting, info
    return load_model


def provenance(config, model_config=None, started=None):
    model_path = Path(config['model']).expanduser()
    out = dict(model=config['model'], requested_revision=config.get('revision'), seed=config.get('seed', 0),
               config_sha256=hashlib.sha256(json.dumps({k: v for k, v in config.items() if k != 'lab_root'}, sort_keys=True).encode()).hexdigest(),
               mlx_version=_version('mlx'), mlx_lm_version=_version('mlx-lm'), seconds=time.time() - started if started else None)
    if model_config: out['model_config'] = {k: v for k, v in model_config.items() if isinstance(v, (int, float, str, bool))}
    if model_path.is_dir():
        out['weight_file_manifest'] = [dict(name=p.name, bytes=p.stat().st_size) for p in sorted(model_path.glob('*.safetensors'))]
    return out


def _version(name):
    try: return importlib.metadata.version(name)
    except importlib.metadata.PackageNotFoundError: return None


def run(config, folder):
    folder = Path(folder)
    config = dict(config, lab_root=str(folder.parent))
    started = time.time()
    progress = progress_writer(folder)
    load_model = loader(config)
    operation = config['operation']
    if operation == 'capture':
        from . import capture
        result = capture.run(config, folder, load_model, progress)
    elif operation == 'atlas':
        from . import atlas
        result = atlas.run(config, folder, progress)
    elif operation == 'sae_train':
        from . import sae
        result = sae.run(config, folder, load_model, progress)
    elif operation == 'ablate':
        from . import ablation
        result = ablation.run(config, folder, load_model, progress)
    elif operation == 'units':
        from . import units
        result = units.run(config, folder, load_model, progress)
    elif operation == 'autointerp':
        from . import autointerp
        result = autointerp.run(config, folder, progress)
    else:
        raise ValueError(f'Unknown operation {operation}')
    state = getattr(load_model, 'state', {})
    result['provenance'] = dict(provenance(config, state.get('model_config'), started), **({'hook': result.get('hook')} if result.get('hook') else {}))
    result['artifacts'] = sorted(p.name for p in folder.iterdir() if p.is_file() and p.suffix in ('.npz', '.npy', '.safetensors', '.json')
                                 and p.name not in ('job.json', 'result.json', 'progress.json'))
    progress('Done', 1.0)
    (folder / 'result.json').write_text(json.dumps(result, ensure_ascii=False, indent=2))
