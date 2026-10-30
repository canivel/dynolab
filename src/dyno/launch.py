"""`dyno models` and `dyno launch` — the downloaded models, and a coding tool running on one of them.

    dyno models                         what's downloaded, and what's being served
    dyno launch claude --model qwen3.8  Claude Code on a local model
    dyno launch codex --model qwen3.8   Codex on a local model

`launch` reuses a Dyno server that already has the model, or starts one for the session and stops it when the
tool exits. Claude Code reaches it through the server's Anthropic Messages API, Codex through its Responses API,
both on this Mac only.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import signal
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

WEIGHTS = ('.safetensors', '.npz', '.gguf')
LAUNCH_PORTS = range(8970, 8980)


def hub():
    if os.environ.get('HF_HUB_CACHE'): return Path(os.environ['HF_HUB_CACHE'])
    return Path(os.environ.get('HF_HOME') or Path.home() / '.cache' / 'huggingface') / 'hub'


def repo_of(path):
    """The repository id a hub cache path belongs to, or the path itself."""
    match = re.search(r'models--([^/]+?)--([^/]+)', str(path))
    return f'{match.group(1)}/{match.group(2)}' if match else str(path)


def drafter_of(config, name=''):
    """The base model a speculative-decoding drafter is for, or None for an ordinary model.

    A DFlash2 drafter (z-lab/Qwen3.8-27B-DFlash2) has weights and a config like a model, but it only loads next to
    its base model; served alone, mlx_lm fails on it ("missing rope_theta").
    """
    if not isinstance(config, dict): return None
    if 'dflash_config' in config or any('dflash' in str(a).lower() for a in config.get('architectures') or ()):
        base = re.sub(r'-DFlash\d*$', '', repo_of(name).rsplit('/', 1)[-1], flags=re.I) if name else ''
        return f'a {base} model' if base else 'its base model'
    return None


def drafter_refusal(argv):
    """Why `dyno serve` can't serve its --model, when that names a drafter instead of a model; None otherwise."""
    ref = next((a.split('=', 1)[1] for a in argv if a.startswith('--model=')), None)
    if ref is None and '--model' in argv[:-1]:
        ref = argv[argv.index('--model') + 1]
    if not ref: return None
    folder = Path(ref).expanduser()
    if not folder.is_dir():
        snapshots = sorted((hub() / ('models--' + ref.replace('/', '--')) / 'snapshots').glob('*'), key=lambda p: p.stat().st_mtime, reverse=True)
        folder = next(iter(snapshots), None)
    try: config = json.loads((folder / 'config.json').read_text()) if folder else None
    except (OSError, ValueError): return None
    base = drafter_of(config, str(folder))
    if not base: return None
    return (f'{ref} is a draft model for speculative decoding, not a model to serve. Serve {base} instead: '
            '`dyno serve` finds this draft model in the Hugging Face cache and uses it.')


def downloaded(root=None):
    """Every model in the hub cache with weights on disk, newest revision only."""
    out = []
    for folder in sorted((root or hub()).glob('models--*')):
        snapshots = sorted((folder / 'snapshots').glob('*'), key=lambda p: p.stat().st_mtime, reverse=True)
        snapshot = next((s for s in snapshots if (s / 'config.json').exists()), None)
        if snapshot is None: continue
        files = [f for f in snapshot.iterdir() if f.suffix in WEIGHTS]
        if not files: continue
        # Files in a snapshot are symlinks to blobs; an unfinished download leaves the blob missing.
        if any(not f.exists() for f in files) or any((folder / 'blobs').glob('*.incomplete')): continue
        try: config = json.loads((snapshot / 'config.json').read_text())
        except (OSError, ValueError): config = {}
        # Served automatically next to the model it drafts for (`dyno serve --speculative auto`).
        if drafter_of(config): continue
        text = config.get('text_config') if isinstance(config.get('text_config'), dict) else {}
        context = config.get('max_position_embeddings') or text.get('max_position_embeddings')
        out.append(dict(id=repo_of(folder), path=str(snapshot), bytes=sum(f.stat().st_size for f in files),
                        context=context if isinstance(context, int) else None, mlx='quantization' in config or 'mlx' in folder.name.lower()))
    return out


def resolve(name, models):
    """A model by exact id, or by a piece of its name ("qwen3.8-27b"), case and punctuation aside."""
    key = lambda s: re.sub(r'[^a-z0-9.]', '', s.lower())
    exact = [m for m in models if m['id'].lower() == name.lower() or m['path'] == name]
    if exact: return exact
    want = key(name)
    return [m for m in models if want in key(m['id'])]


def _listening(port, host='127.0.0.1'):
    with socket.socket() as s:
        s.settimeout(0.3)
        return s.connect_ex((host, port)) == 0


def _get(url, timeout=2.0):
    try:
        with urllib.request.urlopen(url, timeout=timeout) as r: return json.loads(r.read())
    except (urllib.error.URLError, OSError, ValueError):
        return None


def speaks_anthropic(port):
    """Whether the server answers the Messages API (Dyno 0.6.9 and later)."""
    request = urllib.request.Request(f'http://127.0.0.1:{port}/v1/messages/count_tokens', method='POST',
                                     data=b'{"messages":[{"role":"user","content":"hi"}]}', headers={'Content-Type': 'application/json'})
    try:
        with urllib.request.urlopen(request, timeout=3) as r: return r.status == 200
    except (urllib.error.URLError, OSError):
        return False


def serving():
    """Running `dyno serve` processes: {port, model id, pid}, from their command lines."""
    try:
        listing = subprocess.run(['ps', '-axo', 'pid=,args='], capture_output=True, text=True, timeout=6).stdout
    except (OSError, subprocess.SubprocessError):
        return []
    out = []
    for line in listing.splitlines():
        if not re.search(r'-m dyno serve\b|\bdyno serve\b', line): continue
        model, port = re.search(r'--model\s+(\S+)', line), re.search(r'--port\s+(\d+)', line)
        if model and port and _listening(int(port.group(1))):
            out.append(dict(pid=int(line.split()[0]), port=int(port.group(1)), id=repo_of(model.group(1))))
    return out


def size(n):
    return f'{n / 1e9:.1f} GB' if n >= 1e9 else f'{n / 1e6:.0f} MB'


def models(argv):
    parser = argparse.ArgumentParser(prog='dyno models', description='Downloaded models, and which ones are being served.')
    parser.add_argument('--json', action='store_true')
    args = parser.parse_args(argv)
    found, served = downloaded(), serving()
    for m in found: m['ports'] = [s['port'] for s in served if s['id'] == m['id']]
    if args.json:
        print(json.dumps(found, indent=2)); return 0
    if not found:
        print(f'No models downloaded in {hub()}. Get one with `dyno pull mlx-community/Qwen3-8B-4bit`.'); return 1
    width = min(64, max(len(m['id']) for m in found) + 2)
    print(f"{'MODEL':<{width}}{'SIZE':>9}{'CONTEXT':>9}  SERVING")
    for m in found:
        context = f"{m['context'] // 1024}k" if m['context'] else '—'
        ports = ', '.join(f':{p}' for p in m['ports']) or ''
        print(f"{m['id'][:width - 1]:<{width}}{size(m['bytes']):>9}{context:>9}  {ports}")
    return 0


def _free_port():
    for port in LAUNCH_PORTS:
        if not _listening(port): return port
    raise RuntimeError(f'No free port between {LAUNCH_PORTS.start} and {LAUNCH_PORTS.stop - 1}')


def _start_server(model, port, extra, mode='serve', thinking=None):
    logs = Path.home() / '.mlx-dyno' / 'logs'
    logs.mkdir(parents=True, exist_ok=True)
    log = logs / f'launch-{port}.log'
    # Codex doesn't say how long a reply may be, and mlx_lm's default (512 tokens) cuts off a model that thinks first.
    if not any(e.split('=')[0] == '--max-tokens' for e in extra): extra = ['--max-tokens', '32768', *extra]
    # Serve only: one request at a time on the fast path, none of the research features (see `dyno serve --help`).
    if not any(e.split('=')[0] == '--mode' for e in extra): extra = ['--mode', mode, *extra]
    if thinking is not None and not any(e.split('=')[0] == '--chat-template-args' for e in extra):
        extra = ['--chat-template-args', json.dumps({'enable_thinking': thinking}), *extra]
    command = [sys.executable, '-m', 'dyno', 'serve', '--model', model['id'], '--host', '127.0.0.1', '--port', str(port), *extra]
    with open(log, 'w') as out:
        process = subprocess.Popen(command, stdout=out, stderr=subprocess.STDOUT, start_new_session=True)
    return process, log


def _wait(process, port, log, limit=900):
    started = time.time()
    while time.time() - started < limit:
        if process.poll() is not None:
            tail = log.read_text(errors='replace')[-1500:] if log.exists() else ''
            raise RuntimeError(f'The model server stopped while starting (see {log}):\n{tail}')
        if _get(f'http://127.0.0.1:{port}/v1/models', timeout=1): return
        time.sleep(1)
    raise RuntimeError(f'The model server did not answer within {limit // 60} minutes (see {log})')


def warm_up(port, timeout=900):
    """mlx_lm loads the model (and Dyno its drafter) on the first request: do that now, before the tool's first turn."""
    body = json.dumps({'model': 'default_model', 'messages': [{'role': 'user', 'content': 'hi'}], 'max_tokens': 1}).encode()
    request = urllib.request.Request(f'http://127.0.0.1:{port}/v1/chat/completions', data=body, headers={'Content-Type': 'application/json'})
    try:
        with urllib.request.urlopen(request, timeout=timeout) as r: r.read()
    except (urllib.error.URLError, OSError, ValueError):
        pass


def speed_report(port, log=None):
    """One line on how fast this server can go: its mode and whether speculative decoding is on, and if not, why."""
    stats = _get(f'http://127.0.0.1:{port}/stats', timeout=3) or {}
    mode = stats.get('mode') or 'research'
    drafter = (stats.get('speculative') or {}).get('mode')
    lines = []
    if not (stats.get('model') or {}).get('loaded_at'):
        pass  # the drafter is chosen when the model loads, on the first request
    elif drafter:
        lines.append(f"Speculative decoding: on ({'DFlash2 draft model' if drafter == 'dflash' else 'MTP head'}).")
    else:
        why = ''
        if log and Path(log).exists():
            said = [l.strip() for l in Path(log).read_text(errors='replace').splitlines() if l.startswith('Speculative decoding off')]
            why = said[-1].split(':', 1)[1].strip() if said else ''
        lines.append('Speculative decoding: off' + (f' ({why})' if why else '') + '. Replies come out at plain speed. '
                     'For Qwen3.8-27B, `dyno pull z-lab/Qwen3.8-27B-DFlash2` gets the fastest draft model.')
    if mode != 'serve':
        lines.append(f'The server on :{port} runs in research mode. For the fastest replies, start the model in Models with '
                     '"Serve only", or quit it and let `dyno launch` start one.')
    return lines


def _name(model):
    # The short name isn't one the server lists, so the translator uses the model it serves.
    return model['id'].rsplit('/', 1)[-1]


TIMEOUT_MS = 3_600_000


def claude_env(port, model, environ=None):
    """The environment that points Claude Code at a Dyno server, and only there."""
    env = dict(os.environ if environ is None else environ)
    env.pop('ANTHROPIC_API_KEY', None)  # a real key would take precedence and is never needed locally
    name = _name(model)
    env.update(ANTHROPIC_BASE_URL=f'http://127.0.0.1:{port}', ANTHROPIC_AUTH_TOKEN='dyno', ANTHROPIC_MODEL=name,
               ANTHROPIC_DEFAULT_OPUS_MODEL=name, ANTHROPIC_DEFAULT_SONNET_MODEL=name, ANTHROPIC_DEFAULT_HAIKU_MODEL=name,
               CLAUDE_CODE_SUBAGENT_MODEL=name, CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC='1')
    if model.get('context'): env['CLAUDE_CODE_MAX_CONTEXT_TOKENS'] = str(model['context'])
    # Claude Code gives up on a request after 10 minutes and sends it again from the start; a slower Mac can take that
    # long to read a big prompt, and then it never answers.
    env.setdefault('API_TIMEOUT_MS', str(TIMEOUT_MS))
    return env, []


def codex_args(port, model, environ=None):
    """Codex options for a Dyno provider; its own config and sign-in are left as they are."""
    options = {'model_provider': '"dyno"', 'model_providers.dyno.name': '"Dyno"',
               'model_providers.dyno.base_url': f'"http://127.0.0.1:{port}/v1"',
               'model_providers.dyno.wire_api': '"responses"', 'model_providers.dyno.requires_openai_auth': 'false',
               # Codex drops a stream silent for 5 minutes; Dyno sends keepalives, and this covers any gap.
               'model_providers.dyno.stream_idle_timeout_ms': str(TIMEOUT_MS)}
    if model.get('context'): options['model_context_window'] = str(model['context'])
    args = [part for key, value in options.items() for part in ('-c', f'{key}={value}')]
    return dict(os.environ if environ is None else environ), [*args, '-m', _name(model)]


TOOLS = {'claude': ('Claude Code', 'npm install -g @anthropic-ai/claude-code', claude_env),
         'codex': ('Codex', 'npm install -g @openai/codex', codex_args)}


def launch(argv):
    if '--' in argv:
        cut = argv.index('--'); argv, passthrough = argv[:cut], argv[cut + 1:]
    else:
        passthrough = []
    parser = argparse.ArgumentParser(prog='dyno launch', description='Run a coding tool on a local model.',
                                     epilog='Arguments after -- go to the tool, e.g. dyno launch claude --model qwen3-8b -- -p "fix the tests" '
                                            'or dyno launch codex --model qwen3-8b -- exec "fix the tests"')
    parser.add_argument('tool', choices=sorted(TOOLS))
    parser.add_argument('--model', required=True, help='a downloaded model: its id or part of its name (see `dyno models`)')
    parser.add_argument('--port', type=int, help='use the Dyno server on this port')
    parser.add_argument('--keep', action='store_true', help="leave a server this command started running when the tool exits")
    parser.add_argument('--research', action='store_true',
                        help='start the server in research mode (Observer history, activation capture) instead of serve only')
    parser.add_argument('--thinking', choices=('on', 'off'),
                        help="whether the model thinks before answering, for a server this command starts (default: the model's own; off is faster)")
    parser.add_argument('--serve-arg', action='append', default=[], metavar='ARG',
                        help='passed to `dyno serve` when one is started, e.g. --serve-arg=--max-tokens=16384')
    args = parser.parse_args(argv)
    label, install, environment = TOOLS[args.tool]

    executable = shutil.which(args.tool)
    if not executable:
        print(f'{label} is not installed. Install it with: {install}', file=sys.stderr); return 1
    matches = resolve(args.model, downloaded())
    if not matches:
        print(f'No downloaded model matches {args.model!r}. See `dyno models`, or download one with `dyno pull`.', file=sys.stderr); return 1
    if len(matches) > 1:
        print(f'{args.model!r} matches {len(matches)} models; name one:', file=sys.stderr)
        for m in matches: print(f"  {m['id']}", file=sys.stderr)
        return 2
    model = matches[0]

    process, port, log = None, args.port, None
    if port is None:
        running = [s for s in serving() if s['id'] == model['id']]
        ready = next((s for s in running if speaks_anthropic(s['port'])), None)
        if ready:
            port = ready['port']
            print(f"Using {model['id']} on :{port}", file=sys.stderr)
        else:
            if running:
                print(f"The server on :{running[0]['port']} is from an older Dyno without the Anthropic API; "
                      f"starting another copy of the model ({size(model['bytes'])}).", file=sys.stderr)
            port = _free_port()
            print(f"Loading {model['id']} on :{port}…", file=sys.stderr)
            process, log = _start_server(model, port, args.serve_arg, 'research' if args.research else 'serve',
                                         None if args.thinking is None else args.thinking == 'on')
            try:
                _wait(process, port, log)
                warm_up(port)
            except (RuntimeError, KeyboardInterrupt) as error:
                process.terminate()
                print(error if isinstance(error, RuntimeError) else 'Stopped.', file=sys.stderr); return 1
    elif not speaks_anthropic(port):
        print(f':{port} is not a Dyno server with the coding tools\' APIs (Dyno 0.6.9 or later). Update Dyno, or leave out --port.', file=sys.stderr); return 1

    # The tool owns the terminal: Ctrl-C reaches it, not this wrapper. Closing the terminal (SIGHUP) or being
    # told to stop (SIGTERM) still runs the cleanup below, so a model this command started never outlives it.
    def stopped(signum, frame): raise SystemExit(128 + signum)
    previous = {s: signal.signal(s, h) for s, h in ((signal.SIGINT, signal.SIG_IGN), (signal.SIGHUP, stopped), (signal.SIGTERM, stopped))}
    if args.thinking and not process:
        print(f'--thinking applies to a server this command starts; the one on :{port} keeps its own setting.', file=sys.stderr)
    for line in speed_report(port, log): print(line, file=sys.stderr)
    try:
        print(f'The first reply waits while the model reads {label}\'s instructions (about 20,000 tokens): '
              'on some Macs that takes several minutes. Later replies only read what\'s new.', file=sys.stderr)
        env, options = environment(port, model)
        code = subprocess.call([executable, *options, *passthrough], env=env)
    finally:
        for s, h in previous.items(): signal.signal(s, h)
        if process and not args.keep:
            process.terminate()
            try: process.wait(timeout=20)
            except subprocess.TimeoutExpired: process.kill()
        elif process:
            print(f"The model server is still running on :{port} (stop it with `dyno stop {port}`).", file=sys.stderr)
    return code
