#!/usr/bin/env bash
# WAN 2.2 Runtime Initialization Script
# Installs ComfyUI, PyTorch, and custom nodes at container startup
# This runs in RunPod where disk space is abundant

set -e

echo "==================================================================="
echo "WAN 2.2 Runtime Initialization"
echo "==================================================================="

# Check if already initialized (for persistent storage)
if [ -f "/comfyui/.initialized" ]; then
    echo "✅ Already initialized - skipping setup"
    exit 0
fi

echo "📦 Installing ComfyUI ${COMFYUI_VERSION:-v0.3.55}..."
cd /
/usr/bin/yes | comfy --workspace /comfyui install --version "${COMFYUI_VERSION:-v0.3.55}" --nvidia

# Copy extra_model_paths.yaml for network volume support
if [ -f "/etc/extra_model_paths.yaml" ]; then
    echo "📋 Copying extra_model_paths.yaml for network volume support..."
    cp /etc/extra_model_paths.yaml /comfyui/extra_model_paths.yaml
fi

# Install PyTorch 2.7.1 with CUDA 12.8 support (pinned version for stability)
# Note: Latest PyTorch (2.9.x) may have compatibility issues with some custom nodes
echo "🔥 Installing PyTorch 2.7.1 with CUDA 12.8 support..."
pip install --no-cache-dir \
    torch==2.7.1+cu128 \
    torchvision==0.22.1+cu128 \
    torchaudio==2.7.1+cu128 \
    --index-url https://download.pytorch.org/whl/cu128

echo "⚡ Installing HuggingFace CLI for fast model downloads..."
uv pip install --no-cache huggingface-hub[cli,hf_transfer]
export HF_HUB_ENABLE_HF_TRANSFER=1

echo "🧩 Installing custom nodes..."
cd /comfyui/custom_nodes

# Install ComfyUI Manager (pinned to v3.37.1 - last version before v3.38 security migration)
# v3.38+ requires ComfyUI v0.3.76+ which we don't use
# FORCE reinstall to ensure correct version (removes any existing installation)
MANAGER_VERSION="3.37.1"
if [ -d "ComfyUI-Manager" ]; then
    echo "Removing existing ComfyUI-Manager to ensure correct version..."
    rm -rf ComfyUI-Manager
fi
echo "Installing ComfyUI-Manager v${MANAGER_VERSION}..."
git clone --branch ${MANAGER_VERSION} --depth 1 https://github.com/ltdrdata/ComfyUI-Manager.git

# Install ComfyUI-Manager dependencies
echo "📦 Installing ComfyUI-Manager dependencies..."
if [ -f "ComfyUI-Manager/requirements.txt" ]; then
    pip install -r ComfyUI-Manager/requirements.txt
fi

# Configure ComfyUI-Manager with security_level=weak
# This is required for ComfyUI-Manager v3.37.1 with ComfyUI v0.3.55
echo "⚙️  Configuring ComfyUI-Manager (security_level=weak)..."

# Create config in multiple locations to ensure it works
# Location 1: Inside ComfyUI-Manager custom node directory (v3.37.1 location)
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

# Install WAN Video Wrapper (pinned to v1.3.0 - commit d9def84332e50af26ec5cde080d4c3703b837520)
# This version is tested and stable with our ComfyUI setup
if [ ! -d "ComfyUI-WanVideoWrapper" ]; then
    echo "Installing ComfyUI-WanVideoWrapper v1.3.0..."
    git clone https://github.com/kijai/ComfyUI-WanVideoWrapper.git
    cd ComfyUI-WanVideoWrapper
    git checkout d9def84332e50af26ec5cde080d4c3703b837520
    cd ..
fi

# Install ComfyUI-KJNodes
if [ ! -d "ComfyUI-KJNodes" ]; then
    echo "Installing ComfyUI-KJNodes..."
    git clone https://github.com/kijai/ComfyUI-KJNodes.git
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

# Install ComfyUI_performance-report
if [ ! -d "ComfyUI_performance-report" ]; then
    echo "Installing ComfyUI_performance-report..."
    git clone https://github.com/njlent/ComfyUI_performance-report.git
fi

# Install LanPaint
if [ ! -d "LanPaint" ]; then
    echo "Installing LanPaint..."
    git clone https://github.com/scraed/LanPaint.git
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

# ComfyUI-KJNodes dependencies
if [ -f "ComfyUI-KJNodes/requirements.txt" ]; then
    echo "  → ComfyUI-KJNodes..."
    uv pip install --no-cache -r ComfyUI-KJNodes/requirements.txt
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
if [ -f "ComfyUI_LayerStyle/requirements.txt" ]; then
    echo "  → ComfyUI_LayerStyle..."
    uv pip install --no-cache -r ComfyUI_LayerStyle/requirements.txt
fi

# ComfyUI_LayerStyle_Advance dependencies
if [ -f "ComfyUI_LayerStyle_Advance/requirements.txt" ]; then
    echo "  → ComfyUI_LayerStyle_Advance..."
    uv pip install --no-cache -r ComfyUI_LayerStyle_Advance/requirements.txt
fi

# ComfyUI_performance-report dependencies
if [ -f "ComfyUI_performance-report/requirements.txt" ]; then
    echo "  → ComfyUI_performance-report..."
    uv pip install --no-cache -r ComfyUI_performance-report/requirements.txt
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
SAGEATTENTION_WHEEL_URL="https://huggingface.co/Kijai/PrecompiledWheels/resolve/main/sageattention-2.2.0-cp312-cp312-linux_x86_64.whl"

echo "� Installing Triton 3.3.0 from prebuilt wheel (required for SageAttention)..."
echo "   URL: $TRITON_WHEEL_URL"
uv pip install --no-cache packaging "$TRITON_WHEEL_URL"

echo ""
echo "📦 Installing SageAttention 2.2.0 from prebuilt wheel..."
echo "   URL: $SAGEATTENTION_WHEEL_URL"
echo ""

uv pip install --no-cache "$SAGEATTENTION_WHEEL_URL"

if [ $? -eq 0 ]; then
    echo ""
    echo "✅ SageAttention2++ wheel installed successfully!"
    echo "   Using prebuilt wheel - no compilation needed!"
else
    echo ""
    echo "❌ SageAttention2++ installation failed!"
    echo "   Attempted to install from: $SAGEATTENTION_WHEEL_URL"
    exit 1
fi

# Verify SageAttention is importable and triton is working
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

