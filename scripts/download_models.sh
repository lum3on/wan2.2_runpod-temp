#!/bin/bash
set -e

echo "========================================="
echo "WAN 2.2 Model Downloader"
echo "========================================="

# Model storage directory (use RunPod's persistent /workspace if available)
if [ -d "/workspace" ]; then
    MODEL_DIR="/workspace/models"
    echo "✅ Using RunPod persistent storage: /workspace/models"
else
    MODEL_DIR="/comfyui/models"
    echo "⚠️  Using container storage: /comfyui/models"
fi

# Create ALL ComfyUI model directories for maximum compatibility
echo "📁 Creating complete ComfyUI model folder structure..."
mkdir -p \
    "$MODEL_DIR/checkpoints" \
    "$MODEL_DIR/clip" \
    "$MODEL_DIR/clip_vision" \
    "$MODEL_DIR/configs" \
    "$MODEL_DIR/controlnet" \
    "$MODEL_DIR/diffusers" \
    "$MODEL_DIR/embeddings" \
    "$MODEL_DIR/gligen" \
    "$MODEL_DIR/hypernetworks" \
    "$MODEL_DIR/loras" \
    "$MODEL_DIR/style_models" \
    "$MODEL_DIR/unet" \
    "$MODEL_DIR/upscale_models" \
    "$MODEL_DIR/vae" \
    "$MODEL_DIR/vae_approx" \
    "$MODEL_DIR/animatediff_models" \
    "$MODEL_DIR/animatediff_motion_lora" \
    "$MODEL_DIR/ipadapter" \
    "$MODEL_DIR/photomaker" \
    "$MODEL_DIR/sams" \
    "$MODEL_DIR/insightface" \
    "$MODEL_DIR/facerestore_models" \
    "$MODEL_DIR/facedetection" \
    "$MODEL_DIR/mmdets" \
    "$MODEL_DIR/instantid" \
    "$MODEL_DIR/text_encoders" \
    "$MODEL_DIR/diffusion_models"

# Symlink to ComfyUI models directory if using /workspace
if [ "$MODEL_DIR" != "/comfyui/models" ]; then
    echo "Creating symlinks to ComfyUI models directory..."
    rm -rf /comfyui/models
    ln -sf "$MODEL_DIR" /comfyui/models
fi

# Function to download model if it doesn't exist
download_model() {
    local url=$1
    local output=$2
    local name=$(basename "$output")

    if [ -f "$output" ]; then
        echo "✅ $name already exists, skipping..."
        return 0
    fi

    echo "📥 Downloading $name..."

    # Try huggingface-cli first for HuggingFace URLs (much faster)
    if [[ "$url" == *"huggingface.co"* ]] && command -v huggingface-cli &> /dev/null; then
        echo "   Using huggingface-cli (fast HF transfer)..."

        # Extract repo and file path from URL
        # URL format: https://huggingface.co/REPO/resolve/main/PATH
        local repo=$(echo "$url" | sed -n 's|.*huggingface.co/\([^/]*/[^/]*\)/resolve.*|\1|p')
        local file_path=$(echo "$url" | sed -n 's|.*resolve/main/\(.*\)|\1|p')

        if [ -n "$repo" ] && [ -n "$file_path" ]; then
            local temp_dir=$(mktemp -d)
            huggingface-cli download "$repo" "$file_path" \
                --local-dir "$temp_dir" \
                --local-dir-use-symlinks False \
                --quiet 2>&1 | grep -v "Fetching" || true

            # Move downloaded file to target location
            local downloaded_file="$temp_dir/$file_path"
            if [ -f "$downloaded_file" ]; then
                mv "$downloaded_file" "$output"
                rm -rf "$temp_dir"
                echo "✅ Downloaded $name"
                return 0
            else
                echo "   ⚠️  huggingface-cli failed, falling back to aria2c..."
                rm -rf "$temp_dir"
            fi
        fi
    fi

    # Try aria2c (faster with multi-connection downloads)
    if command -v aria2c &> /dev/null; then
        echo "   Using aria2c (multi-connection download)..."
        aria2c \
            --console-log-level=error \
            --summary-interval=10 \
            --max-connection-per-server=32 \
            --split=32 \
            --min-split-size=1M \
            --max-concurrent-downloads=1 \
            --continue=true \
            --allow-overwrite=true \
            --auto-file-renaming=false \
            --out="$output" \
            "$url" 2>&1 | grep -E "(Download complete|ERROR)" || true

        if [ -f "$output" ]; then
            echo "✅ Downloaded $name"
            return 0
        else
            echo "   ⚠️  aria2c failed, falling back to wget..."
        fi
    fi

    # Fallback to wget with improved progress display
    echo "   Using wget (single-connection download)..."
    wget --progress=dot:giga --show-progress -O "$output" "$url"
    echo "✅ Downloaded $name"
}

# Parallel download manager (up to 6 concurrent downloads)
download_parallel() {
    local max_parallel=6
    local -a pids=()

    for args in "$@"; do
        # Wait if we've hit the parallel limit
        while [ ${#pids[@]} -ge $max_parallel ]; do
            for i in "${!pids[@]}"; do
                if ! kill -0 "${pids[$i]}" 2>/dev/null; then
                    unset 'pids[$i]'
                fi
            done
            pids=("${pids[@]}")  # Re-index array
            sleep 0.5
        done

        # Start download in background
        eval "download_model $args" &
        pids+=($!)
    done

    # Wait for all remaining downloads
    for pid in "${pids[@]}"; do
        wait "$pid" 2>/dev/null || true
    done
}

echo ""
echo "========================================="
echo "Downloading WAN 2.2 Models (~80GB total)"
echo "========================================="
echo ""
if command -v huggingface-cli &> /dev/null; then
    echo "Download method: huggingface-cli (fastest) + aria2c (32 connections) + parallel (6 concurrent)"
else
    echo "Download method: aria2c (32 connections) + parallel (6 concurrent)"
fi
echo ""

# Prepare download list for parallel execution
echo "📦 Preparing to download diffusion models (fp16 + fp8_scaled)..."

# Diffusion Models - Download in parallel (4 large models)
download_parallel \
    "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/diffusion_models/wan2.2_t2v_high_noise_14B_fp16.safetensors $MODEL_DIR/diffusion_models/wan2.2_t2v_high_noise_14B_fp16.safetensors" \
    "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/diffusion_models/wan2.2_t2v_low_noise_14B_fp16.safetensors $MODEL_DIR/diffusion_models/wan2.2_t2v_low_noise_14B_fp16.safetensors" \
    "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/diffusion_models/wan2.2_t2v_high_noise_14B_fp8_scaled.safetensors $MODEL_DIR/diffusion_models/wan2.2_t2v_high_noise_14B_fp8_scaled.safetensors" \
    "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/diffusion_models/wan2.2_t2v_low_noise_14B_fp8_scaled.safetensors $MODEL_DIR/diffusion_models/wan2.2_t2v_low_noise_14B_fp8_scaled.safetensors"

# Text Encoders, VAE, LoRAs, and Upscale Models - Download in parallel
echo "📦 Downloading text encoders, VAE, LoRAs, and upscale models..."
download_parallel \
    "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/text_encoders/umt5_xxl_fp16.safetensors $MODEL_DIR/text_encoders/umt5_xxl_fp16.safetensors" \
    "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors $MODEL_DIR/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors" \
    "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/vae/wan_2.1_vae.safetensors $MODEL_DIR/vae/wan_2.1_vae.safetensors" \
    "https://huggingface.co/yo9otatara/model/resolve/main/Instareal_high.safetensors $MODEL_DIR/loras/Instareal_high.safetensors" \
    "https://huggingface.co/yo9otatara/model/resolve/main/Instareal_low.safetensors $MODEL_DIR/loras/Instareal_low.safetensors" \
    "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/Lightx2v/lightx2v_T2V_14B_cfg_step_distill_v2_lora_rank256_bf16.safetensors $MODEL_DIR/loras/lightx2v_T2V_14B_cfg_step_distill_v2_lora_rank256_bf16.safetensors"

echo "📦 Downloading upscale models..."
download_parallel \
    "https://huggingface.co/yo9otatara/model/resolve/main/4xNomosUniDAT_otf.pth $MODEL_DIR/upscale_models/4xNomosUniDAT_otf.pth" \
    "https://huggingface.co/yo9otatara/model/resolve/main/4x-ClearRealityV1.pth $MODEL_DIR/upscale_models/4x-ClearRealityV1.pth" \
    "https://huggingface.co/yo9otatara/model/resolve/main/1xSkinContrast-High-SuperUltraCompact.pth $MODEL_DIR/upscale_models/1xSkinContrast-High-SuperUltraCompact.pth" \
    "https://huggingface.co/yo9otatara/model/resolve/main/1xDeJPG_realplksr_otf.safetensors $MODEL_DIR/upscale_models/1xDeJPG_realplksr_otf.safetensors" \
    "https://huggingface.co/yo9otatara/model/resolve/main/4x-UltraSharpV2_Lite.pth $MODEL_DIR/upscale_models/4x-UltraSharpV2_Lite.pth"

echo ""
echo "========================================="
echo "✅ All models downloaded successfully!"
echo "========================================="
echo ""
echo "Model directory: $MODEL_DIR"
echo "Total models: $(find "$MODEL_DIR" -type f | wc -l)"
echo ""

