# Cycle 3 — task

**Date:** 2026-05-08
**Set by:** architect
**Cycle:** 3 (final cycle for the recipe lock)

## Goal

Launch `app.py` (Gradio demo on port 7860) and prove end-to-end inference works for both **object mode** (FreeSplatter-O) and **scene mode** (FreeSplatter-S) with real input. Once both modes produce outputs, lock `RECIPE.md` with the cycle-3 verified procedure.

This closes pattern instance #2 fully tested: env (cycle 1), weights (cycle 2), inference (cycle 3).

## Verification

```bash
# 1. App.py launches, gradio listens on port 7860
source /workspace/activate.sh
cd /workspace/FreeSplatter
HF_HOME=/workspace/hf-cache python app.py 2>&1 | tee /tmp/app-cycle-3.log
# expect (within ~2 min, peer models lazy-load on first run):
#   "Running on local URL:  http://0.0.0.0:7860"

# 2. Curl the health endpoint from the pod itself (sanity)
curl -s http://localhost:7860/ | head -c 200
# expect: HTML doctype + gradio shell

# 3. Architect opens an SSH tunnel from local: ssh ... -L 7860:localhost:7860
#    Vlad opens http://localhost:7860 in his browser, drives both modes:
#    - Object mode: upload single image -> Run -> expect 3D Gaussian splat output
#    - Scene mode: upload 4 multi-view images -> Run -> expect 3D scene output
#    Vlad reports back via chat; pod-shell saves output samples to /workspace/outputs/.

# 4. After Vlad confirms both modes succeed, capture timing + memory:
#    - app.py first-cold-inference latency (object mode + scene mode)
#    - peak GPU memory during each run (nvidia-smi during, or torch.cuda.max_memory_allocated())
#    Bank these in handoff.md for the recipe.
```

## Scope

**In scope:**
- `app.py` launch + lifecycle management (start in tmux, capture log)
- `/workspace/hf-cache/` and `./ckpts/` (whichever app.py uses for caching; cycle 2 surfaced that app.py uses `./ckpts/` not `HF_HOME` — peer models lazy-download on first run)
- `/workspace/outputs/` for inference outputs
- `.architect/log/2026-05-08-cycle-03.md` and `.architect/handoff.md`
- `.architect/RECIPE.md` — append a cycle-3 section once Vlad confirms outputs

**Out of scope:**
- Modifying any code in `freesplatter/` or `app.py`
- Re-downloading FreeSplatter weights (cycle 2 finished those)
- `apt`/system-level changes
- Anything outside `/workspace/`

## Prior context

- Cycle 1 closed clean (env + stop/start verified)
- Cycle 2 partial done (FreeSplatter weights + 3-config smoke test green; peer-pre-pull blocked by RMBG-2.0 gate; deferred to lazy-load on first app.py run with HF_TOKEN)
- **HF_TOKEN is now provisioned at `/root/.hf-secret`** (chmod 600). Source it before any `hf` or `app.py` call: `source /root/.hf-secret`. Vlad has accepted RMBG-2.0 terms account-side, so app.py's lazy-pull should succeed.
- This is a fresh pod (`com3tlvpfgnmmk` in US-KS-2, A6000) — **NOT** the cycle 1+2 pod. Reused volume `ehtswxltst`. Tmux session, /root/.ssh, /root/.bashrc plumbing all needs re-init from /workspace state.

## Steps in order

1. **SSH in (fresh-host known_hosts handling), recreate tmux `arch`, restore /root/.ssh from /workspace/.ssh-state/, source HF_TOKEN from /root/.hf-secret**, `source /workspace/activate.sh`.
2. **Pull voxelo/main** in `/workspace/FreeSplatter` to pick up this task.md.
3. **Launch app.py inside tmux**, bound to 0.0.0.0:7860 (gradio default). Use `tee /tmp/app-cycle-3.log` so we have a stable log source. The first run will lazy-download Hunyuan3D-1, RMBG-2.0, sudo-ai/zero123plus-v1.x to `./ckpts/` — could take 5-10 min.
4. **Wait until gradio prints `Running on local URL:`** by polling `/tmp/app-cycle-3.log`. Once it does, surface to architect (me) so I can open an SSH `-L 7860:localhost:7860` tunnel from the laptop.
5. **Architect opens the tunnel + tells Vlad to open the browser.** Vlad drives both modes and reports back.
6. **After Vlad confirms,** pod-shell:
   - Saves a sample of the output(s) to `/workspace/outputs/cycle-3/` so we have provenance for the recipe
   - Captures runtime + memory metrics (from app.py log + nvidia-smi snapshot)
   - Writes `.architect/handoff.md` with status `done`
   - Commits + pushes
7. **Architect closes**: appends cycle-3 section to `.architect/RECIPE.md`, locks pattern instance #2 fully tested, updates memory and decisions.

## Open questions

- **Peer-model cache location.** Cycle 2 finding suggests app.py uses `./ckpts/` (relative) not `HF_HOME`. If app.py downloads to `./ckpts/` we need to pin that to a /workspace path so it survives stop/start. Suggest symlinking before launch: `ln -sfn /workspace/ckpts /workspace/FreeSplatter/ckpts` (after `mkdir -p /workspace/ckpts`). Note in handoff if a different path turns out to be canonical.
- **Object-mode vs scene-mode order.** Either is fine. Suggest scene mode first (less likely to hit RMBG dependency) so we have at least one mode green even if RMBG access has a hiccup.
- **Auth surface.** The pod-side HF_HOME default may differ from `app.py`'s hardcoded paths. If app.py fails to read RMBG-2.0 because it doesn't see HF_TOKEN, you may need to `export HF_TOKEN=...` in the same shell as app.py (not just in the pre-launch source). Standard fix: source `/root/.hf-secret` inside the tmux session BEFORE launching app.py.

## Constraints

- Cycle 3 budget: under 1.5 GPU-hours (~$0.75 ceiling on A6000) including the 5-10 min peer model download + interactive testing.
- Don't kill app.py mid-run — let Vlad use it until he confirms both modes done.
- If a model fails to download with auth errors, surface and stop. Don't try alternate auth methods.

## Notes

- Gradio's port 7860 may have a public-facing URL too if `share=True` is set in app.py — we'll use the SSH tunnel either way to keep traffic private.
- After cycle 3 closes, Vlad will likely want the pod stopped. Surface that as the final action (cost-hygiene), not autonomously.
