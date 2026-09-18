"""Conservative eligibility checks. Unknown identity is never a confirmed match."""
import hashlib
import re
from pathlib import Path
from .studies import digest

FIELDS = ('revision','architecture','quantization','tokenizer_sha256','model_config_sha256','hook','layer','pooling','dimension','normalization','backend')


def fingerprint(model_path, config, dimension, backend='mlx', layer=None):
    root=Path(model_path)
    files={}
    for name in ('tokenizer.json','tokenizer.model','tokenizer_config.json','special_tokens_map.json'):
        path=root/name
        if path.is_file() and path.stat().st_size <= 64*1024*1024:
            files[name]=hashlib.sha256(path.read_bytes()).hexdigest()
    revision=root.name if root.parent.name=='snapshots' and re.fullmatch('[a-f0-9]{40}',root.name) else None
    return dict(schema='dyno.compatibility/1',revision=revision,architecture=config.get('model_type'),
        quantization=config.get('quantization',config.get('quantization_config')),
        tokenizer_sha256=digest(files) if files else None,model_config_sha256=digest(config) if config else None,
        hook='block output',layer=layer,pooling='last input token',dimension=dimension,normalization='training-only mean and standard deviation, floor 0.01',backend=backend)


def compare_contracts(source, target):
    if not isinstance(source,dict) or not isinstance(target,dict):raise ValueError('Compatibility contracts must be objects')
    rows=[]
    for key in FIELDS:
        a,b=source.get(key),target.get(key)
        state='unknown' if a is None or b is None else 'match' if a==b else 'mismatch'
        rows.append(dict(field=key,source=a,target=b,status=state))
    status='mismatch' if any(r['status']=='mismatch' for r in rows) else 'unknown' if any(r['status']=='unknown' for r in rows) else 'compatible'
    return dict(status=status,allowed=status=='compatible',fields=rows,
        explanation='Strict reuse requires every field to match. Unknown metadata blocks eligibility. Snapshot revisions and local file hashes describe available identity; this check does not attest weight integrity, scientific validity or numerical parity. It does not execute or apply an artifact.')


def require_compatible(source,target):
    report=compare_contracts(source,target)
    if not report['allowed']:raise ValueError('Artifact reuse blocked: '+report['status'])
    return report
