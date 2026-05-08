# Cycle 2 — handoff

**Date:** 2026-05-08
**Status:** `in-progress` — partial. FreeSplatter weights + smoke test green; peer-model pre-pull blocked on gated repo + spec issues. Architect call needed before cycle 3.

## What worked

- **Pod connect + state restore.** Fresh pod `com3tlvpfgnmmk` at `64.247.206.204:34045`. Volume `ehtswxltst` reattached cleanly. All cycle-1 artefacts intact (venv, kernels, sentinels, `/workspace/.ssh-state/`). SSH key re-installed at `/root/.ssh/pod_id_ed25519`, GitHub auth confirmed (`Hi visualvlad!`). tmux `arch` recreated.
- **Repo pulled** to `26c89b8`.
- **FreeSplatter weights downloaded.** `FREESPLATTER_DOWNLOAD_WEIGHTS=1 bash scripts/bootstrap.sh`: steps 1-6 sentinel-skipped, step 7 pulled 3.6 GB total via `huggingface-cli`. Sentinel `/workspace/.freesplatter-weights-complete` written.
- **Smoke test passed.** All 3 configs (`freesplatter-object`, `freesplatter-object-2dgs`, `freesplatter-scene`) instantiate cleanly via `FreeSplatterModel(**cfg.model.params).cuda().eval()` — 307.9M params each. `cfg.model.params` schema guess was correct.

## What didn't work — peer-model pre-pull

The peer-model pre-pull as specified in cycle-2 task.md is **wrong on multiple axes**. None of these are pod-shell mistakes; they're spec issues to fix before cycle 3.

1. **`briaai/RMBG-2.0` is gated.** `GatedRepoError: 401 Client Error`. Anonymous downloads do not work — task.md said this would. Need HF_TOKEN with prior gated-access acceptance for that repo. Per task.md instruction If something prompts for auth, surface and stop, I stopped.

2. **Wrong cache destination.** `app.py` calls `snapshot_download('tencent/Hunyuan3D-1', repo_type='model', local_dir='./ckpts/Hunyuan3D-1')` and `webui/runner.py` uses `cache_dir='ckpts/'` (relative to FreeSplatter repo root). Pre-pulling into `HF_HOME=/workspace/hf-cache` does NOT prevent re-download in cycle 3 — app.py uses `local_dir`/`cache_dir` not `HF_HOME`.

3. **Include filter doesn't recurse.** `huggingface-cli download Tencent/Hunyuan3D-1 --include '*.safetensors'` matched only root-level files (none of which exist as safetensors); the actual safetensors live under `mvd_lite/`, `mvd_std/`, `svrm/`. fnmatch `*` doesn't cross `/`. Would need `**/*.safetensors` or drop the filter.

4. **Peer-model list is incomplete.** `webui/runner.py` also loads:
   - `sudo-ai/zero123plus-v1.1` (with `custom_pipeline="sudo-ai/zero123plus-pipeline"`)
   - `sudo-ai/zero123plus-v1.2`
   - `./ckpts/Hunyuan3D-1/mvd_std` subdir specifically (full repo not needed; only `mvd_std/` for the std pipeline)

5. **Bootstrap-emitted spec drift.** Cycle-2 task.md verification listing has `/workspace/weights/checkpoints/*.safetensors` — actual is `/workspace/weights/*.safetensors` (no `checkpoints/` subdir).

## Decisions I made (within my lane)

- Stopped peer-pull as soon as RMBG-2.0 hit GatedRepoError, per surface and stop instruction.
- Did NOT try to set `HF_TOKEN` myself (auth secret = architect/Vlad's call).
- Did NOT retry Hunyuan3D-1 with a fixed include pattern, because the destination is also wrong — partial fix would still be wrong.
- Smoke test executed regardless because the 3 configs are self-contained — no peer model needed for FreeSplatterModel instantiation.

## What architect needs to decide before cycle 3

1. **HF_TOKEN provisioning.** Set `HF_TOKEN` in pod env (or write to `/root/.cache/huggingface/token` via `huggingface-cli login`). Vlad's HF account also needs to have accepted gated access for `briaai/RMBG-2.0` (one-time at https://huggingface.co/briaai/RMBG-2.0 while logged in).
2. **Rewrite peer-pull strategy.** Either:
   - (a) skip peer pre-pull entirely — let `app.py` populate `./ckpts/` on first run (cycle 3 will be slow but correct), OR
   - (b) pre-pull to the correct destinations: `huggingface-cli download tencent/Hunyuan3D-1 --local-dir /workspace/FreeSplatter/ckpts/Hunyuan3D-1` (specifically for the `mvd_std` subset if you want to save disk), and use `cache_dir=/workspace/FreeSplatter/ckpts` for the snapshot downloads of RMBG-2.0 + zero123plus.
3. **Patch cycle-2 task.md template** for future repos: drop `checkpoints/` from the FreeSplatter weights listing.
4. **Possible `pod-shell-prep.sh`.** The `/root/.ssh/pod_id_ed25519` restore + git core.sshCommand setup is currently manual (3 commands). Lyra's `install-pod-claude.sh` automates this via `init-pod.sh`. Bypass-conda variant doesn't ship that. Could be a tiny script next to `scripts/bootstrap.sh` that the operator runs first thing on a fresh pod, OR baked into bootstrap.sh as an idempotent first step (with the heuristic if /workspace/.ssh-state/ exists, restore it). Not blocking, but a recurring tax.

## Open questions

- Cycle 1's `task.md` listed Hunyuan3D-1 as ~5 GB. Hunyuan3D-1 actually contains BOTH `mvd_lite/` AND `mvd_std/` (each ~5 GB at first glance — full repo could be 10-15 GB). Pre-pulling only `mvd_std/` saves disk. Architect to decide if `mvd_lite/` is also needed.
- Disk: `/workspace` MFS shows volume-wide 67% used; the per-pod 100GB quota counter isn't visible via `df`. Hunyuan3D-1 + RMBG-2.0 + zero123plus-v1.1 + zero123plus-v1.2 could push us over. Worth a check via runpod console or a `du -sh /workspace/*` audit before pulling.

## Pointers

- Log: `.architect/log/2026-05-08-cycle-02.md`
- Files written/changed:
  - `/workspace/weights/{freesplatter-object,freesplatter-object-2dgs,freesplatter-scene}.safetensors` (1.23 GB each)
  - `/workspace/.freesplatter-weights-complete` (sentinel)
  - `/workspace/hf-cache/hub/models--Tencent--Hunyuan3D-1/` (only `config.json`; cleanup candidate)
  - `/root/.ssh/pod_id_ed25519` (restored, ephemeral)
  - `/workspace/FreeSplatter/_smoke.py` (smoke test artefact, leave for now)
- Next cycle: cycle 3 = gradio app boot + image-to-3D inference round-trip. Blocked on the HF_TOKEN + peer-pull-strategy decisions above.
