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

echo "🔥 Installing PyTorch with CUDA 12.8 support..."
pip install --no-cache-dir --upgrade \
    torch \
    torchvision \
    torchaudio \
    --index-url https://download.pytorch.org/whl/cu128

echo "🧩 Installing custom nodes..."
cd /comfyui/custom_nodes

# Install ComfyUI Manager
if [ ! -d "ComfyUI-Manager" ]; then
    echo "Installing ComfyUI-Manager..."
    git clone https://github.com/ltdrdata/ComfyUI-Manager.git
fi

# Install WAN Video Wrapper
if [ ! -d "ComfyUI-WanVideoWrapper" ]; then
    echo "Installing ComfyUI-WanVideoWrapper..."
    git clone https://github.com/kijai/ComfyUI-WanVideoWrapper.git
fi

echo "📚 Installing WAN Video Wrapper dependencies..."
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

echo "⚡ Installing SageAttention dependencies..."
uv pip install --no-cache \
    wheel \
    setuptools \
    packaging \
    ninja \
    triton

echo "🚀 Installing SageAttention2..."
uv pip install --no-cache sageattention

echo "📓 Installing JupyterLab..."
uv pip install --no-cache \
    jupyterlab \
    notebook \
    ipywidgets \
    matplotlib \
    pandas

# Create JupyterLab configuration
echo "⚙️  Configuring JupyterLab..."
mkdir -p /root/.jupyter
cat > /root/.jupyter/jupyter_lab_config.py << 'EOF'
c.ServerApp.ip = '0.0.0.0'
c.ServerApp.port = 8189
c.ServerApp.allow_root = True
c.ServerApp.open_browser = False
c.ServerApp.token = ''
c.ServerApp.password = ''
c.ServerApp.root_dir = '/comfyui'
EOF

# Clean up
echo "🧹 Cleaning up..."
rm -rf /root/.cache/pip
rm -rf /root/.cache/uv
rm -rf /tmp/*

# Mark as initialized
touch /comfyui/.initialized

echo "==================================================================="
echo "✅ Runtime initialization complete!"
echo "==================================================================="

