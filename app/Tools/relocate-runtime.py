"""Make bundled Mach-O pool libraries resolve beside each binary, not in the build tree."""
from pathlib import Path
import re
import subprocess
import sys

root = Path(sys.argv[1]).resolve()
for binary in root.iterdir():
    if binary.is_symlink() or not binary.is_file():
        continue
    if 'Mach-O' not in subprocess.check_output(['file', '-b', str(binary)], text=True):
        continue
    load_commands = subprocess.check_output(['otool', '-l', str(binary)], text=True)
    paths = re.findall(r'cmd LC_RPATH\s+cmdsize \d+\s+path (.*?) \(offset', load_commands)
    for path in paths:
        if path.startswith('/'):
            subprocess.run(['install_name_tool', '-delete_rpath', path, str(binary)], check=True)
    if '@loader_path' not in paths:
        subprocess.run(['install_name_tool', '-add_rpath', '@loader_path', str(binary)], check=True)
# The enclosing build signs every modified Mach-O after this step.

# Never ship an executable that works only because the build host has Homebrew.
for binary in root.iterdir():
    if binary.is_symlink() or not binary.is_file():
        continue
    if 'Mach-O' not in subprocess.check_output(['file', '-b', str(binary)], text=True):
        continue
    dependencies = subprocess.check_output(['otool', '-L', str(binary)], text=True).splitlines()[1:]
    for line in dependencies:
        dependency = line.strip().split(' (', 1)[0]
        if dependency.startswith('/') and not dependency.startswith(('/usr/lib/', '/System/Library/')):
            raise SystemExit(f'Unbundled dependency in {binary.name}: {dependency}')
        for prefix in ('@rpath/', '@loader_path/'):
            if dependency.startswith(prefix) and not (root / dependency[len(prefix):]).is_file():
                raise SystemExit(f'Missing bundled dependency in {binary.name}: {dependency}')
