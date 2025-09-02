#!/bin/bash
set -euo pipefail

source /venv/main/bin/activate
COMFYUI_DIR="${WORKSPACE}/ComfyUI"

# ---- YOUR CONFIG (minimal) ----

APT_PACKAGES=(aria2 git)

PIP_PACKAGES=()

NODES=(
  "https://github.com/silveroxides/ComfyUI_PowerShiftScheduler"
  "https://github.com/feffy380/comfyui-chroma-cache"
)

WORKFLOWS=()

CHECKPOINT_MODELS=()   # none
UNET_MODELS=()         # none
LORA_MODELS=()         # skipped for now
VAE_MODELS=(
  "https://huggingface.co/lodestones/Chroma/resolve/main/ae.safetensors"
)
ESRGAN_MODELS=()
CONTROLNET_MODELS=()

TEXT_ENCODER_MODELS=(
  "https://huggingface.co/comfyanonymous/flux_text_encoders/resolve/main/t5xxl_fp16.safetensors"
)

DIFFUSION_MODELS=(
  "https://huggingface.co/lodestones/Chroma/resolve/main/chroma-unlocked-v48.safetensors"
)

### DO NOT EDIT BELOW HERE UNLESS YOU KNOW WHAT YOU ARE DOING ###

function provisioning_start() {
    provisioning_print_header
    provisioning_get_apt_packages
    provisioning_get_nodes
    provisioning_get_pip_packages

    # Install ComfyUI’s requirements
    pip install --no-cache-dir -r "${COMFYUI_DIR}/requirements.txt"

    # Remove stale ckpt
    rm -f "${COMFYUI_DIR}/models/ckpt/realvisxlV50_v50LightningBakedvae.safetensors" || true

    # Model categories
    provisioning_get_files "${COMFYUI_DIR}/models/checkpoints"   "${CHECKPOINT_MODELS[@]}"
    provisioning_get_files "${COMFYUI_DIR}/models/unet"          "${UNET_MODELS[@]}"
    provisioning_get_files "${COMFYUI_DIR}/models/lora"          "${LORA_MODELS[@]}"
    provisioning_get_files "${COMFYUI_DIR}/models/controlnet"    "${CONTROLNET_MODELS[@]}"
    provisioning_get_files "${COMFYUI_DIR}/models/vae"           "${VAE_MODELS[@]}"
    provisioning_get_files "${COMFYUI_DIR}/models/esrgan"        "${ESRGAN_MODELS[@]}"
    provisioning_get_files "${COMFYUI_DIR}/models/text_encoders" "${TEXT_ENCODER_MODELS[@]}"
    provisioning_get_files "${COMFYUI_DIR}/models/diffusion_models" "${DIFFUSION_MODELS[@]}"

    provisioning_print_end
}

function provisioning_get_apt_packages() {
    if [[ ${#APT_PACKAGES[@]} -gt 0 ]]; then
        sudo apt-get update -y
        sudo apt-get install -y "${APT_PACKAGES[@]}"
    fi
}

function provisioning_get_pip_packages() {
    if [[ ${#PIP_PACKAGES[@]} -gt 0 ]]; then
        pip install --no-cache-dir "${PIP_PACKAGES[@]}"
    fi
}

function provisioning_get_nodes() {
    for repo in "${NODES[@]}"; do
        dir="${repo##*/}"
        path="${COMFYUI_DIR}/custom_nodes/${dir}"
        requirements="${path}/requirements.txt"
        if [[ -d $path ]]; then
            if [[ ${AUTO_UPDATE,,} != "false" ]]; then
                echo "Updating node: $repo"
                ( cd "$path" && git pull )
                [[ -e $requirements ]] && pip install --no-cache-dir -r "$requirements"
            fi
        else
            echo "Cloning node: $repo"
            git clone "$repo" "$path" --recursive
            [[ -e $requirements ]] && pip install --no-cache-dir -r "$requirements"
        fi
    done
}

function provisioning_get_files() {
    if [[ $# -lt 2 ]]; then return 0; fi
    dir="$1"
    shift
    urls=("$@")
    mkdir -p "$dir"
    echo "Downloading ${#urls[@]} file(s) to $dir..."
    for url in "${urls[@]}"; do
        filename="$(basename "${url%%\?*}")"
        echo "Downloading: $filename"
        aria2c -x 16 -s 16 --continue=true -d "$dir" -o "$filename" "$url"
    done
}

function provisioning_print_header() {
    echo -e "\n##############################################"
    echo "#          Provisioning container            #"
    echo "##############################################"
}

function provisioning_print_end() {
    echo -e "\nProvisioning complete: Application will start now\n"
}

# Run provisioning unless disabled
if [[ ! -f /.noprovisioning ]]; then
    provisioning_start
fi
