import copy
import tempfile
import unittest
from dyno.lab.regressions import paired_report, ResearchReports
from dyno.lab.studies import Studies
from test_controlled_studies import protocol


def evidence():
    p=protocol();p['cases']=[dict(id=str(i),group=str(i//2),split='test',prompt='Case '+str(i)) for i in range(4)]
    s=dict(protocol=p,runs=[],labels=[])
    for i in range(4):
        for condition in ('neutral','pressure'):
            rid=f'{i}-{condition}';s['runs'].append(dict(id=rid,case=str(i),condition=condition,seed=0,split='test',status='completed'))
            value=('fail' if i<2 else 'pass') if condition=='neutral' else 'pass'
            s['labels'].append(dict(run_id=rid,reviewer='fixture',value=value))
    return s


class RegressionTests(unittest.TestCase):
    def test_counts_groups_and_uncertainty(self):
        s=evidence();r=paired_report(s,s,'neutral','pressure')['rows'][1]
        self.assertEqual((r['scored_pairs'],r['independent_groups'],r['improved'],r['regressed']), (4,2,2,0))
        self.assertEqual(r['paired_delta'],.5);self.assertEqual(r['group_bootstrap_95'],[0.,1.])
        self.assertEqual(paired_report(s,s,'pressure','neutral')['rows'][1]['regressed'],2)
    def test_missing_disputed_not_pass_and_single_group_no_interval(self):
        s=evidence();s['labels'].append(dict(run_id='0-pressure',reviewer='second',value='fail'))
        s['runs']=[r for r in s['runs'] if r['case'] in ('0','1')]
        r=paired_report(s,s,'neutral','pressure')['rows'][1]
        self.assertEqual(r['scored_pairs'],1);self.assertEqual(len(r['excluded']),3);self.assertIsNone(r['group_bootstrap_95'])
    def test_frozen_history_and_config_validation(self):
        with tempfile.TemporaryDirectory() as root:
            studies=Studies(root+'/studies');s=studies.create(evidence()['protocol']);s.update(runs=evidence()['runs'],labels=evidence()['labels'],status='finished');studies._write(s)
            reports=ResearchReports(root+'/reports',studies)
            config=dict(title='fixture',baseline='neutral',comparison='pressure',sources=[dict(metric='honesty',study_id=s['id'])])
            r=reports.regression(config);s['labels']=[];studies._write(s)
            self.assertEqual(reports.read(r['id'])['results'][0]['rows'][1]['scored_pairs'],4)
            bad=copy.deepcopy(config);bad['sources']*=2
            with self.assertRaises(ValueError):reports.regression(bad)

    def test_checkpoint_protocol_and_lineage(self):
        with tempfile.TemporaryDirectory() as root:
            store=Studies(root+'/studies');reports=ResearchReports(root+'/reports',store)
            ids=[]
            for _ in range(2):
                s=store.create(evidence()['protocol']);s.update(runs=evidence()['runs'],labels=evidence()['labels'],status='finished');store._write(s);ids.append(s['id'])
            config=dict(title='checkpoint fixture',sources=[dict(label=str(i),study_id=id,revision='unknown',training_data='unknown',adapter='none') for i,id in enumerate(ids)])
            report=reports.checkpoints(config);self.assertEqual(len(report['results']),2)
            self.assertEqual(report['results'][0]['rows'][1]['paired_delta'],0)
            s['protocol']['temperature']=1.2;store._write(s)
            with self.assertRaisesRegex(ValueError,'same frozen protocol'):reports.checkpoints(config)
