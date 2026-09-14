"""Explicit token boundaries for teacher-forced response representation capture."""


def response_tokens(tokenizer, prompt, response, limit):
    if not isinstance(prompt, str) or not prompt.strip():
        raise ValueError('Response capture requires a nonempty serialized prompt')
    if not isinstance(response, str) or not response.strip():
        raise ValueError('Response capture requires a nonempty response')
    prefix = tokenizer.encode(prompt)
    tokens = tokenizer.encode(prompt + response)
    if not prefix or len(tokens) <= len(prefix) or tokens[:len(prefix)] != prefix:
        raise ValueError('Tokenization changes at the prompt/response boundary; capture cannot assign response tokens reliably')
    if len(tokens) > limit:
        raise ValueError(f'Prompt plus response has {len(tokens)} tokens; configured limit is {limit}. Inputs are not silently truncated.')
    return tokens, len(prefix)


def summarize_response(states, prompt_tokens):
    import numpy as np
    states = np.asarray(states, dtype=np.float32)
    if states.ndim != 2 or not 0 < prompt_tokens < states.shape[0]:
        raise ValueError('Expected [token, hidden] states with nonempty prompt and response spans')
    if not np.isfinite(states).all():
        raise ValueError('Nonfinite activation states')
    return dict(prompt_last=states[prompt_tokens-1],
                prompt_mean=states[:prompt_tokens].mean(axis=0),
                response_mean=states[prompt_tokens:].mean(axis=0))
