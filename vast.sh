#!/usr/bin/env bash
set -euo pipefail

# --- venv & paths ---
: "${WORKSPACE:=/workspace}"
source /venv/main/bin/activate
COMFYUI_DIR="${WORKSPACE}/ComfyUI"

# --- functions (define BEFORE any use) ---
get_files() {
  [[ $# -ge 2 ]] || return 0
  local dir="$1"; shift
  local urls=("$@")
  mkdir -p "$dir"
  echo "Downloading ${#urls[@]} file(s) to $dir..."
  for url in "${urls[@]}"; do
    local fname="$(basename "${url%%\?*}")"
    echo "Downloading: $fname"
    aria2c -x 16 -s 16 --continue=true -d "$dir" -o "$fname" "$url"
  done
}

get_nodes() {
  local repos=(
    "https://github.com/silveroxides/ComfyUI_PowerShiftScheduler"
    "https://github.com/feffy380/comfyui-chroma-cache"
  )
  mkdir -p "${COMFYUI_DIR}/custom_nodes"
  for repo in "${repos[@]}"; do
    local dir="${repo##*/}"
    local path="${COMFYUI_DIR}/custom_nodes/${dir}"
    local req="${path}/requirements.txt"
    if [[ -d $path ]]; then
      echo "Updating node: $repo"; ( cd "$path" && git pull )
    else
      echo "Cloning node: $repo"; git clone "$repo" "$path" --recursive
    fi
    if [[ -e $req ]]; then
      echo "Installing node requirements for ${dir}..."
      # Non-fatal on node deps
      pip install --no-cache-dir -r "$req" || echo "[WARN] node deps failed for ${dir}, continuing"
    fi
  done
}

# --- model lists ---
VAE_MODELS=("https://huggingface.co/lodestones/Chroma/resolve/main/ae.safetensors")
TEXT_ENCODER_MODELS=(
  "https://huggingface.co/comfyanonymous/flux_text_encoders/resolve/main/t5xxl_fp16.safetensors"
)
DIFFUSION_MODELS=("https://huggingface.co/lodestones/Chroma1-Base/resolve/main/Chroma1-Base.safetensors")

# --- logging ---
LOGDIR="/var/log/portal"
STATUSDIR="${LOGDIR}/prov-status"
mkdir -p "$LOGDIR" "$STATUSDIR"

echo "### Provisioning (non-fatal parallel) ###"

# ensure aria2 (no global apt-get update)
if ! command -v aria2c >/dev/null 2>&1; then
  sudo apt-get install -y aria2
fi

# remove default ckpt if present
rm -f "${COMFYUI_DIR}/models/ckpt/realvisxlV50_v50LightningBakedvae.safetensors"

# --- PARALLEL: model downloads + pip (venv active) ---
pids=(); names=()

(
  get_files "${COMFYUI_DIR}/models/vae" "${VAE_MODELS[@]}"; ec=$?
  echo "$ec" > "${STATUSDIR}/dl_vae.exit"
) > "${LOGDIR}/dl_vae.log" 2>&1 & pids+=("$!"); names+=("dl_vae")

(
  get_files "${COMFYUI_DIR}/models/text_encoders" "${TEXT_ENCODER_MODELS[@]}"; ec=$?
  echo "$ec" > "${STATUSDIR}/dl_text_enc.exit"
) > "${LOGDIR}/dl_text_enc.log" 2>&1 & pids+=("$!"); names+=("dl_text_enc")

(
  get_files "${COMFYUI_DIR}/models/diffusion_models" "${DIFFUSION_MODELS[@]}"; ec=$?
  echo "$ec" > "${STATUSDIR}/dl_diff.exit"
) > "${LOGDIR}/dl_diff.log" 2>&1 & pids+=("$!"); names+=("dl_diff")

(
  pip install --no-cache-dir -r "${COMFYUI_DIR}/requirements.txt"; ec=$?
  echo "$ec" > "${STATUSDIR}/pip_reqs.exit"
) > "${LOGDIR}/pip_reqs.log" 2>&1 & pids+=("$!"); names+=("pip_reqs")

# wait for all (do NOT fail the script)
for pid in "${pids[@]}"; do wait "$pid" || true; done

# summary
echo "----- Provisioning task summary -----"
for n in "${names[@]}"; do
  ec="$(cat "${STATUSDIR}/${n}.exit" 2>/dev/null || echo 1)"
  if [[ "$ec" -eq 0 ]]; then
    echo "[OK]   ${n}"
  else
    echo "[FAIL] ${n} (exit ${ec}) -> see ${LOGDIR}/${n}.log"
  fi
done

# nodes last (non-fatal)
get_nodes

echo "Provisioning complete (non-fatal mode)."
