"""Restricted inference-only port of linear PEFT LoRA/RSLoRA to MLX."""
import math


def attach(model, weights, config):
    import mlx.core as mx
    import mlx.nn as nn
    if (config.get('peft_type')!='LORA' or config.get('bias')!='none' or config.get('use_dora')
        or config.get('fan_in_fan_out') or config.get('rank_pattern') or config.get('alpha_pattern')
        or config.get('modules_to_save') or config.get('lora_bias')):
        raise ValueError('Unsupported adapter configuration; do not approximate it')
    rank=config['r'];alpha=config['lora_alpha']
    if not isinstance(rank,int) or rank<=0 or not math.isfinite(alpha):raise ValueError('Invalid adapter scale')
    scale=alpha/(math.sqrt(rank) if config.get('use_rslora') else rank)
    pairs={}
    for key,array in weights.items():
        prefix='base_model.model.'
        if not key.startswith(prefix) or not key.endswith(('.lora_A.weight','.lora_B.weight')):
            raise ValueError('Unexpected adapter tensor '+key)
        path,side=key[len(prefix):].rsplit('.lora_',1)
        pairs.setdefault(path,{})[side[0]]=array
    replacements=[]
    class LoRA(nn.Module):
        def __init__(self,original,a,b):
            super().__init__();self.original=original;self.a=a;self.b=b
        def __call__(self,x):
            base=self.original(x)
            delta=(x.astype(self.a.dtype)@self.a.T)@self.b.T*scale
            return (base.astype(delta.dtype)+delta).astype(base.dtype)
    # Validate every target before changing any modules.
    for path,pair in sorted(pairs.items()):
        parts=path.split('.');parent=model
        for name in parts[:-1]:parent=parent[int(name)] if name.isdigit() else getattr(parent,name)
        name=parts[-1];original=getattr(parent,name)
        if set(pair)!=set('AB') or not isinstance(original,nn.Linear):raise ValueError('Unpaired or non-linear LoRA target')
        a,b=pair['A'],pair['B'];out_dim,in_dim=original.weight.shape
        if a.shape!=(rank,in_dim) or b.shape!=(out_dim,rank):raise ValueError('Adapter dimensions differ')
        if not bool(mx.all(mx.isfinite(a))) or not bool(mx.all(mx.isfinite(b))):raise ValueError('Nonfinite adapter')
        replacements.append((parent,name,original,LoRA(original,a,b)))
    for parent,name,original,wrapped in replacements:setattr(parent,name,wrapped)
    return [(parent,name,original) for parent,name,original,_ in replacements],scale
