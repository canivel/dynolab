"""Data-only exports for Lab → Research artifacts. Optional upstream dependencies stay external."""
import json
import math
from pathlib import Path


def _list(value):
    if hasattr(value, 'detach'): value = value.detach().cpu()
    return value.tolist() if hasattr(value, 'tolist') else value


def _write(value, destination):
    text = json.dumps(value, ensure_ascii=False, allow_nan=False)
    if len(text.encode()) > 8_000_000: raise ValueError('Artifact exceeds 8 MB')
    Path(destination).write_text(text)
    return Path(destination)


def attention(tokens, values, destination, *, model, source='TransformerLens / CircuitsVis'):
    """Export one [query,key] head. Pass cache[hook][batch, head] explicitly."""
    values = _list(values)
    if not 1 <= len(tokens) <= 128 or len(values) != len(tokens) or any(len(row) != len(tokens) or any(not math.isfinite(v) or not 0 <= v <= 1 for v in row) for row in values):
        raise ValueError('Expected one square attention head, at most 128 tokens, values in [0,1]')
    return _write(dict(kind='attention', model=model, source=source, tokens=tokens, values=values,
        note='One attention head. Attention weights are not causal importance; source hook/layer should be included in source.'), destination)


def sae_features(tokens, values, destination, *, model, source, feature_ids=None):
    """Export [tokens,features] output of sae.encode, including SAELens outputs."""
    values = _list(values)
    if not tokens or len(tokens)>512 or len(values)!=len(tokens) or not values or not values[0]: raise ValueError('Invalid token/feature shape')
    width=len(values[0])
    if width>256 or any(len(row)!=width for row in values): raise ValueError('Select at most 256 features before exporting')
    ids=feature_ids if feature_ids is not None else list(range(width))
    if len(ids)!=width or len(set(ids))!=width: raise ValueError('Provide one unique ID per selected feature')
    return _write(dict(kind='features',model=model,source=source,note='Source SAE activations; no semantic labels inferred by Dyno.',
        features=[dict(id=str(ids[i]),label='Unlabeled',tokens=tokens,activations=[float(row[i]) for row in values]) for i in range(width)]),destination)


def neuronpedia(feature, destination):
    """Convert a public /api/feature/{model}/{source}/{index} response; no network call."""
    label='; '.join(e.get('description','') for e in feature.get('explanations',[])[:3]) or 'Unlabeled'
    rows=feature.get('activations',[])[:32]
    if not rows: raise ValueError('Feature has no activation examples')
    return _write(dict(kind='features',model=feature['modelId'],source='Neuronpedia / '+feature['layer'],
        note='Public source examples and annotations, not measurements on your local model.',
        features=[dict(id=f"{feature['index']} / example {i}",label=label,tokens=row['tokens'],activations=row['values']) for i,row in enumerate(rows)]),destination)


def circuit_graph(graph, destination, *, model, node_indices, labels=None):
    """Export an explicit induced subgraph of circuit-tracer Graph (rows=targets).

    Select nodes upstream. No automatic top-edge pruning hides missing evidence.
    labels may map original integer node indices to descriptive strings.
    """
    if not 1<=len(node_indices)<=128 or len(set(node_indices))!=len(node_indices): raise ValueError('Select 1–128 unique nodes')
    n=graph.adjacency_matrix.shape[0]
    if graph.adjacency_matrix.shape!=(n,n) or any(type(i) is not int or not 0<=i<n for i in node_indices): raise ValueError('Invalid graph dimensions or indices')
    # Slice before moving off the device: avoid copying a full large graph.
    matrix=_list(graph.adjacency_matrix[node_indices][:,node_indices])
    edges=[dict(source=str(node_indices[s]),target=str(node_indices[t]),weight=float(matrix[t][s])) for t in range(len(node_indices)) for s in range(len(node_indices)) if matrix[t][s]!=0]
    if len(edges)>1024: raise ValueError('Select a smaller subgraph (maximum 1024 edges)')
    return _write(dict(kind='graph',model=model,source='circuit-tracer',
        note=f'Explicit induced subgraph: {len(node_indices)} of {n} nodes. Omitted nodes and edges are not displayed. Attribution weights require intervention validation.',
        nodes=[dict(id=str(i),label=(labels or {}).get(i,f'Node {i}')) for i in node_indices],edges=edges),destination)
