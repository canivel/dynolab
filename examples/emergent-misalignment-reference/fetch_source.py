"""Fetch the pinned upstream evaluation source for the held reference study."""
from pathlib import Path
import json, hashlib, urllib.request
p=Path(__file__).parent/'upstream'
m=json.loads((p/'manifest.json').read_text())
data=urllib.request.urlopen(m['url']).read()
if hashlib.sha256(data).hexdigest()!=m['sha256']: raise ValueError('Upstream source hash mismatch')
(p/'questions.yaml').write_bytes(data)
