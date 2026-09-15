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
