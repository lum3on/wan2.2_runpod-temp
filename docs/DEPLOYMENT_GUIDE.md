# WAN 2.2 RunPod Template - Deployment Guide

## 🎯 Quick Start

This guide will help you build and deploy the WAN 2.2 ComfyUI template to GitHub Container Registry (GHCR) for use with RunPod.

---

## 📋 Prerequisites

### Required
- ✅ **Docker Desktop** installed and running
- ✅ **NVIDIA GPU** with CUDA support (for local testing)
- ✅ **GitHub Account** (for GHCR)
- ✅ **GitHub Personal Access Token** (PAT) with package permissions

### Optional
- RunPod account (for deployment)
- 50GB+ free disk space (for building)

---

## 🔑 Step 1: Create GitHub Personal Access Token

1. Go to: https://github.com/settings/tokens
2. Click **"Generate new token (classic)"**
3. Give it a name: `GHCR WAN 2.2 Template`
4. Select scopes:
   - ✅ `write:packages`
   - ✅ `read:packages`
   - ✅ `delete:packages`
5. Click **"Generate token"**
6. **COPY THE TOKEN** - you won't see it again!

---

## 🚀 Step 2: Build and Push to GHCR

### Option A: Windows (PowerShell) - RECOMMENDED

```powershell
# Run the automated script
.\build_and_deploy_ghcr.ps1
```

Then select option **5** (Quick build and push - skip testing)

### Option B: Linux/Mac (Bash)

```bash
# Make script executable
chmod +x build_and_deploy_ghcr.sh

# Run the script
./build_and_deploy_ghcr.sh
```

Then select option **5** (Quick build and push - skip testing)

### Option C: Manual Commands

```powershell
# 1. Login to GHCR
echo YOUR_GITHUB_TOKEN | docker login ghcr.io -u lum3on --password-stdin

# 2. Build the image (30-60 minutes)
docker build -f Dockerfile.wan22 -t ghcr.io/lum3on/wan22-runpod:latest --progress=plain .

# 3. Push to GHCR
docker push ghcr.io/lum3on/wan22-runpod:latest
```

---

## 📦 What's Being Built

Your Docker image includes:

### Base Stack
- **CUDA:** 12.8.1
- **PyTorch:** 2.8.0
- **Python:** 3.12
- **ComfyUI:** v0.3.55 (specific version)

### Custom Nodes
- ComfyUI Manager
- WAN Video Wrapper
- SageAttention3 (Blackwell GPU optimization)

### Pre-downloaded Models (~25GB)

#### Diffusion Models (14B fp16)
- `wan2.2_t2v_high_noise_14B_fp16.safetensors`
- `wan2.2_t2v_low_noise_14B_fp16.safetensors`

#### Text Encoders
- `umt5_xxl_fp16.safetensors`
- `umt5_xxl_fp8_e4m3fn_scaled.safetensors`

#### VAE
- `wan_2.1_vae.safetensors`

#### LoRAs
- `Instareal_high.safetensors`
- `Instareal_low.safetensors`
- `lightx2v_T2V_14B_cfg_step_distill_v2_lora_rank256_bf16.safetensors`

#### Upscale Models
- `4xNomosUniDAT_otf.pth`
- `4x-ClearRealityV1.pth`
- `1xSkinContrast-High-SuperUltraCompact.pth`
- `1xDeJPG_realplksr_otf.safetensors`
- `4x-UltraSharpV2_Lite.pth`

### Services
- **ComfyUI API:** Port 8188 (with SageAttention3)
- **JupyterLab:** Port 8189 (full filesystem access)

---

## 🌐 Step 3: Create RunPod Compute Template

**Note:** This is a COMPUTE template, not serverless. Use RunPod Pods, not Serverless Endpoints.

1. Go to: https://www.runpod.io/console/pods
2. Click **"New Template"** (or use the template section)
3. Configure:

   **Template Settings:**
   - **Template Name:** `WAN 2.2 ComfyUI v0.3.56 - Compute`
   - **Docker Image:** `ghcr.io/lum3on/wan22-runpod:latest` (PUBLIC)
   - **Container Disk:** `50 GB` (minimum)
   - **Expose HTTP Ports:** `8188,8189` ⚠️ **CRITICAL - Must expose both ports, with 8188 first!**

   **Environment Variables (Optional):**
   ```
   COMFY_LOG_LEVEL=DEBUG
   ```

4. Click **"Save Template"**

---

## 🎮 Step 4: Deploy Compute Pod

1. Go to: https://www.runpod.io/console/pods
2. Click **"Deploy"** or **"New Pod"**
3. Configure:
   - **Select Template:** Choose your WAN 2.2 template
   - **GPU Type:** RTX 5090 or B200 (recommended for SageAttention3)
   - **Volume:** Optional - for persistent storage
   - **Ports:** Verify 8188 and 8189 are exposed

4. Click **"Deploy"**
5. Wait for pod to start (2-5 minutes for model downloads)

---

## 🧪 Step 5: Test Your Deployment

### Access Services

Once deployed, RunPod will provide proxy URLs for your exposed ports:

- **ComfyUI Interface:** `https://<pod-id>-8188.proxy.runpod.net`
- **JupyterLab:** `https://<pod-id>-8189.proxy.runpod.net`

Use the private service port in the proxy URL. Do not use the mapped public port from RunPod runtime port mappings. If the Connect tab opens an Access Denied page, open `https://<pod-id>-8188.proxy.runpod.net/` directly and update the template HTTP port order to `8188,8189`.

**Finding your URLs:**
1. Go to your pod in RunPod console
2. Click on the pod
3. Look for "Connect" section
4. You'll see the proxy URLs for ports 8188 and 8189

### Test ComfyUI

**Web Interface:**
```
Open in browser: https://<pod-id>-8188.proxy.runpod.net
```

**API Test:**
```bash
curl https://<pod-id>-8188.proxy.runpod.net/system_stats
```

### Test JupyterLab

**Web Interface:**
```
Open in browser: https://<pod-id>-8189.proxy.runpod.net
```

Navigate to `/comfyui/models/` to verify all models are present.

---

## 📊 Image Specifications

| Component | Size | Details |
|-----------|------|---------|
| Base Image | ~5 GB | CUDA 12.8.1 + Ubuntu 24.04 |
| PyTorch | ~3 GB | PyTorch 2.8.0 with CUDA 12.8 |
| ComfyUI | ~2 GB | v0.3.56 + custom nodes |
| Models | ~25 GB | All WAN 2.2 models + LoRAs + upscalers |
| **Total** | **~35 GB** | Compressed image size |

**Build Time:** 30-60 minutes (depending on internet speed)

---

## 🔧 Troubleshooting

### Build Issues

**Problem:** Docker build fails with "out of space"
```powershell
# Clean up Docker
docker system prune -a --volumes
```

**Problem:** Model download fails
```powershell
# Check internet connection and retry
docker build --no-cache -f Dockerfile.wan22 -t ghcr.io/lum3on/wan22-runpod:latest .
```

### Push Issues

**Problem:** Authentication failed
```powershell
# Re-login to GHCR
echo YOUR_TOKEN | docker login ghcr.io -u lum3on --password-stdin
```

**Problem:** Image is private on GHCR
1. Go to: https://github.com/lum3on?tab=packages
2. Find `wan22-runpod` package
3. Click **"Package settings"**
4. Scroll to **"Danger Zone"**
5. Click **"Change visibility"** → **"Public"**

### RunPod Issues

**Problem:** ComfyUI not starting
- Check logs in RunPod console
- Verify GPU is available
- Increase execution timeout

**Problem:** Models not loading
- Check JupyterLab at port 8189
- Verify models in `/comfyui/models/`
- Check disk space

---

## 💡 Tips & Best Practices

### Cost Optimization
- Use **Idle Timeout: 5 seconds** to minimize costs
- Start with **1 worker** and scale up as needed
- Use **Spot instances** when available

### Performance
- **RTX 5090 or B200** GPUs get best performance with SageAttention3
- Increase **Max Workers** during peak usage
- Monitor **Queue Delay** in RunPod dashboard

### Development
- Use **JupyterLab** (port 8189) to:
  - Explore model directories
  - Debug workflows
  - Check logs
  - Upload custom models

---

## 📚 Additional Resources

- **ComfyUI Docs:** https://github.com/comfyanonymous/ComfyUI
- **WAN Video Wrapper:** https://github.com/kijai/ComfyUI-WanVideoWrapper
- **RunPod Docs:** https://docs.runpod.io/
- **GHCR Docs:** https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry

---

## 🆘 Support

If you encounter issues:

1. Check the troubleshooting section above
2. Review RunPod logs in the console
3. Check JupyterLab for filesystem issues
4. Open an issue on GitHub

---

## ✅ Deployment Checklist

- [ ] GitHub PAT created with package permissions
- [ ] Docker Desktop installed and running
- [ ] Dockerfile.wan22 reviewed and updated
- [ ] Image built successfully
- [ ] Image pushed to GHCR
- [ ] GHCR package set to public
- [ ] RunPod template created
- [ ] Serverless endpoint deployed
- [ ] ComfyUI API tested (port 8188)
- [ ] JupyterLab tested (port 8189)
- [ ] Models verified in JupyterLab

---

**Built with ❤️ for the ComfyUI and RunPod community**

