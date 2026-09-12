"""Validated, user-initiated Windows setup; no password collection."""
import base64
import csv
import io
import json
from pathlib import Path
import re
import tempfile

from .runtime import private_ip
from .worker import bundle_root, run_hidden


def setup_request(address, key):
    address = str(private_ip(address.strip()))
    parts = key.strip().split()
    if len(parts) < 2 or parts[0] != 'ssh-ed25519':
        raise ValueError('Paste an Ed25519 public key starting with ssh-ed25519.')
    try:
        decoded = base64.b64decode(parts[1], validate=True)
    except ValueError as exc:
        raise ValueError('Invalid public key encoding') from exc
    if len(decoded) != 51 or decoded[:19] != b'\x00\x00\x00\x0bssh-ed25519\x00\x00\x00\x20':
        raise ValueError('Invalid Ed25519 public key')
    if '\n' in key.strip() or '\r' in key.strip():
        raise ValueError('Paste exactly one public key')
    return dict(mac_address=address, public_key='ssh-ed25519 ' + parts[1])


def launch_setup(request):
    return launch_elevated(request, 'setup-lan.ps1')


def launch_elevated(request, script_name):
    identity = run_hidden(['whoami', '/user', '/fo', 'csv', '/nh'], capture_output=True, text=True, timeout=10)
    if identity.returncode:
        raise ValueError('Could not identify the current Windows account')
    rows = list(csv.reader(io.StringIO(identity.stdout.strip())))
    sid = rows[0][-1]
    if not re.fullmatch(r'S-1-[0-9-]+', sid):
        raise ValueError('Could not read the Windows account SID')
    with tempfile.TemporaryDirectory(prefix='dyno-worker-setup-') as folder:
        request_path = Path(folder) / 'request.json'
        result_path = Path(folder) / 'result.txt'
        request_path.write_text(json.dumps(request | {'user_sid': sid}), encoding='utf-8')
        script = bundle_root() / script_name
        # Encode fixed PowerShell syntax rather than interpolating user data into a shell.
        def literal(value):
            return "'" + str(value).replace("'", "''") + "'"
        elevated = '& ' + literal(script) + ' -RequestPath ' + literal(request_path) + ' -ResultPath ' + literal(result_path)
        encoded = base64.b64encode(elevated.encode('utf-16le')).decode('ascii')
        wrapper = "$ErrorActionPreference = 'Stop'; try { $p = Start-Process powershell.exe -Verb RunAs -Wait -PassThru -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-EncodedCommand','" + encoded + "'; exit $p.ExitCode } catch { [Console]::Error.WriteLine('Windows setup was cancelled or could not start: ' + $_.Exception.Message); exit 1 }"
        result = run_hidden(['powershell.exe', '-NoProfile', '-Command', wrapper], capture_output=True, text=True)
        output = result_path.read_text(encoding='utf-8-sig') if result_path.exists() else result.stderr.strip()
        if result.returncode:
            raise ValueError(output or 'Windows setup was cancelled or failed')
        if not result_path.exists() or not output.strip():
            raise ValueError('Windows setup returned no result; connection setup was not confirmed')
        return output
