"""Paired descriptive comparisons with group-level uncertainty and frozen evidence."""
import copy
import random
import time
import uuid
from .studies import Studies, digest, text

METRICS = ('target_behavior', 'correctness', 'refusal', 'honesty', 'monitor_detectability')


def reference_labels(study):
    latest = {}
    for label in study.get('labels', []):
        latest[(label['run_id'], label['reviewer'])] = label['value']
    values = {}
    for (run, _), value in latest.items(): values.setdefault(run, set()).add(value)
    return {run: (1 if labels == {'pass'} else 0 if labels == {'fail'} else None) for run, labels in values.items()}


def paired_report(before, after, baseline, comparison):
    """Pair two conditions, possibly from separate studies, by case and seed."""
    a_labels, b_labels = reference_labels(before), reference_labels(after)
    rows = []
    for split in ('development', 'test'):
        def records(study, condition):
            return {(r['case'], r['seed']): r for r in study['runs']
                    if r['condition'] == condition and r['split'] == split and r['status'] == 'completed'}
        a, b = records(before, baseline), records(after, comparison)
        planned = {(c['id'], seed) for c in before['protocol']['cases'] if c['split'] == split for seed in before['protocol']['seeds']}
        groups = {c['id']: c['group'] for c in before['protocol']['cases']}
        pairs, excluded = [], []
        grouped = {}
        for case, seed in sorted(planned):
            left, right = a.get((case, seed)), b.get((case, seed))
            av = a_labels.get(left['id']) if left else None
            bv = b_labels.get(right['id']) if right else None
            if av is None or bv is None:
                excluded.append(dict(case=case, seed=seed, reason='missing_completed_run' if not left or not right else 'missing_uncertain_or_disputed_reference'))
                continue
            delta = bv-av
            row = dict(case=case, seed=seed, group=groups[case], baseline_run=left['id'], comparison_run=right['id'], baseline=av, comparison=bv, delta=delta)
            pairs.append(row); grouped.setdefault(groups[case], []).append(row)
        group_rows = [dict(group=g, pairs=len(v), baseline=sum(r['baseline'] for r in v)/len(v), comparison=sum(r['comparison'] for r in v)/len(v), delta=sum(r['delta'] for r in v)/len(v)) for g,v in sorted(grouped.items())]
        deltas = [g['delta'] for g in group_rows]
        interval = None
        if len(deltas) >= 2:
            rng = random.Random(0)
            samples = sorted(sum(rng.choice(deltas) for _ in deltas)/len(deltas) for _ in range(2000))
            interval = [samples[49], samples[1949]]
        rows.append(dict(split=split, planned_pairs=len(planned), scored_pairs=len(pairs), independent_groups=len(group_rows),
            improved=sum(p['delta']>0 for p in pairs), regressed=sum(p['delta']<0 for p in pairs), unchanged=sum(p['delta']==0 for p in pairs),
            baseline_rate=sum(g['baseline'] for g in group_rows)/len(group_rows) if group_rows else None,
            comparison_rate=sum(g['comparison'] for g in group_rows)/len(group_rows) if group_rows else None,
            paired_delta=sum(deltas)/len(deltas) if deltas else None, group_bootstrap_95=interval, groups=group_rows, pairs=pairs, excluded=excluded))
    return dict(rows=rows, interpretation='Pass means the saved rubric is satisfied, including appropriate refusal, not more refusal. Rates weight case groups equally. The percentile interval resamples author-defined groups (2000 draws, seed 0); few or dependent groups can make it unreliable. One group has no interval. References and group independence are not authenticated. No safety or causal claim follows automatically.')


class ResearchReports(Studies):
    def __init__(self, root, studies):
        super().__init__(root)
        self.studies = studies

    def regression(self, config):
        if not isinstance(config, dict) or set(config) != {'title', 'baseline', 'comparison', 'sources'}: raise ValueError('Use title, baseline, comparison and sources')
        title = text(config['title'], 'title', 200)
        baseline, comparison = config['baseline'], config['comparison']
        if baseline == comparison: raise ValueError('Choose distinct conditions')
        sources = config['sources']
        if not isinstance(sources, list) or not 1 <= len(sources) <= 5: raise ValueError('Choose 1–5 metric studies')
        frozen, results, seen = [], [], set()
        for source in sources:
            if not isinstance(source,dict) or set(source) != {'metric','study_id'} or source['metric'] not in METRICS or source['metric'] in seen: raise ValueError('Use each supported metric once')
            seen.add(source['metric']); study = self.studies.read(source['study_id'])
            if study['status'] in ('running','cancelling') or study.get('imported'): raise ValueError('Use inactive local studies')
            conditions = {c['id'] for c in study['protocol']['conditions']}
            if baseline not in conditions or comparison not in conditions: raise ValueError('Both conditions must exist in every selected study')
            frozen.append(dict(metric=source['metric'], sha256=digest(study), study=study))
            results.append(dict(metric=source['metric'], rubric=study['protocol']['rubric'], source_id=study['id'], **paired_report(study,study,baseline,comparison)))
        record = dict(id=uuid.uuid4().hex, created=time.time(), status='completed', kind='regression', protocol=dict(title=title), runs=[], config=copy.deepcopy(config), sources=frozen, results=results)
        with self.lock: self._write(record)
        return record

    def compatibility(self, config, jobs):
        from .compatibility import compare_contracts
        if not isinstance(config,dict) or set(config)!={'source_job_id','target_job_id'}:raise ValueError('Select source_job_id and target_job_id')
        source,target=(jobs.read(config[key]) for key in ('source_job_id','target_job_id'))
        if source['status']!='completed' or target['status']!='completed':raise ValueError('Both jobs must be completed')
        def contract(job):return job.get('result',{}).get('compatibility',{}).get('fingerprint',{})
        result=compare_contracts(contract(source),contract(target))
        record=dict(id=uuid.uuid4().hex,created=time.time(),status='completed',kind='compatibility',protocol=dict(title='Artifact compatibility check'),runs=[],config=config,results=[],compatibility=result,
            source_hash=digest(source),target_hash=digest(target))
        with self.lock:self._write(record)
        return record

    def checkpoints(self, config):
        if not isinstance(config,dict) or set(config)!={'title','sources'}:raise ValueError('Use title and checkpoint sources')
        text(config['title'],'title',200)
        sources=config['sources']
        if not isinstance(sources,list) or not 2<=len(sources)<=4:raise ValueError('Choose 2–4 checkpoint studies')
        frozen=[];seen=set()
        for entry in sources:
            if not isinstance(entry,dict) or set(entry)!={'label','study_id','revision','training_data','adapter'}:raise ValueError('Each checkpoint needs label, study_id, revision, training_data and adapter (use unknown when unavailable)')
            for key in ('label','revision','training_data','adapter'):text(entry[key],key,2000)
            if entry['study_id'] in seen:raise ValueError('Choose distinct study runs')
            seen.add(entry['study_id']);study=self.studies.read(entry['study_id'])
            if study['status'] in ('running','cancelling') or study.get('imported'):raise ValueError('Use inactive local studies')
            frozen.append(dict(metadata=copy.deepcopy(entry),study=study,sha256=digest(study)))
        def comparable(study):return {k:v for k,v in study['protocol'].items() if k not in ('title','parent_hash','source')}
        baseline=frozen[0];results=[]
        for candidate in frozen[1:]:
            if comparable(baseline['study'])!=comparable(candidate['study']):raise ValueError('Checkpoint studies must use the same frozen protocol, cases, rubric and generation settings')
            for condition in baseline['study']['protocol']['conditions']:
                results.append(dict(metric=candidate['metadata']['label']+' / '+condition['id'],rubric=baseline['study']['protocol']['rubric'],**paired_report(baseline['study'],candidate['study'],condition['id'],condition['id'])))
        record=dict(id=uuid.uuid4().hex,created=time.time(),status='completed',kind='checkpoints',protocol=dict(title=config['title']),runs=[],config=copy.deepcopy(config),sources=frozen,results=results,
            provenance_note='Checkpoint, adapter and training-data lineage are supplied by the researcher, not authenticated. Endpoint names do not prove revision identity. Compare held-out groups and declare any overlap or prior test use. No training or automatic model loading occurs.')
        with self.lock:self._write(record)
        return record
