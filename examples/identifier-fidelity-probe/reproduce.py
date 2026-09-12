"""Run the frozen experiment through the same API used by the native Lab."""
import json
from pathlib import Path
from dyno.sdk import Lab
R=Path(__file__).parent/'run'
config=json.loads((R/'experiment.json').read_text())
lab=Lab();submitted=lab.submit(**config)
identifier=submitted['id'];print(identifier,flush=True)
job=lab.wait(identifier)
(R/'result.json').write_text(json.dumps(job,indent=2))
for name in job['result']['artifacts']:lab.artifact(identifier,name,R/name)
