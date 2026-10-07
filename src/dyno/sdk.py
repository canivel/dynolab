"""Dependency-free Python client for Dyno's research API."""
import json
import time
import urllib.error
import urllib.request


class DynoError(RuntimeError):
    pass


class Lab:
    api_prefix = "/lab/v1"
    def __init__(self, base_url='http://127.0.0.1:8980', timeout=10):
        self.base_url, self.timeout = base_url.rstrip('/'), timeout

    def _request(self, path, body=None):
        request=urllib.request.Request(self.base_url+self.api_prefix+path,
            data=json.dumps(body).encode() if body is not None else None,
            headers={'Content-Type':'application/json'})
        try:
            with urllib.request.urlopen(request,timeout=self.timeout) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            raise DynoError(error.read().decode()) from error

    def artifact(self, identifier, name, destination):
        """Download an artifact named in job['result']['artifacts']."""
        from pathlib import Path
        from urllib.parse import quote
        url = self.base_url+'/lab/v1/jobs/'+quote(identifier, safe='')+'/artifacts/'+quote(name, safe='')
        with urllib.request.urlopen(url, timeout=self.timeout) as response:
            Path(destination).write_bytes(response.read())
        return Path(destination)

    def schema(self): return self._request('/openapi.json')
    def studies(self): return self._request('/studies')['studies']
    def create_study(self, protocol): return self._request('/studies', protocol)
    def study(self, identifier): return self._request('/studies/'+identifier)
    def run_study(self, identifier, port, model): return self._request('/studies/'+identifier+'/run', dict(port=port, model=model))
    def cancel_study(self, identifier): return self._request('/studies/'+identifier+'/cancel', {})
    def label_run(self, identifier, run_id, value, reviewer, note=''): return self._request('/studies/'+identifier+'/labels', dict(run_id=run_id, value=value, reviewer=reviewer, note=note))
    def study_summary(self, identifier): return self._request('/studies/'+identifier+'/summary')
    def export_study(self, identifier): return self._request('/studies/'+identifier+'/export')
    def import_study(self, bundle): return self._request('/studies/import', bundle)
    def prepare_review(self, identifier, reviewer, prior_exposure):
        return self._request('/studies/'+identifier+'/prepare-review', dict(reviewer=reviewer, prior_exposure=prior_exposure))
    def review(self, identifier, review_id):
        return self._request('/studies/'+identifier+'/review', dict(review_id=review_id))
    def review_label(self, identifier, review_id, item_id, value, note=''):
        return self._request('/studies/'+identifier+'/review-label', dict(review_id=review_id, item_id=item_id, value=value, note=note))
    def reveal_review(self, identifier, review_id):
        return self._request('/studies/'+identifier+'/reveal-review', dict(review_id=review_id))
    def reproduce_study(self, identifier): return self._request('/studies/'+identifier+'/reproduce', {})
    def agent_tasks(self): return self._request('/agent-tasks')['tasks']
    def prepare_agent_task(self, config): return self._request('/agent-tasks',config)
    def agent_task(self, identifier): return self._request('/agent-tasks/'+identifier)
    def run_agent_task(self, identifier): return self._request('/agent-tasks/'+identifier+'/run',{})
    def cancel_agent_task(self, identifier): return self._request('/agent-tasks/'+identifier+'/cancel',{})
    def research_reports(self): return self._request('/reports')['reports']
    def research_report(self, identifier): return self._request('/reports/'+identifier)
    def checkpoint_report(self, config): return self._request('/reports/checkpoints',config)
    def compatibility_report(self, source_job_id, target_job_id): return self._request('/reports/compatibility', dict(source_job_id=source_job_id,target_job_id=target_job_id))
    def regression_report(self, config): return self._request('/reports/regression', config)
    def monitors(self): return self._request('/monitors')['evaluations']
    def prepare_monitor(self, source_id, config): return self._request('/monitors', dict(source_id=source_id, config=config))
    def monitor(self, identifier): return self._request('/monitors/'+identifier)
    def select_monitor_threshold(self, identifier, candidates, prior_test_exposure): return self._request('/monitors/'+identifier+'/select-threshold', dict(candidates=candidates,prior_test_exposure=prior_test_exposure))
    def run_monitor(self, identifier): return self._request('/monitors/'+identifier+'/run', {})
    def cancel_monitor(self, identifier): return self._request('/monitors/'+identifier+'/cancel', {})
    def monitor_report(self, identifier): return self._request('/monitors/'+identifier+'/report')
    def export_monitor(self, identifier): return self._request('/monitors/'+identifier+'/export')
    def reproduction_report(self, identifier): return self._request('/studies/'+identifier+'/reproduction-report')
    def monitor_metrics(self, rows, threshold): return self._request('/monitor-metrics', dict(rows=rows, threshold=threshold))
    def health(self): return self._request('/health')
    def jobs(self): return self._request('/jobs')['jobs']
    def submit(self, operation, model, **settings):
        return self._request('/jobs',dict(settings,operation=operation,model=model))
    def submit_pool(self, operation, model, pool_port=8978, **settings):
        """Run research against resident GGUF weights; the Lab service stays at base_url."""
        if type(pool_port) is not int or not 1024 <= pool_port <= 65535:
            raise ValueError('pool_port must be 1024–65535')
        return self.submit(operation, model, **dict(settings, backend='pool', pool_port=pool_port))
    def inspect(self, model, prompt, **settings): return self.submit('inspect',model,prompt=prompt,**settings)
    def capture_response(self, model, prompt, response, **settings):
        """Replay prompt plus response and export separate response-mean representations."""
        return self.inspect(model, prompt, response=response, **settings)
    def compare(self, model, prompt, **settings): return self.submit('compare',model,prompt=prompt,**settings)
    def probe(self, model, examples, **settings): return self.submit('probe',model,examples=examples,**settings)
    def sae(self, model, examples, **settings): return self.submit('sae',model,examples=examples,**settings)
    def patch_sweep(self, model, prompt, clean_prompt, target_token, foil_token, **settings):
        return self.submit('patch_sweep', model, prompt=prompt, clean_prompt=clean_prompt, target_token=target_token, foil_token=foil_token, **settings)
    def job(self, identifier): return self._request('/jobs/'+identifier)
    def cancel(self, identifier): return self._request('/jobs/'+identifier+'/cancel',{})
    # --- Agent sandbox tests: a lead agent and the team it builds, watched by a hidden Observer ---
    @staticmethod
    def _id(identifier):
        from urllib.parse import quote
        return quote(str(identifier), safe='')

    @staticmethod
    def _with_harness(body, harness_dir):
        return dict(body, harness_dir=harness_dir) if harness_dir else body

    def environments(self, harness_dir=None):
        """Environment templates (built-in and yours) and running instances."""
        return self._request('/sandbox/environments' + (f'?harness_dir={self._id(harness_dir)}' if harness_dir else ''))
    def environment(self, identifier, harness_dir=None):
        return self._request(f'/sandbox/environment-templates/{self._id(identifier)}' + (f'?harness_dir={self._id(harness_dir)}' if harness_dir else ''))
    def save_environment(self, spec, files=None, replace=False, harness_dir=None):
        """Save an environment template (segments, nodes, gateway rules). The harness checks it first."""
        return self._request('/sandbox/environment-templates', self._with_harness(dict(spec=spec, files=files or {}, replace=replace), harness_dir))
    def environment_from_compose(self, compose, identifier=None, title=None, save=False, replace=False, harness_dir=None):
        """Convert a Docker Compose file (YAML or JSON text) into an environment: spec, warnings, errors and
        the harness's validation. With save=True a valid one is saved. See the x-dyno keys in the guide."""
        body = dict(compose=compose, save=save, replace=replace)
        if identifier: body['id'] = identifier
        if title: body['title'] = title
        return self._request('/sandbox/environment-templates/from-compose', self._with_harness(body, harness_dir))

    def export_test_package(self, spec=None, test_id=None, title=None, description=None, author=None):
        """A shareable test package (environment, goal, rules, lead, prompt, alerts, script, history) from a setup
        spec or a past test. Save it as JSON (for example name.dynotest.json); it holds no model or port."""
        body = {k: v for k, v in dict(spec=spec, room=test_id, title=title, description=description, author=author).items() if v}
        return self._request('/sandbox/packages/export', body)
    def preview_test_package(self, package=None, url=None):
        """What importing would create (environment, prompt) and what the test would run. Nothing is saved."""
        return self._request('/sandbox/packages/preview', {k: v for k, v in dict(package=package, url=url).items() if v is not None})
    def import_test_package(self, package=None, url=None):
        """Import a package (an object, JSON text, or an https URL): saves the environment and prompt, reusing identical
        ones, and returns `setup` to start from. Choose a running model for setup['agents'][0] before starting."""
        return self._request('/sandbox/packages/import', {k: v for k, v in dict(package=package, url=url).items() if v is not None})

    def sandbox_runs(self): return self._request('/sandbox/runs')['runs']
    def sandbox_readiness(self): return self._request('/sandbox/readiness')
    def plan_agent_test(self, spec, harness_dir=None):
        """How each rule will be watched, and what must be fixed before the test can start. Nothing runs."""
        return self._request('/sandbox/rooms/plan', self._with_harness(dict(spec=spec), harness_dir))
    def start_agent_test(self, spec, harness_dir=None):
        """Start a test: spec has environment, goal, rules, agents (the lead: name, role, port, model),
        optional limits and prompt. Runs a sandbox and the model until a final report or a limit."""
        return self._request('/sandbox/runs', self._with_harness(dict(kind='room', spec=spec), harness_dir))
    def agent_tests(self): return self._request('/sandbox/rooms')['rooms']
    def agent_test(self, identifier, after=0, observed=0):
        """The test's transcript events after `after` and Observer entries after `observed`, and its verdict."""
        return self._request(f'/sandbox/rooms/{self._id(identifier)}?after={int(after)}&observed={int(observed)}')
    def message_agent_test(self, identifier, text, name='User'):
        """Write in a running test's chat. Every agent reads it at its next turn; the Observer records it."""
        return self._request(f'/sandbox/rooms/{self._id(identifier)}/messages', dict(text=text, name=name))
    def end_agent_test(self, identifier): return self._request(f'/sandbox/rooms/{self._id(identifier)}/end', {})
    def stop_agent_test(self, identifier): return self._request(f'/sandbox/runs/{self._id(identifier)}/cancel', {})
    def export_agent_test(self, identifier, format='md', thinking=True, observer=True):
        """Write the full log (format='md') or the raw files (format='zip'); returns the file's path."""
        return self._request(f'/sandbox/rooms/{self._id(identifier)}/export', dict(format=format, thinking=thinking, observer=observer))
    def agent_prompts(self, harness_dir=None):
        return self._request('/sandbox/prompts' + (f'?harness_dir={self._id(harness_dir)}' if harness_dir else ''))
    def agent_prompt(self, identifier): return self._request(f'/sandbox/prompts/{self._id(identifier)}')
    def save_agent_prompt(self, name, lead, teammate, note='', identifier=None):
        """A new prompt, or a new version of one. Earlier versions are never changed."""
        body = dict(name=name, lead=lead, teammate=teammate, note=note)
        return self._request('/sandbox/prompts', dict(body, id=identifier) if identifier else body)
    def observer_alerts(self): return self._request('/sandbox/alerts')['alerts']
    def save_observer_alert(self, alert): return self._request('/sandbox/alerts', alert)
    def delete_observer_alert(self, identifier): return self._request('/sandbox/alerts/delete', dict(id=identifier))
    def try_observer_alert(self, alert, test_id): return self._request('/sandbox/alerts/try', dict(alert=alert, room=test_id))
    def agent_evals(self, include_interactive=False):
        """Every finished test as a table of scenarios x configs, with safe rates and 95% ranges."""
        return self._request(f'/sandbox/evals?interactive={int(bool(include_interactive))}')
    def agent_eval_cell(self, scenario, config, include_interactive=False):
        return self._request(f'/sandbox/evals/cell?scenario={self._id(scenario)}&config={self._id(config)}&interactive={int(bool(include_interactive))}')
    def compare_agent_configs(self, a, b, include_interactive=False):
        """Config B against config A on the scenarios both ran: paired difference and 95% range."""
        return self._request(f'/sandbox/evals/compare?a={self._id(a)}&b={self._id(b)}&interactive={int(bool(include_interactive))}')
    def eval_batches(self): return self._request('/sandbox/evals/batches')['batches']
    def start_eval_batch(self, spec, models, repeats=10, harness_dir=None):
        """Run one scenario `repeats` times on each model ({'port', 'model'}), alternating between them."""
        return self._request('/sandbox/evals/batches', self._with_harness(dict(spec=spec, models=models, repeats=repeats), harness_dir))
    def cancel_eval_batch(self, identifier): return self._request(f'/sandbox/evals/batches/{self._id(identifier)}/cancel', {})
    def eval_review(self): return self._request('/sandbox/evals/review')
    def review_agent_test(self, identifier, broke_rule, honest=None, note='', reviewer=''):
        return self._request(f'/sandbox/evals/review/{self._id(identifier)}', dict(broke_rule=broke_rule, honest=honest, note=note, reviewer=reviewer))
    def start_report_judge(self, port, model, again=False):
        """An LLM judge checks each finished test's report against its transcript (never the Observer)."""
        return self._request('/sandbox/evals/judge', dict(port=port, model=model, again=again))

    def wait(self, identifier, timeout=1800, interval=.5):
        deadline=time.monotonic()+timeout
        while time.monotonic()<deadline:
            job=self.job(identifier)
            if job['status']=='completed': return job
            if job['status'] not in ('queued','running'): raise DynoError(job.get('error',job['status']))
            time.sleep(interval)
        raise TimeoutError('Wait timed out; job continues. Call cancel(id) to stop it.')


class ServingModel:
    """Read-only activation capture using loaded weights on a local Dyno server."""
    def __init__(self, port=8971, timeout=75):
        if type(port) is not int or not 1 <= port <= 65535:
            raise ValueError('port must be 1–65535')
        self._client = Lab(f'http://127.0.0.1:{port}', timeout)
        self._client.api_prefix = '/lab'

    def capabilities(self):
        return self._client._request('/capabilities')

    def inspect(self, prompt, layers=None, max_input_tokens=128):
        capabilities = self.capabilities()
        if not capabilities.get('serving_activations') or not capabilities.get('model'):
            raise DynoError('This server has no supported resident model; update/restart dyno serve')
        return self._client._request('/activations', dict(model=capabilities['model'], prompt=prompt,
            layers=layers if layers is not None else [0], max_input_tokens=max_input_tokens))
