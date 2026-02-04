#!/bin/bash
set -e

echo "========================================="
echo "WAN 2.2 Model Downloader"
echo "========================================="

# ============================================================================
# MODEL DOWNLOAD FLAGS - Set these in RunPod Environment Variables
# ============================================================================
# All flags default to DOWNLOAD_ALL value. Set individual flags to override.
#
# DOWNLOAD_WAN_CORE=true     - Core WAN 2.2 T2V models (~60GB) + CLIP/VAE/LoRAs/Upscale
# DOWNLOAD_VACE=true         - VACE modules for video editing (~30GB)
# DOWNLOAD_ANIMATE=true      - Animate 14B model (~28GB)
# DOWNLOAD_SCAIL=true        - SCAIL preview model (~28GB)
# DOWNLOAD_LIGHTX=true       - LTX-2 models: checkpoint, upscalers, lora, text encoder (~50GB)
# DOWNLOAD_LTX_LORAS=true    - LTX-2 LoRA pack: IC-LoRAs + Camera Control (~2GB)
# DOWNLOAD_FLUX=true         - FLUX.1-dev models: GGUF diffusion, VAE, ControlNet Upscaler, CLIP (~15GB)
# DOWNLOAD_CLIP=true         - CLIP text encoder + vision (~12GB)
# DOWNLOAD_VAE=true          - VAE model (~300MB)
# DOWNLOAD_LORAS=true        - LoRA models (~3GB)
# DOWNLOAD_CONTROLNET=true   - ControlNet model (~2GB)
# DOWNLOAD_DETECTION=true    - Detection model (~40MB)
# DOWNLOAD_UPSCALE=true      - Upscale models (~5GB)
# DOWNLOAD_MATANYONE=true    - MatAnyone video matting (~1.5GB)
#
# DOWNLOAD_ALL=true          - Master switch (default: true = download everything)
#                              Set to "false" then enable individual flags
# ============================================================================

# DOWNLOAD_ALL defaults to true (downloads everything)
# If DOWNLOAD_ALL=false, only explicitly enabled flags will download
: "${DOWNLOAD_ALL:=true}"

# Individual flags: default to DOWNLOAD_ALL value
# This way: DOWNLOAD_ALL=false means nothing downloads unless explicitly set
: "${DOWNLOAD_WAN_CORE:=$DOWNLOAD_ALL}"
: "${DOWNLOAD_VACE:=$DOWNLOAD_ALL}"
: "${DOWNLOAD_ANIMATE:=$DOWNLOAD_ALL}"
: "${DOWNLOAD_SCAIL:=$DOWNLOAD_ALL}"
: "${DOWNLOAD_LIGHTX:=$DOWNLOAD_ALL}"
: "${DOWNLOAD_LTX_LORAS:=$DOWNLOAD_ALL}"
: "${DOWNLOAD_FLUX:=false}"
: "${DOWNLOAD_CLIP:=$DOWNLOAD_ALL}"
: "${DOWNLOAD_VAE:=$DOWNLOAD_ALL}"
: "${DOWNLOAD_LORAS:=$DOWNLOAD_ALL}"
: "${DOWNLOAD_CONTROLNET:=$DOWNLOAD_ALL}"
: "${DOWNLOAD_DETECTION:=$DOWNLOAD_ALL}"
: "${DOWNLOAD_UPSCALE:=$DOWNLOAD_ALL}"
: "${DOWNLOAD_MATANYONE:=$DOWNLOAD_ALL}"

# BUNDLE LOGIC: WAN_CORE includes essential dependencies
# If WAN_CORE is enabled, also enable CLIP, VAE, LoRAs, and Upscale models (required for T2V workflows)
if [ "$DOWNLOAD_WAN_CORE" = "true" ]; then
    DOWNLOAD_CLIP="true"
    DOWNLOAD_VAE="true"
    DOWNLOAD_LORAS="true"
    DOWNLOAD_UPSCALE="true"
fi

# Model storage directory (use RunPod's persistent /workspace if available)
if [ -d "/workspace" ]; then
    MODEL_DIR="/workspace/models"
    echo "✅ Using RunPod persistent storage: /workspace/models"
else
    MODEL_DIR="/comfyui/models"
    echo "⚠️  Using container storage: /comfyui/models"
fi

# Show download configuration
echo ""
echo "📋 Download Configuration (set env vars to 'false' to skip):"
echo "   DOWNLOAD_WAN_CORE=$DOWNLOAD_WAN_CORE     (Core T2V ~60GB)"
echo "   DOWNLOAD_VACE=$DOWNLOAD_VACE         (VACE ~30GB)"
echo "   DOWNLOAD_ANIMATE=$DOWNLOAD_ANIMATE      (Animate ~28GB)"
echo "   DOWNLOAD_SCAIL=$DOWNLOAD_SCAIL        (SCAIL ~28GB)"
echo "   DOWNLOAD_LIGHTX=$DOWNLOAD_LIGHTX       (LTX-2 ~50GB)"
echo "   DOWNLOAD_LTX_LORAS=$DOWNLOAD_LTX_LORAS    (LTX-2 LoRAs ~2GB)"
echo "   DOWNLOAD_FLUX=$DOWNLOAD_FLUX        (FLUX.1-dev ~15GB)"
echo "   DOWNLOAD_CLIP=$DOWNLOAD_CLIP         (CLIP ~12GB)"
echo "   DOWNLOAD_VAE=$DOWNLOAD_VAE          (VAE ~300MB)"
echo "   DOWNLOAD_LORAS=$DOWNLOAD_LORAS        (LoRAs ~3GB)"
echo "   DOWNLOAD_CONTROLNET=$DOWNLOAD_CONTROLNET   (ControlNet ~2GB)"
echo "   DOWNLOAD_DETECTION=$DOWNLOAD_DETECTION    (Detection ~40MB)"
echo "   DOWNLOAD_UPSCALE=$DOWNLOAD_UPSCALE      (Upscale ~5GB)"
echo "   DOWNLOAD_MATANYONE=$DOWNLOAD_MATANYONE    (MatAnyone ~1.5GB)"
echo ""

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
    "$MODEL_DIR/unet/gguf" \
    "$MODEL_DIR/upscale_models" \
    "$MODEL_DIR/latent_upscale_models" \
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
    "$MODEL_DIR/diffusion_models" \
    "$MODEL_DIR/detection"

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
echo "║  Total Download Size: ~147GB                                         ║"
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
echo "   • Phase 1: Diffusion Models (6 files, ~120GB) - includes VACE, Animate, SCAIL"
echo "   • Phase 2: CLIP, CLIP Vision, VAE, LoRAs (6 files, ~16GB)"
echo "   • Phase 3: ControlNet Models (1 file, ~2GB)"
echo "   • Phase 4: Detection Models (1 file, ~40MB)"
echo "   • Phase 5: Upscale Models (5 files, ~5GB)"
echo "   • Phase 6: MatAnyone Model (1 file, ~1.5GB)"
echo ""
echo "⏱️  Estimated time: 45-65 minutes (depending on network speed)"
echo ""

# Phase 1: Diffusion Models (respects individual flags)
echo "╔═══════════════════════════════════════════════════════════════════════╗"
echo "║  PHASE 1/6: Diffusion Models (Core WAN 2.2 + VACE + Animate + SCAIL) ║"
echo "╚═══════════════════════════════════════════════════════════════════════╝"

# Build download list based on flags
PHASE1_DOWNLOADS=()

if [ "$DOWNLOAD_WAN_CORE" = "true" ]; then
    echo "   ✅ WAN Core T2V models enabled"
    PHASE1_DOWNLOADS+=("https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/diffusion_models/wan2.2_t2v_high_noise_14B_fp16.safetensors $MODEL_DIR/diffusion_models/wan2.2_t2v_high_noise_14B_fp16.safetensors")
    PHASE1_DOWNLOADS+=("https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/diffusion_models/wan2.2_t2v_low_noise_14B_fp16.safetensors $MODEL_DIR/diffusion_models/wan2.2_t2v_low_noise_14B_fp16.safetensors")
    # Yogo-Wan LoRAs (bundled with WAN Core)
    PHASE1_DOWNLOADS+=("https://huggingface.co/yo9otatara/F5/resolve/main/Yogo-Wan-V1_000014000.safetensors $MODEL_DIR/loras/Yogo-Wan-V1_000014000.safetensors")
    PHASE1_DOWNLOADS+=("https://huggingface.co/yo9otatara/F5/resolve/main/Yogo-Wan-V1_000017000.safetensors $MODEL_DIR/loras/Yogo-Wan-V1_000017000.safetensors")
else
    echo "   ⏭️  WAN Core T2V models SKIPPED (DOWNLOAD_WAN_CORE=false)"
fi

if [ "$DOWNLOAD_VACE" = "true" ]; then
    echo "   ✅ VACE modules enabled"
    PHASE1_DOWNLOADS+=("https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/Fun/VACE/Wan2_2_Fun_VACE_module_A14B_HIGH_bf16.safetensors $MODEL_DIR/diffusion_models/Wan2_2_Fun_VACE_module_A14B_HIGH_bf16.safetensors")
    PHASE1_DOWNLOADS+=("https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/Fun/VACE/Wan2_2_Fun_VACE_module_A14B_LOW_bf16.safetensors $MODEL_DIR/diffusion_models/Wan2_2_Fun_VACE_module_A14B_LOW_bf16.safetensors")
else
    echo "   ⏭️  VACE modules SKIPPED (DOWNLOAD_VACE=false)"
fi

if [ "$DOWNLOAD_ANIMATE" = "true" ]; then
    echo "   ✅ Animate model enabled"
    PHASE1_DOWNLOADS+=("https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/diffusion_models/wan2.2_animate_14B_bf16.safetensors $MODEL_DIR/diffusion_models/wan2.2_animate_14B_bf16.safetensors")
else
    echo "   ⏭️  Animate model SKIPPED (DOWNLOAD_ANIMATE=false)"
fi

if [ "$DOWNLOAD_SCAIL" = "true" ]; then
    echo "   ✅ SCAIL model enabled"
    PHASE1_DOWNLOADS+=("https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/SCAIL/Wan21-14B-SCAIL-preview_comfy_bf16.safetensors $MODEL_DIR/diffusion_models/Wan21-14B-SCAIL-preview_comfy_bf16.safetensors")
else
    echo "   ⏭️  SCAIL model SKIPPED (DOWNLOAD_SCAIL=false)"
fi

if [ ${#PHASE1_DOWNLOADS[@]} -gt 0 ]; then
    download_parallel "${PHASE1_DOWNLOADS[@]}"
else
    echo "   ⚠️  No Phase 1 downloads - all diffusion models skipped"
fi

# Phase 2: CLIP, CLIP Vision, VAE & LoRAs
echo "╔═══════════════════════════════════════════════════════════════════════╗"
echo "║  PHASE 2/6: CLIP, CLIP Vision, VAE & LoRAs                           ║"
echo "╚═══════════════════════════════════════════════════════════════════════╝"

PHASE2_DOWNLOADS=()

if [ "$DOWNLOAD_CLIP" = "true" ]; then
    echo "   ✅ CLIP models enabled"
    PHASE2_DOWNLOADS+=("https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/text_encoders/umt5_xxl_fp16.safetensors $MODEL_DIR/clip/umt5_xxl_fp16.safetensors")
    PHASE2_DOWNLOADS+=("https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/clip_vision/clip_vision_h.safetensors $MODEL_DIR/clip_vision/clip_vision_h.safetensors")
else
    echo "   ⏭️  CLIP models SKIPPED (DOWNLOAD_CLIP=false)"
fi

if [ "$DOWNLOAD_VAE" = "true" ]; then
    echo "   ✅ VAE model enabled"
    PHASE2_DOWNLOADS+=("https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/vae/wan_2.1_vae.safetensors $MODEL_DIR/vae/wan_2.1_vae.safetensors")
else
    echo "   ⏭️  VAE model SKIPPED (DOWNLOAD_VAE=false)"
fi

if [ "$DOWNLOAD_LORAS" = "true" ]; then
    echo "   ✅ LoRA models enabled"
    PHASE2_DOWNLOADS+=("https://huggingface.co/yo9otatara/model/resolve/main/Instareal_high.safetensors $MODEL_DIR/loras/Instareal_high.safetensors")
    PHASE2_DOWNLOADS+=("https://huggingface.co/yo9otatara/model/resolve/main/Instareal_low.safetensors $MODEL_DIR/loras/Instareal_low.safetensors")
    PHASE2_DOWNLOADS+=("https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/Lightx2v/lightx2v_T2V_14B_cfg_step_distill_v2_lora_rank256_bf16.safetensors $MODEL_DIR/loras/lightx2v_T2V_14B_cfg_step_distill_v2_lora_rank256_bf16.safetensors")
    PHASE2_DOWNLOADS+=("https://huggingface.co/yo9otatara/model/resolve/main/f5_style2.1_000000400.safetensors $MODEL_DIR/loras/f5_style2.1_000000400.safetensors")
    PHASE2_DOWNLOADS+=("https://huggingface.co/yo9otatara/model/resolve/main/WAN2.1_TheIncrediblesPixarStyle_v1_by-AI_Characters.safetensors $MODEL_DIR/loras/WAN2.1_TheIncrediblesPixarStyle_v1_by-AI_Characters.safetensors")
else
    echo "   ⏭️  LoRA models SKIPPED (DOWNLOAD_LORAS=false)"
fi

if [ ${#PHASE2_DOWNLOADS[@]} -gt 0 ]; then
    download_parallel "${PHASE2_DOWNLOADS[@]}"
else
    echo "   ⚠️  No Phase 2 downloads - all CLIP/VAE/LoRA models skipped"
fi

# Phase 3: ControlNet Models
echo "╔═══════════════════════════════════════════════════════════════════════╗"
echo "║  PHASE 3/6: ControlNet Models                                        ║"
echo "╚═══════════════════════════════════════════════════════════════════════╝"

if [ "$DOWNLOAD_CONTROLNET" = "true" ]; then
    echo "   ✅ ControlNet model enabled"
    download_parallel \
        "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/Wan21_Uni3C_controlnet_fp16.safetensors $MODEL_DIR/controlnet/Wan21_Uni3C_controlnet_fp16.safetensors"
else
    echo "   ⏭️  ControlNet model SKIPPED (DOWNLOAD_CONTROLNET=false)"
fi

# Phase 4: Detection Models
echo "╔═══════════════════════════════════════════════════════════════════════╗"
echo "║  PHASE 4/6: Detection Models                                         ║"
echo "╚═══════════════════════════════════════════════════════════════════════╝"

if [ "$DOWNLOAD_DETECTION" = "true" ]; then
    echo "   ✅ Detection model enabled"
    download_parallel \
        "https://huggingface.co/Wan-AI/Wan2.2-Animate-14B/resolve/main/process_checkpoint/det/yolov10m.onnx $MODEL_DIR/detection/yolov10m.onnx"
else
    echo "   ⏭️  Detection model SKIPPED (DOWNLOAD_DETECTION=false)"
fi

# Phase 5: Upscale Models
echo "╔═══════════════════════════════════════════════════════════════════════╗"
echo "║  PHASE 5/6: Upscale Models                                           ║"
echo "╚═══════════════════════════════════════════════════════════════════════╝"

if [ "$DOWNLOAD_UPSCALE" = "true" ]; then
    echo "   ✅ Upscale models enabled"
    download_parallel \
        "https://huggingface.co/yo9otatara/model/resolve/main/4xNomosUniDAT_otf.pth $MODEL_DIR/upscale_models/4xNomosUniDAT_otf.pth" \
        "https://huggingface.co/yo9otatara/model/resolve/main/4x-ClearRealityV1.pth $MODEL_DIR/upscale_models/4x-ClearRealityV1.pth" \
        "https://huggingface.co/yo9otatara/model/resolve/main/1xSkinContrast-High-SuperUltraCompact.pth $MODEL_DIR/upscale_models/1xSkinContrast-High-SuperUltraCompact.pth" \
        "https://huggingface.co/yo9otatara/model/resolve/main/1xDeJPG_realplksr_otf.safetensors $MODEL_DIR/upscale_models/1xDeJPG_realplksr_otf.safetensors" \
        "https://huggingface.co/yo9otatara/model/resolve/main/4x-UltraSharpV2_Lite.pth $MODEL_DIR/upscale_models/4x-UltraSharpV2_Lite.pth"
else
    echo "   ⏭️  Upscale models SKIPPED (DOWNLOAD_UPSCALE=false)"
fi

# Phase 6: MatAnyone Model (Custom Node Checkpoint)
echo "╔═══════════════════════════════════════════════════════════════════════╗"
echo "║  PHASE 6/6: MatAnyone Model                                          ║"
echo "╚═══════════════════════════════════════════════════════════════════════╝"

if [ "$DOWNLOAD_MATANYONE" = "true" ]; then
    echo "   ✅ MatAnyone model enabled"
    # Create MatAnyone checkpoint directory if it doesn't exist
    MATANYONE_DIR="/comfyui/custom_nodes/ComfyUI-MatAnyone/checkpoint"
    mkdir -p "$MATANYONE_DIR"
    download_parallel \
        "https://github.com/pq-yang/MatAnyone/releases/download/v1.0.0/matanyone.pth $MATANYONE_DIR/matanyone.pth"
else
    echo "   ⏭️  MatAnyone model SKIPPED (DOWNLOAD_MATANYONE=false)"
fi

# Phase 7: LTX-2 Models (Lightricks)
echo "╔═══════════════════════════════════════════════════════════════════════╗"
echo "║  PHASE 7/7: LTX-2 Models (Lightricks)                                ║"
echo "╚═══════════════════════════════════════════════════════════════════════╝"

if [ "$DOWNLOAD_LIGHTX" = "true" ]; then
    echo "   ✅ LTX-2 models enabled"
    download_parallel \
        "https://huggingface.co/Lightricks/LTX-2/resolve/main/ltx-2-19b-dev.safetensors $MODEL_DIR/checkpoints/ltx-2-19b-dev.safetensors" \
        "https://huggingface.co/Lightricks/LTX-2/resolve/main/ltx-2-spatial-upscaler-x2-1.0.safetensors $MODEL_DIR/latent_upscale_models/ltx-2-spatial-upscaler-x2-1.0.safetensors" \
        "https://huggingface.co/Lightricks/LTX-2/resolve/main/ltx-2-temporal-upscaler-x2-1.0.safetensors $MODEL_DIR/latent_upscale_models/ltx-2-temporal-upscaler-x2-1.0.safetensors" \
        "https://huggingface.co/Lightricks/LTX-2/resolve/main/ltx-2-19b-distilled-lora-384.safetensors $MODEL_DIR/loras/ltx-2-19b-distilled-lora-384.safetensors" \
        "https://huggingface.co/Comfy-Org/ltx-2/resolve/main/split_files/text_encoders/gemma_3_12B_it.safetensors $MODEL_DIR/text_encoders/gemma_3_12B_it.safetensors"
else
    echo "   ⏭️  LTX-2 models SKIPPED (DOWNLOAD_LIGHTX=false)"
fi

# Phase 8: LTX-2 LoRA Pack (IC-LoRAs + Camera Control)
echo "╔═══════════════════════════════════════════════════════════════════════╗"
echo "║  PHASE 8: LTX-2 LoRA Pack                                            ║"
echo "╚═══════════════════════════════════════════════════════════════════════╝"

if [ "$DOWNLOAD_LTX_LORAS" = "true" ]; then
    echo "   ✅ LTX-2 LoRA pack enabled"
    download_parallel \
        "https://huggingface.co/Lightricks/LTX-2-19b-IC-LoRA-Canny-Control/resolve/main/ltx-2-19b-ic-lora-canny-control.safetensors $MODEL_DIR/loras/ltx-2-19b-ic-lora-canny-control.safetensors" \
        "https://huggingface.co/Lightricks/LTX-2-19b-IC-LoRA-Depth-Control/resolve/main/ltx-2-19b-ic-lora-depth-control.safetensors $MODEL_DIR/loras/ltx-2-19b-ic-lora-depth-control.safetensors" \
        "https://huggingface.co/Lightricks/LTX-2-19b-IC-LoRA-Detailer/resolve/main/ltx-2-19b-ic-lora-detailer.safetensors $MODEL_DIR/loras/ltx-2-19b-ic-lora-detailer.safetensors" \
        "https://huggingface.co/Lightricks/LTX-2-19b-IC-LoRA-Pose-Control/resolve/main/ltx-2-19b-ic-lora-pose-control.safetensors $MODEL_DIR/loras/ltx-2-19b-ic-lora-pose-control.safetensors" \
        "https://huggingface.co/Lightricks/LTX-2-19b-LoRA-Camera-Control-Dolly-In/resolve/main/ltx-2-19b-lora-camera-control-dolly-in.safetensors $MODEL_DIR/loras/ltx-2-19b-lora-camera-control-dolly-in.safetensors" \
        "https://huggingface.co/Lightricks/LTX-2-19b-LoRA-Camera-Control-Dolly-Left/resolve/main/ltx-2-19b-lora-camera-control-dolly-left.safetensors $MODEL_DIR/loras/ltx-2-19b-lora-camera-control-dolly-left.safetensors" \
        "https://huggingface.co/Lightricks/LTX-2-19b-LoRA-Camera-Control-Dolly-Out/resolve/main/ltx-2-19b-lora-camera-control-dolly-out.safetensors $MODEL_DIR/loras/ltx-2-19b-lora-camera-control-dolly-out.safetensors" \
        "https://huggingface.co/Lightricks/LTX-2-19b-LoRA-Camera-Control-Dolly-Right/resolve/main/ltx-2-19b-lora-camera-control-dolly-right.safetensors $MODEL_DIR/loras/ltx-2-19b-lora-camera-control-dolly-right.safetensors" \
        "https://huggingface.co/Lightricks/LTX-2-19b-LoRA-Camera-Control-Jib-Down/resolve/main/ltx-2-19b-lora-camera-control-jib-down.safetensors $MODEL_DIR/loras/ltx-2-19b-lora-camera-control-jib-down.safetensors" \
        "https://huggingface.co/Lightricks/LTX-2-19b-LoRA-Camera-Control-Jib-Up/resolve/main/ltx-2-19b-lora-camera-control-jib-up.safetensors $MODEL_DIR/loras/ltx-2-19b-lora-camera-control-jib-up.safetensors" \
        "https://huggingface.co/Lightricks/LTX-2-19b-LoRA-Camera-Control-Static/resolve/main/ltx-2-19b-lora-camera-control-static.safetensors $MODEL_DIR/loras/ltx-2-19b-lora-camera-control-static.safetensors"
else
    echo "   ⏭️  LTX-2 LoRA pack SKIPPED (DOWNLOAD_LTX_LORAS=false)"
fi

# Phase 9: FLUX.1-dev Models
echo "╔═══════════════════════════════════════════════════════════════════════╗"
echo "║  PHASE 9: FLUX.1-dev Models                                          ║"
echo "╚═══════════════════════════════════════════════════════════════════════╝"

if [ "$DOWNLOAD_FLUX" = "true" ]; then
    echo "   ✅ FLUX.1-dev models enabled"
    download_parallel \
        "https://huggingface.co/city96/FLUX.1-dev-gguf/resolve/main/flux1-dev-Q8_0.gguf $MODEL_DIR/unet/gguf/flux1-dev-Q8_0.gguf" \
        "https://huggingface.co/Comfy-Org/z_image_turbo/resolve/main/split_files/vae/ae.safetensors $MODEL_DIR/vae/flux_ae.safetensors" \
        "https://huggingface.co/jasperai/Flux.1-dev-Controlnet-Upscaler/resolve/main/diffusion_pytorch_model.safetensors $MODEL_DIR/controlnet/flux_controlnet_upscaler.safetensors" \
        "https://huggingface.co/zer0int/CLIP-GmP-ViT-L-14/resolve/main/ViT-L-14-TEXT-detail-improved-hiT-GmP-HF.safetensors $MODEL_DIR/clip/ViT-L-14-TEXT-detail-improved-hiT-GmP-HF.safetensors" \
        "https://huggingface.co/Comfy-Org/stable-diffusion-3.5-fp8/resolve/main/text_encoders/t5xxl_fp16.safetensors $MODEL_DIR/text_encoders/t5xxl_fp16.safetensors" \
        "https://huggingface.co/Alissonerdx/flux.1-dev-SRPO-LoRas/resolve/main/srpo_128_base_oficial_model_fp16.safetensors $MODEL_DIR/loras/srpo_128_base_oficial_model_fp16.safetensors" \
        "https://huggingface.co/yo9otatara/model/resolve/main/Flux_Skin_Detailer.safetensors $MODEL_DIR/loras/Flux_Skin_Detailer.safetensors"
else
    echo "   ⏭️  FLUX.1-dev models SKIPPED (DOWNLOAD_FLUX=false)"
fi

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

