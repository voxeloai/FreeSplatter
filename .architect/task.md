# Cycle 1 — task

**Date:** 2026-05-07
**Set by:** architect
**Cycle:** 1

## Goal

Stand up the FreeSplatter env on the pod via `scripts/bootstrap.sh`, prove the venv + 3 custom CUDA kernels build cleanly + the FreeSplatter Python package imports, then verify it survives a stop/start cycle.

This is the **first instance of the bypass-conda (uv venv) variant** of `runpod-persistent-gpu-pod`. Lyra-2 was conda-based; this one isn't. If anything in the pattern breaks because of the bypass, surface it in the handoff so the pattern templates get updated.

## Verification

```bash
# 1. Bootstrap is idempotent + completes
bash scripts/bootstrap.sh
# expect: exits 0, "Bootstrap complete." last log line

# 2. Activation script works
source /workspace/activate.sh
# expect: which python -> /workspace/envs/freesplatter/bin/python

# 3. Torch + CUDA
python -c "import torch; print(torch.__version__, torch.cuda.is_available(), torch.version.cuda)"
# expect: 2.4.0+cu121 True 12.1

# 4. xformers (note: must be 0.0.27.post2 for torch 2.4.0; the requirements.txt
#    pin of 0.0.22.post7 is wrong — README's 0.0.27.post2 is correct).
python -c "import xformers; print(xformers.__version__)"
# expect: 0.0.27.post2

# 5. The 3 custom CUDA kernels imported successfully
python -c "import diff_gaussian_rasterization; import diff_surfel_rasterization; import nvdiffrast.torch as dr; print('kernels OK')"
# expect: "kernels OK"

# 6. FreeSplatter package imports
python -c "from freesplatter.models.model import FreeSplatter; print('FreeSplatter import OK')"
# expect: "FreeSplatter import OK"

# 7. STOP pod from RunPod console, START again, re-attach tmux, then:
source /workspace/activate.sh
# Re-run steps 3, 5, 6. All must pass with the same outputs.
```

## Scope

**In scope:**
- `scripts/bootstrap.sh`
- `scripts/install-pod-claude.sh` (only if optional autonomous mode is needed; default mode skips this)
- `/workspace/activate.sh` (written by bootstrap)
- `/workspace/envs/freesplatter/` (the venv)
- `.architect/log/` and `.architect/handoff.md`

**Out of scope:**
- Editing upstream code in `freesplatter/`, `configs/`, `app.py` — leave alone.
- Downloading model weights — that's cycle 2.
- Running `app.py` — that's cycle 2/3.
- Any GCC version pinning — system gcc on the base image works for these kernels (no upstream pin specified).

## Prior context

Lyra-2 (the first pattern instance) ran the conda path and surfaced ~15 issues. The bypass-conda decision (`Architect/decisions/2026-05-05-bypass-conda.md`) was deferred to "next repo" — that's this one. Expectations:

- No `conda tos accept` friction.
- No `nothing provides __win` channel mismatch.
- No `LibMambaUnsatisfiableError`.
- uv venv creation < 30s.
- `uv pip install -r requirements.txt` faster than conda's pip.
- Custom kernel builds (3 of them) total ~5-10 min on A40.

If any of those go sideways, log the surprise.

## Open questions

- **`xformers` version conflict.** `requirements.txt` pins `xformers==0.0.22.post7` (incompatible with torch 2.4.0). README pins `0.0.27.post2`. Bootstrap installs `0.0.27.post2` BEFORE `pip install -r requirements.txt` and filters xformers out of requirements.txt. Verify this works; if not, alternative is `pip install --no-deps -r requirements.txt`.
- **`TORCH_CUDA_ARCH_LIST`.** Bootstrap doesn't set it explicitly — relies on `nvcc` auto-detecting the present GPU (A40, sm_86). If we ever switch GPU class we'll need to rebuild the 3 kernels. Note this in the handoff.
- **`Hunyuan3D-1` and `RMBG-2.0` weights.** Used by inference, lazy-loaded on first run from HF. Cycle 1 doesn't touch them. Cycle 2 may want to pre-pull.

## Constraints

- A40 GPU at $0.39/hr — keep cycle 1 under 2 GPU-hours of total wall time.
- Don't pre-download the FreeSplatter weights yet; cycle 2 owns weights.
- Don't run `pip install` outside the venv. Always `source /workspace/activate.sh` first; verify with `which python`.

## Notes

- This is the first uv-venv instance of the pattern. Take notes — anything that surprises us lifts to the pattern templates.
- Quick test command for later cycles: `python app.py` (Gradio demo on port 7860; tunnel via SSH `-L 7860:localhost:7860` for access from the laptop).
