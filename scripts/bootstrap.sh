#!/usr/bin/env bash
# bootstrap.sh — first-boot install + idempotent re-run after stop/start.
#
# Variant: BYPASS-CONDA (uv venv based).
# This is the first instance of the runpod-persistent-gpu-pod pattern that
# does not use conda — see Architect/decisions/2026-05-05-bypass-conda.md.
# What conda was doing for Lyra-2 (Python isolation, gcc pin, libmamba) is
# replaced here by: uv venv (Python isolation), system gcc (no pin), and
# the base image's /usr/local/cuda (no CUDA install dance).
#
# Idempotent. Sentinel-gated. Safe to re-run on every pod start.

set -euo pipefail

# ─────────────────────────────────────────────────────────────
# 0. Repo-specific config
# ─────────────────────────────────────────────────────────────
REPO_NAME="${REPO_NAME:-FreeSplatter}"
ENV_NAME="${ENV_NAME:-freesplatter}"
PYTHON_VERSION="${PYTHON_VERSION:-3.10}"
TORCH_VERSION="${TORCH_VERSION:-2.4.0}"
TORCHVISION_VERSION="${TORCHVISION_VERSION:-0.19.0}"
XFORMERS_VERSION="${XFORMERS_VERSION:-0.0.27.post2}"   # README says this; requirements.txt's 0.0.22.post7 is wrong for torch 2.4
TORCH_INDEX_URL="${TORCH_INDEX_URL:-https://download.pytorch.org/whl/cu121}"

HF_REPO_ID="${HF_REPO_ID:-TencentARC/FreeSplatter}"
HF_INCLUDE_PATTERN="${HF_INCLUDE_PATTERN:-*}"

BUILD_VERSION="${BUILD_VERSION:-v1}"

# ─────────────────────────────────────────────────────────────
# Paths (uniform across repos under this pattern)
# ─────────────────────────────────────────────────────────────
WORKSPACE="/workspace"
REPO_DIR="${WORKSPACE}/${REPO_NAME}"
ENV_DIR="${WORKSPACE}/envs/${ENV_NAME}"
WEIGHTS_DIR="${WORKSPACE}/weights"
HF_CACHE_DIR="${WORKSPACE}/hf-cache"
OUTPUTS_DIR="${WORKSPACE}/outputs"

INSTALL_SENTINEL="${WORKSPACE}/.${ENV_NAME}-pip-installed-${BUILD_VERSION}"
WEIGHTS_SENTINEL="${WORKSPACE}/.${ENV_NAME}-weights-complete"
ACTIVATE_SCRIPT="${WORKSPACE}/activate.sh"

mkdir -p "${WORKSPACE}/envs" "${WEIGHTS_DIR}" "${HF_CACHE_DIR}" "${OUTPUTS_DIR}"

log()  { printf '\033[1;34m[bootstrap]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[bootstrap]\033[0m %s\n' "$*" >&2; }

# Phase flags (default: do everything except weight download until cycle 2)
DO_BUILD_KERNELS="${FREESPLATTER_BUILD_KERNELS:-1}"
DO_DOWNLOAD_WEIGHTS="${FREESPLATTER_DOWNLOAD_WEIGHTS:-0}"

# ─────────────────────────────────────────────────────────────
# 1. System packages (ephemeral — re-run on every pod start, ~10s)
# Custom CUDA kernels need: gcc, g++, build-essential, cuda toolkit.
# ffmpeg + libgl1 are runtime deps (rembg, open3d, gradio).
# ─────────────────────────────────────────────────────────────
log "Installing system packages (ephemeral, fast)"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
    build-essential ninja-build cmake pkg-config \
    ffmpeg git curl ca-certificates \
    libgl1 libglib2.0-0 \
    libegl1 libgles2 \
    tmux

# ─────────────────────────────────────────────────────────────
# 2. CUDA — use the base image's system install.
# RunPod's pytorch-* base images ship a CUDA-devel toolkit at /usr/local/cuda.
# FreeSplatter requires CUDA >= 12.1; base image's 12.x is fine.
# ─────────────────────────────────────────────────────────────
SYSTEM_CUDA="/usr/local/cuda"
if [[ ! -d "${SYSTEM_CUDA}" || ! -x "${SYSTEM_CUDA}/bin/nvcc" ]]; then
    warn "No system CUDA found at ${SYSTEM_CUDA}. The 3 custom kernels will fail to build."
    warn "If running on a non-pytorch base image, install nvidia-cuda-toolkit via apt or switch image."
    exit 1
fi
export CUDA_HOME="${SYSTEM_CUDA}"
export PATH="${CUDA_HOME}/bin:${PATH}"
export LD_LIBRARY_PATH="${CUDA_HOME}/lib64:${LD_LIBRARY_PATH:-}"
log "Using system CUDA at ${SYSTEM_CUDA} ($(nvcc --version | grep release | awk '{print $5,$6}' | tr -d ','))"

# ─────────────────────────────────────────────────────────────
# 3. uv — fast Python installer/venv. Lives in /workspace so it persists.
# ─────────────────────────────────────────────────────────────
UV_BIN="${WORKSPACE}/.local/bin/uv"
if [[ ! -x "${UV_BIN}" ]]; then
    log "Installing uv to ${WORKSPACE}/.local"
    UV_INSTALL_DIR="${WORKSPACE}/.local/bin" \
    XDG_DATA_HOME="${WORKSPACE}/.local/share" \
    UV_UNMANAGED_INSTALL="${WORKSPACE}/.local/bin" \
        bash -c 'curl -fsSL https://astral.sh/uv/install.sh | sh' 2>&1 | tail -5
    if [[ ! -x "${UV_BIN}" ]]; then
        # Fallback: uv installer may have placed it under ~/.local/bin (HOME=/root by default).
        if [[ -x "/root/.local/bin/uv" ]]; then
            mkdir -p "${WORKSPACE}/.local/bin"
            cp "/root/.local/bin/uv" "${UV_BIN}"
            log "Copied uv from /root/.local/bin/ to persistent location"
        else
            warn "uv install failed; check curl + script output above"
            exit 1
        fi
    fi
fi
export PATH="${WORKSPACE}/.local/bin:${PATH}"
log "uv: $(uv --version)"

# ─────────────────────────────────────────────────────────────
# 4. venv — create once, lives on volume
# ─────────────────────────────────────────────────────────────
if [[ ! -d "${ENV_DIR}" || ! -x "${ENV_DIR}/bin/python" ]]; then
    log "Creating venv at ${ENV_DIR} (Python ${PYTHON_VERSION})"
    uv venv --python "${PYTHON_VERSION}" "${ENV_DIR}"
fi
# shellcheck source=/dev/null
source "${ENV_DIR}/bin/activate"
log "Python: $(python --version)  ($(which python))"

# ─────────────────────────────────────────────────────────────
# 5. Repo — clone once, pull on subsequent runs
# ─────────────────────────────────────────────────────────────
if [[ ! -d "${REPO_DIR}/.git" ]]; then
    log "Cloning repo to ${REPO_DIR}"
    : "${REPO_REMOTE:?REPO_REMOTE env var must be set, e.g. https://github.com/voxeloai/FreeSplatter.git}"
    git clone "${REPO_REMOTE}" "${REPO_DIR}"
    cd "${REPO_DIR}"
    git remote add upstream "${UPSTREAM_REMOTE:-https://github.com/TencentARC/FreeSplatter.git}" 2>/dev/null || true
    git checkout voxelo/main 2>/dev/null || git checkout -b voxelo/main origin/voxelo/main
else
    log "Pulling latest on voxelo/main"
    cd "${REPO_DIR}"
    git checkout voxelo/main
    git pull --ff-only origin voxelo/main || warn "git pull non-fast-forward; check manually"
fi

# ─────────────────────────────────────────────────────────────
# 6. Python deps — gated by sentinel.
# Order matters: install torch first (the 3 git+https kernel packages
# require torch already importable to compile their CUDAExtensions), then
# xformers (pinned to 0.0.27.post2 from README, NOT the broken 0.0.22.post7
# in requirements.txt), then the rest with xformers filtered out.
# ─────────────────────────────────────────────────────────────
if [[ "${DO_BUILD_KERNELS}" = "1" && ! -f "${INSTALL_SENTINEL}" ]]; then
    log "Installing Python deps + building 3 custom CUDA kernels"
    log "  This is the slow part. Expect 5-10 min on A40."

    log "Step 6a: torch ${TORCH_VERSION} + torchvision ${TORCHVISION_VERSION} (cu121)"
    uv pip install \
        "torch==${TORCH_VERSION}" \
        "torchvision==${TORCHVISION_VERSION}" \
        --index-url "${TORCH_INDEX_URL}"

    log "Step 6b: xformers ${XFORMERS_VERSION} (pinned to README; requirements.txt is wrong)"
    uv pip install "xformers==${XFORMERS_VERSION}" --index-url "${TORCH_INDEX_URL}"

    log "Step 6c: build backends pre-installed (avoids --no-build-isolation gotchas)"
    uv pip install hatchling pathspec editables setuptools wheel ninja packaging

    log "Step 6d: split install — pure-pip deps first, then git+ kernels with --no-build-isolation"
    REQ_FILE="${REPO_DIR}/requirements.txt"
    if [[ ! -f "${REQ_FILE}" ]]; then
        warn "No requirements.txt at ${REQ_FILE}"
        exit 1
    fi
    # The 3 git+https kernel packages do `import torch` at setup.py load time,
    # so uv's default isolated build env (which lacks torch) fails them with
    # ModuleNotFoundError: No module named 'torch'. Solve by splitting:
    # pure deps go through normal resolution; git+ packages run with
    # --no-build-isolation against the venv (where torch is already installed
    # from step 6a).
    grep -v -E '^xformers' "${REQ_FILE}" | grep -v -E '^git\+' > /tmp/req-pure.txt
    grep -E '^git\+' "${REQ_FILE}" > /tmp/req-git.txt
    log "  Step 6d.1: $(wc -l < /tmp/req-pure.txt) pure-pip deps (normal isolation)"
    uv pip install -r /tmp/req-pure.txt
    log "  Step 6d.2: $(wc -l < /tmp/req-git.txt) git+ deps (--no-build-isolation; the 3 CUDA kernels compile here)"
    # NOTE: not setting TORCH_CUDA_ARCH_LIST — let nvcc auto-detect from the
    # pod's GPU. If GPU class changes later, delete the relevant site-packages
    # dirs and re-run with the sentinel removed.
    #
    # gcc 13 / CUDA 12.8 fix: the diff-gaussian-rasterization and
    # diff-surfel-rasterization headers use std::uintptr_t and uint32_t but
    # only include <iostream>, <vector>, <cuda_runtime_api.h>. Newer libstdc++
    # in gcc 13 doesn't transitively pull in <cstdint>, so compilation fails
    # with `namespace "std" has no member "uintptr_t"`. Force-include cstdint
    # via NVCC_PREPEND_FLAGS (applies to every nvcc call) and CXXFLAGS (applies
    # to the host gcc calls torch's build_ext spawns).
    export NVCC_PREPEND_FLAGS="${NVCC_PREPEND_FLAGS:-} -include cstdint"
    export CXXFLAGS="${CXXFLAGS:-} -include cstdint"
    uv pip install --no-build-isolation -r /tmp/req-git.txt
    rm -f /tmp/req-pure.txt /tmp/req-git.txt

    log "Step 6e: hf_transfer (HF_HUB_ENABLE_HF_TRANSFER=1 is set in base images)"
    uv pip install hf_transfer

    log "Step 6f: onnxruntime-gpu (rembg peer dep — upstream's requirements.txt is missing it)"
    # rembg is in requirements.txt but it lazy-imports onnxruntime at module
    # load time; importing freesplatter.utils.infer_util fails without it.
    # Pick the GPU build since we're on a CUDA pod and rembg matmul is hot.
    uv pip install onnxruntime-gpu

    touch "${INSTALL_SENTINEL}"
    log "Install + kernel build complete; sentinel: ${INSTALL_SENTINEL}"
elif [[ -f "${INSTALL_SENTINEL}" ]]; then
    log "Install sentinel exists; skipping pip install + kernel rebuild"
else
    log "FREESPLATTER_BUILD_KERNELS=0; skipping pip install + kernel build"
fi

# ─────────────────────────────────────────────────────────────
# 7. Model weights — sentinel-gated. Default OFF (cycle 2 turns it on).
# ─────────────────────────────────────────────────────────────
if [[ "${DO_DOWNLOAD_WEIGHTS}" = "1" && ! -f "${WEIGHTS_SENTINEL}" ]]; then
    log "Downloading model weights from HuggingFace: ${HF_REPO_ID}"
    if command -v hf >/dev/null 2>&1; then
        HF_HOME="${HF_CACHE_DIR}" hf download \
            "${HF_REPO_ID}" \
            --include "${HF_INCLUDE_PATTERN}" \
            --local-dir "${WEIGHTS_DIR}"
    else
        HF_HOME="${HF_CACHE_DIR}" huggingface-cli download \
            "${HF_REPO_ID}" \
            --include "${HF_INCLUDE_PATTERN}" \
            --local-dir "${WEIGHTS_DIR}"
    fi
    touch "${WEIGHTS_SENTINEL}"
    log "Weights downloaded; sentinel: ${WEIGHTS_SENTINEL}"
elif [[ -f "${WEIGHTS_SENTINEL}" ]]; then
    log "Weights sentinel exists; skipping download"
else
    log "FREESPLATTER_DOWNLOAD_WEIGHTS=0; skipping weights (cycle 2 will own this)"
fi

# ─────────────────────────────────────────────────────────────
# 8. Activation script — written/refreshed every run
# ─────────────────────────────────────────────────────────────
log "Writing ${ACTIVATE_SCRIPT}"
cat > "${ACTIVATE_SCRIPT}" <<EOF
# Source this after every pod start: \`source /workspace/activate.sh\`
export PATH="${WORKSPACE}/.local/bin:\${PATH}"
source ${ENV_DIR}/bin/activate
export HF_HOME=${HF_CACHE_DIR}
export PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True
export CUDA_HOME=${SYSTEM_CUDA}
export PATH="\${CUDA_HOME}/bin:\${PATH}"
export LD_LIBRARY_PATH="\${CUDA_HOME}/lib64:\${LD_LIBRARY_PATH:-}"
cd ${REPO_DIR}
EOF

log ""
log "Bootstrap complete."
log "Run: source ${ACTIVATE_SCRIPT}"
log ""
log "Quick verification:"
log "  python -c 'import torch; print(torch.__version__, torch.cuda.is_available())'"
log "  python -c 'import diff_gaussian_rasterization; import diff_surfel_rasterization; import nvdiffrast.torch as dr; print(\"kernels OK\")'"
log "  python -c 'from freesplatter.models.model import FreeSplatter; print(\"FreeSplatter import OK\")'"
