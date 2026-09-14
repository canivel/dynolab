"""Exercise the new SDK/HTTP/worker path against the real pinned model."""
import json
import tempfile
import threading
from pathlib import Path
from http.server import ThreadingHTTPServer
from dyno.lab.server import Handler, Jobs
from dyno.sdk import Lab
from run import ROOT, MODEL, REVISION, LAYER


def main():
    import numpy as np
    row = json.loads((ROOT/'run/answers.json').read_text())[0]
    with tempfile.TemporaryDirectory(prefix='dynolab-response-api-') as directory:
        jobs = Jobs(directory)
        server = ThreadingHTTPServer(('127.0.0.1',0), Handler)
        server.jobs = jobs
        thread = threading.Thread(target=server.serve_forever,daemon=True)
        thread.start()
        try:
            lab = Lab(f'http://127.0.0.1:{server.server_port}')
            job = lab.capture_response(MODEL,row['prompt'],row['answer'],revision=REVISION,
                                       layers=[LAYER],max_input_tokens=512,seed=20260914)
            print('Submitted SDK response capture',job['id'],flush=True)
            result = lab.wait(job['id'])
            target = ROOT/'run/api-response-representations.npz'
            lab.artifact(job['id'],'response-representations.npz',target)
            with np.load(target) as observed, np.load(ROOT/'run'/row['artifact']) as reference:
                errors = {}
                for key in ('prompt_last','prompt_mean','response_mean'):
                    value=observed[f'layer_{LAYER}_{key}']
                    np.testing.assert_allclose(value,reference[key],rtol=1e-5,atol=1e-5)
                    errors[key]=float(np.max(np.abs(value-reference[key])))
            (ROOT/'run/api-verification.json').write_text(json.dumps(dict(job=result,
                max_absolute_errors=errors,passed=True),indent=2))
            print('SDK / HTTP / worker capture agrees with independent pilot capture:',errors,flush=True)
        finally:
            if jobs.active:
                jobs.cancel(jobs.active)
            server.shutdown();server.server_close();thread.join()
            jobs._directory_lock.close()


if __name__ == '__main__':
    main()
