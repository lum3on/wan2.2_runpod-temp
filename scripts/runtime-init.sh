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
# COMFYUI_USE_LATEST=false  - Use pinned stable version v0.3.55 (default)
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
        echo "📦 Installing ComfyUI ${COMFYUI_VERSION:-v0.3.55} (stable)..."
        COMFY_SKIP_FETCH_REGISTRY=1 /usr/bin/yes | comfy --workspace /comfyui install --version "${COMFYUI_VERSION:-v0.3.55}" --nvidia
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
# - COMFYUI_USE_LATEST=false → Use v3.37.1 (for stable ComfyUI v0.3.55)
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
# When COMFYUI_USE_LATEST=false: Use v3.37.1 (last version compatible with v0.3.55)
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
    # Stable ComfyUI v0.3.55 needs pinned ComfyUI-Manager v3.37.1
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

# Skip the rest if already initialized
if [ "$ALREADY_INITIALIZED" = true ]; then
    echo "==================================================================="
    echo "✅ ComfyUI-Manager verified/fixed - skipping remaining setup"
    echo "==================================================================="
    exit 0
fi

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

echo "✅ Custom nodes and dependencies installed!"

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

echo ""
echo "==================================================================="
echo "🚀 Building SageAttention from source for GPU architecture..."
echo "==================================================================="
echo "⚠️  Prebuilt wheels don't include SM90 kernels for H200/Hopper GPUs"
echo "   Building from source to compile CUDA kernels for this GPU..."
echo ""

# Install build dependencies
echo "📦 Installing build dependencies (wheel, setuptools, ninja)..."
uv pip install --no-cache wheel setuptools ninja

# Clone and build SageAttention from source
# This ensures SM90 kernels are compiled for H200 GPUs (compute capability 9.0)
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
# Without this, the build may not compile SM90 kernels even when running on H200
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
    echo "   SM90 kernels compiled for this GPU architecture"
else
    echo ""
    echo "❌ SageAttention2++ build failed!"
    echo "   Check GPU availability and CUDA toolkit"
    exit 1
fi

# Verify SageAttention is importable, triton is working, AND SM90 kernels are available
echo ""
echo "🧪 Verifying SageAttention installation..."
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

if [ $? -ne 0 ]; then
    echo "❌ SageAttention verification failed!"
    echo "   ComfyUI will not work properly with --use-sage-attention"
    exit 1
fi

echo "==================================================================="
echo ""

echo "📓 Installing JupyterLab with full functionality..."
uv pip install --no-cache \
    jupyterlab \
    ipykernel \
    jupyter-server-terminals \
    ipywidgets \
    matplotlib \
    pandas \
    notebook

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

