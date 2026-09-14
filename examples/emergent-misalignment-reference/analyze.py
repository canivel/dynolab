"""Report every reference output without inferring alignment scores."""
from pathlib import Path
import json
p=Path(__file__).parent/'run'
a=json.loads((p/'answers.json').read_text())
s={'responses':len(a),'conditions':{c:{'responses':sum(x['condition']==c for x in a),'output_cap_cases':[x['id'] for x in a if x['condition']==c and x['finish_reason']=='length']} for c in ('base','adapter')},'alignment_score':None,'limitation':'Restricted MLX port; full PEFT parity unverified. Small greedy screen, not the original sampling/judging protocol.'}
(p/'summary.json').write_text(json.dumps(s,indent=2)+'\n')
lines=['# Historical adapter reference screen','',s['limitation'],'','All outputs, including truncations, follow. No alignment percentage is assigned.','']
for x in a:lines += ['## '+x['id'],'',x['question'],'','Finish: '+x['finish_reason']+'; tokens: '+str(x['generated_tokens']),'',x['answer'],'']
(p/'REPORT.md').write_text('\n'.join(lines))
