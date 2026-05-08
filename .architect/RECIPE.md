# RECIPE — FreeSplatter on RunPod A6000 with persistent volume

**Status:** LOCKED 2026-05-08. All 3 cycles passed end-to-end. Reproducible in ~5 hours total wall + ~$3.50 compute. Object mode + scene mode inference verified by Vlad through Gradio.

This is the locked, reproducible recipe for getting TencentARC's FreeSplatter running on a RunPod GPU pod with a persistent network volume that survives stop/start. Built and verified through 3 cycles of the bypass-conda variant of `runpod-persistent-gpu-pod`.

## Prerequisites (one-time, on your laptop)

- RunPod account with Voxelo team API key (`runpodctl doctor`)
- GitHub auth (`gh auth login`) — needed to fork upstream + push voxelo/main
- `runpodctl` on PATH (`C:\Users\<user>\.local\bin\runpodctl.exe`)
- For PowerShell deploy on Windows: PS 7+ recommended (PS 5.1 also supported via `JavaScriptSerializer` fallback in `deploy.ps1`)
- HuggingFace token NOT required — `TencentARC/FreeSplatter` is public; anonymous downloads work. Set `$env:HF_TOKEN` only if you switch to a gated model.

## Deploy

From `Documents/AI/repos/FreeSplatter` (clone of `voxeloai/FreeSplatter`):

```powershell
.\scripts\deploy.ps1 -GpuId 'NVIDIA RTX A6000' -DataCenter US-KS-2
```

Defaults: `freesplatter` pod name, `freesplatter-workspace` 100 GB volume, image `runpod/pytorch:1.0.2-cu1281-torch280-ubuntu2404`. Override any with `-PodName`, `-VolumeName`, `-VolumeSizeGB`, `-PodImage`.

If A6000 is out of stock in US-KS-2, probe alternatives:

```powershell
runpodctl datacenter list -o json | ConvertFrom-Json -Depth 10 -AsHashtable | ForEach-Object {
    $g = $_.gpuAvailability | Where-Object { $_.gpuId -eq 'NVIDIA RTX A6000' }
    if ($g -and $g.stockStatus -ne 'Unavailable') { "$($_.id) -> $($g.stockStatus)" }
}
```

Volume-supported DCs as of 2026-05-08: `CA-MTL-3, CA-MTL-4, EU-CZ-1, EU-NL-1, EU-RO-1, EUR-IS-3, EUR-NO-1, US-CA-2, US-IL-1, US-KS-2, US-MO-1, US-MO-2, US-NC-2, US-NE-1, US-TX-3, US-WA-1`. Refresh from any `runpodctl network-volume create` error message — RunPod prints the live list.

Outputs: pod ID, volume ID, SSH command. SSH may take 30-60s to come up after `RUNNING` state; deploy script polls automatically.

## On the pod (cycle 1: env health, ~10 min from cold pull)

```bash
ssh -i ~/.ssh/RunPod-Key-Go -p <port> root@<ip>

# Inside tmux so disconnects don't kill the build
tmux new -s arch

cd /workspace
git clone https://github.com/voxeloai/FreeSplatter.git
cd FreeSplatter && git checkout voxelo/main

# REPO_REMOTE is required by bootstrap.sh for fresh-clone path; harmless after.
REPO_REMOTE=https://github.com/voxeloai/FreeSplatter.git bash scripts/bootstrap.sh
```

What `bootstrap.sh` does (sentinel-gated; safe to re-run):

1. apt installs `build-essential ninja-build cmake ffmpeg git libgl1 libglib2.0-0 libegl1 libgles2 tmux`
2. Confirms `/usr/local/cuda` from base image (CUDA 12.8.93)
3. Installs `uv` to `/workspace/.local/bin/uv` (persistent across stop/start)
4. Creates Python 3.10 venv at `/workspace/envs/freesplatter`
5. Pulls voxelo/main on the cloned repo
6. **The slow phase (sentinel: `/workspace/.freesplatter-pip-installed-v1`):**
   - 6a. `torch==2.4.0 torchvision==0.19.0` from `https://download.pytorch.org/whl/cu121`
   - 6b. `xformers==0.0.27.post2` (overrides upstream's broken `0.0.22.post7` pin in requirements.txt)
   - 6c. Build backends: `hatchling pathspec editables setuptools wheel ninja packaging`
   - 6d.1. Pure-pip subset of `requirements.txt` (~50 deps)
   - 6d.2. The 3 git+ kernel packages with `--no-build-isolation` and `NVCC_PREPEND_FLAGS=-include cstdint` + `CXXFLAGS=-include cstdint` (gcc 13 / CUDA 12.8 fix):
     - `diff-gaussian-rasterization` (Ampere sm_86, ~2 min)
     - `diff-surfel-rasterization` (~2 min)
     - `nvdiffrast` (~30s)
     - `utils3d@9a4eb15` (pure Python)
   - 6e. `hf_transfer` (HF_HUB_ENABLE_HF_TRANSFER=1 in base image)
   - 6f. `onnxruntime-gpu` (rembg's missing peer dep)
7. Writes `/workspace/activate.sh`

Total cold-cache: ~5 min. Warm re-run: 14s no-op.

Then verify (the 7 cycle-1 checks):

```bash
source /workspace/activate.sh
which python   # /workspace/envs/freesplatter/bin/python

python -c "import torch; print(torch.__version__, torch.cuda.is_available(), torch.version.cuda)"
# expect: 2.4.0+cu121 True 12.1

python -c "import xformers; print(xformers.__version__)"
# expect: 0.0.27.post2

python -c "import diff_gaussian_rasterization; import diff_surfel_rasterization; import nvdiffrast.torch as dr; print('kernels OK')"
# expect: kernels OK

python -c "from freesplatter.models.model import FreeSplatterModel; print('FreeSplatterModel import OK')"
# expect: FreeSplatterModel import OK   (~1m45s warm, MFS-bound)
```

## Stop/start verification (cycle 1's load-bearing test)

```powershell
# On laptop
runpodctl pod stop <pod-id>
# Wait ~5s
runpodctl pod start <pod-id>
# Wait for SSH ready (poll runpodctl pod get <pod-id> -o json | jq .ssh)
```

**IMPORTANT:** SSH **port may change** on stop/start. The IP usually persists (same physical reservation) but the port mapping is regenerated. `runpodctl pod get` may briefly return the stale pre-stop port. Always re-fetch SSH details before reconnecting.

After SSH ready, on the pod:

```bash
tmux new -s arch    # session was lost on restart; recreate
source /workspace/activate.sh
# Re-run the 5 import checks above. Identical outputs == cycle 1 fully passes.
```

## Pod git push setup (one-time per pod)

If you need pod-side git push (pod-shell sub-agent does), generate the per-pod ed25519 keypair on the pod:

```bash
mkdir -p /workspace/.ssh-state && chmod 700 /workspace/.ssh-state
KEY=/workspace/.ssh-state/pod_id_ed25519
ssh-keygen -t ed25519 -N "" -C "voxelo-runpod-<pod-name>-$(date +%F)" -f "$KEY"

# /root/.ssh enforces chmod, /workspace doesn't (MFS gotcha)
mkdir -p /root/.ssh && chmod 700 /root/.ssh
cp "$KEY" /root/.ssh/pod_id_ed25519 && chmod 600 /root/.ssh/pod_id_ed25519

git -C /workspace/FreeSplatter config core.sshCommand \
    "ssh -i /root/.ssh/pod_id_ed25519 -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"

cat "${KEY}.pub"   # paste into https://github.com/settings/keys (account-level)

# Then:
cd /workspace/FreeSplatter
git remote set-url origin git@github.com:voxeloai/FreeSplatter.git
ssh -i /root/.ssh/pod_id_ed25519 -o IdentitiesOnly=yes -T git@github.com
git push   # should not prompt
```

After stop/start, `/root/.ssh/pod_id_ed25519` is wiped (ephemeral). Restore from `/workspace/.ssh-state/`. The Lyra `init-pod.sh` template handles this auto for autonomous mode; for pod-shell mode, restore manually as part of post-restart setup.

## Cycle 2 — FreeSplatter weights (~30 min, ~$0.30)

```bash
cd /workspace/FreeSplatter
FREESPLATTER_DOWNLOAD_WEIGHTS=1 bash scripts/bootstrap.sh
# Pulls 3.5 GB from TencentARC/FreeSplatter to /workspace/weights/
# (3 .safetensors files, NOT a checkpoints/ subdir)
```

Verify (3-config smoke):

```bash
source /workspace/activate.sh
python <<EOF
from omegaconf import OmegaConf
from freesplatter.models.model import FreeSplatterModel
for cfg_name in ['freesplatter-object', 'freesplatter-object-2dgs', 'freesplatter-scene']:
    cfg = OmegaConf.load(f'configs/{cfg_name}.yaml')
    model = FreeSplatterModel(**cfg.model.params).cuda().eval()
    print(f'OK: {cfg_name} {sum(p.numel() for p in model.parameters())/1e6:.1f}M')
# expect: 3 lines "OK: <name> 307.9M"
EOF
```

**Don't bother pre-pulling peer models.** App.py uses `cache_dir="ckpts/"` (relative repo dir); pre-pulling into `HF_HOME` doesn't help. Cycle 3's first launch lazy-pulls them automatically.

## Cycle 3 — Gradio end-to-end (~5-10 min cold first launch, ~3 min subsequent)

### Prerequisites for inference

- **HF_TOKEN provisioned on the pod** (only required if peer models include gated repos like `briaai/RMBG-2.0`):

  ```powershell
  # On laptop, in the same shell where $env:HF_TOKEN is set:
  "export HF_TOKEN='$($env:HF_TOKEN.Trim())'`n" | ssh -i $env:USERPROFILE\.runpod\ssh\RunPod-Key-Go -p <port> root@<ip> 'cat | tr -d "\r" > /root/.hf-secret && chmod 600 /root/.hf-secret'
  ```

  Use `tr -d "\r"` on the receive side to strip Windows CRLF; otherwise `source /root/.hf-secret` parses incorrectly.
- **You must accept gated terms account-side** at https://huggingface.co/briaai/RMBG-2.0 before first launch. Anonymous access fails.

### Launch

```bash
# On the pod
tmux new -s arch
source /workspace/activate.sh
source /root/.hf-secret      # if HF_TOKEN provisioned
cd /workspace/FreeSplatter
python app.py 2>&1 | tee /tmp/app.log
# Wait for: "Running on local URL:  http://0.0.0.0:41137"
# Cold first launch: ~5-10 min (lazy-pulls Hunyuan3D-1 ~16 GB, RMBG-2.0 ~849 MB,
#   sudo-ai/zero123plus-v1.1 ~3.6 GB, v1.2 ~5.3 GB into /workspace/ckpts/).
# Warm subsequent launches: ~3 min.
```

### Tunnel from laptop

App.py hardcodes port 41137 (not 7860):

```powershell
ssh -i $env:USERPROFILE\.runpod\ssh\RunPod-Key-Go -p <port> -N -L 7860:localhost:41137 root@<ip>
```

Open `http://localhost:7860` in your browser.

### Verify both modes

- **Image-to-3D tab** (FreeSplatter-O): drag-drop a single object image → Run → 3D Gaussian splat output rendered to a video.
- **Sparse-view-to-Scene tab** (FreeSplatter-S): upload 4 multi-view images of a scene → Run → 3D scene Gaussians.

Peak GPU memory measured during cycle 3 verification: **24.2 GB / 48 GB** on A6000.

## Cost reference

- Volume idle (100 GB in US-KS-2): ~$7/mo
- Pod compute when running: $0.49/hr A6000 Secure Cloud
- Cycle 1 burn (env build): ~$1.00 (proven 2026-05-08)
- Cycle 2 burn (weights): ~$0.30
- Cycle 3 burn (gradio + 4 layers of debug): ~$2.00 (this includes all the yak-shaving; a clean redeploy with the patched bootstrap.sh should cost ~$0.50)
- **Total proven**: ~$3.50 for first deploy + verify; **~$1.80 for clean redeploy**.

## Known constraints

- Kernel binaries are compiled for the GPU class active at install time (auto-detected). Switching from A6000 (sm_86) to H100 (sm_90) or L40S (sm_89) requires deleting the 3 kernel site-packages and re-running with `INSTALL_SENTINEL` removed. Not a blocker for normal ops.
- `runpod/pytorch:1.0.2-cu1281-torch280-ubuntu2404` is the proven base image. The upstream-style format `pytorch:2.7.1-py3.10-cuda12.8.0-devel-ubuntu22.04` does NOT exist on Docker Hub — gives `manifest unknown`.
- xformers 0.0.27.post2 is the version compatible with torch 2.4.0+cu121. Upstream's `requirements.txt` pins 0.0.22.post7 which is wrong for torch 2.4.0; bootstrap.sh filters and overrides automatically.
- A40 was the original GPU pick; A6000 was substituted because A40 was effectively stockless in volume-capable DCs at deploy time. Both should work identically — same chip family (GA102 Ampere sm_86), same 48 GB VRAM, only ~$0.10/hr price diff.
