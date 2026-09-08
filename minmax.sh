#!/bin/bash

set -euo pipefail

### Configuration ###
WORKSPACE_DIR="${WORKSPACE:-/workspace}"
COMFYUI_DIR="${WORKSPACE_DIR}/ComfyUI"
MODELS_DIR="${COMFYUI_DIR}/models"
CUSTOM_NODES_DIR="${COMFYUI_DIR}/custom_nodes"

HF_SEMAPHORE_DIR="${WORKSPACE_DIR}/hf_download_sem_$$"
HF_MAX_PARALLEL=3

# MiniMax H3 models + Turbo LoRA + encoders.
#
# Includes:
# - FL2VA INT8 ConvRot: T2V / I2V
# - Ref2VA INT8 ConvRot
# - Official Qwen NVFP4 encoder
# - Ultra-Uncensored Heretic Qwen INT8 ConvRot encoder
# - LightX2V H3 FL2V Turbo 8-step LoRA
# - H3 video/audio VAEs
HF_MODELS=(
  # H3 diffusion models
  "https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main/diffusion_models/minimax_h3_fl2va_pruned_int8_convrot.safetensors|$MODELS_DIR/diffusion_models/minimax_h3_fl2va_pruned_int8_convrot.safetensors"
  "https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main/diffusion_models/minimax_h3_ref2va_pruned_int8_convrot.safetensors|$MODELS_DIR/diffusion_models/minimax_h3_ref2va_pruned_int8_convrot.safetensors"

  # Official Qwen encoder — keep for A/B comparison
  #"https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main/text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors|$MODELS_DIR/text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors"

  # Ultra-Uncensored Heretic H3 Qwen encoder
  "https://huggingface.co/ethanfel/Qwen3-VL-32B-Ultra-Heretic-H3-ComfyUI-INT8-ConvRot/resolve/main/qwen3vl_32b_h3_ultra_uncensored_heretic_int8_convrot.safetensors|$MODELS_DIR/text_encoders/qwen3vl_32b_h3_ultra_uncensored_heretic_int8_convrot.safetensors"

  # LightX2V MiniMax H3 FL2V Turbo 8-step LoRA
  "https://huggingface.co/lightx2v/Minimax-h3-Turbo/resolve/main/minimax_h3_fl2v_turbo_8step_v1.0_comfyui_bf16.safetensors|$MODELS_DIR/loras/minimax_h3_fl2v_turbo_8step_v1.0_comfyui_bf16.safetensors"

  # VAEs
  "https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main/vae/minimax_h3_video_vae_fp16.safetensors|$MODELS_DIR/vae/minimax_h3_video_vae_fp16.safetensors"
  "https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main/vae/minimax_h3_audio_vae_fp32.safetensors|$MODELS_DIR/vae/minimax_h3_audio_vae_fp32.safetensors"
)

# Custom nodes: "REPO_URL|DIRECTORY_NAME"
CUSTOM_NODES=(
  "https://github.com/NikoDemon80/ComfyUI-H3-Motion-Context.git|ComfyUI-H3-Motion-Context"
)

### End Configuration ###


script_cleanup() {
  rm -rf "$HF_SEMAPHORE_DIR"
}

# If this script fails we cannot let a serverless worker be marked as ready.
script_error() {
  local exit_code=$?
  local line_number=$1

  echo "[ERROR] Provisioning Script failed at line $line_number with exit code $exit_code" \
    | tee -a "${MODEL_LOG:-/var/log/portal/comfyui.log}"
}

trap script_cleanup EXIT
trap 'script_error $LINENO' ERR


main() {
  . /venv/main/bin/activate

  mkdir -p "$HF_SEMAPHORE_DIR"
  mkdir -p "$CUSTOM_NODES_DIR"

  # Install/update custom nodes while HF models download.
  install_custom_nodes &
  local custom_nodes_pid=$!

  # Download all models in parallel, bounded by HF_MAX_PARALLEL.
  local pids=()

  for model in "${HF_MODELS[@]}"; do
    local url="${model%%|*}"
    local output_path="${model##*|}"

    download_hf_file "$url" "$output_path" &
    pids+=($!)
  done

  # Wait for model downloads.
  for pid in "${pids[@]}"; do
    wait "$pid" || exit 1
  done

  # Ensure custom node install also succeeded.
  wait "$custom_nodes_pid" || exit 1

  echo
  echo "========================================="
  echo "MiniMax H3 provisioning complete"
  echo "========================================="
}


install_custom_nodes() {
  for node in "${CUSTOM_NODES[@]}"; do
    local repo_url="${node%%|*}"
    local directory_name="${node##*|}"
    local target_dir="$CUSTOM_NODES_DIR/$directory_name"

    if [ -d "$target_dir/.git" ]; then
      echo "Updating custom node: $directory_name"

      # Avoid breaking provisioning if upstream history was rewritten.
      git -C "$target_dir" fetch --depth=1 origin
      git -C "$target_dir" reset --hard origin/HEAD
    else
      echo "Installing custom node: $directory_name"

      rm -rf "$target_dir"
      git clone --depth=1 "$repo_url" "$target_dir"
    fi

    # Generic support for nodes that later gain Python dependencies.
    if [ -f "$target_dir/requirements.txt" ]; then
      echo "Installing requirements for: $directory_name"
      pip install -r "$target_dir/requirements.txt"
    fi
  done
}


# Hugging Face download helper.
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

  repo="$(
    echo "$url" |
      tr -d '[:space:]' |
      sed -n 's|https://huggingface.co/\([^/]*/[^/]*\)/resolve/.*|\1|p'
  )"

  file_path="$(
    echo "$url" |
      tr -d '[:space:]' |
      sed -n 's|https://huggingface.co/[^/]*/[^/]*/resolve/[^/]*/\(.*\)|\1|p'
  )"

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
