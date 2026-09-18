"""Grouped train/validation/test probes with validation-only model selection."""
import hashlib
import json
import math
import unicodedata


def validate_dataset(examples):
    if not isinstance(examples,list) or not 12 <= len(examples) <= 512:
        raise ValueError('Validated probes need 12–512 examples, at least 4 per split')
    groups, texts, counts, labels = {}, {}, {}, {}
    for e in examples:
        if not isinstance(e,dict) or e.get('split') not in ('train','validation','test'):
            raise ValueError('Validated probes require train, validation and test splits')
        split=e['split'];group=e.get('group');value=e.get('text')
        if not isinstance(group,str) or not group.strip() or len(group)>128: raise ValueError('Every example needs a nonempty group ID')
        if not isinstance(value,str) or not value.strip() or len(value)>16000: raise ValueError('Invalid example text')
        if type(e.get('label')) is not int or e['label'] not in (0,1): raise ValueError('Probe labels must be binary integers')
        if 'domain' in e and (not isinstance(e['domain'],str) or not e['domain'].strip()): raise ValueError('Invalid domain')
        canonical=' '.join(unicodedata.normalize('NFKC',value).casefold().split())
        if group in groups and groups[group]!=split: raise ValueError('A group cannot cross dataset partitions')
        if canonical in texts and texts[canonical]!=split: raise ValueError('Duplicate normalized text crosses dataset partitions')
        groups[group]=split;texts[canonical]=split;counts[split]=counts.get(split,0)+1;labels.setdefault(split,set()).add(e['label'])
    if any(counts.get(s,0)<4 or labels.get(s)!={0,1} for s in ('train','validation','test')):
        raise ValueError('Each split needs at least four examples with both labels')
    return dict(sha256=hashlib.sha256(json.dumps(examples,sort_keys=True,ensure_ascii=False).encode()).hexdigest(), counts=counts, group_counts={s:sum(v==s for v in groups.values()) for s in counts})


def run_validated_probe(examples, vectors, seed=0):
    import numpy as np
    manifest=validate_dataset(examples);rng=np.random.default_rng(seed)
    y=np.array([e['label'] for e in examples]);masks={s:np.array([e['split']==s for e in examples]) for s in ('train','validation','test')}
    train,val,test=(masks[s] for s in ('train','validation','test'))
    def sigmoid(x):return 1/(1+np.exp(-np.clip(x,-30,30)))
    def metrics(truth,scores):
        pos=scores[truth==1];neg=scores[truth==0]
        return dict(n=len(truth),positive=int(sum(truth)),negative=int(sum(1-truth)),accuracy=float(np.mean((scores>=.5)==truth)),brier=float(np.mean((scores-truth)**2)),auc=float(np.mean((pos[:,None]>neg)+.5*(pos[:,None]==neg))) if len(pos) and len(neg) else None)
    def fit(x,labels,l2):
        w=np.zeros(x.shape[1]);b=0.;rate=.2/max(1.,float(np.linalg.norm(x,ord=2)**2/len(x)))
        for _ in range(400):
            err=sigmoid(x@w+b)-labels;w-=rate*(x.T@err/len(x)+l2*w);b-=rate*err.mean()
        return w,b
    candidates=[];trained={}
    for layer,raw in sorted(vectors.items()):
        x=np.asarray(raw,dtype=np.float64)
        if x.ndim!=2 or len(x)!=len(examples) or not np.isfinite(x).all():raise ValueError('Invalid activation matrix')
        mean=x[train].mean(0);std=x[train].std(0).clip(.01);z=(x-mean)/std
        for l2 in (.001,.01,.1):
            w,b=fit(z[train],y[train],l2);mv=metrics(y[val],sigmoid(z[val]@w+b))
            candidates.append(dict(layer=layer,l2=l2,validation=mv));trained[(layer,l2)]=(w,b,mean,std,z)
    if not candidates:raise ValueError('No candidate layers')
    # No test score or label enters this deterministic selection rule.
    best=min(candidates,key=lambda c:(c['validation']['brier'],c['layer'],c['l2']))
    layer,l2=best['layer'],best['l2'];w,b,mean,std,z=trained[(layer,l2)]
    scores=sigmoid(z@w+b);control_w,control_b=fit(z[train],rng.permutation(y[train]),l2)
    control=sigmoid(z[test]@control_w+control_b)
    majority=np.full(sum(test),float(y[train].mean()>=.5))
    # A text-length control tests an obvious surface correlate without activations.
    lengths=np.array([len(e['text']) for e in examples],dtype=float)[:,None]
    length_z=(lengths-lengths[train].mean(0))/lengths[train].std(0).clip(1)
    lw,lb=fit(length_z[train],y[train],l2)
    domains={}
    for domain in sorted({e.get('domain','unspecified') for e in examples if e['split']=='test'}):
        mask=test & np.array([e.get('domain','unspecified')==domain for e in examples]);domains[domain]=metrics(y[mask],scores[mask])
        domains[domain]['seen_in_training']=any(e.get('domain','unspecified')==domain and e['split']=='train' for e in examples)
    report=dict(layer=layer,l2=l2,selection='Minimum validation Brier score; tie-break by layer then regularization. Test labels never select candidates.',dataset=manifest,
        validation_candidates=candidates,test=metrics(y[test],scores[test]),shuffled_label_control=metrics(y[test],control),majority_control=metrics(y[test],majority),text_length_control=metrics(y[test],sigmoid(length_z[test]@lw+lb)),test_domains=domains,
        scores=[dict(text=e['text'],group=e['group'],split=e['split'],label=e['label'],score=float(s)) for e,s in zip(examples,scores)],
        note='Associational linear probe. A predictive score does not demonstrate causal use, a semantic feature or safety. Controls are single fits, not significance tests. Validation and test reuse across separate jobs is not prevented.')
    return report,dict(weight=w,bias=b,mean=mean,std=std)
