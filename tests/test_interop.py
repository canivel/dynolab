import json
from pathlib import Path
import tempfile
import unittest
from dyno import interop

class InteropTests(unittest.TestCase):
    def test_attention_shape_and_nonfinite(self):
        with tempfile.TemporaryDirectory() as root:
            path=Path(root)/'a.json'
            interop.attention(['a','b'],[[1,0],[.25,.75]],path,model='test')
            self.assertEqual(json.loads(path.read_text())['values'][1],[.25,.75])
            for value in ([[1]],[[float('nan'),0],[0,1]],[[2,0],[0,1]]):
                with self.assertRaises(ValueError): interop.attention(['a','b'],value,path,model='test')
    def test_feature_ids_and_neuronpedia(self):
        with tempfile.TemporaryDirectory() as root:
            path=Path(root)/'f.json'
            interop.sae_features(['one','two'],[[0,3],[2,1]],path,model='test',source='SAELens',feature_ids=[10,20])
            self.assertEqual(json.loads(path.read_text())['features'][1]['activations'],[3,1])
            interop.neuronpedia(dict(modelId='test',layer='0',index=7,activations=[dict(tokens=['x'],values=[2])],explanations=[dict(description='source label')]),path)
            self.assertEqual(json.loads(path.read_text())['features'][0]['label'],'source label')
    def test_graph_orientation(self):
        try: import numpy as np
        except ImportError: self.skipTest('numpy required')
        class Graph: adjacency_matrix=np.array([[0,2],[3,0]])
        with tempfile.TemporaryDirectory() as root:
            path=Path(root)/'g.json'
            interop.circuit_graph(Graph(),path,model='test',node_indices=[0,1])
            edges=json.loads(path.read_text())['edges']
            self.assertIn(dict(source='1',target='0',weight=2),edges)
            with self.assertRaises(ValueError): interop.circuit_graph(Graph(),path,model='test',node_indices=[-1])
