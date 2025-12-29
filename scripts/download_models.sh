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

# Function to get human-readable file size
get_file_size() {
    local file=$1
    if [ -f "$file" ]; then
        local size=$(stat -c%s "$file" 2>/dev/null || stat -f%z "$file" 2>/dev/null || echo "0")
        if [ "$size" -ge 1073741824 ]; then
            echo "$(awk "BEGIN {printf \"%.2f\", $size/1073741824}") GB"
        elif [ "$size" -ge 1048576 ]; then
            echo "$(awk "BEGIN {printf \"%.2f\", $size/1048576}") MB"
        else
            echo "$(awk "BEGIN {printf \"%.2f\", $size/1024}") KB"
        fi
    else
        echo "unknown"
    fi
}

# Function to download model if it doesn't exist
download_model() {
    local url=$1
    local output=$2
    local name=$(basename "$output")
    local start_time=$(date +%s)

    if [ -f "$output" ]; then
        local size=$(get_file_size "$output")
        echo "✅ $name already exists ($size), skipping..."
        return 0
    fi

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "📥 Downloading: $name"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # Try huggingface-cli first for HuggingFace URLs (much faster)
    if [[ "$url" == *"huggingface.co"* ]] && command -v huggingface-cli &> /dev/null; then
        echo "🚀 Method: HuggingFace CLI (optimized transfer protocol)"

        # Extract repo and file path from URL
        # URL format: https://huggingface.co/REPO/resolve/main/PATH
        local repo=$(echo "$url" | sed -n 's|.*huggingface.co/\([^/]*/[^/]*\)/resolve.*|\1|p')
        local file_path=$(echo "$url" | sed -n 's|.*resolve/main/\(.*\)|\1|p')

        if [ -n "$repo" ] && [ -n "$file_path" ]; then
            echo "📦 Repository: $repo"
            echo "📄 File: $file_path"
            echo ""
            echo "⏳ Starting download..."

            local temp_dir=$(mktemp -d)

            # Run huggingface-cli with progress output
            if huggingface-cli download "$repo" "$file_path" \
                --local-dir "$temp_dir" \
                --local-dir-use-symlinks False 2>&1 | \
                grep -v "Fetching" | \
                while IFS= read -r line; do
                    # Show progress lines that contain useful info
                    if [[ "$line" =~ (Downloading|Download|MB|GB|%|eta) ]]; then
                        echo "   $line"
                    fi
                done; then

                # Move downloaded file to target location
                local downloaded_file="$temp_dir/$file_path"
                if [ -f "$downloaded_file" ]; then
                    local size=$(get_file_size "$downloaded_file")
                    mv "$downloaded_file" "$output"
                    rm -rf "$temp_dir"

                    local end_time=$(date +%s)
                    local duration=$((end_time - start_time))
                    local minutes=$((duration / 60))
                    local seconds=$((duration % 60))

                    echo ""
                    echo "✅ Download complete!"
                    echo "   📊 Size: $size"
                    echo "   ⏱️  Time: ${minutes}m ${seconds}s"
                    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                    return 0
                else
                    echo ""
                    echo "⚠️  HuggingFace CLI download failed, trying aria2c..."
                    rm -rf "$temp_dir"
                fi
            else
                echo ""
                echo "⚠️  HuggingFace CLI failed, trying aria2c..."
                rm -rf "$temp_dir"
            fi
        fi
    fi

    # Try aria2c (faster with multi-connection downloads)
    if command -v aria2c &> /dev/null; then
        echo "🚀 Method: aria2c (32 parallel connections)"
        echo ""
        echo "⏳ Starting download..."

        aria2c \
            --console-log-level=warn \
            --summary-interval=5 \
            --max-connection-per-server=32 \
            --split=32 \
            --min-split-size=1M \
            --max-concurrent-downloads=1 \
            --continue=true \
            --allow-overwrite=true \
            --auto-file-renaming=false \
            --show-console-readout=true \
            --human-readable=true \
            --out="$output" \
            "$url" 2>&1 | \
            while IFS= read -r line; do
                # Filter and format aria2c output
                if [[ "$line" =~ (CN:|DL:|ETA:|FileAlloc) ]]; then
                    echo "   $line"
                fi
            done

        if [ -f "$output" ]; then
            local size=$(get_file_size "$output")
            local end_time=$(date +%s)
            local duration=$((end_time - start_time))
            local minutes=$((duration / 60))
            local seconds=$((duration % 60))

            echo ""
            echo "✅ Download complete!"
            echo "   📊 Size: $size"
            echo "   ⏱️  Time: ${minutes}m ${seconds}s"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            return 0
        else
            echo ""
            echo "⚠️  aria2c failed, trying wget..."
        fi
    fi

    # Fallback to wget with improved progress display
    echo "🚀 Method: wget (single connection)"
    echo ""
    echo "⏳ Starting download..."

    wget --progress=bar:force --show-progress -O "$output" "$url" 2>&1 | \
        while IFS= read -r line; do
            echo "   $line"
        done

    if [ -f "$output" ]; then
        local size=$(get_file_size "$output")
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))
        local minutes=$((duration / 60))
        local seconds=$((duration % 60))

        echo ""
        echo "✅ Download complete!"
        echo "   📊 Size: $size"
        echo "   ⏱️  Time: ${minutes}m ${seconds}s"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    fi
}

# Parallel download manager (up to 6 concurrent downloads)
download_parallel() {
    local max_parallel=6
    local -a pids=()
    local total_files=$#
    local completed=0
    local started=0

    echo ""
    echo "╔════════════════════════════════════════════════════════════════════╗"
    echo "║  Parallel Download Manager: Up to $max_parallel concurrent downloads        ║"
    echo "║  Total files in queue: $total_files                                        ║"
    echo "╚════════════════════════════════════════════════════════════════════╝"
    echo ""

    for args in "$@"; do
        started=$((started + 1))

        # Wait if we've hit the parallel limit
        while [ ${#pids[@]} -ge $max_parallel ]; do
            for i in "${!pids[@]}"; do
                if ! kill -0 "${pids[$i]}" 2>/dev/null; then
                    completed=$((completed + 1))
                    echo ""
                    echo "📊 Progress: $completed/$total_files files completed"
                    echo ""
                    unset 'pids[$i]'
                fi
            done
            pids=("${pids[@]}")  # Re-index array
            sleep 1
        done

        # Extract filename for progress display
        local filename=$(echo "$args" | awk '{print $NF}' | xargs basename)
        echo "🚦 Starting download $started/$total_files: $filename"

        # Start download in background
        eval "download_model $args" &
        pids+=($!)

        # Small delay to prevent overwhelming the terminal
        sleep 0.5
    done

    # Wait for all remaining downloads
    echo ""
    echo "⏳ Waiting for remaining downloads to complete..."
    for pid in "${pids[@]}"; do
        if wait "$pid" 2>/dev/null; then
            completed=$((completed + 1))
            echo "📊 Progress: $completed/$total_files files completed"
        fi
    done

    echo ""
    echo "╔════════════════════════════════════════════════════════════════════╗"
    echo "║  ✅ All downloads in this batch complete! ($total_files/$total_files)              ║"
    echo "╚════════════════════════════════════════════════════════════════════╝"
    echo ""
}

echo ""
echo "╔═══════════════════════════════════════════════════════════════════════╗"
echo "║                                                                       ║"
echo "║           🎬 WAN 2.2 Model Download Manager 🎬                        ║"
echo "║                                                                       ║"
echo "║  Total Download Size: ~80GB                                          ║"
echo "║  Storage Location: $MODEL_DIR"
echo "║                                                                       ║"
echo "╚═══════════════════════════════════════════════════════════════════════╝"
echo ""
echo "🔧 Download Configuration:"
if command -v huggingface-cli &> /dev/null; then
    echo "   ✅ Primary: HuggingFace CLI (optimized transfer protocol)"
    echo "   ✅ Fallback: aria2c (32 parallel connections)"
else
    echo "   ✅ Primary: aria2c (32 parallel connections)"
fi
echo "   ✅ Concurrent downloads: Up to 6 files simultaneously"
echo ""
echo "📋 Download Plan:"
echo "   • Phase 1: Diffusion Models (6 files, ~70GB)"
echo "   • Phase 2: Text Encoders, VAE, LoRAs (6 files, ~15GB)"
echo "   • Phase 3: Upscale Models (5 files, ~5GB)"
echo ""
echo "⏱️  Estimated time: 20-35 minutes (depending on network speed)"
echo ""

# Phase 1: Diffusion Models
echo "╔═══════════════════════════════════════════════════════════════════════╗"
echo "║  PHASE 1/3: Diffusion Models (Core WAN 2.2 Models)                   ║"
echo "║  Files: 2 | Size: ~54GB | Format: fp16                               ║"
echo "╚═══════════════════════════════════════════════════════════════════════╝"

download_parallel \
    "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/diffusion_models/wan2.2_t2v_high_noise_14B_fp16.safetensors $MODEL_DIR/diffusion_models/wan2.2_t2v_high_noise_14B_fp16.safetensors" \
    "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/diffusion_models/wan2.2_t2v_low_noise_14B_fp16.safetensors $MODEL_DIR/diffusion_models/wan2.2_t2v_low_noise_14B_fp16.safetensors"
    # COMMENTED OUT - fp8_scaled versions (uncomment if needed):
    # "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/diffusion_models/wan2.2_t2v_high_noise_14B_fp8_scaled.safetensors $MODEL_DIR/diffusion_models/wan2.2_t2v_high_noise_14B_fp8_scaled.safetensors" \
    # "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/diffusion_models/wan2.2_t2v_low_noise_14B_fp8_scaled.safetensors $MODEL_DIR/diffusion_models/wan2.2_t2v_low_noise_14B_fp8_scaled.safetensors" \
    # COMMENTED OUT - VACE modules (uncomment if needed):
    # "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/Fun/VACE/Wan2_2_Fun_VACE_module_A14B_HIGH_bf16.safetensors $MODEL_DIR/diffusion_models/Wan2_2_Fun_VACE_module_A14B_HIGH_bf16.safetensors" \
    # "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/Fun/VACE/Wan2_2_Fun_VACE_module_A14B_LOW_bf16.safetensors $MODEL_DIR/diffusion_models/Wan2_2_Fun_VACE_module_A14B_LOW_bf16.safetensors"

# PHASE 2 COMMENTED OUT - Text Encoders, VAE, LoRAs (uncomment if needed)
# echo "╔═══════════════════════════════════════════════════════════════════════╗"
# echo "║  PHASE 2/3: Text Encoders, VAE & LoRAs                               ║"
# echo "║  Files: 6 | Size: ~15GB                                              ║"
# echo "╚═══════════════════════════════════════════════════════════════════════╝"
#
# download_parallel \
#     "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/text_encoders/umt5_xxl_fp16.safetensors $MODEL_DIR/text_encoders/umt5_xxl_fp16.safetensors" \
#     "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors $MODEL_DIR/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors" \
#     "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/vae/wan_2.1_vae.safetensors $MODEL_DIR/vae/wan_2.1_vae.safetensors" \
#     "https://huggingface.co/yo9otatara/model/resolve/main/Instareal_high.safetensors $MODEL_DIR/loras/Instareal_high.safetensors" \
#     "https://huggingface.co/yo9otatara/model/resolve/main/Instareal_low.safetensors $MODEL_DIR/loras/Instareal_low.safetensors" \
#     "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/Lightx2v/lightx2v_T2V_14B_cfg_step_distill_v2_lora_rank256_bf16.safetensors $MODEL_DIR/loras/lightx2v_T2V_14B_cfg_step_distill_v2_lora_rank256_bf16.safetensors"

# Phase 3: Upscale Models
echo "╔═══════════════════════════════════════════════════════════════════════╗"
echo "║  PHASE 3/3: Upscale Models                                           ║"
echo "║  Files: 5 | Size: ~5GB                                               ║"
echo "╚═══════════════════════════════════════════════════════════════════════╝"

download_parallel \
    "https://huggingface.co/yo9otatara/model/resolve/main/4xNomosUniDAT_otf.pth $MODEL_DIR/upscale_models/4xNomosUniDAT_otf.pth" \
    "https://huggingface.co/yo9otatara/model/resolve/main/4x-ClearRealityV1.pth $MODEL_DIR/upscale_models/4x-ClearRealityV1.pth" \
    "https://huggingface.co/yo9otatara/model/resolve/main/1xSkinContrast-High-SuperUltraCompact.pth $MODEL_DIR/upscale_models/1xSkinContrast-High-SuperUltraCompact.pth" \
    "https://huggingface.co/yo9otatara/model/resolve/main/1xDeJPG_realplksr_otf.safetensors $MODEL_DIR/upscale_models/1xDeJPG_realplksr_otf.safetensors" \
    "https://huggingface.co/yo9otatara/model/resolve/main/4x-UltraSharpV2_Lite.pth $MODEL_DIR/upscale_models/4x-UltraSharpV2_Lite.pth"

# Final summary
echo ""
echo "╔═══════════════════════════════════════════════════════════════════════╗"
echo "║                                                                       ║"
echo "║              ✅ ALL DOWNLOADS COMPLETED SUCCESSFULLY! ✅              ║"
echo "║                                                                       ║"
echo "╚═══════════════════════════════════════════════════════════════════════╝"
echo ""
echo "📊 Download Summary:"
echo "   📁 Storage location: $MODEL_DIR"
echo "   📦 Total files downloaded: $(find "$MODEL_DIR" -type f 2>/dev/null | wc -l)"
echo "   💾 Total storage used: $(du -sh "$MODEL_DIR" 2>/dev/null | cut -f1)"
echo ""
echo "🎉 WAN 2.2 is ready to use!"
echo ""

