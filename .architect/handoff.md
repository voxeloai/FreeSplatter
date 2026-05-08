# Cycles 1-3 — final handoff (recipe locked)

**Status:** `done`
**Date:** 2026-05-08
**Pattern:** runpod-persistent-gpu-pod (bypass-conda variant) — pattern instance #2 fully tested.

## TL;DR

All three cycles closed. Object mode + scene mode end-to-end inference verified by Vlad through Gradio at `http://localhost:7860` (SSH tunnel `-L 7860:localhost:41137`). Recipe is locked in `.architect/RECIPE.md`. Pod stopped. Total spend across all cycles: ~$3.50.

## Cycle outcomes

| cycle | status | notes |
|---|---|---|
| 1 | done (2026-05-08, ~2h, ~$1) | env health + stop/start verified. 5 pattern bugs banked → bootstrap.sh patched. |
| 2 | done (2026-05-08, ~30m, ~$0.30) | FreeSplatter weights (3.5 GB) + 3-config smoke test green. Peer-pull deferred to lazy-load in cycle 3. |
| 3 | done (2026-05-08, ~4h, ~$2) | App.py launched, both inference modes verified. 4 layers of gradio fixes. Recipe locked. |

## What was proven

- Bypass-conda variant works end-to-end (uv venv, system gcc, system CUDA, no conda).
- Stop/start preserves env (14s no-op bootstrap re-run on warm cache).
- Pod resume recovery: when `runpodctl pod start` fails with "not enough free GPUs on host machine", `pod remove` + redeploy gets a fresh host in the same DC, volume reattaches cleanly.
- App.py + Gradio + 4 chained model pipelines (zero123plus-v1.1/v1.2 + Hunyuan3D-1 + FreeSplatterModel + RMBG-2.0) all run on a single A6000 at peak ~24 GB / 48 GB.

## Issues hit + fixes (all banked into bootstrap.sh § 6.5 + Architect templates)

### Cycle 1 (bypass-conda first instance)
1. uv `--no-build-isolation` needed for git+ kernel packages (torch invisible to isolated build venv).
2. gcc 13 / CUDA 12.8 needs `NVCC_PREPEND_FLAGS=-include cstdint` + `CXXFLAGS=-include cstdint` for `diff-*-rasterization`.
3. `rembg` lazy-imports `onnxruntime` — pre-install `onnxruntime-gpu`.
4. Architect-side spec error: `task.md` referenced `FreeSplatter` class; actual is `FreeSplatterModel`.
5. RunPod re-issues SSH ports on pod stop/start (IP usually persists). Always re-fetch via `runpodctl pod get`.

### Cycle 2 (architect-owned task.md spec issues)
6. App.py uses `cache_dir="ckpts/"` (relative repo dir), NOT `HF_HOME`. Pre-pull plan was wrong.
7. HF CLI `--include "*.safetensors"` doesn't recurse subdirs. Use `**/*.safetensors` or omit.
8. Peer model list incomplete — `sudo-ai/zero123plus-v1.1` AND `v1.2` both needed.
9. `briaai/RMBG-2.0` is gated — need HF_TOKEN + account-level Accept Terms.
10. `/workspace/weights/checkpoints/` path was wrong — FreeSplatter writes flat to `/workspace/weights/`.

### Cycle 3 (gradio launch — 4 layers)
11. `ModuleNotFoundError: diffusers_modules` — `init_hf_modules` doesn't reliably add `HF_MODULES_CACHE` to sys.path. Fix: `.pth` file in venv site-packages.
12. `FileNotFoundError: examples/img_to_3d` — upstream's `.gitignore` excludes `examples/`. Fix: `mkdir -p` 6 empty dirs.
13. `TypeError: argument of type 'bool' is not iterable` in `gradio_client/utils.py:880 get_type` — newer JSON Schema `additionalProperties: True` reaches code that expects dict. Fix: `if not isinstance(schema, dict): return None`.
14. `APIInfoParseError: Cannot parse schema True` in `_json_schema_to_python_type` — same bool root cause but recursive code path. Fix: short-circuit on bool.

### Security
15. **Token leak**: pod-shell echoed HF_TOKEN to chat while debugging a CRLF parse error in `/root/.hf-secret` (used `cat -A` on a known-secret file). Token rotated by Vlad. Lifted to `pod-shell.md`: never `cat`/`cat -A`/`od` on secret files.

## Pod state at close

- **Pod**: `com3tlvpfgnmmk` (stopped). Resume with `runpodctl pod start com3tlvpfgnmmk`. SSH port may change on resume — re-fetch.
- **Volume**: `ehtswxltst` (100 GB MFS in US-KS-2, ~47% used: envs 14 GB, weights 3.5 GB, ckpts 29 GB, hf-cache 12 MB, outputs 72 MB). Idle cost ~$7/mo until deleted.
- **GitHub**: per-pod ed25519 pubkey `voxelo-runpod-jxnu5fpi95j9gy-2026-05-08` is in Vlad's account-level keys. Persists across pods.

## Next-cycle suggestion

None. Recipe locked. If FreeSplatter is needed again:
1. `runpodctl pod start com3tlvpfgnmmk` (fresh pod from same volume) OR `deploy.ps1 -GpuId 'NVIDIA RTX A6000' -DataCenter US-KS-2` (if old pod is gone).
2. `bash scripts/bootstrap.sh` — should be a 14s no-op verifying everything's intact, plus the 6.5 runtime patches re-apply.
3. `source /workspace/activate.sh && cd /workspace/FreeSplatter && python app.py`
4. From local: `ssh -L 7860:localhost:41137 ...` then http://localhost:7860.

## Pointers

- Recipe: `.architect/RECIPE.md`
- Per-cycle logs: `.architect/log/2026-05-08-cycle-0{1,2,3}.md`
- Smoke script: `.architect/scripts/smoke_configs.py`
- Architect-side learnings: `Architect/decisions/2026-05-08-bypass-conda-tested.md`, `Architect/memory/playbook_repo_deploy.md`, `Architect/memory/in_flight_freesplatter_deploy.md`
