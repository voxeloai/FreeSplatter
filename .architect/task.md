# Cycle 2 — task

**Date:** 2026-05-08
**Set by:** architect
**Cycle:** 2

## Goal

Download FreeSplatter weights (~0.9 GB) + pre-pull peer-model weights (`Tencent/Hunyuan3D-1` ~5 GB, `briaai/RMBG-2.0` ~1.5 GB) so cycle 3's `app.py` doesn't go to HF on first run. Smoke-test by instantiating `FreeSplatterModel` with each of the 3 configs and confirming forward-pass tensors flow without an explicit input image (just shape verification).

## Verification

```bash
# 1. Sentinel check (post-download)
test -f /workspace/.freesplatter-weights-complete && echo "sentinel OK"

# 2. FreeSplatter weights present
ls -lh /workspace/weights/checkpoints/*.safetensors 2>/dev/null
ls -lh /workspace/weights/*.safetensors 2>/dev/null
# expect: 3 safetensors files for FreeSplatter-O, FreeSplatter-O-2dgs, FreeSplatter-S
#         (~300 MB each)

# 3. Hunyuan3D-1 + RMBG-2.0 in HF cache
ls /workspace/hf-cache/hub/ 2>/dev/null | head
# expect: models--Tencent--Hunyuan3D-1, models--briaai--RMBG-2.0

# 4. Smoke test — load each FreeSplatter config and check forward pass shape
source /workspace/activate.sh
python <<'EOF'
import torch
from omegaconf import OmegaConf
from freesplatter.models.model import FreeSplatterModel

for cfg_name in ['freesplatter-object', 'freesplatter-object-2dgs', 'freesplatter-scene']:
    cfg = OmegaConf.load(f'configs/{cfg_name}.yaml')
    model = FreeSplatterModel(**cfg.model.params).cuda().eval()
    # Try to load the matching checkpoint
    print(f'OK: {cfg_name} instantiated, params={sum(p.numel() for p in model.parameters())/1e6:.1f}M')
EOF
# expect: 3 lines "OK: <name> instantiated, params=~306M" each
```

## Scope

**In scope:**
- `/workspace/.freesplatter-weights-complete` sentinel (created by bootstrap)
- `/workspace/weights/` contents
- `/workspace/hf-cache/` contents
- `.architect/log/2026-05-08-cycle-02.md`
- `.architect/handoff.md`
- `scripts/bootstrap.sh` — only if a real bug surfaces in the weights phase that needs fixing

**Out of scope:**
- Modifying the FreeSplatter `freesplatter/` package
- Running `app.py` (that's cycle 3 — interactive gradio over SSH tunnel)
- Editing `configs/*.yaml`
- Anything outside `/workspace/`

## Prior context

Cycle 1 closed clean (handoff in `.architect/handoff.md`, log in `.architect/log/2026-05-08-cycle-01.md`). Pod stopped + started cleanly; bootstrap re-run = 14s no-op; pre/post-restart re-verify all green.

**Key thing to remember from cycle 1:** SSH port may change on stop/start. The pod was just resumed for cycle 2 — pod-shell, refresh SSH details before connecting if you don't already have a fresh poll.

## Steps in order

1. **SSH in, recreate tmux session `arch`** (it was wiped on the cycle-1 close stop).
2. **`source /workspace/activate.sh`**, verify `which python` lands at `/workspace/envs/freesplatter/bin/python`.
3. **`git pull origin voxelo/main`** in `/workspace/FreeSplatter` to pick up the post-cycle-1 commits (spec correction `b0d440b`, deploy.ps1 fixes + RECIPE `b34b763`).
4. **Pull FreeSplatter weights** by re-running bootstrap with the weights flag:
   ```
   FREESPLATTER_DOWNLOAD_WEIGHTS=1 bash scripts/bootstrap.sh
   ```
   Should be near-instant for everything except step 7 (the weights download). Watch for the new sentinel at `/workspace/.freesplatter-weights-complete`.

5. **Pre-pull peer models** into the HF cache (they auto-load at app.py first-run; pre-pulling makes cycle 3 fast):
   ```
   HF_HOME=/workspace/hf-cache hf download Tencent/Hunyuan3D-1 --include "*.safetensors" "*.json" "*.bin" "config.json"
   HF_HOME=/workspace/hf-cache hf download briaai/RMBG-2.0
   ```

6. **Smoke test** — instantiate the 3 FreeSplatterModel configs as in verification check 4 above. Each should report ~306M params and not crash.

7. **Write cycle 2 handoff.** Status: `done` if all 4 checks pass; `blocked` with details if anything fails.

## Open questions

- **Hunyuan3D-1 size.** README doesn't pin a size; could be 5 GB or 15 GB. Watch `df -h /workspace` during download — we have 100 GB total, ~2 GB used after cycle 1, so there's headroom but let me know if it's >20 GB.
- **Smoke test config keys.** `cfg.model.params` is a guess — if the YAML schema differs (e.g. `cfg.model.config` or just `cfg.params`), use whatever the actual key is and note in handoff.
- **`.safetensors` vs `.bin` weight format.** I assumed `.safetensors`; if FreeSplatter ships `.bin` or `.pt`, adjust the verification listing.

## Constraints

- Cycle 2 budget: under 1 GPU-hour (~$0.50 spend ceiling on A6000).
- Don't re-build the kernels — sentinel `INSTALL_SENTINEL` should keep them skipped. If for some reason it doesn't, surface and stop.
- Don't run `app.py` — that's cycle 3.

## Notes

- HF_TOKEN isn't set in the pod env. All 3 models (TencentARC/FreeSplatter, Tencent/Hunyuan3D-1, briaai/RMBG-2.0) appear public; anonymous downloads should work. If any prompts for auth, surface and stop.
- Hugging Face's `hf` CLI is what bootstrap uses (not the deprecated `huggingface-cli`); both are installed via the venv.
