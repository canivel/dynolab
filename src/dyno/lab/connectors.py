"""Connectors: MCP servers whose tools Dyno's assistant can use, added in Settings → Connectors.

A connector is a local command (stdio, e.g. `npx -y @modelcontextprotocol/server-filesystem ~/Papers`) or a remote
address (streamable HTTP or SSE). The list is kept in <lab>/connectors/connectors.json; the values of a connector's
environment variables and headers, which are usually tokens, go to the login Keychain and never into that file.
Claude Desktop and Claude Code configs ({"mcpServers": {...}}) can be pasted in as they are.

Each conversation turns connectors on and off (the + menu in the assistant). A connector starts the first time a
conversation needs it and keeps running until Dyno quits. Its tools reach the model as <connector>__<tool>. A tool
the server marks read-only runs at once when the person allowed that for the connector; every other call is a
proposal the person approves, like starting a test.

The MCP client is the official SDK (the `mcp` extra, bundled with the app). It is async; one event loop on a
background thread holds every connection, and the lab's threads submit calls to it.
"""
from __future__ import annotations

import asyncio
import base64
import json
import os
import re
import subprocess
import threading
import time
import uuid
from datetime import timedelta
from pathlib import Path

KEYCHAIN = 'dev.dynolab.connector.'
CALL_TIMEOUT = 120          # seconds for one tool call
START_TIMEOUT = 60          # seconds for a server to start and list its tools (npx may download it first)
RESULT_CHARS = 20000
MAX_TOOLS = 60              # per conversation: every tool's schema is sent with each request
NAME = re.compile(r'[^A-Za-z0-9_-]+')
ENV_KEY = re.compile(r'^[A-Za-z_][A-Za-z0-9_]{0,99}$')
HEADER_KEY = re.compile(r"^[A-Za-z0-9!#$%&'*+.^_`|~-]{1,100}$")


class Keychain:
    """Secret values in the login Keychain, base64 so any text survives `security`. Through stdin, never argv."""
    @staticmethod
    def _run(*args, stdin=None):
        return subprocess.run(['/usr/bin/security', *args], input=stdin, capture_output=True, text=True, timeout=20)

    def get(self, service, account):
        try: r = self._run('find-generic-password', '-s', service, '-a', account, '-w')
        except (OSError, subprocess.TimeoutExpired): return None
        if r.returncode != 0: return None
        try: return base64.b64decode(r.stdout.strip()).decode()
        except ValueError: return None

    def set(self, service, account, value):
        data = base64.b64encode(value.encode()).decode()
        r = self._run('-i', stdin=f'add-generic-password -U -s {service} -a {account} -l "Dyno connector" -w {data}\n')
        if r.returncode != 0: raise ValueError('The Keychain refused the value: ' + (r.stderr.strip() or 'unknown error'))

    def delete(self, service, account):
        try: self._run('delete-generic-password', '-s', service, '-a', account)
        except (OSError, subprocess.TimeoutExpired): pass


def _slug(text):
    return NAME.sub('_', str(text).strip().lower()).strip('_')[:24] or 'connector'


def _error_text(error):
    """The SDK wraps failures in task groups; say the innermost one."""
    while getattr(error, 'exceptions', None): error = error.exceptions[0]
    text = str(error).strip() or type(error).__name__
    if isinstance(error, FileNotFoundError): text = f"Couldn't find the command: {error.filename or text}"
    return text[:500]


_login_path = None


def _path():
    """Dyno opens from the Finder with a short PATH; the person's shell knows where npx, uvx and docker live."""
    global _login_path
    if _login_path is None:
        extra = ['/opt/homebrew/bin', '/usr/local/bin', str(Path.home() / '.local/bin'), str(Path.home() / '.cargo/bin')]
        try:
            shell = os.environ.get('SHELL') or '/bin/zsh'
            r = subprocess.run([shell, '-lic', 'printf %s "$PATH"'], capture_output=True, text=True, timeout=10, stdin=subprocess.DEVNULL)
            found = r.stdout.strip().splitlines()[-1] if r.returncode == 0 and r.stdout.strip() else ''
        except (OSError, subprocess.TimeoutExpired, IndexError): found = ''
        parts = [p for p in (found.split(':') + os.environ.get('PATH', '').split(':') + extra) if p]
        _login_path = ':'.join(dict.fromkeys(parts))
    return _login_path


class _Link:
    """One running connection. Its whole life is one task on the loop: the SDK's contexts must close where they opened."""
    def __init__(self, conf, secrets, logs):
        self.conf, self.secrets, self.logs = conf, secrets, logs
        self.session, self.tools, self.error = None, [], None
        self.status = 'starting'
        self.ready = threading.Event()
        self.done = threading.Event()
        self.closing = None
        self.stop_requested = False

    def close(self):  # on the loop
        self.stop_requested = True
        if self.closing: self.closing.set()

    async def run(self):
        from contextlib import AsyncExitStack
        from mcp import ClientSession
        self.closing = asyncio.Event()
        if self.stop_requested: self.closing.set()
        c = self.conf
        try:
            async with AsyncExitStack() as stack:
                if c['transport'] == 'stdio':
                    from mcp.client.stdio import StdioServerParameters, get_default_environment, stdio_client
                    env = dict(get_default_environment(), PATH=_path(), **self.secrets('env'))
                    log = stack.enter_context(open(self.logs / f"{c['id']}.log", 'a'))
                    log.write(f"\n--- {time.strftime('%Y-%m-%d %H:%M:%S')} {c['command']} {' '.join(c.get('args') or [])}\n"); log.flush()
                    args = [os.path.expanduser(a) if a.startswith('~') else a for a in c.get('args') or []]  # no shell to do it
                    params = StdioServerParameters(command=os.path.expanduser(c['command']), args=args, env=env,
                                                   cwd=str(Path(c.get('cwd') or Path.home()).expanduser()))
                    read, write = await stack.enter_async_context(stdio_client(params, errlog=log))
                elif c['transport'] == 'sse':
                    from mcp.client.sse import sse_client
                    read, write = await stack.enter_async_context(sse_client(c['url'], headers=self.secrets('headers') or None))
                else:
                    from mcp.client.streamable_http import streamablehttp_client
                    read, write, _ = await stack.enter_async_context(streamablehttp_client(c['url'], headers=self.secrets('headers') or None))
                session = await stack.enter_async_context(ClientSession(read, write))
                await asyncio.wait_for(session.initialize(), START_TIMEOUT)
                tools, cursor = [], None
                while True:
                    page = await asyncio.wait_for(session.list_tools(cursor) if cursor else session.list_tools(), START_TIMEOUT)
                    tools += page.tools
                    cursor = getattr(page, 'nextCursor', None)
                    if not cursor or len(tools) >= 500: break
                self.session, self.tools, self.status = session, tools, 'running'
                self.ready.set()
                await self.closing.wait()
        except BaseException as error:  # noqa: BLE001 - a server that fails or quits must never take the lab down
            if not self.stop_requested:
                self.error, self.status = self._explain(error), 'error'
        finally:
            self.session = None
            if self.status != 'error': self.status = 'stopped'
            self.ready.set(); self.done.set()

    def _explain(self, error):
        """What went wrong, in words the person can act on."""
        inner = error
        while getattr(inner, 'exceptions', None): inner = inner.exceptions[0]
        status = getattr(getattr(inner, 'response', None), 'status_code', None)
        host = re.sub(r'^https?://([^/:]+).*$', r'\1', self.conf.get('url') or '')
        if status in (401, 403): return f'{host} refused the request ({status}): check the token in the headers'
        if status: return f'{host} answered {status}: is this the MCP address?'
        text = _error_text(error)
        if self.conf['transport'] != 'stdio' and re.search(r'nodename|not known|getaddrinfo|ConnectError|Connection refused|ConnectTimeout', text + type(inner).__name__):
            return f"Couldn't reach {host}: check the address and your connection"
        if self.conf['transport'] == 'stdio' and not isinstance(inner, FileNotFoundError):
            said = self._server_said()
            if said: return f'The server stopped: {said}'
        return text

    def _server_said(self):
        """The line in this run's log that says why the server quit: a Python exception, or the first error line."""
        try: log = (self.logs / f"{self.conf['id']}.log").read_text(errors='replace')
        except OSError: return ''
        lines = [l.strip() for l in log.rsplit('\n--- ', 1)[-1].splitlines()[1:] if l.strip()]
        exc = [l for l in lines if re.match(r'^[\w.]*(Error|Exception)\b.*:', l)]
        if exc: return exc[-1][:300]
        for l in lines:
            l2 = re.sub(r'^(npm )?(error|ERR!)\s*(\w+\s)?', '', l, flags=re.I).strip() if l.lower().startswith('npm') else l
            if re.search(r'error|not found|denied|refused|missing|invalid|required', l, re.I) and len(l2) > 20 and 'complete log' not in l2:
                return l2[:300]
        return lines[-1][:300] if lines else ''


class Connectors:
    def __init__(self, folder, keychain=None):
        self.folder = Path(folder)
        self.folder.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.logs = self.folder / 'logs'
        self.logs.mkdir(exist_ok=True, mode=0o700)
        self.path = self.folder / 'connectors.json'
        self.keychain = keychain or Keychain()
        self.lock = threading.RLock()
        self.links: dict[str, _Link] = {}
        self.loop = None

    # --- the list ------------------------------------------------------------------------

    def _load(self):
        try: data = json.loads(self.path.read_text())
        except (OSError, ValueError): return []
        return [c for c in data.get('connectors') or [] if isinstance(c, dict) and c.get('id')]

    def _store(self, items):
        tmp = self.path.with_suffix('.tmp')
        tmp.write_text(json.dumps(dict(connectors=items), indent=2)); os.chmod(tmp, 0o600); tmp.replace(self.path)

    def get(self, cid):
        c = next((c for c in self._load() if c['id'] == cid), None)
        if c is None: raise ValueError('Unknown connector')
        return c

    def _secrets(self, c):
        def read(kind):
            return {k: v for k in c.get(f'{kind}_keys') or [] if (v := self.keychain.get(KEYCHAIN + c['id'], f'{kind}:{k}')) is not None}
        return read

    def _public(self, c):
        link = self.links.get(c['id'])
        out = {k: c.get(k) for k in ('id', 'name', 'transport', 'command', 'args', 'cwd', 'url', 'env_keys', 'headers_keys', 'allow_reads')}
        out.update(prefix=c['prefix'], status=link.status if link else 'stopped', error=link.error if link else None, remote=c['transport'] != 'stdio',
                   tools=[dict(name=t.name, title=getattr(t, 'title', None), description=(t.description or '')[:300], read_only=self._read_only(t))
                          for t in (link.tools if link else [])])
        return out

    def list(self):
        return dict(connectors=[self._public(c) for c in self._load()], file=str(self.path))

    def save(self, body):
        """Add or change one: {id?, name, transport: stdio|http|sse, command, args, cwd, url, env, headers, allow_reads}.
        In env and headers a value of null keeps the saved one; a key left out is removed."""
        if not isinstance(body, dict): raise ValueError('Send a connector')
        unknown = set(body) - {'id', 'name', 'transport', 'command', 'args', 'cwd', 'url', 'env', 'headers', 'allow_reads'}
        if unknown: raise ValueError('Unknown fields: ' + ', '.join(sorted(unknown)))
        with self.lock:
            items = self._load()
            old = next((c for c in items if c['id'] == body.get('id')), None) if body.get('id') else None
            if body.get('id') and old is None: raise ValueError('Unknown connector')
            name = ' '.join(str(body.get('name') or '').split())[:60]
            if not name: raise ValueError('Give the connector a name')
            transport = body.get('transport') or ('stdio' if body.get('command') else 'http')
            if transport not in ('stdio', 'http', 'sse'): raise ValueError('transport is stdio, http or sse')
            c = dict(id=old['id'] if old else uuid.uuid4().hex[:12], name=name, transport=transport, allow_reads=bool(body.get('allow_reads')))
            if transport == 'stdio':
                command = str(body.get('command') or '').strip()
                if not command: raise ValueError('Give the command that starts the server, e.g. npx')
                args = body.get('args') or []
                if not isinstance(args, list) or not all(isinstance(a, (str, int, float)) for a in args): raise ValueError('args is a list of strings')
                c.update(command=command, args=[str(a) for a in args][:100], cwd=str(body.get('cwd') or '').strip() or None)
            else:
                url = str(body.get('url') or '').strip()
                if not re.match(r'^https?://[^\s]+$', url): raise ValueError('Give the server address, starting with https://')
                c['url'] = url
            secrets = {}
            for kind, field, pattern in (('env', 'env', ENV_KEY), ('headers', 'headers', HEADER_KEY)):
                given = body.get(field) or {}
                if not isinstance(given, dict): raise ValueError(f'{field} is an object of names and values')
                for k, v in given.items():
                    if not pattern.match(str(k)): raise ValueError(f'"{k}" is not a valid {"variable" if kind == "env" else "header"} name')
                    if v is not None and not isinstance(v, (str, int, float)): raise ValueError(f'The value of {k} must be text')
                    if v is None and k not in ((old or {}).get(f'{kind}_keys') or []): raise ValueError(f'Give a value for {k}')
                c[f'{kind}_keys'] = sorted(map(str, given))
                secrets[kind] = given
            names = {x['prefix'] for x in items if x['id'] != c['id']}
            prefix, n = _slug(name), 2
            while prefix in names: prefix, n = f'{_slug(name)[:21]}_{n}', n + 1
            c['prefix'] = old['prefix'] if old and _slug(old['name']) == _slug(name) else prefix
            for kind, given in secrets.items():
                for k, v in given.items():
                    if v is not None: self.keychain.set(KEYCHAIN + c['id'], f'{kind}:{k}', str(v))
                for k in set((old or {}).get(f'{kind}_keys') or []) - set(map(str, given)):
                    self.keychain.delete(KEYCHAIN + c['id'], f'{kind}:{k}')
            items = [c if x['id'] == c['id'] else x for x in items] if old else items + [c]
            self._store(items)
        if old and c['id'] in self.links: self.restart(c['id'])
        return self._public(c)

    def delete(self, body):
        cid = str((body or {}).get('id') or '')
        with self.lock:
            c = self.get(cid)
            self.stop(cid)
            for kind in ('env', 'headers'):
                for k in c.get(f'{kind}_keys') or []: self.keychain.delete(KEYCHAIN + cid, f'{kind}:{k}')
            self._store([x for x in self._load() if x['id'] != cid])
        return dict(deleted=cid)

    def import_config(self, body):
        """A pasted Claude Desktop / Claude Code config: {"mcpServers": {"name": {...}}}, or just the inner object."""
        text = (body or {}).get('json')
        try: data = json.loads(text) if isinstance(text, str) else text
        except ValueError as error: raise ValueError(f"That isn't valid JSON: {error}") from None
        if not isinstance(data, dict): raise ValueError('Paste a JSON object')
        servers = data.get('mcpServers') or data.get('servers') or data
        if not isinstance(servers, dict) or not servers or not all(isinstance(v, dict) for v in servers.values()):
            raise ValueError('Paste {"mcpServers": {"name": {"command": ..., "args": [...]}}}')
        added = []
        for name, s in servers.items():
            kind = str(s.get('type') or s.get('transport') or '').lower()
            transport = 'stdio' if s.get('command') else 'sse' if kind == 'sse' else 'http'
            added.append(self.save(dict(name=name, transport=transport, command=s.get('command'), args=s.get('args'), cwd=s.get('cwd'),
                                        url=s.get('url') or s.get('serverUrl'), env=s.get('env') or {}, headers=s.get('headers') or {})
                                   if transport == 'stdio' else
                                   dict(name=name, transport=transport, url=s.get('url') or s.get('serverUrl'), headers=s.get('headers') or {})))
        return dict(added=added)

    # --- connections ---------------------------------------------------------------------

    def _ensure_loop(self):
        with self.lock:
            if self.loop is None:
                self.loop = asyncio.new_event_loop()
                threading.Thread(target=self.loop.run_forever, name='dyno-connectors', daemon=True).start()
            return self.loop

    def start(self, cid):
        """Starts the connector if it isn't running (or failed). Returns at once; `wait` for it."""
        c = self.get(cid)
        with self.lock:
            link = self.links.get(cid)
            if link and link.status in ('starting', 'running'): return link
            try: import mcp  # noqa: F401
            except ImportError: raise ValueError('Connectors need the MCP library (pip install "mlx-dyno[mcp]")') from None
            link = self.links[cid] = _Link(c, self._secrets(c), self.logs)
            asyncio.run_coroutine_threadsafe(link.run(), self._ensure_loop())
            return link

    def wait(self, cid, timeout=START_TIMEOUT + 5):
        link = self.start(cid)
        link.ready.wait(timeout)
        return link

    def test(self, body):
        cid = str((body or {}).get('id') or '')
        self.restart(cid)
        self.wait(cid)
        return self._public(self.get(cid))

    def stop(self, cid):
        link = self.links.pop(cid, None)
        if link and self.loop: self.loop.call_soon_threadsafe(link.close)

    def restart(self, cid):
        self.stop(cid)
        return self.start(cid)

    def stop_all(self, wait=3):
        """When the lab quits: close every connection, so local servers exit instead of outliving Dyno."""
        links = list(self.links.values())
        for cid in list(self.links): self.stop(cid)
        deadline = time.time() + wait
        for link in links: link.done.wait(max(0, deadline - time.time()))

    # --- tools for the assistant ---------------------------------------------------------

    @staticmethod
    def _read_only(tool):
        return bool(getattr(tool.annotations, 'readOnlyHint', False)) if getattr(tool, 'annotations', None) else False

    def tools(self, ids, wait=True):
        """{tool name for the model: dict(connector, tool, read_only, spec)} for the connectors a conversation has on.
        Connectors that are still starting are waited for; ones that failed are left out (`problems` says why)."""
        out, problems = {}, []
        known = {c['id']: c for c in self._load()}
        for cid in ids or []:
            c = known.get(cid)
            if c is None: continue
            try: link = self.wait(cid) if wait else self.start(cid)
            except ValueError as error: problems.append(f"{c['name']}: {error}"); continue
            if link.status != 'running': problems.append(f"{c['name']}: {link.error or 'not running'}"); continue
            for t in link.tools:
                if len(out) >= MAX_TOOLS: problems.append(f'Only the first {MAX_TOOLS} connector tools are offered'); break
                name = f"{c['prefix']}__{NAME.sub('_', t.name)}"[:64]
                schema = t.inputSchema if isinstance(t.inputSchema, dict) else {'type': 'object', 'properties': {}}
                desc = ((t.description or t.name).strip()[:1000] + f" (from the {c['name']} connector)")
                out[name] = dict(connector=cid, connector_name=c['name'], tool=t.name, read_only=self._read_only(t) and bool(c.get('allow_reads')),
                                 spec=dict(type='function', function=dict(name=name, description=desc, parameters=schema)))
        return out, problems

    def call(self, cid, tool, args):
        link = self.links.get(cid)
        if not link or link.status != 'running': link = self.wait(cid)
        if link.status != 'running' or link.session is None: raise ValueError(f"The connector isn't running: {link.error or link.status}")
        future = asyncio.run_coroutine_threadsafe(
            link.session.call_tool(tool, args, read_timeout_seconds=timedelta(seconds=CALL_TIMEOUT)), self.loop)
        try: result = future.result(CALL_TIMEOUT + 5)
        except Exception as error:  # noqa: BLE001
            future.cancel()
            raise ValueError(f'The connector call failed: {_error_text(error)}') from None
        parts = []
        for block in result.content or []:
            kind = getattr(block, 'type', '')
            if kind == 'text': parts.append(block.text)
            elif kind == 'resource':
                r = block.resource
                parts.append(getattr(r, 'text', None) or f'[a {getattr(r, "mimeType", "file")} resource: {getattr(r, "uri", "")}]')
            elif kind == 'resource_link': parts.append(f'[link: {getattr(block, "name", "")} {getattr(block, "uri", "")}]')
            else: parts.append(f'[{kind or "content"} not shown: the assistant reads text only]')
        if not parts and getattr(result, 'structuredContent', None) is not None:
            parts.append(json.dumps(result.structuredContent, ensure_ascii=False, default=str))
        text = '\n'.join(parts).strip() or '(no content)'
        if len(text) > RESULT_CHARS: text = text[:RESULT_CHARS] + f'… [{len(text) - RESULT_CHARS:,} more characters]'
        if result.isError: raise ValueError(text)
        return text
