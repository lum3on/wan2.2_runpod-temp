# WAN 2.2 RunPod Compute Template

![Docker Build](https://github.com/lum3on/wan2.2_runpod-temp/actions/workflows/docker-build.yml/badge.svg)

A custom RunPod **COMPUTE** Docker template for WAN 2.2 video generation with CUDA 12.8, PyTorch 2.8, ComfyUI, ComfyUI Manager, WAN Video Wrapper, and JupyterLab.

<!-- Last updated: 2025-12-22 - GHCR token refreshed -->

**Template Type:** Compute (not serverless)
**ComfyUI:** Port 8188 (directly accessible)
**JupyterLab:** Port 8189 (full backend access)
**Auto-built:** Every push triggers automatic Docker build and GHCR deployment

## 🎯 Features

- **CUDA 12.8.1** - Latest CUDA support for Blackwell GPUs (RTX 5090, B200)
- **PyTorch 2.8.0** - Latest PyTorch with CUDA 12.8 support
- **Python 3.12** - Modern Python runtime
- **ComfyUI** - Latest version with full workflow support
- **SageAttention3** - Optimized attention mechanism for Blackwell GPUs (CRITICAL for performance)
- **ComfyUI Manager** - Easy custom node management
- **WAN Video Wrapper** - Complete WAN 2.2 video generation support
- **JupyterLab** - Full file system access for backend management
- **Pre-downloaded Models** - All WAN 2.2 models included (fp8 scaled for efficiency)

## 📦 What's Included

### Custom Nodes
- **ComfyUI-Manager** - Node package manager
- **ComfyUI-WanVideoWrapper** - WAN 2.2 video generation nodes

### Pre-installed Models
All models are downloaded during Docker build:

- **Text Encoders** (`/comfyui/models/text_encoders/`)
  - `t5xxl_fp8_e4m3fn.safetensors`
  - `clip_l.safetensors`

- **CLIP Vision** (`/comfyui/models/clip_vision/`)
  - `sigclip_vision_patch14_384.safetensors`

- **Transformer** (`/comfyui/models/diffusion_models/`)
  - `wan2.2_1.3B_fp8_scaled.safetensors` (main video model)

- **VAE** (`/comfyui/models/vae/`)
  - `wan_vae.safetensors`

### Services
- **ComfyUI API** - Port 8188 (with SageAttention3 enabled)
- **JupyterLab** - Port 8189 (full file system access)

## 🚀 Quick Start

### Automated Builds (Recommended)

**Every push to this repository automatically builds and publishes the Docker image to GHCR!**

- **Image URL:** `ghcr.io/lum3on/wan22-runpod:latest`
- **Build Status:** Check the badge above
- **No manual builds needed** - Just push your changes and the image updates automatically

### Option 1: Use Pre-built Image (Recommended)

The image is automatically built and available on GitHub Container Registry:

```bash
# Pull the latest image
docker pull ghcr.io/lum3on/wan22-runpod:latest

# Run locally for testing
docker run -d --gpus all \
  -p 8188:8188 -p 8189:8189 \
  ghcr.io/lum3on/wan22-runpod:latest
```

### Option 2: Build Locally (For Development)

```bash
# Clone this repository
git clone https://github.com/lum3on/wan2.2_runpod-temp.git
cd wan2.2_runpod-temp

# Build the Docker image
docker build -f Dockerfile.wan22 -t wan22-runpod:latest .

# Run with docker-compose
docker-compose -f docker-compose.wan22.yml up -d
```

### Option 3: Deploy to RunPod (Compute Pod)

**Public Image Available:** `ghcr.io/lum3on/wan22-runpod:latest`

1. **Use Pre-built Image (Recommended)**
   - The image is already built and public on GitHub Container Registry
   - No need to build locally unless you want to customize

2. **Create RunPod Compute Template**
   - Go to [RunPod Console](https://www.runpod.io/console/pods)
   - Click "New Template" or use existing template
   - Set Docker Image: `ghcr.io/lum3on/wan22-runpod:latest`
   - Container Disk: 50 GB (minimum)
   - **Expose HTTP Ports:** `8188,8189` (CRITICAL!)
   - Environment Variables (optional):
     - `COMFY_LOG_LEVEL=DEBUG`
     - `GPU_TYPE=auto` (see GPU Types below)
     - `LUMEON_GITHUB_TOKEN=<your_token>` (required for private `LumeonLAB/comfyui_lum3on-upscale`)

3. **Deploy Compute Pod**
   - Go to [RunPod Pods](https://www.runpod.io/console/pods)
   - Click "Deploy" or "New Pod"
   - Select your template
   - Configure GPU (RTX 5090 or B200 recommended for SageAttention3)
   - **Important:** Make sure ports 8188 and 8189 are exposed
   - Deploy!

4. **Access Your Services**
   - Once deployed, RunPod will provide you with connection URLs
   - **ComfyUI:** `https://<pod-id>-8188.proxy.runpod.net`
   - **JupyterLab:** `https://<pod-id>-8189.proxy.runpod.net`

## 🔧 Usage

### Accessing Services

After deployment on RunPod, you can access:

- **ComfyUI Interface**: `https://<pod-id>-8188.proxy.runpod.net`
- **JupyterLab**: `https://<pod-id>-8189.proxy.runpod.net`

**Note:** RunPod provides HTTPS proxy URLs for exposed ports. Replace `<pod-id>` with your actual pod ID.

### JupyterLab Access

JupyterLab provides full file system access to:
- `/comfyui/` - ComfyUI root directory
- `/comfyui/models/` - All model directories
- `/comfyui/custom_nodes/` - Custom nodes
- `/comfyui/output/` - Generated outputs
- `/comfyui/input/` - Input files

**Note**: JupyterLab is configured with no password for easy access. In production, consider adding authentication.

### Using ComfyUI

1. **Access the Web Interface:**
   - Open `https://<pod-id>-8188.proxy.runpod.net` in your browser
   - You'll see the ComfyUI interface
   - Load workflows from the WAN Video Wrapper examples

2. **Using the API:**
   ```bash
   # Get system stats
   curl https://<pod-id>-8188.proxy.runpod.net/system_stats

   # Submit a workflow (use ComfyUI's API format)
   curl -X POST https://<pod-id>-8188.proxy.runpod.net/prompt \
     -H "Content-Type: application/json" \
     -d '{"prompt": {...}}'
   ```

## 📁 Directory Structure

```
/comfyui/
├── models/
│   ├── text_encoders/      # T5 and CLIP text encoders
│   ├── clip_vision/        # CLIP vision models
│   ├── diffusion_models/   # WAN transformer models
│   ├── vae/                # VAE models
│   ├── checkpoints/        # Additional checkpoints
│   ├── loras/              # LoRA models
│   └── ...
├── custom_nodes/
│   ├── ComfyUI-Manager/
│   └── ComfyUI-WanVideoWrapper/
├── input/                  # Input files
├── output/                 # Generated outputs
└── workflows/              # Saved workflows
```

## 🎨 Example Workflows

Check the `example_workflows/` directory in the WAN Video Wrapper for sample workflows:
- Text-to-Video (T2V)
- Image-to-Video (I2V)
- Video-to-Video (V2V)
- Camera control
- And more!

## 🔍 Model Sources

All models are sourced from:
- **Main Models**: [Kijai/WanVideo_comfy](https://huggingface.co/Kijai/WanVideo_comfy)
- **FP8 Scaled Models**: [Kijai/WanVideo_comfy_fp8_scaled](https://huggingface.co/Kijai/WanVideo_comfy_fp8_scaled)

## 💾 Storage Requirements

- **Docker Image**: ~15-20 GB
- **Models**: ~10-15 GB (included in image)
- **Runtime**: 5-10 GB (for outputs and temp files)
- **Recommended Total**: 50 GB minimum

## ⚙️ Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `COMFY_LOG_LEVEL` | `DEBUG` | ComfyUI logging level (DEBUG, INFO, WARNING, ERROR) |
| `GPU_TYPE` | `auto` | GPU type for SageAttention build method (see below) |
| `COMFYUI_USE_LATEST` | `false` | Use latest ComfyUI instead of pinned v0.3.56 |
| `LUMEON_GITHUB_TOKEN` | unset | GitHub personal access token used to clone private `LumeonLAB/comfyui_lum3on-upscale` at runtime |

### GPU_TYPE Values

| Value | Description | SageAttention Install Method |
|-------|-------------|------------------------------|
| `auto` | Auto-detect GPU from nvidia-smi (default) | Automatic |
| `PRO_BLACKWELL` | NVIDIA RTX PRO 6000/5000 Blackwell | Build from source with SM120 kernels |
| `RTX50` | NVIDIA RTX 5090/5080/5070 (Blackwell) | Build from source with SM120 kernels |
| `B200` | NVIDIA B200/GB200 (Blackwell datacenter) | Build from source with SM100 kernels |
| `H200` | NVIDIA H200 (Hopper) | Build from source with SM90 kernels |
| `H100` | NVIDIA H100 (Hopper) | Build from source with SM90 kernels |
| `6000` | NVIDIA RTX 6000 Ada | Prebuilt wheel |
| `4090` | NVIDIA RTX 4090 (Ada Lovelace) | Prebuilt wheel |

**Note:** Blackwell GPUs (RTX 50-series, RTX PRO Blackwell, B200) require building SageAttention from source because prebuilt wheels don't include SM120/SM100 kernels. H200/H100 GPUs also require source builds for SM90 kernels. Ada/Ampere GPUs can use the faster prebuilt wheel installation.

## 🔄 CI/CD Automation

This repository uses **GitHub Actions** for automated Docker builds and deployment:

### How It Works

1. **Automatic Builds**: Every push to `master` branch triggers a Docker build
2. **GHCR Push**: Successfully built images are automatically pushed to GitHub Container Registry
3. **Build Caching**: GitHub Actions cache speeds up subsequent builds by 50%+
4. **Multiple Tags**: Images are tagged with:
   - `latest` (for main branch)
   - Git SHA (for traceability)
   - Version tags (if you push `v*.*.*` tags)

### Workflow File

See [`.github/workflows/docker-build.yml`](.github/workflows/docker-build.yml) for the complete workflow configuration.

### Manual Trigger

You can also manually trigger a build:
1. Go to [Actions tab](https://github.com/lum3on/wan2.2_runpod-temp/actions)
2. Select "Build and Push Docker Image to GHCR"
3. Click "Run workflow"
4. Optionally specify a custom tag

### Build Status

Check the build status badge at the top of this README or visit the [Actions page](https://github.com/lum3on/wan2.2_runpod-temp/actions).

## 🐛 Troubleshooting

### CI/CD Issues

**Build failing in GitHub Actions:**
- Check the [Actions tab](https://github.com/lum3on/wan2.2_runpod-temp/actions) for error logs
- Verify Dockerfile syntax is correct
- Ensure all required files are committed

**Image not appearing in GHCR:**
- Verify GitHub Actions has package write permissions
- Check that the workflow completed successfully
- Visit [Packages](https://github.com/lum3on?tab=packages) to see published images

### ComfyUI not starting
- Check logs: `docker logs wan22-comfyui`
- Verify GPU is available: `nvidia-smi`
- Ensure CUDA 12.8 drivers are installed

### Models not loading
- Check model paths in JupyterLab
- Verify models were downloaded during build
- Check disk space: `df -h`

### JupyterLab not accessible
- Verify port 8189 is exposed in RunPod template
- Check that the pod is running
- Try accessing via RunPod's proxy URL: `https://<pod-id>-8189.proxy.runpod.net`

### ComfyUI not accessible
- Verify port 8188 is exposed in RunPod template
- Check that ComfyUI started successfully in pod logs
- Try accessing via RunPod's proxy URL: `https://<pod-id>-8188.proxy.runpod.net`

## 📚 Additional Resources

- [ComfyUI Documentation](https://github.com/comfyanonymous/ComfyUI)
- [WAN Video Wrapper](https://github.com/kijai/ComfyUI-WanVideoWrapper)
- [RunPod Documentation](https://docs.runpod.io/)
- [Original RunPod Worker](https://github.com/runpod-workers/worker-comfyui)

## 🤝 Contributing

Contributions are welcome! Please feel free to submit issues or pull requests.

## 📄 License

This project is based on:
- [runpod-workers/worker-comfyui](https://github.com/runpod-workers/worker-comfyui) - AGPL-3.0
- [kijai/ComfyUI-WanVideoWrapper](https://github.com/kijai/ComfyUI-WanVideoWrapper) - Apache-2.0

## 🙏 Acknowledgments

- RunPod team for the original worker-comfyui
- Kijai for the WAN Video Wrapper
- ComfyUI community
- WAN Video team

## 📞 Support

For issues and questions:
- Open an issue on GitHub
- Check the RunPod Discord
- Review ComfyUI documentation

---

**Built with ❤️ for the ComfyUI and RunPod community**

