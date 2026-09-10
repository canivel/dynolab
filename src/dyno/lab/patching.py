"""Bounded single-site causal patching on an isolated MLX model."""
def sweep(config, selected, encode, forward, captured, active, tokenizer):
    import mlx.core as mx
    clean = encode(config['clean_prompt'])
    corrupt = encode(config['prompt'])
    if len(clean) != len(corrupt):
        raise ValueError('Clean and corrupted prompts must have equal token counts; align tokens explicitly')
    positions = config.get('positions', list(range(len(clean))))
    if not isinstance(positions, list) or not positions or len(set(positions)) != len(positions) or any(type(p) is not int or not 0 <= p < len(clean) for p in positions):
        raise ValueError('positions must contain unique valid token indices')
    if len(positions) * len(selected) > 128:
        raise ValueError('At most 128 layer/token patch sites per experiment')
    target = tokenizer.encode(config['target_token'], add_special_tokens=False)
    foil = tokenizer.encode(config['foil_token'], add_special_tokens=False)
    if len(target) != 1 or len(foil) != 1 or target == foil:
        raise ValueError('Target and foil must be distinct single tokens, including a leading space if needed')
    def metric(logits):
        return float((logits[0,-1,target[0]] - logits[0,-1,foil[0]]).item())
    clean_score = metric(forward(clean))
    donor = {i: captured[i] for i in selected}
    corrupt_score = metric(forward(corrupt))
    gap = clean_score - corrupt_score
    rows = []
    try:
        for layer in selected:
            for position in positions:
                def patch(h, layer=layer, position=position):
                    return mx.concatenate([h[:,:position,:], donor[layer][:,position:position+1,:], h[:,position+1:,:]], axis=1)
                active[layer] = patch
                score = metric(forward(corrupt))
                rows.append(dict(layer=layer, position=position, patched_logit_difference=score,
                    delta=score-corrupt_score, recovery=(score-corrupt_score)/gap if abs(gap)>1e-6 else None))
                active.clear()
    finally:
        active.clear()
    control = metric(forward(corrupt))
    return dict(patches=rows, tokens=[tokenizer.decode([i]) for i in corrupt],
        clean_tokens=[tokenizer.decode([i]) for i in clean], clean_logit_difference=clean_score,
        corrupted_logit_difference=corrupt_score, restored_control_logit_difference=control,
        target_token=config['target_token'], foil_token=config['foil_token'],
        note='Single block-output site patched from clean into corrupted input. Recovery is unbounded; undefined for a near-zero clean/corrupted gap. This is causal patching, not a full circuit graph.')
