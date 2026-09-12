"""Mac coordinator with loopback RPC carried over a strict LAN SSH tunnel.

Discovery pairing is handled separately; this runtime retains strict SSH trust.
"""
from __future__ import annotations
import ipaddress
import json
import os
from pathlib import Path
import re
import signal
import socket
import subprocess
import sys
import time
import threading
import urllib.request

LLAMA_REVISION = '5bda51bfbc62e64193221e639f6ad4e08767d760'
PRIVATE = tuple(ipaddress.ip_network(n) for n in ('10.0.0.0/8','172.16.0.0/12','192.168.0.0/16'))


def private_ip(value):
    ip = ipaddress.IPv4Address(value)
    if not any(ip in n for n in PRIVATE):
        raise ValueError('Use a private IPv4 LAN address; public, loopback and link-local peers are not allowed')
    return ip


def interfaces(text):
    result, name, active, entries = [], '', False, []
    def finish():
        if active and re.fullmatch(r'(en|bridge)\d+', name):
            result.extend(dict(interface=name, address=a, network=str(ipaddress.IPv4Network((a, m), strict=False))) for a,m in entries)
    for line in text.splitlines():
        if line and not line[0].isspace():
            finish(); name=line.split(':')[0]; active=False; entries=[]
        if 'status: active' in line: active=True
        m=re.search(r'\binet (\d+\.\d+\.\d+\.\d+) netmask (0x[0-9a-fA-F]+)', line)
        if m:
            try:
                private_ip(m[1]); entries.append((m[1], str(ipaddress.IPv4Address(int(m[2],16)))))
            except ValueError: pass
    finish()
    return result


def lan_interfaces():
    if sys.platform != 'darwin': raise ValueError('The coordinator preview currently runs on macOS; workers may run on Windows, WSL or Linux')
    return interfaces(subprocess.check_output(['/sbin/ifconfig'], text=True))


def validate(config, inventory):
    if not isinstance(config,dict): raise ValueError('Configuration must be a JSON object')
    allowed={'binary','model','local_address','peer','user','ssh_port','rpc_port','port','context','alias','pairing_id','load_timeout_seconds'}
    if set(config)-allowed: raise ValueError('Unknown configuration fields: '+', '.join(sorted(set(config)-allowed)))
    c=dict(config)
    for key in ('binary','model','local_address','peer','user'):
        if not isinstance(c.get(key),str) or not c[key].strip(): raise ValueError(f'{key} is required')
    local,peer=private_ip(c['local_address']),private_ip(c['peer'])
    interface=next((n for n in inventory if n['address']==str(local)),None)
    if not interface: raise ValueError('Choose an active wired/Wi-Fi LAN address on this Mac')
    network=ipaddress.ip_network(interface['network'])
    if peer not in network or peer in (network.network_address,network.broadcast_address,local):
        raise ValueError('Worker must be another host on the selected interface’s directly connected subnet')
    if not re.fullmatch(r'[A-Za-z_][A-Za-z0-9_.-]{0,63}',c['user']): raise ValueError('Use a simple SSH account name')
    for key,default in [('ssh_port',22),('rpc_port',50052),('port',8978),('context',2048)]:
        c.setdefault(key,default)
        limit=32768 if key=='context' else 65535
        if type(c[key]) is not int or not 1<=c[key]<=limit: raise ValueError(f'Invalid {key}')
    c.setdefault('load_timeout_seconds', 600)
    if type(c['load_timeout_seconds']) is not int or not 60 <= c['load_timeout_seconds'] <= 7200:
        raise ValueError('load_timeout_seconds must be an integer between 60 and 7200')
    c.setdefault('alias','dyno-pool')
    if not isinstance(c['alias'],str) or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,63}',c['alias']): raise ValueError('Invalid model alias')
    for key in ('binary','model'):
        c[key]=str(Path(c[key]).expanduser().resolve())
        if not Path(c[key]).is_file(): raise ValueError(f'{key} must be an existing local file')
    if not os.access(c['binary'],os.X_OK): raise ValueError('llama-server is not executable')
    with open(c['model'],'rb') as f:
        if f.read(4)!=b'GGUF': raise ValueError('Pool requires GGUF weights; an MLX model folder cannot be reused')
    if 'pairing_id' in c: paired_directory(c)
    c['interface']=interface['interface']
    return c


def check_route(c):
    route=subprocess.check_output(['/sbin/route','-n','get',c['peer']],text=True)
    m=re.search(r'interface:\s*(\S+)',route)
    if not m or m[1]!=c['interface']: raise ValueError('Route leaves the selected LAN interface (possibly a VPN); pool was not started')
    if re.search(r'gateway:\s*\d+\.\d+\.\d+\.\d+',route):
        raise ValueError('Routed peers are not supported; use a directly connected LAN peer')


def clean_env():
    return {k:v for k,v in os.environ.items() if not k.startswith(('LLAMA_ARG_','GGML_RPC_'))} | {'GGML_RPC_NO_RDMA':'1'}


def check_binary(c):
    p=subprocess.run([c['binary'],'--help'],capture_output=True,text=True,timeout=20,env=clean_env())
    text=p.stdout+p.stderr
    version=subprocess.run([c['binary'],'--version'],capture_output=True,text=True,timeout=20,env=clean_env())
    if LLAMA_REVISION[:7] not in version.stdout+version.stderr:
        raise ValueError('This preview requires llama.cpp commit '+LLAMA_REVISION+'; build the matching coordinator and worker')
    if p.returncode or not all(x in text for x in ('--rpc','--split-mode','--alias','--list-devices')):
        raise ValueError('Select a llama-server built with GGML_RPC=ON; required options were not found')


def plan(config):
    c=validate(config,lan_interfaces()); check_route(c); check_binary(c)
    return {'status':'plan_only','interface':c['interface'],'peer':c['peer'],
        'endpoint':f"http://127.0.0.1:{c['port']}/v1",'model_alias':c['alias'],
        'model_file_bytes':Path(c['model']).stat().st_size,'context':c['context'],
        'transport':'SSH, TCP only; remote and local RPC bind loopback',
        'allocation':'llama.cpp memory-based layer split; verify actual offload in runtime log',
        'memory_estimate':None,'performance_estimate':None,
        'notice':'File size is not peak memory. No reservation or distributed GPU test has run. A separate model allocation is required.',
        'recommended_revision':LLAMA_REVISION}


def pairing_record(ident, root=None):
    if not isinstance(ident, str) or not re.fullmatch('[0-9a-f]{32}', ident):
        raise ValueError('Invalid saved pairing identifier')
    directory = (Path(root) if root is not None else Path.home() / '.dyno' / 'pairs') / ident
    if directory.is_symlink():
        raise ValueError('Saved pairing must not be a symbolic link')
    for filename in ('identity', 'known_hosts', 'connection.json'):
        path = directory / filename
        if not path.is_file() or path.is_symlink():
            raise ValueError('Saved pairing files are missing or invalid; pair again')
    if (directory / 'connection.json').stat().st_size > 16384:
        raise ValueError('Saved pairing record is too large')
    record = json.loads((directory / 'connection.json').read_text())
    if not isinstance(record, dict) or record.get('pairing_id') != ident:
        raise ValueError('Saved pairing identifier does not match its record')
    for field in ('peer', 'local_address'):
        private_ip(record.get(field, ''))
    if not isinstance(record.get('user'), str) or not re.fullmatch(r'[A-Za-z_][A-Za-z0-9_.-]{0,63}', record['user']):
        raise ValueError('Saved pairing has an invalid SSH username')
    if type(record.get('ssh_port')) is not int or not 1 <= record['ssh_port'] <= 65535 or type(record.get('rpc_port')) is not int or record['rpc_port'] != 50052:
        raise ValueError('Saved pairing ports changed; pair again')
    return record


def paired_directory(c):
    ident = c.get('pairing_id')
    record = pairing_record(ident)
    if any(record[k] != c.get(k) for k in ('peer', 'local_address', 'user', 'ssh_port', 'rpc_port')):
        raise ValueError('Saved pairing does not match this connection; select its network or pair again')
    return Path.home() / '.dyno' / 'pairs' / ident


def ssh_args(c, port):
    trust = []
    if 'pairing_id' in c:
        directory = paired_directory(c)
        trust = ['-i', str(directory / 'identity'), '-o', 'IdentitiesOnly=yes',
                 '-o', 'IdentityAgent=none', '-o', 'HostKeyAlgorithms=ssh-ed25519',
                 '-o', 'UserKnownHostsFile="' + str(directory / 'known_hosts') + '"',
                 '-o', 'GlobalKnownHostsFile=/dev/null']
    return ['/usr/bin/ssh','-F','/dev/null',*trust,'-N','-T','-o','BatchMode=yes',
        '-o','StrictHostKeyChecking=yes','-o','ExitOnForwardFailure=yes',
        '-o','ServerAliveInterval=5','-o','ServerAliveCountMax=2',
        '-o','ConnectTimeout=10','-o','ForwardAgent=no',
        '-b',c['local_address'],'-p',str(c['ssh_port']),
        '-L',f"127.0.0.1:{port}:127.0.0.1:{c['rpc_port']}", f"{c['user']}@{c['peer']}"]


def resolved_ssh_args(c, port):
    """Recover legacy port-22 pairings only with the already-pinned identity.

    A short authenticated check on Dyno's dedicated port is allowed to select a
    different endpoint, but never to replace a host key or edit trust files.
    """
    original = ssh_args(c, port)
    if not c.get('pairing_id') or c['ssh_port'] != 22:
        return original
    candidate = list(original)
    candidate[candidate.index('-p') + 1] = '50054'
    candidate[-1:-1] = ['-o', 'HostKeyAlias=' + c['peer'], '-o', 'HostKeyAlgorithms=ssh-ed25519']
    check = list(candidate)
    check.remove('-N')
    index = check.index('-L')
    del check[index:index + 2]
    # The worker's authorized key forces a harmless echo command and permits
    # only forwarding to the loopback RPC destination.
    check.append('exit')
    try:
        result = subprocess.run(check, capture_output=True, text=True, timeout=12)
        if result.returncode == 0:
            return candidate
    except (OSError, subprocess.SubprocessError):
        pass
    return original


def server_args(c, port):
    # Output tensors can precede the worker layers in the GGUF. Keeping these
    # small tensors on CPU prevents Metal's mapped range spanning worker weights.
    return [c['binary'],'--model',c['model'],'--host','127.0.0.1','--port',str(c['port']),
        '--alias',c['alias'],'--rpc',f'127.0.0.1:{port}','--split-mode','layer',
        '--load-mode','mmap','--override-tensor','^output.*=CPU','--verbosity','4','--n-gpu-layers','999','--ctx-size',str(c['context']),'--parallel','1']


def discovered_memory(output):
    devices={m[1]:int(m[2]) for m in re.finditer(r'^\s*(MTL\d+|RPC\d+):.*\(\d+ MiB, (\d+) MiB free\)',output,re.M)}
    if not any(k.startswith('MTL') for k in devices) or not any(k.startswith('RPC') for k in devices):
        raise ValueError('Expected a local Metal accelerator and a remote RPC device; no weights were loaded')
    return devices


def free_port():
    with socket.socket() as s: s.bind(('127.0.0.1',0)); return s.getsockname()[1]


def terminate(p):
    if p is not None and p.poll() is None:
        p.terminate()
        try: p.wait(timeout=8)
        except subprocess.TimeoutExpired: p.kill(); p.wait(timeout=5)


def run(config, probe=False):
    c=validate(config,lan_interfaces()); check_route(c); check_binary(c)
    # Refuse to replace or adopt an unrelated endpoint.
    with socket.socket() as s: s.bind(('127.0.0.1',c['port']))
    tunnel=server=None
    telemetry_stop=threading.Event()
    telemetry_thread=None
    stopped=False
    parent=os.getppid()
    def stop(*_):
        nonlocal stopped
        stopped=True
    old={sig:signal.signal(sig,stop) for sig in (signal.SIGINT,signal.SIGTERM)}
    def emit(**event): print(json.dumps(event),flush=True)
    try:
        emit(status='checking_connection', message='Checking the saved worker identity and SSH endpoint')
        port=free_port(); args=resolved_ssh_args(c,port)
        if stopped or os.getppid()!=parent: return
        check_route(c)
        telemetry_port = None
        if c.get('pairing_id') and not probe:
            telemetry_port = free_port()
            while telemetry_port == port: telemetry_port = free_port()
            args[-1:-1] = ['-L', f'127.0.0.1:{telemetry_port}:127.0.0.1:50055']
        emit(status='ssh_endpoint_verified' if args[args.index('-p')+1] != str(c['ssh_port']) else 'connecting',
             ssh_port=int(args[args.index('-p')+1]), message='Strict host checking remains enabled')
        tunnel=subprocess.Popen(args)
        deadline=time.monotonic()+15
        while not stopped:
            if os.getppid()!=parent:
                stopped=True; break
            if tunnel.poll() is not None: raise ValueError('SSH failed. Verify the LAN address, known host key and key-based login first')
            try:
                with socket.create_connection(('127.0.0.1',port),timeout=.2): break
            except OSError:
                if time.monotonic()>deadline: raise ValueError('SSH tunnel timed out')
                time.sleep(.1)
        if stopped: return
        emit(status='tunnel_ready',interface=c['interface'],peer=c['peer'])
        if telemetry_port is not None:
            from .telemetry import poll
            telemetry_thread=threading.Thread(target=poll,args=(telemetry_port,telemetry_stop,emit),daemon=True)
            telemetry_thread.start()
        # Discover both accelerators before allowing weights to load.
        server=subprocess.Popen([c['binary'],'--rpc',f'127.0.0.1:{port}','--list-devices'],
            env=clean_env(),stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
        deadline=time.monotonic()+30
        output=''
        while not stopped:
            if os.getppid()!=parent: stopped=True; break
            try:
                output,_=server.communicate(timeout=.2)
                break
            except subprocess.TimeoutExpired:
                if time.monotonic()>deadline: raise ValueError('RPC device discovery timed out; check the worker process')
        if stopped: return
        print(output,flush=True)
        if server.returncode: raise ValueError('RPC device discovery failed')
        memory=discovered_memory(output)
        emit(status='devices_discovered',free_memory_mib=memory,
             notice='Snapshot only; no reservation, context or workspace guarantee')
        if any(value == 0 for name, value in memory.items() if name.startswith('RPC')):
            raise ValueError('Worker RPC reports 0 MiB free GPU memory. This is the runtime capacity reading, not GPU utilization. If telemetry shows free VRAM, stop and start RPC in the worker app, then Check devices again. Re-pairing is not needed.')
        if probe: return
        if Path(c['model']).stat().st_size > sum(memory.values())*1024*1024:
            raise ValueError('GGUF file alone exceeds reported free accelerator memory; choose a smaller model')
        server=subprocess.Popen(server_args(c,port),env=clean_env())
        emit(status='loading',endpoint=f"http://127.0.0.1:{c['port']}/v1",model=c['alias'])
        deadline=time.monotonic()+c['load_timeout_seconds']
        ready=False; next_route=0
        while not stopped:
            if os.getppid()!=parent:
                stopped=True; break
            if tunnel.poll() is not None: raise ValueError('Worker tunnel disconnected; stopping the owned coordinator')
            if server.poll() is not None: raise ValueError(f'Coordinator exited ({server.returncode}); inspect the runtime log')
            if time.monotonic()>=next_route:
                check_route(c); validate(config,lan_interfaces()); next_route=time.monotonic()+5
            if not ready:
                try:
                    with urllib.request.urlopen(f"http://127.0.0.1:{c['port']}/health",timeout=1) as r:
                        ready=r.status==200
                except OSError: pass
                if ready: emit(status='ready',endpoint=f"http://127.0.0.1:{c['port']}/v1")
                elif time.monotonic()>deadline: raise ValueError(f"Model loading exceeded {c['load_timeout_seconds']} seconds; stopping pool. Check worker transfer progress and the configured loading deadline.")
            time.sleep(.25)
    finally:
        telemetry_stop.set()
        if telemetry_thread is not None: telemetry_thread.join(timeout=3)
        try:
            terminate(server)
        finally:
            terminate(tunnel)
            for sig,handler in old.items(): signal.signal(sig,handler)
            emit(status='stopped')
