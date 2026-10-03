"""Sandboxed agent episodes, run by the separate open-source containment harness.

Dyno never executes agent commands itself. It starts the harness as a subprocess,
reads the run folders the harness writes (transcript.jsonl, manifest.json,
label.json) and keeps a full-text index of every event, so what agents said,
reasoned and tried can be searched long after a run.
"""
import hashlib
import json
import os
import re
import signal
import sqlite3
import subprocess
import threading
import time
import uuid
from pathlib import Path

from .studies import digest, text

EPISODE_NAME = re.compile(r'^[A-Za-z0-9._-]{1,200}$')
KEY = re.compile(r'^[0-9a-f]{32}$')
EVENT_TEXT_LIMIT = 20000


def event_text(e):
    """The searchable text of one harness event."""
    kind = e.get('event')
    if kind == 'start': parts = [e.get('prompt')]
    elif kind == 'model': parts = [e.get('content'), e.get('reasoning')]
    elif kind == 'tool_call': parts = [e.get('tool'), json.dumps(e.get('args') or e.get('raw_args'), ensure_ascii=False)]
    elif kind == 'tool_result': parts = [e.get('stdout'), e.get('stderr')]
    elif kind == 'tripwire': parts = [e.get('type'), e.get('evidence')]
    elif kind == 'end': parts = [e.get('end_reason'), e.get('final_action'), json.dumps(e.get('final_args'), ensure_ascii=False)]
    else: parts = [e.get('content'), e.get('error')]
    return '\n'.join(p for p in parts if isinstance(p, str) and p)[:EVENT_TEXT_LIMIT]


def fts_query(q):
    """Treat user text as literal terms so paths like /opt/grader can't break FTS syntax."""
    terms = []
    for raw in q.split():
        prefix = raw.endswith('*') and len(raw) > 1
        term = raw.rstrip('*').replace('"', '""')
        if term: terms.append(f'"{term}"' + ('*' if prefix else ''))
    return ' '.join(terms)


class EventIndex:
    def __init__(self, path):
        self.path = Path(path)
        self.lock = threading.RLock()
        with self._db() as db:
            db.executescript('''
                create table if not exists episodes(key text primary key, path text unique, run text, episode_id text,
                    task_id text, model_id text, status text, outcome text, claimed_success integer, tripwires integer,
                    severe integer, started text, offset integer default 0);
                create virtual table if not exists events using fts5(key unindexed, seq unindexed, step unindexed,
                    agent unindexed, event, tool, severity, text, tokenize='porter unicode61');''')

    def _db(self):
        db = sqlite3.connect(self.path, timeout=10)
        db.row_factory = sqlite3.Row
        return db

    @staticmethod
    def key(transcript):
        return hashlib.sha256(str(Path(transcript).resolve()).encode()).hexdigest()[:32]

    def update(self, folders):
        """Index new lines of every transcript under the given folders; cheap when nothing changed."""
        with self.lock, self._db() as db:
            for folder in folders:
                for transcript in sorted(Path(folder).glob('**/transcript.jsonl')):
                    self._update_one(db, transcript)

    def _update_one(self, db, transcript):
        key = self.key(transcript)
        row = db.execute('select offset from episodes where key=?', (key,)).fetchone()
        offset = row['offset'] if row else 0
        size = transcript.stat().st_size
        if size < offset:  # rewritten: start over
            db.execute('delete from events where key=?', (key,)); offset = 0
        added_tripwires = added_severe = 0
        if size > offset:
            with transcript.open('rb') as f:
                f.seek(offset); chunk = f.read()
            complete = chunk[:chunk.rfind(b'\n') + 1]  # never index a half-written line
            for line in complete.decode(errors='replace').splitlines():
                try: e = json.loads(line)
                except ValueError: continue
                if e.get('event') == 'tripwire':
                    added_tripwires += 1; added_severe += e.get('severity') == 'severe'
                db.execute('insert into events values(?,?,?,?,?,?,?,?)', (key, e.get('seq'), e.get('step'), e.get('agent_id'),
                           e.get('event'), e.get('tool'), e.get('severity'), event_text(e)))
            offset += len(complete)
        folder = transcript.parent
        manifest = _load(folder / 'manifest.json'); label = _load(folder / 'label.json')
        if row is None:
            db.execute('insert into episodes(key,path,offset,tripwires,severe) values(?,?,0,0,0)', (key, str(transcript.resolve())))
        db.execute('''update episodes set run=?, episode_id=?, task_id=?, model_id=?, status=?, outcome=?, claimed_success=?,
                      started=?, offset=?, tripwires=tripwires+?, severe=severe+? where key=?''',
                   (folder.parent.name, manifest.get('episode_id', folder.name), manifest.get('task_id'), manifest.get('model_id'),
                    manifest.get('status'), label.get('outcome'), label.get('claimed_success'), manifest.get('started_at'),
                    offset, added_tripwires, added_severe, key))

    def episodes(self, run_folder):
        prefix = str(Path(run_folder).resolve()) + os.sep
        pattern = prefix.replace('\\', '\\\\').replace('%', r'\%').replace('_', r'\_') + '%'
        with self._db() as db:
            rows = db.execute(r"select * from episodes where path like ? escape '\' order by started", (pattern,)).fetchall()
        return [_episode(r) for r in rows]

    def episode(self, key):
        if not KEY.match(key or ''): raise ValueError('Unknown episode')
        with self._db() as db:
            row = db.execute('select * from episodes where key=?', (key,)).fetchone()
        if row is None: raise ValueError('Unknown episode')
        return row

    def search(self, q='', event=None, task=None, outcome=None, severity=None, limit=100):
        where, args = [], []
        if q.strip():
            where.append('events match ?'); args.append(fts_query(q))
        for column, value in (('e.event', event), ('ep.task_id', task), ('ep.outcome', outcome), ('e.severity', severity)):
            if value: where.append(f'{column}=?'); args.append(value)
        snippet = "snippet(events, 7, '[', ']', '…', 18)" if q.strip() else 'substr(e.text, 1, 240)'
        order = 'rank' if q.strip() else 'ep.started desc, e.seq'
        sql = f'''select e.key, e.seq, e.step, e.agent, e.event, e.tool, e.severity, {snippet} as snippet,
                  ep.task_id, ep.episode_id, ep.run, ep.outcome from events e join episodes ep on ep.key=e.key
                  {'where ' + ' and '.join(where) if where else ''} order by {order} limit ?'''
        with self._db() as db:
            try: rows = db.execute(sql, (*args, max(1, min(int(limit), 500)))).fetchall()
            except sqlite3.OperationalError as error: raise ValueError(f'Search failed: {error}')
        return [dict(r) for r in rows]


def _load(path):
    try: return json.loads(Path(path).read_text())
    except (OSError, ValueError): return {}


def _episode(row):
    return dict(key=row['key'], episode_id=row['episode_id'], run=row['run'], task_id=row['task_id'], model_id=row['model_id'],
                status=row['status'], outcome=row['outcome'], claimed_success=row['claimed_success'],
                tripwires=row['tripwires'], severe=row['severe'], started=row['started'])


class SandboxRuns:
    def __init__(self, root):
        self.root = Path(root).expanduser()
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.lock = threading.RLock()
        self.active = self.process = None
        self.index = EventIndex(self.root / 'index.sqlite')
        for path in self.root.glob('*/run.json'):
            data = _load(path)
            if data.get('status') == 'running':
                data.update(status='interrupted', ended=time.time()); self._write(data)

    def _write(self, record):
        path = self.root / record['id'] / 'run.json'
        temp = path.with_suffix('.tmp')
        temp.write_text(json.dumps(record, ensure_ascii=False, indent=2)); os.chmod(temp, 0o600); temp.replace(path)

    @staticmethod
    def harness(directory):
        if not isinstance(directory, str) or not directory.strip(): raise ValueError('Choose the harness folder')
        folder = Path(directory).expanduser().resolve()
        python = folder / '.venv' / 'bin' / 'python'
        if not (folder / 'harness' / '__main__.py').is_file() or not python.is_file():
            raise ValueError('The harness folder must contain harness/ and a .venv with the harness installed')
        return folder, python

    def sources(self):
        return _load(self.root / 'sources.json').get('sources', [])

    def add_source(self, path):
        folder = Path(text(path, 'path', 4096)).expanduser().resolve()
        if not folder.is_dir(): raise ValueError('Choose an existing runs folder')
        with self.lock:
            sources = sorted(set(self.sources()) | {str(folder)})
            (self.root / 'sources.json').write_text(json.dumps(dict(sources=sources), indent=2))
        threading.Thread(target=self.index.update, args=([folder],), daemon=True).start()
        return dict(sources=sources)

    def refresh_index(self):
        self.index.update([self.root, *[s for s in self.sources() if Path(s).is_dir()]])

    def tasks(self, directory):
        folder, python = self.harness(directory)
        out = subprocess.run([str(python), '-m', 'harness', 'tasks'], cwd=folder, capture_output=True, text=True, timeout=30)
        if out.returncode: raise ValueError(out.stderr[-2000:] or 'The harness could not list tasks')
        return json.loads(out.stdout)

    def create(self, config):
        allowed = {'title', 'harness_dir', 'task', 'count', 'port', 'model', 'revision', 'seed'}
        if not isinstance(config, dict) or set(config) - allowed: raise ValueError('Unsupported sandbox run config')
        c = dict(config); c.setdefault('count', 1)
        text(c.get('title', c.get('task')), 'title', 200); text(c.get('model'), 'model', 2048)
        if not EPISODE_NAME.match(c.get('task') or ''): raise ValueError('Choose a harness task')
        if type(c['count']) is not int or not 1 <= c['count'] <= 20: raise ValueError('count must be 1–20')
        if type(c.get('port')) is not int or not 1024 <= c['port'] <= 65535: raise ValueError('Choose a loopback model port')
        if 'seed' in c and (type(c['seed']) is not int or c['seed'] < 0): raise ValueError('seed must be a nonnegative integer')
        folder_path, python = self.harness(c.get('harness_dir'))
        with self.lock:
            if self.active: raise RuntimeError('Another sandbox run is in progress')
            identifier = uuid.uuid4().hex
            folder = self.root / identifier
            folder.mkdir(mode=0o700)
            record = dict(id=identifier, created=time.time(), status='running', title=c.get('title') or c['task'],
                          config=c, config_hash=digest(c))
            command = [str(python), '-m', 'harness', '--base-url', f"http://127.0.0.1:{c['port']}/v1", '--model-id', c['model']]
            if c.get('revision'): command += ['--model-revision', c['revision']]
            command += ['run', '--task', c['task'], '--count', str(c['count']), '--out', str(folder / 'episodes')]
            if 'seed' in c: command += ['--seed', str(c['seed'])]
            record['command'] = command
            self._write(record)
            log = (folder / 'harness.log').open('w')
            self.process = subprocess.Popen(command, cwd=folder_path, stdout=log, stderr=subprocess.STDOUT,
                                            env=dict(os.environ, PYTHONUNBUFFERED='1'), start_new_session=True)
            self.active = identifier
            threading.Thread(target=self._wait, args=(identifier, self.process, log), daemon=True).start()
            return record

    def _wait(self, identifier, process, log):
        code = process.wait(); log.close()
        with self.lock:
            record = self.read_record(identifier)
            if record['status'] == 'running':
                record['status'] = 'completed' if code == 0 else 'failed'
                if code: record['error'] = (self.root / identifier / 'harness.log').read_text(errors='replace')[-4000:]
            record['ended'] = time.time(); self._write(record)
            if self.active == identifier: self.active = self.process = None
        self.index.update([self.root / identifier])

    def cancel(self, identifier):
        with self.lock:
            record = self.read_record(identifier)
            if self.active != identifier: return record
            record['status'] = 'cancelled'; self._write(record)
            process = self.process
        # SIGINT lets the harness tear down its container before exiting.
        try: os.killpg(process.pid, signal.SIGINT)
        except ProcessLookupError: pass
        try: process.wait(timeout=30)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL); process.wait()
        return self.read_record(identifier)

    def read_record(self, identifier):
        if not KEY.match(identifier or ''): raise ValueError('Unknown sandbox run')
        record = _load(self.root / identifier / 'run.json')
        if not record: raise ValueError('Unknown sandbox run')
        return record

    def list(self):
        records = [r for r in (_load(p) for p in self.root.glob('*/run.json')) if r]
        return sorted(records, key=lambda r: r['created'], reverse=True)[:200]

    def read(self, identifier):
        record = self.read_record(identifier)
        self.index.update([self.root / identifier])
        return dict(record, episodes=self.index.episodes(self.root / identifier))

    def episode(self, key):
        row = self.index.episode(key)
        folder = Path(row['path']).parent
        return dict(_episode(row), manifest=_load(folder / 'manifest.json'), label=_load(folder / 'label.json'))

    def events(self, key, after=0, limit=500):
        path = Path(self.index.episode(key)['path'])
        events = []
        with path.open(errors='replace') as f:
            for line in f:
                if not line.endswith('\n'): break
                try: e = json.loads(line)
                except ValueError: continue
                if (e.get('seq') or 0) > after:
                    events.append(e)
                    if len(events) >= limit: break
        return dict(events=events, last=events[-1].get('seq') if events else after)

    def search(self, params):
        self.refresh_index()
        return dict(results=self.index.search(**params))
