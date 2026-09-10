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
    def health(self): return self._request('/health')
    def jobs(self): return self._request('/jobs')['jobs']
    def submit(self, operation, model, **settings):
        return self._request('/jobs',dict(settings,operation=operation,model=model))
    def inspect(self, model, prompt, **settings): return self.submit('inspect',model,prompt=prompt,**settings)
    def compare(self, model, prompt, **settings): return self.submit('compare',model,prompt=prompt,**settings)
    def probe(self, model, examples, **settings): return self.submit('probe',model,examples=examples,**settings)
    def sae(self, model, examples, **settings): return self.submit('sae',model,examples=examples,**settings)
    def patch_sweep(self, model, prompt, clean_prompt, target_token, foil_token, **settings):
        return self.submit('patch_sweep', model, prompt=prompt, clean_prompt=clean_prompt, target_token=target_token, foil_token=foil_token, **settings)
    def job(self, identifier): return self._request('/jobs/'+identifier)
    def cancel(self, identifier): return self._request('/jobs/'+identifier+'/cancel',{})
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
