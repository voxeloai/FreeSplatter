"""Cycle-2 smoke test — instantiate each FreeSplatterModel config.

Run from the FreeSplatter repo root (after `source /workspace/activate.sh`):
    python .architect/scripts/smoke_configs.py
"""
import torch
from omegaconf import OmegaConf
from freesplatter.models.model import FreeSplatterModel

CFGS = ['freesplatter-object', 'freesplatter-object-2dgs', 'freesplatter-scene']

for cfg_name in CFGS:
    cfg = OmegaConf.load(f'configs/{cfg_name}.yaml')
    model = FreeSplatterModel(**cfg.model.params).cuda().eval()
    n = sum(p.numel() for p in model.parameters()) / 1e6
    print(f'OK: {cfg_name} instantiated, params={n:.1f}M')
    del model
    torch.cuda.empty_cache()
