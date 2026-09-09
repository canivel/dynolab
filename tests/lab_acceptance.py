"""Opt-in real-model acceptance suite. Run against an idle development lab.

PYTHONPATH=src python tests/lab_acceptance.py --url http://127.0.0.1:8986
"""
import argparse
from dyno.sdk import Lab


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--url',default='http://127.0.0.1:8986')
    parser.add_argument('--model',default='mlx-community/Qwen1.5-0.5B-Chat-4bit')
    args=parser.parse_args()
    lab=Lab(args.url)
    texts=['This is terrible','This is great','I hate it','I love it','An awful day','A lovely day','That was disappointing','That was wonderful','Bad service here','Excellent meal today','A dreadful experience','A joyful experience']
    examples=[dict(text=text,label=i%2,split='train' if i<8 else 'test') for i,text in enumerate(texts)]
    configurations=[
        ('inspect',dict(prompt='The capital of France is',layers=[4,8])),
        ('compare',dict(prompt='The capital of France is',layers=[8],strengths=[0,1,1.5],max_tokens=12)),
        ('probe',dict(examples=examples,layers=[8])),
        ('sae',dict(examples=examples,layers=[8],features=16,steps=20)),
    ]
    for operation, config in configurations:
        job=lab.submit(operation,args.model,**config)
        result=lab.wait(job['id'],timeout=180)['result']
        if operation=='compare':
            neutral=result['trials'][1]
            assert abs(neutral['delta'])<1e-6
            assert neutral['baseline']==neutral['output']
        elif operation=='inspect':
            assert all(len(layer['norms'])==len(result['tokens']) for layer in result['layers'])
        elif operation=='probe':
            assert 0<=result['reports'][0]['auc']<=1
            assert len(result['reports'][0]['scores'])==len(examples)
        else:
            assert result['reports'][0]['held_out_mse']>=0
            assert result['artifacts']
        print(operation,'passed',job['id'])

if __name__=='__main__': main()
