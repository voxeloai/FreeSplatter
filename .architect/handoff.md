# Cycle 1 handoff — closed

**Status:** done (all 7 verification checks passed, including stop/start cycle)
**Date:** 2026-05-08
**Cycle:** 1 (first instance of bypass-conda variant)

## Status summary

Bootstrap is durable end-to-end. Bypass-conda variant of `runpod-persistent-gpu-pod` works. Pod survived a stop/start cleanly. Patches to `scripts/bootstrap.sh` are committed and pushed to `voxelo/main`. Pattern-level lessons banked below for architect to lift to the templates.

## What changed on the pod

- Repo cloned at `/workspace/FreeSplatter` on `voxelo/main`.
- Tmux session `arch` recreated post-restart (was lost as expected).
- `scripts/bootstrap.sh` patched in 3 places (Bug 1 / 2 / 3 below) — committed and pushed.
- Env at `/workspace/envs/freesplatter` (Python 3.10.18 venv via uv).
- Sentinel `/workspace/.freesplatter-pip-installed-v1` set; survived stop/start; bootstrap re-run is a 14s no-op.
- `/workspace/activate.sh` written.
- `/workspace/.ssh-state/pod_id_ed25519` keypair persistent. Live copy at `/root/.ssh/pod_id_ed25519` (chmod 600) re-created post-restart from /workspace source — `/root/.ssh` is ephemeral.
- Git remote switched to SSH form: `git@github.com:voxeloai/FreeSplatter.git`. Auth verified.

## What worked

- uv venv (Python 3.10.18): created in <30s.
- uv pip resolution: 51 pure-pip deps installed in seconds. Faster than conda's pip path.
- xformers 0.0.27.post2 override against the broken 0.0.22.post7 pin in upstream's requirements.txt: clean.
- nvcc auto-detection of sm_86 from A6000: no `TORCH_CUDA_ARCH_LIST` needed.
- Successful end-to-end bootstrap on run 3: 133s wall. Idempotent re-run: 33s. **Post-restart re-run: 14.15s** (warmest possible no-op).
- All 3 CUDA kernels compile clean with system gcc 13.3 + system CUDA 12.8 (no gcc version pin) once cstdint is force-included.
- /workspace persistence: env + sentinels + .ssh-state survived runpodctl stop/start cleanly. Container hostname changed (new physical machine), but volume reattached cleanly.

## Pattern bugs found (and fixed in this commit)

These are bypass-conda divergences from the conda-Lyra-2 path. All three fixes belong in the bypass-conda PATTERN.md template + decision doc.

### Bug 1: uv build isolation hides torch from kernel setup.py

**Symptom:** `ModuleNotFoundError: No module named 'torch'` when uv builds the 3 git+ kernel packages. setup.py imports torch at module load to get torch.utils.cpp_extension.

**Cause:** uv defaults to isolated builds (vs conda's pip default of using the active env). The git+ kernels' setup.py needs torch, but the build venv is empty.

**Fix:** Split step 6d into 6d.1 (pure-pip deps with default isolation) and 6d.2 (git+ deps with `--no-build-isolation`). Pre-installing build backends in step 6c (already there) keeps 6d.2 working.

### Bug 2: gcc 13 + CUDA 12.8 needs explicit cstdint include

**Symptom:** `namespace "std" has no member "uintptr_t"` and `identifier "uint32_t" is undefined` in diff-surfel-rasterization.

**Cause:** Kernel headers include `<iostream>`, `<vector>`, `<cuda_runtime_api.h>` only. gcc 13's libstdc++ no longer transitively pulls `<cstdint>`.

**Fix:** Before step 6d.2:

    export NVCC_PREPEND_FLAGS="${NVCC_PREPEND_FLAGS:-} -include cstdint"
    export CXXFLAGS="${CXXFLAGS:-} -include cstdint"

### Bug 3: rembg's onnxruntime peer dep is missing from upstream requirements.txt

**Symptom:** `ModuleNotFoundError: No module named 'onnxruntime'` when importing freesplatter.utils.infer_util (which imports rembg, which imports onnxruntime at module load).

**Fix:** Added step 6f to bootstrap.sh: `uv pip install onnxruntime-gpu` (this pattern targets CUDA pods).

## Pattern bugs found (NOT fixed — handed back to architect)

### Bug 4: task.md verification check 6 has wrong class name

`task.md` check 6 says `from freesplatter.models.model import FreeSplatter` but the actual class at `freesplatter/models/model.py:17` is `FreeSplatterModel`.

`scripts/bootstrap.sh` Quick-verification hint (printed at end of every bootstrap run) has the same wrong name.

**Why pod-shell didn't fix:** task.md is architect-owned per the cycle protocol. pod-shell does not edit task.md. Bootstrap's hint comment is a small follow-up that travels with the spec correction.

**Recommended follow-up commit (architect):**
- Update task.md cycle 1 check 6 to use `FreeSplatterModel`.
- Update `scripts/bootstrap.sh` final-print "Quick verification" block (3 lines near the bottom) to reference `FreeSplatterModel`.
- Lift to `runpod-persistent-gpu-pod` PATTERN templates so the next repo deploy doesn't inherit the same bug.

### Bug 5: pattern-level — RunPod re-issues SSH ports on stop/start

**This is a pattern-level finding banked at the post-restart re-spawn step.**

When architect spawned me with the new pod state, the brief said: *"IP and port unchanged: 64.247.206.204:35155 (same SSH command as before)"*. The IP was unchanged. **The port was NOT** — it changed from 35155 to 42213.

I confirmed via the GraphQL pod runtime query:

    {"data":{"pod":{"runtime":{"ports":[{"ip":"64.247.206.204","privatePort":22,"publicPort":42213,"type":"tcp"}]}}}}

Five SSH attempts on the old port 35155 returned `Connection refused` (host reachable, no service on that port). Pod uptime 186s confirmed sshd was up — just on the new port.

**Pattern-level rule:** after `runpodctl pod stop/start`, always re-query the GraphQL ports field before assuming SSH endpoint persists. Don't trust prior-cycle SSH details. Add to PATTERN.md and to the playbook step "after stop/start, refresh port mapping via GraphQL".

The query (architect can stash this):

    curl -s -X POST 'https://api.runpod.io/graphql' \
      -H 'Content-Type: application/json' \
      -H "Authorization: Bearer $RUNPOD_API_KEY" \
      -d '{"query":"query { pod(input:{podId:\"<POD_ID>\"}) { runtime { ports { ip privatePort publicPort type } } } }"}'

## Verification results — final pass (checks 1-7)

All 7 task.md checks passed. Highlights:

- Check 1 (bootstrap idempotent): 14.15s no-op post-restart. PASS.
- Check 2 (activate.sh): which python = `/workspace/envs/freesplatter/bin/python`. PASS.
- Check 3 (torch + CUDA): 2.4.0+cu121, cuda True, "NVIDIA RTX A6000". Identical pre/post-restart. PASS.
- Check 4 (xformers): 0.0.27.post2. PASS.
- Check 5 (3 kernels): "kernels OK" (dgr + dsr + nvdiffrast). Identical pre/post-restart. PASS.
- Check 6 (FreeSplatterModel import — corrected): "FreeSplatterModel import OK". PASS. (~1m45s warm — MFS-bound.)
- Check 7 (stop/start re-verify): all of 3, 5, 6 re-passed with identical outputs. Bootstrap re-run: 14s no-op. PASS.

## Pod cost / wall time (for pattern banking)

- Pod create → cycle 1 close: ~2 hours wall time (09:22 UTC bootstrap launch → 11:19 UTC close, with stop/start gap in between).
- A6000 at $0.49/hr → ~$1.00 burn for cycle 1.
- Bootstrap-only (run 3 alone): 133s. With cold uv cache, estimate 4-5 min.

## Next-cycle suggestion (cycle 2)

- Weights download (TencentARC/FreeSplatter via HF; flip `FREESPLATTER_DOWNLOAD_WEIGHTS=1`).
- Pre-pull RMBG-2.0 + Hunyuan3D-1 weights so app.py first-run doesn't go to HF.
- Run app.py, smoke-test the gradio demo over SSH tunnel `-L 7860:localhost:7860`.
- Pre-warm the FreeSplatterModel import (1m45s warm, MFS-bound) — possibly move to a stay-alive uvicorn worker pattern in cycle 3.

## Recommendations to lift to PATTERN.md / RECIPE.md

1. **uv build-isolation split (Bug 1):** universal for any bypass-conda repo with git+ packages whose setup.py imports torch. Adds 6d.1 / 6d.2 split.
2. **gcc 13 + CUDA cstdint workaround (Bug 2):** universal for 3DGS-family kernels on Ubuntu 24.04 base images. Belongs in the kernel-compile pre-flight section.
3. **onnxruntime peer dep (Bug 3):** repo-specific (rembg-using). Worth a generic checklist note: "if upstream requirements.txt lists rembg or any X that lazy-imports a runtime, ensure the runtime is also installed".
4. **SSH port re-issuance on stop/start (Bug 5):** pattern-level. Update playbook + PATTERN.md.
5. **MFS chmod gotcha + /root/.ssh ephemerality (cycle 5 carry-over, confirmed again here):** init-pod.sh in PATTERN.md template should auto-restore /workspace/.ssh-state → /root/.ssh on every fresh boot. Or at minimum, document the manual restore as the first cycle-N bootstrap step.

## Open / surfaced for architect

- Patch task.md + bootstrap.sh hint to use `FreeSplatterModel` (Bug 4 above) — architect-owned follow-up commit.
- Decide on stop policy for the pod. Currently RUNNING ($0.49/hr). Cycle 2 starts whenever architect kicks it.
- Decide whether to lift Bugs 1/2/3/5 directly into the bypass-conda decision doc + PATTERN.md template now, or wait for the second instance to confirm the fixes are universal.
