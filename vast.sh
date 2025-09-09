#!/bin/bash
set -euo pipefail

source /venv/main/bin/activate
COMFYUI_DIR="${WORKSPACE}/ComfyUI"

# --- CONFIG ---
NODES=(
  "https://github.com/silveroxides/ComfyUI_PowerShiftScheduler"
  "https://github.com/feffy380/comfyui-chroma-cache"
)
VAE_MODELS=("https://huggingface.co/lodestones/Chroma/resolve/main/ae.safetensors")
TEXT_ENCODER_MODELS=(
  "https://huggingface.co/comfyanonymous/flux_text_encoders/resolve/main/t5xxl_fp16.safetensors"
  "https://huggingface.co/silveroxides/flan-t5-xxl-encoder-only/resolve/main/flan-t5-xxl-fp16.safetensors"
)
DIFFUSION_MODELS=("https://huggingface.co/lodestones/Chroma/resolve/main/chroma-unlocked-v48.safetensors")
STRICT_NODES="${STRICT_NODES:-0}" # 0=warn & continue on node deps

LOGDIR="/var/log/portal"
mkdir -p "$LOGDIR"
STATUSDIR="${LOGDIR}/prov-status"
mkdir -p "$STATUSDIR"

# --- helpers ---
run_bg() {
  # usage: run_bg <name> <command...>
  local name="$1"; shift
  ( 
    # subshell: run task, capture exit, write status
    "$@"; ec=$?
    echo "$ec" > "${STATUSDIR}/${name}.exit"
  ) >"${LOGDIR}/${name}.log" 2>&1 &
  echo $!
}

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
  for repo in "${NODES[@]}"; do
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
      if [[ "$STRICT_NODES" = "1" ]]; then
        pip install --no-cache-dir -r "$req"
      else
        pip install --no-cache-dir -r "$req" || echo "[WARN] node deps failed for ${dir}, continuing"
      fi
    fi
  done
}

provisioning_start() {
  echo "##############################################"
  echo "# Provisioning container start (non-fatal)   #"
  echo "##############################################"

  # ensure aria2 (no apt-get update)
  command -v aria2c >/dev/null || sudo apt-get install -y aria2

  # remove Vast’s default ckpt if present
  rm -f "${COMFYUI_DIR}/models/ckpt/realvisxlV50_v50LightningBakedvae.safetensors" || true

  # --- PARALLEL: start 3 downloads + pip ---
  pids=()
  pids+=("$(run_bg dl_vae      bash -lc 'get_files \"${COMFYUI_DIR}/models/vae\"              \"${VAE_MODELS[@]}\"')")
  pids+=("$(run_bg dl_text_enc bash -lc 'get_files \"${COMFYUI_DIR}/models/text_encoders\"    \"${TEXT_ENCODER_MODELS[@]}\"')")
  pids+=("$(run_bg dl_diff     bash -lc 'get_files \"${COMFYUI_DIR}/models/diffusion_models\" \"${DIFFUSION_MODELS[@]}\"')")
  pids+=("$(run_bg pip_reqs    bash -lc 'pip install --no-cache-dir -r \"${COMFYUI_DIR}/requirements.txt\"')")

  # wait for all (don’t fail the script)
  for pid in "${pids[@]}"; do wait "$pid" || true; done

  # summary
  echo "----- Provisioning task summary -----"
  failed_any=0
  for f in "${STATUSDIR}"/*.exit; do
    [[ -e "$f" ]] || continue
    name="$(basename "$f" .exit)"
    ec="$(cat "$f")"
    if [[ "$ec" -eq 0 ]]; then
      echo "[OK]   ${name}"
    else
      echo "[FAIL] ${name} (exit ${ec}) -> see ${LOGDIR}/${name}.log"
      failed_any=1
    fi
  done
  [[ "$failed_any" -eq 1 ]] && echo "[WARN] One or more steps failed; continuing anyway."

  # nodes last (never fatal)
  get_nodes

  echo "Provisioning complete (non-fatal mode)."
}

# main
[[ ! -f /.noprovisioning ]] && provisioning_start
