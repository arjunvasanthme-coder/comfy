#!/bin/bash

set -euo pipefail

### Configuration ###
WORKSPACE_DIR="${WORKSPACE:-/workspace}"
COMFYUI_DIR="${WORKSPACE_DIR}/ComfyUI"
MODELS_DIR="${COMFYUI_DIR}/models"
HF_SEMAPHORE_DIR="${WORKSPACE_DIR}/hf_download_sem_$$"
HF_MAX_PARALLEL=3

# Model declarations: "URL|OUTPUT_PATH"
HF_MODELS=(
  "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors|$MODELS_DIR/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors"
  "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/vae/wan_2.1_vae.safetensors|$MODELS_DIR/vae/wan_2.1_vae.safetensors"

  "https://huggingface.co/lightx2v/Wan2.2-Distill-Models/resolve/main/wan2.2_i2v_A14b_high_noise_scaled_fp8_e4m3_lightx2v_4step_comfyui.safetensors|$MODELS_DIR/diffusion_models/wan2.2_i2v_A14b_high_noise_scaled_fp8_e4m3_lightx2v_4step_comfyui.safetensors"
  "https://huggingface.co/lightx2v/Wan2.2-Distill-Models/resolve/main/wan2.2_i2v_A14b_low_noise_scaled_fp8_e4m3_lightx2v_4step_comfyui.safetensors|$MODELS_DIR/diffusion_models/wan2.2_i2v_A14b_low_noise_scaled_fp8_e4m3_lightx2v_4step_comfyui.safetensors"

  "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/LoRAs/Stable-Video-Infinity/v2.0/SVI_v2_PRO_Wan2.2-I2V-A14B_HIGH_lora_rank_128_fp16.safetensors|$MODELS_DIR/loras/SVI_v2_PRO_Wan2.2-I2V-A14B_HIGH_lora_rank_128_fp16.safetensors"
  "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/LoRAs/Stable-Video-Infinity/v2.0/SVI_v2_PRO_Wan2.2-I2V-A14B_LOW_lora_rank_128_fp16.safetensors|$MODELS_DIR/loras/SVI_v2_PRO_Wan2.2-I2V-A14B_LOW_lora_rank_128_fp16.safetensors"
)
### End Configuration ###

script_cleanup() {
   rm -rf "$HF_SEMAPHORE_DIR"
}

# If this script fails we cannot let a serverless worker be marked as ready.
script_error() {
    local exit_code=$?
    local line_number=$1
    echo "[ERROR] Provisioning Script failed at line $line_number with exit code $exit_code" | tee -a "${MODEL_LOG:-/var/log/portal/comfyui.log}"
}

trap script_cleanup EXIT
trap 'script_error $LINENO' ERR

main() {
    . /venv/main/bin/activate
    mkdir -p "$HF_SEMAPHORE_DIR"
    pids=()
    # Download all models in parallel
    for model in "${HF_MODELS[@]}"; do
        url="${model%%|*}"
        output_path="${model##*|}"
        download_hf_file "$url" "$output_path" &
        pids+=($!)
    done
    
    # Wait for each job and check exit status
    for pid in "${pids[@]}"; do
        wait "$pid" || exit 1
    done
}

# HuggingFace download helper
# replace download_hf_file/acquire_slot/release_slot with this

download_hf_file() {
  local url="$1"
  local output_path="$2"
  local lockfile="${output_path}.lock"
  local max_retries=5
  local retry_delay=2
  local slot=""
  local temp_dir=""

  cleanup_download() {
    local rc=$?
    [ -n "${temp_dir:-}" ] && rm -rf "$temp_dir"
    [ -n "${slot:-}" ] && release_slot "$slot"
    rmdir "$lockfile" 2>/dev/null || true
    return "$rc"
  }

  slot="$(acquire_slot)"
  trap cleanup_download RETURN

  mkdir -p "$(dirname "$output_path")"

  while ! mkdir "$lockfile" 2>/dev/null; do
    if [ -f "$output_path" ]; then
      echo "File already exists: $output_path (skipping)"
      return 0
    fi
    echo "Another process is downloading to $output_path (waiting...)"
    sleep 1
  done

  if [ -f "$output_path" ]; then
    echo "File already exists: $output_path (skipping)"
    return 0
  fi

  local repo
  local file_path

  repo="$(echo "$url" | tr -d '[:space:]' | sed -n 's|https://huggingface.co/\([^/]*/[^/]*\)/resolve/.*|\1|p')"
  file_path="$(echo "$url" | tr -d '[:space:]' | sed -n 's|https://huggingface.co/[^/]*/[^/]*/resolve/[^/]*/\(.*\)|\1|p')"

  if [ -z "$repo" ] || [ -z "$file_path" ]; then
    echo "ERROR: Invalid HuggingFace URL: $url"
    return 1
  fi

  temp_dir="$(mktemp -d)"

  local attempt=1
  while [ "$attempt" -le "$max_retries" ]; do
    echo "Downloading $file_path (attempt $attempt/$max_retries)..."

  if hf download "$repo" "$file_path" --local-dir "$temp_dir"; then
    mkdir -p "$(dirname "$output_path")"
  
    if [ ! -f "$temp_dir/$file_path" ]; then
      echo "ERROR: downloaded file not found: $temp_dir/$file_path"
      return 1
    fi
  
    mv "$temp_dir/$file_path" "$output_path"
    echo "✓ Successfully downloaded: $output_path"
    return 0
  fi

    echo "✗ Download failed (attempt $attempt/$max_retries), retrying in ${retry_delay}s..."
    sleep "$retry_delay"
    retry_delay=$((retry_delay * 2))
    attempt=$((attempt + 1))
  done

  echo "ERROR: Failed to download $output_path after $max_retries attempts"
  return 1
}

acquire_slot() {
  mkdir -p "$HF_SEMAPHORE_DIR"

  while true; do
    for i in $(seq 1 "$HF_MAX_PARALLEL"); do
      local slot="$HF_SEMAPHORE_DIR/slot_$i"
      if mkdir "$slot" 2>/dev/null; then
        echo "$slot"
        return 0
      fi
    done
    sleep 0.5
  done
}

release_slot() {
  rmdir "$1" 2>/dev/null || true
}


main
