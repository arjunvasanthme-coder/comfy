#!/bin/bash
set -euo pipefail

source /venv/main/bin/activate
COMFYUI_DIR="${WORKSPACE}/ComfyUI"

# ---- CONFIG ----

NODES=(
  "https://github.com/silveroxides/ComfyUI_PowerShiftScheduler"
  "https://github.com/feffy380/comfyui-chroma-cache"
)

VAE_MODELS=(
  "https://huggingface.co/lodestones/Chroma/resolve/main/ae.safetensors"
)

TEXT_ENCODER_MODELS=(
  "https://huggingface.co/comfyanonymous/flux_text_encoders/resolve/main/t5xxl_fp16.safetensors"
  "https://huggingface.co/silveroxides/flan-t5-xxl-encoder-only/resolve/main/flan-t5-xxl-fp16.safetensors"
)

DIFFUSION_MODELS=(
  "https://huggingface.co/lodestones/Chroma/resolve/main/chroma-unlocked-v48.safetensors"
)

### --- FUNCTIONS --- ###

function provisioning_start() {
    provisioning_print_header

    # install aria2 if missing, no apt-get update
    if ! command -v aria2c >/dev/null; then
        sudo apt-get install -y aria2
    fi

    provisioning_get_nodes

    # install ComfyUI deps
    pip install --no-cache-dir -r "${COMFYUI_DIR}/requirements.txt"

    # remove old ckpt
    rm -f "${COMFYUI_DIR}/models/ckpt/realvisxlV50_v50LightningBakedvae.safetensors" || true

    # downloads
    provisioning_get_files "${COMFYUI_DIR}/models/vae"           "${VAE_MODELS[@]}"
    provisioning_get_files "${COMFYUI_DIR}/models/text_encoders" "${TEXT_ENCODER_MODELS[@]}"
    provisioning_get_files "${COMFYUI_DIR}/models/diffusion_models" "${DIFFUSION_MODELS[@]}"

    provisioning_print_end
}

function provisioning_get_nodes() {
    for repo in "${NODES[@]}"; do
        dir="${repo##*/}"
        path="${COMFYUI_DIR}/custom_nodes/${dir}"
        requirements="${path}/requirements.txt"
        if [[ -d $path ]]; then
            echo "Updating node: $repo"
            ( cd "$path" && git pull )
            [[ -e $requirements ]] && pip install --no-cache-dir -r "$requirements"
        else
            echo "Cloning node: $repo"
            git clone "$repo" "$path" --recursive
            [[ -e $requirements ]] && pip install --no-cache-dir -r "$requirements"
        fi
    done
}

function provisioning_get_files() {
    if [[ $# -lt 2 ]]; then return 0; fi
    dir="$1"; shift
    urls=("$@")
    mkdir -p "$dir"
    for url in "${urls[@]}"; do
        filename="$(basename "${url%%\?*}")"
        echo "Downloading $filename"
        aria2c -x 16 -s 16 --continue=true -d "$dir" -o "$filename" "$url"
    done
}

function provisioning_print_header() {
    echo "##############################################"
    echo "#        Provisioning container start         #"
    echo "##############################################"
}

function provisioning_print_end() {
    echo "Provisioning complete."
}

### --- MAIN --- ###
if [[ ! -f /.noprovisioning ]]; then
    provisioning_start
fi
