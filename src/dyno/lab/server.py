"""Research jobs run serially in disposable processes, separate from inference."""
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import threading
import time
import uuid
from urllib.parse import parse_qs
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from ..execution import ExecutionHTTPMixin
from .studies import Studies, summarize, monitor_metrics
from .monitors import Monitors
from .regressions import ResearchReports
from .agent_tasks import AgentTasks
from .sandbox import SandboxRuns

OPERATIONS = ('inspect', 'compare', 'probe', 'sae', 'patch_sweep')


def validate(body):
    if not isinstance(body, dict) or body.get('operation') not in OPERATIONS:
        raise ValueError('operation must be inspect, compare, probe, sae or patch_sweep')
    if not isinstance(body.get('model'), str) or not body['model'].strip():
        raise ValueError('Choose a local model directory or Hugging Face model ID')
    if 'response' in body and (body['operation'] != 'inspect' or not isinstance(body['response'], str) or not body['response'].strip()):
        raise ValueError('A nonempty response can only be captured with inspect')
    if not isinstance(body.get('layers', [0]), list) or not 1 <= len(body.get('layers', [0])) <= 8:
        raise ValueError('Select between 1 and 8 layers')
    if any(type(i) is not int or not 0 <= i < 256 for i in body.get('layers', [0])):
        raise ValueError('Layer indices must be integers between 0 and 255')
    if len(set(body.get('layers', [0]))) != len(body.get('layers', [0])):
        raise ValueError('Layer indices must be unique')
    if body['operation'] == 'patch_sweep':
        if any(not isinstance(body.get(key), str) or not body[key].strip() for key in ('prompt', 'clean_prompt', 'target_token', 'foil_token')):
            raise ValueError('Causal patching requires prompt, clean_prompt, target_token and foil_token')
        if 'positions' in body:
            positions = body['positions']
            if not isinstance(positions, list) or not positions or any(type(p) is not int or p < 0 for p in positions) or len(set(positions)) != len(positions) or len(positions)*len(body.get('layers', [0])) > 128:
                raise ValueError('Select unique nonnegative positions; at most 128 layer/token sites')
    for key, default, maximum in [('max_tokens', 32, 128), ('max_input_tokens', 256, 1024), ('seed', 0, 2147483647)]:
        value = body.get(key, default)
        if type(value) is not int or not (0 if key == 'seed' else 1) <= value <= maximum:
            raise ValueError(f'{key} is out of range')
    if len(body.get('examples', [])) > 512:
        raise ValueError('At most 512 examples per experiment')
    if 'probe_validation' in body and type(body['probe_validation']) is not bool:
        raise ValueError('probe_validation must be a boolean')
    if 'intervention_controls' in body and type(body['intervention_controls']) is not bool:
        raise ValueError('intervention_controls must be a boolean')
    if body.get('intervention_controls'):
        if body['operation'] != 'compare': raise ValueError('intervention_controls applies only to comparisons')
        if type(body.get('control_repeats', 3)) is not int or not 1 <= body.get('control_repeats', 3) <= 5:
            raise ValueError('control_repeats must be 1–5')
        if len(body.get('prompts', [body.get('prompt')])) * len(body.get('strengths', [0, .5, 1, 1.5])) > 24:
            raise ValueError('Controlled interventions support at most 24 prompt/strength pairs')
    if body.get('probe_validation'):
        if body['operation'] != 'probe': raise ValueError('probe_validation applies only to probes')
        from .probe_validation import validate_dataset
        validate_dataset(body.get('examples'))
    if body.get('backend') == 'pool':
        if type(body.get('pool_port')) is not int or not 1024 <= body['pool_port'] <= 65535:
            raise ValueError('Choose a loopback pool port')
        if len(body.get('layers',[0])) > 4 or body.get('max_input_tokens',256)>256:
            raise ValueError('Pool experiments support up to 4 layers and 256 input tokens')
    elif body.get('backend') not in (None, 'mlx'):
        raise ValueError('Unsupported research backend')
    if len(json.dumps(body)) > 500_000:
        raise ValueError('Experiment configuration is too large')
    return body


class Jobs:
    def __init__(self, root):
        self.root = Path(root).expanduser()
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        import fcntl
        self._directory_lock = (self.root / '.lock').open('a')
        try:
            fcntl.flock(self._directory_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            self._directory_lock.close()
            raise RuntimeError('Another Lab service is already using this data directory')
        self.lock = threading.RLock()
        self.active = None
        self.process = None
        # A interrupted app/service must not leave jobs permanently running.
        for path in self.root.glob('*/job.json'):
            try:
                data = json.loads(path.read_text())
                if data['status'] in ('queued', 'running'):
                    data.update(status='interrupted', ended=time.time())
                    self.write(path, data)
            except (OSError, ValueError, KeyError):
                pass

    @staticmethod
    def write(path, data):
        temp = path.with_suffix('.tmp')
        temp.write_text(json.dumps(data, ensure_ascii=False, indent=2))
        os.chmod(temp, 0o600)
        temp.replace(path)

    def read(self, identifier):
        if len(identifier) != 32 or any(c not in '0123456789abcdef' for c in identifier):
            raise FileNotFoundError(identifier)
        return json.loads((self.root / identifier / 'job.json').read_text())

    def list(self):
        results = []
        for p in self.root.glob('*/job.json'):
            try:
                data = json.loads(p.read_text())
                results.append({k: v for k, v in data.items() if k not in ('result', 'config')})
            except (OSError, ValueError):
                pass
        return sorted(results, key=lambda x: x['created'], reverse=True)[:100]

    def submit(self, config):
        config = validate(config)
        with self.lock:
            if self.active:
                raise RuntimeError('A research job is already running. Cancel it or wait.')
            identifier = uuid.uuid4().hex
            folder = self.root / identifier
            folder.mkdir(mode=0o700)
            data = dict(id=identifier, created=time.time(), status='queued', operation=config['operation'], model=config['model'], config=config)
            self.write(folder / 'job.json', data)
            self.active = identifier
            threading.Thread(target=self.run, args=(data, folder), daemon=True).start()
            return data

    def run(self, data, folder):
        try:
            with self.lock:
                if self.active != data['id']:
                    return
                data['status'] = 'running'
                self.write(folder / 'job.json', data)
                env = dict(os.environ, PYTHONUNBUFFERED='1')
                with (folder / 'worker.log').open('w') as log:
                    self.process = subprocess.Popen([sys.executable, '-m', 'dyno.lab.worker', str(folder)], env=env, stdout=log, stderr=log)
                process = self.process
            process.wait(timeout=1800)
            with self.lock:
                if self.active != data['id']:
                    return
                result_path = folder / 'result.json'
                if process.returncode == 0 and result_path.exists():
                    data.update(status='completed', result=json.loads(result_path.read_text()))
                else:
                    data.update(status='failed', error=(folder / 'worker.log').read_text()[-4000:])
        except Exception as error:
            with self.lock:
                if self.active != data['id']:
                    return
                if self.process and self.process.poll() is None:
                    self.process.kill()
                    self.process.wait()
                data.update(status='failed', error=str(error))
        finally:
            with self.lock:
                if self.active == data['id']:
                    data['ended'] = time.time()
                    self.write(folder / 'job.json', data)
                    self.active = self.process = None

    def cancel(self, identifier):
        with self.lock:
            data = self.read(identifier)
            if self.active == identifier:
                if self.process:
                    self.process.kill()
                    self.process.wait()
                self.active = self.process = None
                data.update(status='cancelled', ended=time.time())
                self.write(self.root / identifier / 'job.json', data)
            return data


class Handler(ExecutionHTTPMixin, BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        if not self._execution_local():
            return
        path = self.path.split('?', 1)[0]
        if path == '/lab/v1/health':
            self._execution_send({'status': 'ok', 'api_version': 1, 'worker_revision': 2, 'controlled_studies': 1, 'monitor_evaluations': 1, 'sandbox_episodes': 1, 'operations': OPERATIONS})
        elif path.startswith('/lab/v1/sandbox/'):
            try: self._execution_send(self._sandbox_get(path.removeprefix('/lab/v1/sandbox/').split('/'), self._query()))
            except (ValueError, OSError, subprocess.SubprocessError) as error: self._execution_send({'error': str(error)}, 400)
        elif path == '/lab/v1/agent-tasks':
            self._execution_send({'tasks':self.server.agent_tasks.list()})
        elif path.startswith('/lab/v1/agent-tasks/'):
            try:self._execution_send(self.server.agent_tasks.read(path.rsplit('/',1)[-1]))
            except (ValueError,OSError) as error:self._execution_send({'error':str(error)},400)
        elif path == '/lab/v1/reports':
            self._execution_send({'reports': self.server.reports.list()})
        elif path.startswith('/lab/v1/reports/'):
            try: self._execution_send(self.server.reports.read(path.rsplit('/',1)[-1]))
            except (ValueError, OSError) as error: self._execution_send({'error':str(error)},400)
        elif path == '/lab/v1/monitors':
            self._execution_send({'evaluations': self.server.monitors.list()})
        elif path.startswith('/lab/v1/monitors/'):
            try:
                parts = path.removeprefix('/lab/v1/monitors/').split('/')
                if len(parts) == 1: result = self.server.monitors.read(parts[0])
                elif parts[1:] == ['report']: result = self.server.monitors.report(parts[0])
                elif parts[1:] == ['export']: result = self.server.monitors.export(parts[0])
                else: raise ValueError('Unknown monitor route')
                self._execution_send(result)
            except (ValueError, OSError) as error:
                self._execution_send({'error': str(error)}, 400)
        elif path == '/lab/v1/studies':
            self._execution_send({'studies': self.server.studies.list()})
        elif path.startswith('/lab/v1/studies/'):
            try:
                parts = path.removeprefix('/lab/v1/studies/').split('/')
                data = self.server.studies.read(parts[0])
                if len(parts) == 1: result = data
                elif parts[1:] == ['summary']: result = summarize(data)
                elif parts[1:] == ['export']: result = self.server.studies.export(parts[0])
                elif parts[1:] == ['reproduction-report']: result = self.server.studies.reproduction_report(parts[0])
                else: raise ValueError('Unknown study route')
                self._execution_send(result)
            except (ValueError, OSError) as error:
                self._execution_send({'error': str(error)}, 400)
        elif path == '/lab/v1/jobs':
            self._execution_send({'jobs': self.server.jobs.list()})
        elif path == '/lab/v1/openapi.json':
            self._execution_send(json.loads(Path(__file__).with_name('openapi.json').read_text()))
        elif '/artifacts/' in path and path.startswith('/lab/v1/jobs/'):
            try:
                pieces = path.split('/')
                if len(pieces) != 7:
                    raise FileNotFoundError()
                job = self.server.jobs.read(pieces[4])
                name = pieces[6]
                if name not in job.get('result', {}).get('artifacts', []):
                    raise FileNotFoundError()
                content = (self.server.jobs.root / job['id'] / name).read_bytes()
                self.send_response(200)
                self.send_header('Content-Type', 'application/octet-stream')
                self.send_header('Content-Length', str(len(content)))
                self.send_header('Cache-Control', 'no-store')
                self.end_headers()
                self.wfile.write(content)
            except (OSError, ValueError):
                self._execution_send({'error': 'artifact not found'}, 404)
        elif path.startswith('/lab/v1/jobs/'):
            try:
                self._execution_send(self.server.jobs.read(path.rsplit('/', 1)[-1]))
            except (OSError, ValueError):
                self._execution_send({'error': 'job not found'}, 404)
        else:
            self._execution_send({'error': 'not found'}, 404)

    def _query(self):
        query = self.path.split('?', 1)[1] if '?' in self.path else ''
        return {k: v[-1] for k, v in parse_qs(query).items()}

    def _sandbox_get(self, parts, query):
        runs = self.server.sandbox
        if parts == ['runs']: return {'runs': runs.list()}
        if parts == ['sources']: return {'sources': runs.sources()}
        if parts == ['readiness']: return runs.readiness()
        if parts == ['stats']: return runs.stats()
        if parts == ['evaluators']: return runs.evaluators()
        if parts == ['environments']: return runs.environments(query.get('harness_dir'))
        if parts == ['engine']: return runs.engine(query.get('harness_dir'))
        if len(parts) == 2 and parts[0] == 'environment-templates': return runs.environment_detail(query.get('harness_dir'), parts[1])
        if len(parts) == 3 and parts[0] == 'environments' and parts[2] == 'events': return runs.environment_events(query.get('harness_dir'), parts[1])
        if len(parts) == 3 and parts[0] == 'episodes' and parts[2] == 'evaluations': return runs.episode_evaluations(parts[1])
        if parts == ['threads']: return runs.threads(int(query.get('limit', 200)))
        if parts == ['feed']: return runs.feed(int(query.get('after', 0)), int(query.get('limit', 100)))
        if len(parts) == 2 and parts[0] == 'tasks': return runs.task_detail(query.get('harness_dir'), parts[1])
        if len(parts) == 3 and parts[0] == 'runs' and parts[2] == 'verify': return runs.verify(parts[1])
        if parts == ['tasks']: return runs.tasks(query.get('harness_dir'))
        if parts == ['search']:
            params = {k: query[k] for k in ('q', 'event', 'task', 'outcome', 'severity', 'limit') if query.get(k)}
            return runs.search(params)
        if len(parts) == 2 and parts[0] == 'runs': return runs.read(parts[1])
        if parts == ['rooms']: return runs.rooms()
        if parts == ['prompts']: return runs.prompts.list(query.get('harness_dir'))
        if parts == ['alerts']: return runs.alerts.list()
        if len(parts) == 2 and parts[0] == 'prompts': return runs.prompts.get(parts[1])
        interactive = query.get('interactive') == '1'
        if parts == ['evals']: return runs.evals.overview(interactive)
        if parts == ['evals', 'cell']: return runs.evals.cell(query.get('scenario'), query.get('config'), interactive)
        if parts == ['evals', 'compare']: return runs.evals.compare(query.get('a'), query.get('b'), interactive)
        if parts == ['evals', 'batches']: return runs.evals.batches()
        if parts == ['evals', 'review']: return runs.evals.grading.overview()
        if len(parts) == 3 and parts[:2] == ['evals', 'review']: return runs.evals.grading.detail(parts[2])
        if len(parts) == 2 and parts[0] == 'rooms': return runs.room(parts[1], int(query.get('after', 0)), int(query.get('observed', 0)))
        if len(parts) == 2 and parts[0] == 'episodes': return runs.episode(parts[1])
        if len(parts) == 3 and parts[0] == 'episodes' and parts[2] == 'events':
            return runs.events(parts[1], int(query.get('after', 0)))
        raise ValueError('Unknown sandbox route')

    def do_DELETE(self):
        if not self._execution_local():
            return
        path = self.path.split('?', 1)[0]
        if not path.startswith('/lab/v1/jobs/'):
            self._execution_send({'error': 'not found'}, 404)
            return
        try:
            import shutil
            with self.server.jobs.lock:
                job = self.server.jobs.read(path.rsplit('/', 1)[-1])
                if self.server.jobs.active == job['id']:
                    self._execution_send({'error': 'cancel active job before deleting'}, 409)
                    return
                shutil.rmtree(self.server.jobs.root / job['id'])
            self._execution_send({'deleted': True})
        except (OSError, ValueError):
            self._execution_send({'error': 'job not found'}, 404)

    def do_POST(self):
        if not self._execution_local():
            return
        try:
            length = int(self.headers.get('Content-Length', '0'))
            maximum = 4_000_000 if self.path == '/lab/v1/studies/import' else 500_000
            if not 0 < length <= maximum:
                raise ValueError(f'Request must be 1–{maximum} bytes')
            body = json.loads(self.rfile.read(length))
            if not isinstance(body, dict): raise ValueError('Request must be an object')
            if self.path == '/lab/v1/sandbox/runs':
                self._execution_send(self.server.sandbox.create(body), 201)
            elif self.path == '/lab/v1/sandbox/rooms/plan':
                self._execution_send(self.server.sandbox.room_plan(body))
            elif self.path.startswith('/lab/v1/sandbox/rooms/') and self.path.endswith('/messages'):
                self._execution_send(self.server.sandbox.room_message(self.path.split('/')[-2], body), 201)
            elif self.path == '/lab/v1/sandbox/alerts':
                self._execution_send(self.server.sandbox.alerts.save(body), 201)
            elif self.path == '/lab/v1/sandbox/alerts/delete':
                self._execution_send(self.server.sandbox.alerts.delete(body))
            elif self.path == '/lab/v1/sandbox/alerts/try':
                self._execution_send(self.server.sandbox.alerts.try_on(body))
            elif self.path == '/lab/v1/sandbox/prompts':
                self._execution_send(self.server.sandbox.prompts.save(body), 201)
            elif self.path == '/lab/v1/sandbox/evals/judge':
                self._execution_send(self.server.sandbox.evals.grading.start_judge(body), 202)
            elif self.path.startswith('/lab/v1/sandbox/evals/review/'):
                self._execution_send(self.server.sandbox.evals.grading.save_review(self.path.split('/')[-1], body), 201)
            elif self.path == '/lab/v1/sandbox/evals/batches':
                self._execution_send(self.server.sandbox.evals.start_batch(body), 201)
            elif self.path.startswith('/lab/v1/sandbox/evals/batches/') and self.path.endswith('/cancel'):
                self._execution_send(self.server.sandbox.evals.cancel_batch(self.path.split('/')[-2]))
            elif self.path.startswith('/lab/v1/sandbox/rooms/') and self.path.endswith('/export'):
                from .room_export import export
                if set(body) - {'format', 'thinking', 'observer'}: raise ValueError('Use format, thinking and observer')
                self._execution_send(export(self.server.sandbox, self.path.split('/')[-2], body.get('format'),
                                            thinking=body.get('thinking') is not False, observer=body.get('observer') is not False))
            elif self.path.startswith('/lab/v1/sandbox/rooms/') and self.path.endswith('/end'):
                self._execution_send(self.server.sandbox.room_end(self.path.split('/')[-2]))
            elif self.path == '/lab/v1/sandbox/environment-templates':
                self._execution_send(self.server.sandbox.save_environment(body), 201)
            elif self.path == '/lab/v1/sandbox/environment-templates/delete':
                self._execution_send(self.server.sandbox.delete_environment(body))
            elif self.path == '/lab/v1/sandbox/engine/setup':
                self._execution_send(self.server.sandbox.setup_engine(body), 202)
            elif self.path == '/lab/v1/sandbox/environments':
                self._execution_send(self.server.sandbox.environment_action(body), 202)
            elif self.path == '/lab/v1/sandbox/evaluators':
                self._execution_send(self.server.sandbox.save_monitor(body), 201)
            elif self.path == '/lab/v1/sandbox/evaluators/delete':
                self._execution_send(self.server.sandbox.delete_monitor(body))
            elif self.path.startswith('/lab/v1/sandbox/evaluators/') and self.path.endswith('/run'):
                self._execution_send(self.server.sandbox.run_monitor(self.path.split('/')[-2], body), 202)
            elif self.path == '/lab/v1/sandbox/tasks':
                self._execution_send(self.server.sandbox.save_task(body), 201)
            elif self.path == '/lab/v1/sandbox/tasks/dryrun':
                self._execution_send(self.server.sandbox.dryrun_task(body))
            elif self.path == '/lab/v1/sandbox/tasks/delete':
                self._execution_send(self.server.sandbox.delete_task(body))
            elif self.path == '/lab/v1/sandbox/readiness':
                if set(body) != {'harness_dir'}: raise ValueError('Use harness_dir')
                self._execution_send(self.server.sandbox.check_readiness(body['harness_dir']), 202)
            elif self.path == '/lab/v1/sandbox/sources':
                if set(body) != {'path'}: raise ValueError('Use path')
                self._execution_send(self.server.sandbox.add_source(body['path']), 201)
            elif self.path.startswith('/lab/v1/sandbox/runs/') and self.path.endswith('/seal'):
                if body: raise ValueError('Seal expects an empty object')
                self._execution_send(self.server.sandbox.seal(self.path.split('/')[-2]))
            elif self.path.startswith('/lab/v1/sandbox/episodes/') and self.path.endswith('/review'):
                self._execution_send(self.server.sandbox.review(self.path.split('/')[-2], body), 201)
            elif self.path.startswith('/lab/v1/sandbox/runs/') and self.path.endswith('/cancel'):
                if body: raise ValueError('Cancel expects an empty object')
                self._execution_send(self.server.sandbox.cancel(self.path.split('/')[-2]))
            elif self.path == '/lab/v1/agent-tasks':
                self._execution_send(self.server.agent_tasks.create(body),201)
            elif self.path.startswith('/lab/v1/agent-tasks/'):
                parts=self.path.removeprefix('/lab/v1/agent-tasks/').split('/')
                if len(parts)!=2 or body:raise ValueError('Task action expects an empty object')
                if parts[1]=='run':result=self.server.agent_tasks.run(parts[0])
                elif parts[1]=='cancel':result=self.server.agent_tasks.cancel(parts[0])
                else:raise ValueError('Unknown task action')
                self._execution_send(result)
            elif self.path == '/lab/v1/reports/compatibility':
                self._execution_send(self.server.reports.compatibility(body,self.server.jobs),201)
            elif self.path == '/lab/v1/reports/checkpoints':
                self._execution_send(self.server.reports.checkpoints(body),201)
            elif self.path == '/lab/v1/reports/regression':
                self._execution_send(self.server.reports.regression(body),201)
            elif self.path == '/lab/v1/monitors':
                if set(body) != {'source_id', 'config'}: raise ValueError('Use source_id and config')
                self._execution_send(self.server.monitors.create(body['source_id'], body['config']), 201)
            elif self.path.startswith('/lab/v1/monitors/'):
                parts = self.path.removeprefix('/lab/v1/monitors/').split('/')
                if len(parts) != 2: raise ValueError('Invalid monitor route')
                if parts[1] == 'select-threshold':
                    if set(body)!={'candidates','prior_test_exposure'}:raise ValueError('Use candidates and prior_test_exposure')
                    self._execution_send(self.server.monitors.select_threshold(parts[0],body['candidates'],body['prior_test_exposure']),201)
                    return
                if body: raise ValueError('Monitor action expects an empty object')
                if parts[1] == 'run': result = self.server.monitors.run(parts[0])
                elif parts[1] == 'cancel': result = self.server.monitors.cancel(parts[0])
                else: raise ValueError('Unknown monitor action')
                self._execution_send(result)
            elif self.path == '/lab/v1/studies':
                self._execution_send(self.server.studies.create(body), 201)
            elif self.path == '/lab/v1/studies/import':
                self._execution_send(self.server.studies.import_bundle(body), 201)
            elif self.path == '/lab/v1/monitor-metrics':
                self._execution_send(monitor_metrics(body.get('rows'), body.get('threshold')))
            elif self.path.startswith('/lab/v1/studies/'):
                parts = self.path.removeprefix('/lab/v1/studies/').split('/')
                if len(parts) != 2: raise ValueError('Unknown study route')
                identifier, action = parts
                if action == 'run': result = self.server.studies.run(identifier, body.get('port'), body.get('model'))
                elif action == 'cancel': result = self.server.studies.cancel(identifier)
                elif action == 'labels': result = self.server.studies.label(identifier, body.get('run_id'), body.get('value'), body.get('reviewer'), body.get('note', ''))
                elif action == 'prepare-review': result = self.server.studies.prepare_review(identifier, body.get('reviewer'), body.get('prior_exposure'))
                elif action == 'review': result = self.server.studies.review(identifier, body.get('review_id'))
                elif action == 'review-label': result = self.server.studies.review_label(identifier, body.get('review_id'), body.get('item_id'), body.get('value'), body.get('note', ''))
                elif action == 'reveal-review': result = self.server.studies.reveal_review(identifier, body.get('review_id'))
                elif action == 'reproduce': result = self.server.studies.reproduce(identifier)
                else: raise ValueError('Unknown study action')
                self._execution_send(result)
            elif self.path == '/lab/v1/jobs':
                self._execution_send(self.server.jobs.submit(body), 202)
            elif self.path.startswith('/lab/v1/jobs/') and self.path.endswith('/cancel'):
                self._execution_send(self.server.jobs.cancel(self.path.split('/')[-2]))
            else:
                self._execution_send({'error': 'not found'}, 404)
        except RuntimeError as error:
            self._execution_send({'error': str(error)}, 409)
        except (ValueError, TypeError, OSError) as error:
            self._execution_send({'error': str(error)}, 400)


def main(argv=None):
    parser = argparse.ArgumentParser(description='Dyno local AI safety and alignment research API')
    parser.add_argument('--port', type=int, default=8980)
    parser.add_argument('--data-dir', default='~/.mlx-dyno/lab')
    args = parser.parse_args(argv)
    server = ThreadingHTTPServer(('127.0.0.1', args.port), Handler)
    server.jobs = Jobs(args.data_dir)
    server.studies = Studies(Path(args.data_dir).expanduser() / 'controlled-studies')
    server.agent_tasks = AgentTasks(Path(args.data_dir).expanduser() / 'agent-tasks')
    server.sandbox = SandboxRuns(Path(args.data_dir).expanduser() / 'sandbox-runs')
    server.reports = ResearchReports(Path(args.data_dir).expanduser() / 'research-reports', server.studies)
    server.monitors = Monitors(Path(args.data_dir).expanduser() / 'monitor-evaluations', server.studies)
    print(f'Dyno Research Lab: http://127.0.0.1:{args.port}/lab/v1', flush=True)
    def terminate(*_):
        raise KeyboardInterrupt()
    signal.signal(signal.SIGTERM, terminate)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        if server.sandbox.active:
            server.sandbox.cancel(server.sandbox.active)
        if server.agent_tasks.active:
            server.agent_tasks.cancel(server.agent_tasks.active)
        if server.monitors.active:
            server.monitors.cancel(server.monitors.active)
        if server.studies.active:
            server.studies.cancel(server.studies.active)
        if server.jobs.active:
            server.jobs.cancel(server.jobs.active)
        server.server_close()
        server.jobs._directory_lock.close()
    return 0
