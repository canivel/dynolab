"""Bounded read-only capture, executed only on the serving generation thread."""
from queue import Queue, Empty
import threading
import time


def validate(config):
    if not isinstance(config, dict):
        raise ValueError('Expected a JSON object')
    if set(config) - {'model', 'prompt', 'layers', 'max_input_tokens'}:
        raise ValueError('Serving capture accepts only model, prompt, layers and max_input_tokens; interventions are isolated experiments')
    if not isinstance(config.get('model'), str) or not config['model']:
        raise ValueError('Specify the exact resident model returned by capabilities')
    if not isinstance(config.get('prompt'), str) or not config['prompt'].strip() or len(config['prompt']) > 32768:
        raise ValueError('Provide a nonempty prompt of at most 32768 characters')
    layers = config.get('layers', [0])
    if not isinstance(layers, list) or not 1 <= len(layers) <= 4 or any(type(i) is not int or i < 0 for i in layers) or len(set(layers)) != len(layers):
        raise ValueError('Choose 1–4 distinct nonnegative layer indices')
    limit = config.get('max_input_tokens', 128)
    if type(limit) is not int or not 1 <= limit <= 256:
        raise ValueError('Serving capture supports 1–256 input tokens')
    return dict(config, layers=layers, max_input_tokens=limit)


def capture(provider, config):
    import mlx.core as mx
    from ..lab.worker import tap_layer
    config = validate(config)
    key = provider.model_key
    if not key or str(key[0]) != config['model'] or provider.model is None:
        raise ValueError('Resident model changed or is not loaded. Refresh the serving model selection; no model was loaded or replaced.')
    model, tokenizer = provider.model, provider.tokenizer
    layers = model.layers
    if any(i >= len(layers) for i in config['layers']):
        raise ValueError(f'Model has {len(layers)} layers')
    ids = tokenizer.encode(config['prompt'])
    if not 1 <= len(ids) <= config['max_input_tokens']:
        raise ValueError(f'Prompt has {len(ids)} tokens; limit is {config["max_input_tokens"]}. No truncation was applied.')
    # No serving KV cache, RNG seed change, optimizer, or weight mutation.
    originals = {i: layers[i] for i in config['layers']}
    states = {}
    started = time.monotonic()
    try:
        for i, original in originals.items():
            layers[i] = tap_layer(original, i, states, {}, [True])
        logits = model(mx.array([ids]))
        mx.eval(logits, *states.values())
        maps = [dict(layer=i, norms=mx.linalg.norm(states[i][0].astype(mx.float32), axis=-1).tolist()) for i in config['layers']]
        probabilities = mx.softmax(logits[0, -1].astype(mx.float32))
        top_ids = mx.argsort(probabilities)[-5:][::-1].tolist()
        return dict(tokens=[tokenizer.decode([i]) for i in ids], token_ids=ids, layers=maps,
            next_tokens=[dict(token_id=i, token=tokenizer.decode([i]), probability=float(probabilities[i].item())) for i in top_ids],
            note='Read-only activation norms from the resident model. Raw text, fresh forward pass; not a trace of another request. No intermediate logit lens or raw tensor artifact in this mode.',
            provenance=dict(model=str(key[0]), mode='serving_model', hook='block output', input_mode='raw text', layers=config['layers'], seconds=time.monotonic()-started))
    finally:
        for i, original in originals.items():
            layers[i] = original
        states.clear()


class CaptureBroker:
    def __init__(self):
        self.queue = Queue(maxsize=1)
        self.slot = threading.Lock()

    def submit(self, config, timeout=60):
        config = validate(config)
        if not self.slot.acquire(blocking=False):
            raise RuntimeError('A serving activation capture is already pending or running')
        task = dict(config=config, done=threading.Event(), cancelled=threading.Event())
        self.queue.put_nowait(task)
        # Slot is released by the generation thread, even after an HTTP timeout.
        if not task['done'].wait(timeout):
            task['cancelled'].set()
            raise TimeoutError('Capture timed out waiting for the generation scheduler. If already started it will finish its bounded forward pass; pending capture is cancelled.')
        if 'error' in task:
            raise task['error']
        return task['result']

    def service(self, provider):
        try:
            task = self.queue.get_nowait()
        except Empty:
            return
        try:
            if not task['cancelled'].is_set():
                task['result'] = capture(provider, task['config'])
        except Exception as error:
            task['error'] = error
        finally:
            task['done'].set()
            self.slot.release()
