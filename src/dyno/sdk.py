"""Dependency-free Python client for Dyno's research API."""
import json
import time
import urllib.error
import urllib.request


class DynoError(RuntimeError):
    pass


class Lab:
    def __init__(self, base_url='http://127.0.0.1:8980', timeout=10):
        self.base_url, self.timeout = base_url.rstrip('/'), timeout

    def _request(self, path, body=None):
        request=urllib.request.Request(self.base_url+'/lab/v1'+path,
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
