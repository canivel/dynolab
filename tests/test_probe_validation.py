import copy
import unittest
try:
 import numpy as np
except ImportError:np=None
from dyno.lab.probe_validation import validate_dataset, run_validated_probe


def dataset():
 return [dict(text=f'{split} independent example {i}', group=f'{split}-{i}', split=split, label=i%2, domain='held-domain' if split=='test' else 'development-domain') for split in ['train','validation','test'] for i in range(4)]


class DatasetChecks(unittest.TestCase):
 def test_group_and_normalized_text_leakage(self):
  d=dataset();self.assertEqual(validate_dataset(d)['counts'],dict(train=4,validation=4,test=4))
  d[4]['group']=d[0]['group']
  with self.assertRaisesRegex(ValueError,'group'):validate_dataset(d)
  d=dataset();d[4]['text']=' '+d[0]['text'].upper()+'  '
  with self.assertRaisesRegex(ValueError,'normalized'):validate_dataset(d)
 def test_missing_partition_or_label(self):
  d=dataset();d[4]['split']='test'
  with self.assertRaises(ValueError):validate_dataset(d)
  d=dataset();d[0]['label']=True
  with self.assertRaises(ValueError):validate_dataset(d)


@unittest.skipIf(np is None,'numpy required')
class ProbeSelectionTests(unittest.TestCase):
 def test_test_labels_cannot_select_layer_or_fit(self):
  d=dataset();y=np.array([e['label'] for e in d]);x=np.stack([y*2-1,np.arange(12)%3],axis=1)
  vectors={1:x,2:np.zeros((12,2))};a,weights=run_validated_probe(d,vectors,3)
  changed=copy.deepcopy(d)
  for e in changed:
   if e['split']=='test':e['label']=1-e['label']
  b,weights2=run_validated_probe(changed,vectors,3)
  self.assertEqual((a['layer'],a['l2']),(b['layer'],b['l2']))
  np.testing.assert_allclose(weights['weight'],weights2['weight'])
  self.assertEqual(a['test']['accuracy'],1);self.assertEqual(b['test']['accuracy'],0)
  self.assertFalse(a['test_domains']['held-domain']['seen_in_training'])
  self.assertIn('text_length_control',a);self.assertIn('shuffled_label_control',a)
 def test_normalization_uses_train_only_and_bad_matrix_rejected(self):
  d=dataset();x=np.arange(24).reshape(12,2).astype(float);_,w=run_validated_probe(d,{2:x})
  np.testing.assert_allclose(w['mean'],x[:4].mean(0))
  x[7,1]=np.nan
  with self.assertRaisesRegex(ValueError,'matrix'):run_validated_probe(d,{2:x})
