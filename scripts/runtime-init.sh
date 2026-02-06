#!/usr/bin/env bash
# WAN 2.2 Runtime Initialization Script
# Installs ComfyUI, PyTorch, and custom nodes at container startup
# This runs in RunPod where disk space is abundant

set -e

echo "==================================================================="
echo "WAN 2.2 Runtime Initialization"
echo "==================================================================="

# ============================================================================
# COMFYUI VERSION FLAG - Set in RunPod Environment Variables
# ============================================================================
# COMFYUI_USE_LATEST=true   - Install latest ComfyUI version (bleeding edge)
# COMFYUI_USE_LATEST=false  - Use pinned stable version v0.3.56 (default)
# ============================================================================
: "${COMFYUI_USE_LATEST:=false}"

# Check if already initialized (for persistent storage)
ALREADY_INITIALIZED=false
if [ -f "/comfyui/.initialized" ]; then
    echo "✅ Main initialization already done - checking ComfyUI-Manager version..."
    ALREADY_INITIALIZED=true
fi

if [ "$ALREADY_INITIALIZED" = false ]; then
    cd /
    # COMFY_SKIP_FETCH_REGISTRY=1 prevents the slow "FETCH ComfyRegistry Data" during init
    # The registry fetch will happen when ComfyUI actually starts

    if [ "$COMFYUI_USE_LATEST" = "true" ]; then
        echo "📦 Installing ComfyUI (LATEST version)..."
        echo "   ⚠️  Note: Latest version may have compatibility issues with some nodes"
        COMFY_SKIP_FETCH_REGISTRY=1 /usr/bin/yes | comfy --workspace /comfyui install --nvidia
    else
        echo "📦 Installing ComfyUI ${COMFYUI_VERSION:-v0.3.56} (stable)..."
        COMFY_SKIP_FETCH_REGISTRY=1 /usr/bin/yes | comfy --workspace /comfyui install --version "${COMFYUI_VERSION:-v0.3.56}" --nvidia
    fi
fi

# Copy extra_model_paths.yaml for network volume support
if [ -f "/etc/extra_model_paths.yaml" ] && [ ! -f "/comfyui/extra_model_paths.yaml" ]; then
    echo "📋 Copying extra_model_paths.yaml for network volume support..."
    cp /etc/extra_model_paths.yaml /comfyui/extra_model_paths.yaml
fi

# Only install PyTorch and dependencies on first init
if [ "$ALREADY_INITIALIZED" = false ]; then
    if [ "$COMFYUI_USE_LATEST" = "true" ]; then
        # When using latest ComfyUI, let it install its own PyTorch version (2.9.x)
        # via comfy-cli requirements - this ensures compatibility with latest ComfyUI
        echo "🔥 Skipping PyTorch install - latest ComfyUI will use PyTorch 2.9.x from requirements..."
    else
        # Install PyTorch 2.7.1 with CUDA 12.8 support (pinned version for stability)
        # Note: Latest PyTorch (2.9.x) may have compatibility issues with some custom nodes
        echo "🔥 Installing PyTorch 2.7.1 with CUDA 12.8 support..."
        pip install --no-cache-dir \
            torch==2.7.1+cu128 \
            torchvision==0.22.1+cu128 \
            torchaudio==2.7.1+cu128 \
            --index-url https://download.pytorch.org/whl/cu128
    fi

    echo "⚡ Installing HuggingFace CLI for fast model downloads..."
    uv pip install --no-cache huggingface-hub[cli,hf_transfer]
fi
export HF_HUB_ENABLE_HF_TRANSFER=1

# ============================================================================
# ComfyUI-Manager Installation - ALWAYS runs to ensure correct version
# ============================================================================
# Version matching is CRITICAL to prevent execution.py patching errors:
# - COMFYUI_USE_LATEST=true  → Use latest ComfyUI-Manager (for latest ComfyUI)
# - COMFYUI_USE_LATEST=false → Use v3.37.1 (for stable ComfyUI v0.3.56)
#
# Mismatched versions cause: "patched_execute() takes X positional arguments but Y were given"
# This section runs EVERY startup to fix any incorrect Manager versions.
# ============================================================================

echo "🧩 Checking ComfyUI-Manager version..."
cd /comfyui/custom_nodes

# ============================================================================
# ComfyUI-Manager Version Selection
# ============================================================================
# When COMFYUI_USE_LATEST=true: Use latest ComfyUI-Manager (compatible with latest ComfyUI)
# When COMFYUI_USE_LATEST=false: Use v3.37.1 (last version compatible with v0.3.56)
#
# CRITICAL: ComfyUI-Manager v3.38+ patches execution.py with updated function signatures.
# Using the wrong version causes: "patched_execute() takes X positional arguments but Y were given"
# ============================================================================

if [ "$COMFYUI_USE_LATEST" = "true" ]; then
    # Latest ComfyUI needs latest ComfyUI-Manager
    echo "   📦 Using LATEST ComfyUI-Manager (for latest ComfyUI)..."
    MANAGER_VERSION="latest"
    MANAGER_NEEDS_INSTALL=false

    if [ -d "ComfyUI-Manager" ]; then
        # For latest mode, always update to get the newest version
        echo "   🔄 Updating ComfyUI-Manager to latest..."
        cd ComfyUI-Manager
        git fetch origin
        git reset --hard origin/main
        cd ..
        MANAGER_NEEDS_INSTALL=false
    else
        MANAGER_NEEDS_INSTALL=true
    fi

    if [ "$MANAGER_NEEDS_INSTALL" = true ]; then
        rm -rf ComfyUI-Manager
        echo "   Installing ComfyUI-Manager (latest) from Comfy-Org..."
        git clone --depth 1 https://github.com/Comfy-Org/ComfyUI-Manager.git
    fi

    # Install dependencies
    echo "   📦 Installing ComfyUI-Manager dependencies..."
    if [ -f "ComfyUI-Manager/requirements.txt" ]; then
        pip install -r ComfyUI-Manager/requirements.txt
    fi
else
    # Stable ComfyUI v0.3.56 needs pinned ComfyUI-Manager v3.37.1
    MANAGER_VERSION="3.37.1"
    MANAGER_NEEDS_INSTALL=false

    # Check if Manager exists and verify version
    if [ -d "ComfyUI-Manager" ]; then
        # Check the version in manager_core.py
        if [ -f "ComfyUI-Manager/glob/manager_core.py" ]; then
            INSTALLED_VERSION=$(grep -oP "version_code = \[\K[0-9, ]+" ComfyUI-Manager/glob/manager_core.py 2>/dev/null | tr -d ' ' || echo "")
            if [ "$INSTALLED_VERSION" = "3,37,1" ]; then
                echo "   ✅ ComfyUI-Manager v${MANAGER_VERSION} already installed correctly"
            else
                echo "   ⚠️  Wrong version detected: $INSTALLED_VERSION - reinstalling v${MANAGER_VERSION}..."
                MANAGER_NEEDS_INSTALL=true
            fi
        else
            echo "   ⚠️  Manager found but version file missing - reinstalling..."
            MANAGER_NEEDS_INSTALL=true
        fi
    else
        echo "   📦 ComfyUI-Manager not found - installing..."
        MANAGER_NEEDS_INSTALL=true
    fi

    if [ "$MANAGER_NEEDS_INSTALL" = true ]; then
        # Remove any existing installation
        rm -rf ComfyUI-Manager

        echo "Installing ComfyUI-Manager v${MANAGER_VERSION} from Comfy-Org..."
        # Use the new official Comfy-Org repository (ltdrdata repo redirects here)
        git clone --branch ${MANAGER_VERSION} --depth 1 https://github.com/Comfy-Org/ComfyUI-Manager.git

        # Install dependencies
        echo "📦 Installing ComfyUI-Manager dependencies..."
        if [ -f "ComfyUI-Manager/requirements.txt" ]; then
            pip install -r ComfyUI-Manager/requirements.txt
        fi
    fi
fi

# ALWAYS configure ComfyUI-Manager with security_level=weak (runs every startup)
# This is required for both v3.37.1 and latest versions
echo "⚙️  Configuring ComfyUI-Manager (security_level=weak)..."

# Create config in multiple locations to ensure it works
# Location 1: Inside ComfyUI-Manager custom node directory
MANAGER_NODE_CONFIG="/comfyui/custom_nodes/ComfyUI-Manager/config.ini"
cat > "$MANAGER_NODE_CONFIG" << 'MANAGEREOF'
[default]
security_level = weak
MANAGEREOF
echo "   ✅ ComfyUI-Manager config created at $MANAGER_NODE_CONFIG"

# Location 2: ComfyUI user config directory (legacy location)
mkdir -p "/comfyui/user/default/ComfyUI-Manager"
cat > "/comfyui/user/default/ComfyUI-Manager/config.ini" << 'MANAGEREOF'
[default]
security_level = weak
MANAGEREOF
echo "   ✅ ComfyUI-Manager config also created at /comfyui/user/default/ComfyUI-Manager/config.ini"

# Skip custom node installation if already initialized, but continue
# to SageAttention/JupyterLab sections which must run every startup
if [ "$ALREADY_INITIALIZED" = true ]; then
    echo "==================================================================="
    echo "✅ ComfyUI-Manager verified/fixed - skipping custom node install"
    echo "   (SageAttention & JupyterLab will still be checked)"
    echo "==================================================================="
else

echo "🧩 Installing other custom nodes..."

# Install WAN Video Wrapper (pinned to v1.3.0 - commit d9def84332e50af26ec5cde080d4c3703b837520)
# This version is tested and stable with our ComfyUI setup
if [ ! -d "ComfyUI-WanVideoWrapper" ]; then
    echo "Installing ComfyUI-WanVideoWrapper v1.3.0..."
    git clone https://github.com/kijai/ComfyUI-WanVideoWrapper.git
    cd ComfyUI-WanVideoWrapper
    git checkout d9def84332e50af26ec5cde080d4c3703b837520
    cd ..
fi

# Install ComfyUI-KJNodes (pinned to v1.1.9 - commit e64b67b8f4aa3a555cec61cf18ee7d1cfbb3e5f0)
# This version is tested and stable with our ComfyUI setup
if [ ! -d "ComfyUI-KJNodes" ]; then
    echo "Installing ComfyUI-KJNodes v1.1.9..."
    git clone https://github.com/kijai/ComfyUI-KJNodes.git
    cd ComfyUI-KJNodes
    git checkout e64b67b8f4aa3a555cec61cf18ee7d1cfbb3e5f0
    cd ..
fi

# Install ComfyUI-VideoHelperSuite
if [ ! -d "ComfyUI-VideoHelperSuite" ]; then
    echo "Installing ComfyUI-VideoHelperSuite..."
    git clone https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite.git
fi

# Install masquerade-nodes-comfyui
if [ ! -d "masquerade-nodes-comfyui" ]; then
    echo "Installing masquerade-nodes-comfyui..."
    git clone https://github.com/BadCafeCode/masquerade-nodes-comfyui.git
fi

# Install ComfyLiterals
if [ ! -d "ComfyLiterals" ]; then
    echo "Installing ComfyLiterals..."
    git clone https://github.com/M1kep/ComfyLiterals.git
fi

# Install ComfyUI_Fill-Nodes
if [ ! -d "ComfyUI_Fill-Nodes" ]; then
    echo "Installing ComfyUI_Fill-Nodes..."
    git clone https://github.com/filliptm/ComfyUI_Fill-Nodes.git
fi

# Install ComfyUI_LayerStyle
if [ ! -d "ComfyUI_LayerStyle" ]; then
    echo "Installing ComfyUI_LayerStyle..."
    git clone https://github.com/chflame163/ComfyUI_LayerStyle.git
fi

# Install ComfyUI_LayerStyle_Advance
if [ ! -d "ComfyUI_LayerStyle_Advance" ]; then
    echo "Installing ComfyUI_LayerStyle_Advance..."
    git clone https://github.com/chflame163/ComfyUI_LayerStyle_Advance.git
fi

# Install ComfyUI_performance-report (skip if using latest ComfyUI - incompatible with new execute signature)
if [ "$COMFYUI_USE_LATEST" != "true" ]; then
    if [ ! -d "ComfyUI_performance-report" ]; then
        echo "Installing ComfyUI_performance-report..."
        git clone https://github.com/njlent/ComfyUI_performance-report.git
    fi
else
    echo "⚠️ Skipping ComfyUI_performance-report (incompatible with latest ComfyUI)"
    # Remove existing installation if present to prevent errors
    if [ -d "ComfyUI_performance-report" ]; then
        echo "  → Removing existing ComfyUI_performance-report (incompatible)..."
        rm -rf ComfyUI_performance-report
    fi
fi

# Install ComfyUI_Upscale-utils (PRIVATE REPO - requires GITHUB_TOKEN env var)
# Set GITHUB_TOKEN in RunPod environment variables to enable this
if [ ! -d "ComfyUI_Upscale-utils" ]; then
    if [ -n "$GITHUB_TOKEN" ]; then
        echo "Installing ComfyUI_Upscale-utils (private repo)..."
        git clone https://${GITHUB_TOKEN}@github.com/njlent/ComfyUI_Upscale-utils.git
        if [ -d "ComfyUI_Upscale-utils" ]; then
            echo "  ✅ ComfyUI_Upscale-utils installed successfully"
            # Install requirements if they exist
            if [ -f "ComfyUI_Upscale-utils/requirements.txt" ]; then
                echo "  → Installing ComfyUI_Upscale-utils dependencies..."
                pip install -r ComfyUI_Upscale-utils/requirements.txt
            fi
        else
            echo "  ❌ ComfyUI_Upscale-utils installation failed"
        fi
    else
        echo "⏭️  Skipping ComfyUI_Upscale-utils (private repo) - GITHUB_TOKEN not set"
    fi
fi

# Install LanPaint
if [ ! -d "LanPaint" ]; then
    echo "Installing LanPaint..."
    git clone https://github.com/scraed/LanPaint.git
fi

# Install ComfyUI-MatAnyone (video matting node)
# Force reinstall if __init__.py is missing (incomplete clone)
if [ ! -f "ComfyUI-MatAnyone/__init__.py" ]; then
    echo "Installing ComfyUI-MatAnyone..."
    rm -rf ComfyUI-MatAnyone
    git clone --recursive https://github.com/FuouM/ComfyUI-MatAnyone.git
    # Verify the clone was successful
    if [ -f "ComfyUI-MatAnyone/__init__.py" ]; then
        echo "  ✅ ComfyUI-MatAnyone installed successfully"
        ls -la ComfyUI-MatAnyone/
    else
        echo "  ❌ ComfyUI-MatAnyone installation failed - __init__.py not found"
    fi
fi

# Install ComfyUI-Custom-Scripts (pythongosssss) - no requirements.txt needed
if [ ! -d "ComfyUI-Custom-Scripts" ]; then
    echo "Installing ComfyUI-Custom-Scripts..."
    git clone https://github.com/pythongosssss/ComfyUI-Custom-Scripts.git
fi

# Install ComfyUI-basic_data_handling
if [ ! -d "ComfyUI-basic_data_handling" ]; then
    echo "Installing ComfyUI-basic_data_handling..."
    git clone https://github.com/StableLlama/ComfyUI-basic_data_handling.git
fi

# Install ComfyUI-mxToolkit
if [ ! -d "ComfyUI-mxToolkit" ]; then
    echo "Installing ComfyUI-mxToolkit..."
    git clone https://github.com/Smirnov75/ComfyUI-mxToolkit.git
fi

# Install ComfyUI-Easy-Use
if [ ! -d "ComfyUI-Easy-Use" ]; then
    echo "Installing ComfyUI-Easy-Use..."
    git clone https://github.com/yolain/ComfyUI-Easy-Use.git
fi

# Install ComfyUI_essentials
if [ ! -d "ComfyUI_essentials" ]; then
    echo "Installing ComfyUI_essentials..."
    git clone https://github.com/cubiq/ComfyUI_essentials.git
fi

# Install ComfyUI-Wan-VACE-Prep (no external dependencies)
if [ ! -d "ComfyUI-Wan-VACE-Prep" ]; then
    echo "Installing ComfyUI-Wan-VACE-Prep..."
    git clone https://github.com/stuttlepress/ComfyUI-Wan-VACE-Prep.git
fi

# ============================================================================
# FLUX Custom Nodes - Only installed when DOWNLOAD_FLUX=true
# ============================================================================
if [ "$DOWNLOAD_FLUX" = "true" ]; then
    echo ""
    echo "🎨 Installing FLUX custom nodes (DOWNLOAD_FLUX=true)..."

    # Install rgthree-comfy (workflow utilities)
    if [ ! -d "rgthree-comfy" ]; then
        echo "Installing rgthree-comfy..."
        git clone https://github.com/rgthree/rgthree-comfy.git
    fi

    # Install ComfyUI-GGUF (GGUF model support - required for FLUX GGUF models)
    if [ ! -d "ComfyUI-GGUF" ]; then
        echo "Installing ComfyUI-GGUF..."
        git clone https://github.com/city96/ComfyUI-GGUF.git
    fi

    # Install ComfyUI_UltimateSDUpscale
    if [ ! -d "ComfyUI_UltimateSDUpscale" ]; then
        echo "Installing ComfyUI_UltimateSDUpscale..."
        git clone https://github.com/ssitu/ComfyUI_UltimateSDUpscale.git
    fi

    # Install ComfyUI-Detail-Daemon
    if [ ! -d "ComfyUI-Detail-Daemon" ]; then
        echo "Installing ComfyUI-Detail-Daemon..."
        git clone https://github.com/Jonseed/ComfyUI-Detail-Daemon.git
    fi

    # Install ComfyUI-DyPE
    if [ ! -d "ComfyUI-DyPE" ]; then
        echo "Installing ComfyUI-DyPE..."
        git clone https://github.com/wildminder/ComfyUI-DyPE.git
    fi

    # Install ComfyUI-Flux-Continuum
    if [ ! -d "ComfyUI-Flux-Continuum" ]; then
        echo "Installing ComfyUI-Flux-Continuum..."
        git clone https://github.com/robertvoy/ComfyUI-Flux-Continuum.git
    fi

    echo "✅ FLUX custom nodes installed!"
else
    echo "⏭️  FLUX custom nodes SKIPPED (DOWNLOAD_FLUX=false)"
fi

echo "📚 Installing custom node dependencies..."

# WAN Video Wrapper dependencies
echo "  → WAN Video Wrapper..."
uv pip install --no-cache \
    ftfy \
    accelerate>=1.2.1 \
    einops \
    diffusers>=0.33.0 \
    peft>=0.17.0 \
    sentencepiece>=0.2.0 \
    protobuf \
    pyloudnorm \
    gguf>=0.17.1 \
    opencv-python \
    scipy

# ComfyUI-KJNodes dependencies (v1.1.9)
# Note: librosa is in pyproject.toml but not requirements.txt, so we add it explicitly
if [ -f "ComfyUI-KJNodes/requirements.txt" ]; then
    echo "  → ComfyUI-KJNodes..."
    uv pip install --no-cache -r ComfyUI-KJNodes/requirements.txt librosa
fi

# ComfyUI-VideoHelperSuite dependencies
if [ -f "ComfyUI-VideoHelperSuite/requirements.txt" ]; then
    echo "  → ComfyUI-VideoHelperSuite..."
    uv pip install --no-cache -r ComfyUI-VideoHelperSuite/requirements.txt
fi

# ComfyUI_Fill-Nodes dependencies
if [ -f "ComfyUI_Fill-Nodes/requirements.txt" ]; then
    echo "  → ComfyUI_Fill-Nodes..."
    uv pip install --no-cache -r ComfyUI_Fill-Nodes/requirements.txt
fi

# ComfyUI_LayerStyle dependencies
# Requires opencv-contrib-python for guidedFilter function
if [ -f "ComfyUI_LayerStyle/requirements.txt" ]; then
    echo "  → ComfyUI_LayerStyle..."
    uv pip install --no-cache -r ComfyUI_LayerStyle/requirements.txt
    # Install opencv-contrib-python for guidedFilter (replaces opencv-python)
    uv pip install --no-cache opencv-contrib-python
fi

# ComfyUI_LayerStyle_Advance dependencies
# Requires specific timm version for RotaryEmbedding compatibility
if [ -f "ComfyUI_LayerStyle_Advance/requirements.txt" ]; then
    echo "  → ComfyUI_LayerStyle_Advance..."
    uv pip install --no-cache -r ComfyUI_LayerStyle_Advance/requirements.txt
    # Pin timm to compatible version (0.9.x has RotaryEmbedding)
    uv pip install --no-cache "timm>=0.9.0,<1.0.0"
fi

# ComfyUI_performance-report dependencies (skip if using latest ComfyUI)
if [ "$COMFYUI_USE_LATEST" != "true" ] && [ -f "ComfyUI_performance-report/requirements.txt" ]; then
    echo "  → ComfyUI_performance-report..."
    uv pip install --no-cache -r ComfyUI_performance-report/requirements.txt
fi

# ComfyUI-MatAnyone dependencies (torch is already installed, just need omegaconf)
if [ -d "ComfyUI-MatAnyone" ]; then
    echo "  → ComfyUI-MatAnyone..."
    # omegaconf is the main dependency (torch is already installed)
    uv pip install --no-cache omegaconf
    if [ -f "ComfyUI-MatAnyone/requirements.txt" ]; then
        # Also install from requirements.txt in case there are other deps
        uv pip install --no-cache -r ComfyUI-MatAnyone/requirements.txt
    fi
fi

# ComfyUI-Easy-Use dependencies
if [ -f "ComfyUI-Easy-Use/requirements.txt" ]; then
    echo "  → ComfyUI-Easy-Use..."
    uv pip install --no-cache -r ComfyUI-Easy-Use/requirements.txt
fi

# ComfyUI_essentials dependencies
if [ -f "ComfyUI_essentials/requirements.txt" ]; then
    echo "  → ComfyUI_essentials..."
    uv pip install --no-cache -r ComfyUI_essentials/requirements.txt
fi

# ComfyUI-mxToolkit dependencies
if [ -f "ComfyUI-mxToolkit/requirements.txt" ]; then
    echo "  → ComfyUI-mxToolkit..."
    uv pip install --no-cache -r ComfyUI-mxToolkit/requirements.txt
fi

# ComfyUI-basic_data_handling dependencies
if [ -f "ComfyUI-basic_data_handling/requirements.txt" ]; then
    echo "  → ComfyUI-basic_data_handling..."
    uv pip install --no-cache -r ComfyUI-basic_data_handling/requirements.txt
fi

# ComfyUI core audio dependencies (for nodes_audio.py, nodes_lt_audio.py, nodes_audio_encoder.py)
echo "  → ComfyUI core audio dependencies..."
uv pip install --no-cache librosa soundfile

# FLUX custom node dependencies (only if DOWNLOAD_FLUX=true)
if [ "$DOWNLOAD_FLUX" = "true" ]; then
    echo "  → FLUX custom nodes dependencies..."

    # ComfyUI-GGUF dependencies
    if [ -f "ComfyUI-GGUF/requirements.txt" ]; then
        echo "    → ComfyUI-GGUF..."
        uv pip install --no-cache -r ComfyUI-GGUF/requirements.txt
    fi

    # rgthree-comfy dependencies
    if [ -f "rgthree-comfy/requirements.txt" ]; then
        echo "    → rgthree-comfy..."
        uv pip install --no-cache -r rgthree-comfy/requirements.txt
    fi

    # ComfyUI_UltimateSDUpscale dependencies
    if [ -f "ComfyUI_UltimateSDUpscale/requirements.txt" ]; then
        echo "    → ComfyUI_UltimateSDUpscale..."
        uv pip install --no-cache -r ComfyUI_UltimateSDUpscale/requirements.txt
    fi

    # ComfyUI-Detail-Daemon dependencies
    if [ -f "ComfyUI-Detail-Daemon/requirements.txt" ]; then
        echo "    → ComfyUI-Detail-Daemon..."
        uv pip install --no-cache -r ComfyUI-Detail-Daemon/requirements.txt
    fi

    # ComfyUI-DyPE dependencies
    if [ -f "ComfyUI-DyPE/requirements.txt" ]; then
        echo "    → ComfyUI-DyPE..."
        uv pip install --no-cache -r ComfyUI-DyPE/requirements.txt
    fi

    # ComfyUI-Flux-Continuum dependencies
    if [ -f "ComfyUI-Flux-Continuum/requirements.txt" ]; then
        echo "    → ComfyUI-Flux-Continuum..."
        uv pip install --no-cache -r ComfyUI-Flux-Continuum/requirements.txt
    fi
fi

echo "✅ Custom nodes and dependencies installed!"

fi  # End of ALREADY_INITIALIZED=false block (custom nodes section)

# ============================================================================
# GPU_TYPE Configuration - Set in RunPod Environment Variables
# ============================================================================
# GPU_TYPE=H200    - Build SageAttention from source with SM90 kernels (Hopper)
# GPU_TYPE=H100    - Build SageAttention from source with SM90 kernels (Hopper)
# GPU_TYPE=5090    - Use prebuilt wheel (Ada Lovelace/Blackwell consumer)
# GPU_TYPE=6000    - Use prebuilt wheel (RTX Pro 6000 Ada)
# GPU_TYPE=auto    - Auto-detect from nvidia-smi (default)
# ============================================================================
: "${GPU_TYPE:=auto}"

# Quick check: skip SageAttention install if already importable
SAGE_ALREADY_INSTALLED=false
if python -c "from sageattention import sageattn" 2>/dev/null; then
    echo "==================================================================="
    echo "✅ SageAttention already installed - skipping installation"
    echo "==================================================================="
    SAGE_ALREADY_INSTALLED=true
fi

if [ "$SAGE_ALREADY_INSTALLED" = false ]; then

echo "==================================================================="
echo "⚡ SageAttention2++ Installation Starting"
echo "==================================================================="
echo "📦 Installing SageAttention dependencies..."
echo ""

# SageAttention REQUIRES triton to work properly!
# Without triton, SageAttention will fail silently and output noise
# Using prebuilt Triton wheel from Kijai for better compatibility with PyTorch 2.7
TRITON_WHEEL_URL="https://huggingface.co/Kijai/PrecompiledWheels/resolve/main/triton-3.3.0-cp312-cp312-linux_x86_64.whl"

echo "📦 Installing Triton 3.3.0 from prebuilt wheel (required for SageAttention)..."
echo "   URL: $TRITON_WHEEL_URL"
uv pip install --no-cache packaging "$TRITON_WHEEL_URL"

# Auto-detect GPU type if not specified
if [ "$GPU_TYPE" = "auto" ]; then
    echo ""
    echo "🔍 Auto-detecting GPU type..."
    DETECTED_GPU=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -n1)

    if [ -z "$DETECTED_GPU" ]; then
        echo "   ❌ nvidia-smi failed or no GPU detected!"
        echo "   Defaulting to prebuilt wheel..."
        GPU_TYPE="PREBUILT"
    else
        echo "   Detected: '$DETECTED_GPU'"

        # nvidia-smi naming conventions (case-insensitive matching):
        # - Hopper:    "NVIDIA H200", "NVIDIA H100"
        # - Blackwell: "NVIDIA RTX PRO 6000 Blackwell", "NVIDIA GeForce RTX 5090", "NVIDIA B200"
        # - Ada:       "NVIDIA RTX 6000 Ada Generation", "NVIDIA GeForce RTX 4090"
        # - Ampere:    "NVIDIA A100", "NVIDIA GeForce RTX 3090"

        # Convert to uppercase for consistent matching
        DETECTED_GPU_UPPER=$(echo "$DETECTED_GPU" | tr '[:lower:]' '[:upper:]')

        # Detection order: Most specific patterns first
        # 1. Hopper datacenter (H200, H100) - needs source build for SM90
        if echo "$DETECTED_GPU_UPPER" | grep -qE "H200|H100"; then
            GPU_TYPE="H200"
            echo "   → Hopper datacenter GPU (H200/H100) - will build from source"

        # 2. RTX PRO 6000/5000 Blackwell - needs source build for SM120
        elif echo "$DETECTED_GPU_UPPER" | grep -qE "(RTX PRO 6000|RTX PRO 5000).*BLACKWELL|BLACKWELL.*(RTX PRO 6000|RTX PRO 5000)"; then
            GPU_TYPE="PRO_BLACKWELL"
            echo "   → RTX PRO Blackwell workstation GPU - will build from source (SM120)"

        # 3. GeForce RTX 50-series (Blackwell consumer) - needs source build for SM120
        elif echo "$DETECTED_GPU_UPPER" | grep -qE "RTX 5090|RTX 5080|RTX 5070|RTX 5060"; then
            GPU_TYPE="RTX50"
            echo "   → GeForce RTX 50-series (Blackwell) - will build from source (SM120)"

        # 4. Blackwell datacenter (B200, B100, GB200) - needs source build for SM100
        elif echo "$DETECTED_GPU_UPPER" | grep -qE "B200|B100|GB200"; then
            GPU_TYPE="B200"
            echo "   → Blackwell datacenter GPU (B200/GB200) - will build from source"

        # 5. RTX 6000 Ada - uses prebuilt wheel
        elif echo "$DETECTED_GPU_UPPER" | grep -qE "RTX 6000|RTX 5000 ADA"; then
            GPU_TYPE="6000"
            echo "   → RTX Ada workstation GPU - will use prebuilt wheel"

        # 6. GeForce RTX 40-series (Ada consumer) - uses prebuilt wheel
        elif echo "$DETECTED_GPU_UPPER" | grep -qE "RTX 4090|RTX 4080|RTX 4070|RTX 4060"; then
            GPU_TYPE="4090"
            echo "   → GeForce RTX 40-series (Ada) - will use prebuilt wheel"

        # 7. Ampere datacenter (A100, A6000) - uses prebuilt wheel
        elif echo "$DETECTED_GPU_UPPER" | grep -qE "A100|A6000|A5000|A4000|A40|A30|A10"; then
            GPU_TYPE="A100"
            echo "   → Ampere datacenter/pro GPU - will use prebuilt wheel"

        # 8. GeForce RTX 30-series (Ampere consumer) - uses prebuilt wheel
        elif echo "$DETECTED_GPU_UPPER" | grep -qE "RTX 3090|RTX 3080|RTX 3070|RTX 3060"; then
            GPU_TYPE="3090"
            echo "   → GeForce RTX 30-series (Ampere) - will use prebuilt wheel"

        # 9. L40, L4 (Ada datacenter) - uses prebuilt wheel
        elif echo "$DETECTED_GPU_UPPER" | grep -qE "L40|L4"; then
            GPU_TYPE="L40"
            echo "   → Ada datacenter GPU (L40/L4) - will use prebuilt wheel"

        # 10. Unknown - default to prebuilt wheel
        else
            GPU_TYPE="PREBUILT"
            echo "   → Unknown GPU type, defaulting to prebuilt wheel"
        fi
    fi
else
    echo ""
    echo "📋 GPU_TYPE set explicitly via environment variable: $GPU_TYPE"
fi

echo "   Final GPU_TYPE=$GPU_TYPE"

# Determine installation method based on GPU type
case "$GPU_TYPE" in
    H200|H100|h200|h100)
        # Build from source for Hopper GPUs (SM90)
        echo ""
        echo "==================================================================="
        echo "🚀 Building SageAttention from source for Hopper (SM90)..."
        echo "==================================================================="
        echo "⚠️  Prebuilt wheels don't include SM90 kernels for H200/H100 GPUs"
        echo "   Building from source to compile CUDA kernels for this GPU..."
        echo ""

        # Install build dependencies
        echo "📦 Installing build dependencies (wheel, setuptools, ninja)..."
        uv pip install --no-cache wheel setuptools ninja

        # Clone and build SageAttention from source
        cd /tmp
        if [ -d "SageAttention" ]; then
            rm -rf SageAttention
        fi

        echo "📥 Cloning SageAttention repository..."
        git clone https://github.com/thu-ml/SageAttention.git
        cd SageAttention

        echo ""
        echo "🔨 Compiling CUDA kernels with parallel build..."
        echo "   This may take 3-5 minutes depending on GPU..."
        echo "-------------------------------------------------------------------"

        # Build with parallel compilation for speed
        # CRITICAL: Explicitly set TORCH_CUDA_ARCH_LIST to include SM90 for H200/Hopper GPUs
        export TORCH_CUDA_ARCH_LIST="9.0"
        export EXT_PARALLEL=4
        export NVCC_APPEND_FLAGS="--threads 8"
        export MAX_JOBS=32

        # Use --no-build-isolation to use already-installed torch/triton for CUDA detection
        pip install . --no-cache-dir --no-build-isolation

        BUILD_RESULT=$?

        # Clean up build artifacts
        cd /
        rm -rf /tmp/SageAttention

        if [ $BUILD_RESULT -eq 0 ]; then
            echo "-------------------------------------------------------------------"
            echo ""
            echo "✅ SageAttention2++ built successfully from source!"
            echo "   SM90 kernels compiled for Hopper architecture"
            SAGE_VERIFY_SM90=true
        else
            echo ""
            echo "❌ SageAttention2++ build failed!"
            echo "   Check GPU availability and CUDA toolkit"
            exit 1
        fi
        ;;

    B200|B100|GB200|b200|b100|gb200)
        # Build from source for Blackwell datacenter GPUs (SM100)
        echo ""
        echo "==================================================================="
        echo "🚀 Building SageAttention from source for Blackwell (SM100)..."
        echo "==================================================================="
        echo "⚠️  Prebuilt wheels don't include SM100 kernels for B200/GB200 GPUs"
        echo "   Building from source to compile CUDA kernels for this GPU..."
        echo ""

        # Install build dependencies
        echo "📦 Installing build dependencies (wheel, setuptools, ninja)..."
        uv pip install --no-cache wheel setuptools ninja

        # Clone and build SageAttention from source
        cd /tmp
        if [ -d "SageAttention" ]; then
            rm -rf SageAttention
        fi

        echo "📥 Cloning SageAttention repository..."
        git clone https://github.com/thu-ml/SageAttention.git
        cd SageAttention

        echo ""
        echo "🔨 Compiling CUDA kernels with parallel build..."
        echo "   This may take 3-5 minutes depending on GPU..."
        echo "-------------------------------------------------------------------"

        # Build with parallel compilation for speed
        # CRITICAL: Explicitly set TORCH_CUDA_ARCH_LIST to include SM100 for Blackwell GPUs
        export TORCH_CUDA_ARCH_LIST="10.0"
        export EXT_PARALLEL=4
        export NVCC_APPEND_FLAGS="--threads 8"
        export MAX_JOBS=32

        # Use --no-build-isolation to use already-installed torch/triton for CUDA detection
        pip install . --no-cache-dir --no-build-isolation

        BUILD_RESULT=$?

        # Clean up build artifacts
        cd /
        rm -rf /tmp/SageAttention

        if [ $BUILD_RESULT -eq 0 ]; then
            echo "-------------------------------------------------------------------"
            echo ""
            echo "✅ SageAttention2++ built successfully from source!"
            echo "   SM100 kernels compiled for Blackwell architecture"
            SAGE_VERIFY_SM90=false
        else
            echo ""
            echo "❌ SageAttention2++ build failed!"
            echo "   Check GPU availability and CUDA toolkit"
            exit 1
        fi
        ;;

    PRO_BLACKWELL|RTX50|pro_blackwell|rtx50)
        # Build from source for Blackwell consumer/workstation GPUs (SM120)
        echo ""
        echo "==================================================================="
        echo "🚀 Building SageAttention from source for Blackwell (SM120)..."
        echo "==================================================================="
        echo "⚠️  Prebuilt wheels don't include SM120 kernels for RTX 50-series/PRO Blackwell GPUs"
        echo "   Building from source to compile CUDA kernels for this GPU..."
        echo ""

        # Install build dependencies
        echo "📦 Installing build dependencies (wheel, setuptools, ninja)..."
        uv pip install --no-cache wheel setuptools ninja

        # Clone and build SageAttention from source
        cd /tmp
        if [ -d "SageAttention" ]; then
            rm -rf SageAttention
        fi

        echo "📥 Cloning SageAttention repository..."
        git clone https://github.com/thu-ml/SageAttention.git
        cd SageAttention

        echo ""
        echo "🔨 Compiling CUDA kernels with parallel build..."
        echo "   This may take 3-5 minutes depending on GPU..."
        echo "-------------------------------------------------------------------"

        # Build with parallel compilation for speed
        # CRITICAL: Explicitly set TORCH_CUDA_ARCH_LIST to include SM120 for Blackwell GPUs
        export TORCH_CUDA_ARCH_LIST="12.0"
        export EXT_PARALLEL=4
        export NVCC_APPEND_FLAGS="--threads 8"
        export MAX_JOBS=32

        # Use --no-build-isolation to use already-installed torch/triton for CUDA detection
        pip install . --no-cache-dir --no-build-isolation

        BUILD_RESULT=$?

        # Clean up build artifacts
        cd /
        rm -rf /tmp/SageAttention

        if [ $BUILD_RESULT -eq 0 ]; then
            echo "-------------------------------------------------------------------"
            echo ""
            echo "✅ SageAttention2++ built successfully from source!"
            echo "   SM120 kernels compiled for Blackwell architecture"
            SAGE_VERIFY_SM90=false
        else
            echo ""
            echo "❌ SageAttention2++ build failed!"
            echo "   Check GPU availability and CUDA toolkit"
            exit 1
        fi
        ;;

    6000|4090|4080|4070|4060|A100|A6000|A5000|A4000|A40|A30|A10|3090|3080|3070|3060|L40|L4|PREBUILT)
        # Use prebuilt wheel for Ada Lovelace / Ampere GPUs (NOT Blackwell!)
        echo ""
        echo "==================================================================="
        echo "📦 Installing SageAttention from prebuilt wheel..."
        echo "==================================================================="
        echo "   Using Kijai's prebuilt wheel for $GPU_TYPE GPU"
        echo ""

        SAGE_WHEEL_URL="https://huggingface.co/Kijai/PrecompiledWheels/resolve/main/sageattention-2.2.0-cp312-cp312-linux_x86_64.whl"
        echo "📥 Downloading: $SAGE_WHEEL_URL"
        uv pip install --no-cache "$SAGE_WHEEL_URL"

        if [ $? -eq 0 ]; then
            echo ""
            echo "✅ SageAttention2++ installed from prebuilt wheel!"
        else
            echo ""
            echo "❌ SageAttention2++ wheel installation failed!"
            exit 1
        fi
        SAGE_VERIFY_SM90=false
        ;;

    *)
        # Unknown GPU type - try prebuilt wheel as fallback
        echo ""
        echo "==================================================================="
        echo "⚠️  Unknown GPU_TYPE: $GPU_TYPE"
        echo "==================================================================="
        echo "   Falling back to prebuilt wheel..."
        echo ""

        SAGE_WHEEL_URL="https://huggingface.co/Kijai/PrecompiledWheels/resolve/main/sageattention-2.2.0-cp312-cp312-linux_x86_64.whl"
        echo "📥 Downloading: $SAGE_WHEEL_URL"
        uv pip install --no-cache "$SAGE_WHEEL_URL"

        if [ $? -eq 0 ]; then
            echo ""
            echo "✅ SageAttention2++ installed from prebuilt wheel!"
        else
            echo ""
            echo "❌ SageAttention2++ wheel installation failed!"
            exit 1
        fi
        SAGE_VERIFY_SM90=false
        ;;
esac

# Verify SageAttention is importable and triton is working
echo ""
echo "🧪 Verifying SageAttention installation..."

if [ "$SAGE_VERIFY_SM90" = true ]; then
    # Verify with SM90 check for Hopper GPUs
    python -c "
import sys
try:
    import triton
    print(f'  ✅ Triton {triton.__version__} - OK')
except ImportError as e:
    print(f'  ❌ Triton import failed: {e}')
    sys.exit(1)

try:
    from sageattention import sageattn
    print(f'  ✅ SageAttention - OK')
except ImportError as e:
    print(f'  ❌ SageAttention import failed: {e}')
    sys.exit(1)

# CRITICAL: Verify SM90 kernels are available for H200/Hopper GPUs
try:
    from sageattention.core import SM90_ENABLED
    if SM90_ENABLED:
        print(f'  ✅ SM90 kernels (H200/Hopper) - ENABLED')
    else:
        print(f'  ❌ SM90 kernels NOT enabled - H200 will fail!')
        print(f'     Rebuild SageAttention with TORCH_CUDA_ARCH_LIST=9.0')
        sys.exit(1)
except ImportError:
    # Older versions may not have this check
    print(f'  ⚠️  Could not verify SM90 status (older SageAttention version)')

print('  ✅ All SageAttention dependencies verified!')
"
else
    # Verify without SM90 check for Ada/Blackwell
    python -c "
import sys
try:
    import triton
    print(f'  ✅ Triton {triton.__version__} - OK')
except ImportError as e:
    print(f'  ❌ Triton import failed: {e}')
    sys.exit(1)

try:
    from sageattention import sageattn
    print(f'  ✅ SageAttention - OK')
except ImportError as e:
    print(f'  ❌ SageAttention import failed: {e}')
    sys.exit(1)

print('  ✅ All SageAttention dependencies verified!')
"
fi

if [ $? -ne 0 ]; then
    echo "❌ SageAttention verification failed!"
    echo "   ComfyUI will not work properly with --use-sage-attention"
    exit 1
fi

echo "==================================================================="
echo ""

fi  # End of SAGE_ALREADY_INSTALLED=false block

echo "📓 Installing JupyterLab with full functionality..."
uv pip install --no-cache \
    jupyterlab \
    ipykernel \
    jupyter-server-terminals \
    ipywidgets \
    matplotlib \
    pandas \
    notebook \
    jupyter-archive

# Register Python kernel explicitly for JupyterLab
echo "🔧 Registering Python kernel..."
python -m ipykernel install --name="python3" --display-name="Python 3 (ipykernel)" --sys-prefix

# Verify kernel installation
echo "✅ Installed kernels:"
jupyter kernelspec list

# Create JupyterLab configuration
echo "⚙️  Configuring JupyterLab..."
mkdir -p /root/.jupyter
cat > /root/.jupyter/jupyter_lab_config.py << 'EOF'
# Server settings
c.ServerApp.ip = '0.0.0.0'
c.ServerApp.port = 8189
c.ServerApp.allow_root = True
c.ServerApp.open_browser = False
c.ServerApp.token = ''
c.ServerApp.password = ''
c.ServerApp.root_dir = '/comfyui'

# CRITICAL: Security settings for RunPod proxy access
# RunPod uses proxy URLs (e.g., xxxxx-8189.proxy.runpod.net) which are not "local"
# Without these settings, JupyterLab blocks POST requests (file uploads, folder creation)
# and WebSocket connections (terminal) with 403 Forbidden errors
c.ServerApp.allow_remote_access = True  # Allow non-local Host headers (RunPod proxy)
c.ServerApp.allow_origin = '*'          # Allow CORS from any origin
c.ServerApp.disable_check_xsrf = True   # Disable XSRF protection (safe in isolated container)
c.ServerApp.trust_xheaders = True       # Trust X-Forwarded-* headers from RunPod proxy

# Enable terminals
c.ServerApp.terminals_enabled = True

# File operations settings
c.FileContentsManager.delete_to_trash = False
c.ContentsManager.allow_hidden = True

# Terminal settings - explicitly configure shell
c.ServerApp.terminado_settings = {
    'shell_command': ['/bin/bash']
}

# Enable full file browser capabilities
c.ContentsManager.allow_hidden = True
c.FileContentsManager.always_delete_dir = True
EOF

# Initialize dummy git repo in /comfyui to prevent hangs
# Some packages (SageAttention/Triton) try to run `git describe --tags` for version detection
# If /comfyui isn't a git repo, this can hang forever during workflow execution
echo "🔧 Initializing git repo in /comfyui (prevents version detection hangs)..."
if [ ! -d "/comfyui/.git" ]; then
    cd /comfyui
    git init -q
    git config user.email "comfyui@local"
    git config user.name "ComfyUI"
    git commit --allow-empty -m "init" -q
    git tag v0.0.0
    cd /
fi

# Clean up
echo "🧹 Cleaning up..."
rm -rf /root/.cache/pip
rm -rf /root/.cache/uv
rm -rf /tmp/*

# Set proper permissions for JupyterLab file uploads and folder creation
# Using 777 to ensure full write access for all operations
echo "🔐 Setting permissions for JupyterLab..."
chmod -R 777 /comfyui
chown -R root:root /comfyui

# Ensure the .initialized marker is writable
chmod 666 /comfyui/.initialized 2>/dev/null || true

# Mark as initialized
touch /comfyui/.initialized

echo "==================================================================="
echo "✅ Runtime initialization complete!"
echo "==================================================================="

