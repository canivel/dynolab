"""Include licenses and the unmodified pure-Python discovery source in the ZIP."""
import importlib.metadata
from pathlib import Path
import shutil
import sys

app = Path(sys.argv[1])
for name in ('zeroconf', 'ifaddr', 'cryptography', 'cffi', 'pycparser'):
    distribution = importlib.metadata.distribution(name)
    target = app / 'third-party' / name
    target.mkdir(parents=True, exist_ok=True)
    (target / 'VERSION.txt').write_text(distribution.version, encoding='utf-8')
    for entry in distribution.files or []:
        if entry.name.lower().startswith(('license', 'copying')):
            shutil.copyfile(distribution.locate_file(entry), target / entry.name)
    if name == 'zeroconf':
        source = distribution.locate_file('zeroconf')
        shutil.copytree(source, target / 'source' / 'zeroconf', dirs_exist_ok=True,
                        ignore=shutil.ignore_patterns('__pycache__', '*.pyc'))
