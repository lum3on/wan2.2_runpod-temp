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
# COMFYUI_USE_LATEST=true   - Install latest stable ComfyUI release tag
# COMFYUI_USE_LATEST=false  - Use pinned stable version v0.3.56 (default)
# ============================================================================
: "${COMFYUI_USE_LATEST:=false}"
: "${COMFYUI_DEFAULT_VERSION:=v0.3.56}"

if [ -n "${COMFYUI_CUDA_PROFILE:-}" ]; then
    CUDA_PROFILE="$COMFYUI_CUDA_PROFILE"
elif [ -n "${CUDA_PROFILE:-}" ]; then
    CUDA_PROFILE="$CUDA_PROFILE"
elif [ "$COMFYUI_USE_LATEST" = "true" ]; then
    CUDA_PROFILE="cu130"
else
    CUDA_PROFILE="cu128"
fi
COMFYUI_CUDA_PROFILE="$CUDA_PROFILE"
COMFYUI_REPO_URL="https://github.com/Comfy-Org/ComfyUI.git"
MANAGER_REPO_URL="https://github.com/Comfy-Org/ComfyUI-Manager.git"
WAN_WRAPPER_REPO_URL="https://github.com/kijai/ComfyUI-WanVideoWrapper.git"
KJNODES_REPO_URL="https://github.com/kijai/ComfyUI-KJNodes.git"
LATEST_WAN_WRAPPER_REF="088128b224242e110d3906c6750e9a3a348a659b"
LATEST_KJNODES_REF="bc8e4ce4254bcd0050383386ee2f9d753dbf1fa5"
COMFYUI_DIR="/comfyui"
COMFYUI_VENV="${COMFYUI_DIR}/.venv"
COMFYUI_PYTHON="${COMFYUI_VENV}/bin/python"
COMFYUI_JUPYTER="${COMFYUI_VENV}/bin/jupyter"

case "$CUDA_PROFILE" in
    cu128)
        PYTORCH_INDEX_URL="https://download.pytorch.org/whl/cu128"
        TORCH_VERSION="2.11.0+cu128"
        TORCHVISION_VERSION="0.26.0+cu128"
        TORCHAUDIO_VERSION="2.11.0+cu128"
        EXPECTED_TORCH_FLAVOR="cu128"
        EXPECTED_CUDA_VERSION="12.8"
        ;;
    cu130)
        PYTORCH_INDEX_URL="https://download.pytorch.org/whl/cu130"
        if [ "$COMFYUI_USE_LATEST" = "true" ]; then
            TORCH_VERSION="2.12.1+cu130"
            TORCHVISION_VERSION="0.27.1+cu130"
            TORCHAUDIO_VERSION=""
        else
            TORCH_VERSION="2.11.0+cu130"
            TORCHVISION_VERSION="0.26.0+cu130"
            TORCHAUDIO_VERSION="2.11.0+cu130"
        fi
        EXPECTED_TORCH_FLAVOR="cu130"
        EXPECTED_CUDA_VERSION="13.0"
        ;;
    *)
        echo "Unsupported CUDA profile: $CUDA_PROFILE"
        echo "Supported profiles: cu128, cu130"
        exit 1
        ;;
esac

resolve_latest_semver_tag() {
    local repo_url="$1"
    local tag_pattern="$2"
    local latest_tag

    latest_tag=$(git ls-remote --tags --refs "$repo_url" "$tag_pattern" \
        | awk -F/ '{print $NF}' \
        | grep -E '^v?[0-9]+[.][0-9]+[.][0-9]+$' \
        | sort -V \
        | tail -n1)

    if [ -z "$latest_tag" ]; then
        echo "Failed to resolve latest stable semver tag from $repo_url" >&2
        exit 1
    fi

    printf '%s\n' "$latest_tag"
}

normalize_version() {
    printf '%s' "$1" | sed -E 's/^v//'
}

read_installed_comfyui_version() {
    python - <<'PY'
from pathlib import Path

version_file = Path("/comfyui/comfyui_version.py")
if not version_file.exists():
    raise SystemExit(0)

namespace = {}
exec(version_file.read_text(encoding="utf-8", errors="ignore"), namespace)
print(namespace.get("__version__", ""))
PY
}

sync_repo_ref() {
    local repo_dir="$1"
    local repo_url="$2"
    local ref="$3"

    if [ -d "$repo_dir/.git" ]; then
        echo "  -> Updating ${repo_dir} to ${ref}"
        git -C "$repo_dir" fetch --tags --force origin
    else
        echo "  -> Cloning ${repo_dir} at ${ref}"
        rm -rf "$repo_dir"
        git clone "$repo_url" "$repo_dir"
    fi

    git -C "$repo_dir" checkout --force "$ref"
    git -C "$repo_dir" reset --hard "$ref"
}

log_repo_sha() {
    local repo_dir="$1"
    if [ -d "$repo_dir/.git" ]; then
        echo "  -> ${repo_dir} SHA: $(git -C "$repo_dir" rev-parse HEAD)"
    fi
}

pip_install_runtime() {
    if [ ! -x "$COMFYUI_PYTHON" ]; then
        echo "ComfyUI Python environment is missing: ${COMFYUI_PYTHON}" >&2
        exit 1
    fi

    uv pip install --python "$COMFYUI_PYTHON" --no-cache "$@"
}

use_comfyui_python_environment() {
    if [ ! -x "$COMFYUI_PYTHON" ]; then
        echo "ComfyUI install did not create the expected Python environment: ${COMFYUI_PYTHON}" >&2
        exit 1
    fi

    export VIRTUAL_ENV="$COMFYUI_VENV"
    export PATH="${COMFYUI_VENV}/bin:/opt/venv/bin:${PATH}"
    hash -r

    echo "Using ComfyUI runtime Python: $(python -c 'import sys; print(sys.executable)')"
}

sanitize_requirements_file() {
    local requirements_file="$1"
    local sanitized_file

    if [ "$COMFYUI_USE_LATEST" != "true" ]; then
        printf '%s\n' "$requirements_file"
        return 0
    fi

    sanitized_file="$(mktemp /tmp/comfy-reqs.XXXXXX.txt)"
    python - "$requirements_file" "$sanitized_file" <<'PY'
import re
import sys
from pathlib import Path

source = Path(sys.argv[1])
target = Path(sys.argv[2])
protected = {
    "torch",
    "torchvision",
    "torchaudio",
    "triton",
    "sageattention",
    "sageattn3",
    "flash-attn",
}

def requirement_name(line: str) -> str | None:
    stripped = line.strip()
    if not stripped or stripped.startswith("#"):
        return None
    if stripped.startswith(("-r", "--requirement", "-c", "--constraint")):
        return None
    if stripped.startswith("-e "):
        match = re.search(r"[#&]egg=([A-Za-z0-9_.-]+)", stripped)
        return match.group(1) if match else None
    if stripped.startswith(("git+", "http://", "https://")):
        match = re.search(r"[#&]egg=([A-Za-z0-9_.-]+)", stripped)
        return match.group(1) if match else None

    without_marker = stripped.split(";", 1)[0].strip()
    without_comment = without_marker.split("#", 1)[0].strip()
    match = re.match(r"([A-Za-z0-9_.-]+)", without_comment)
    return match.group(1) if match else None

kept: list[str] = []
removed: list[str] = []

for raw_line in source.read_text(encoding="utf-8", errors="ignore").splitlines():
    name = requirement_name(raw_line)
    normalized = name.lower().replace("_", "-") if name else ""
    if normalized in protected:
        removed.append(raw_line.strip())
        continue
    kept.append(raw_line)

target.write_text("\n".join(kept) + "\n", encoding="utf-8")

if removed:
    print(f"  -> sanitized {source}: removed protected dependencies:", file=sys.stderr)
    for line in removed:
        print(f"     - {line}", file=sys.stderr)
PY
    printf '%s\n' "$sanitized_file"
}

pip_install_requirements_runtime() {
    local requirements_file="$1"
    shift

    if [ "$COMFYUI_USE_LATEST" = "true" ]; then
        local sanitized_file
        local status=0

        sanitized_file="$(sanitize_requirements_file "$requirements_file")"
        pip_install_runtime -r "$sanitized_file" "$@" || status=$?
        rm -f "$sanitized_file"
        return "$status"
    fi

    pip_install_runtime -r "$requirements_file" "$@"
}

audit_pytorch_cuda_stack() {
    python - "$CUDA_PROFILE" "$EXPECTED_TORCH_FLAVOR" "$EXPECTED_CUDA_VERSION" <<'PY'
import sys

profile, expected_flavor, expected_cuda = sys.argv[1:4]

try:
    import torch
except Exception as exc:
    print(f"PyTorch import failed: {exc}")
    sys.exit(1)

print(f"torch.__version__ = {torch.__version__}")
print(f"torch.version.cuda = {torch.version.cuda}")

if f"+{expected_flavor}" not in torch.__version__:
    print(f"Expected PyTorch flavor +{expected_flavor} for profile {profile}")
    sys.exit(1)

if not torch.version.cuda or not torch.version.cuda.startswith(expected_cuda):
    print(f"Expected torch.version.cuda to start with {expected_cuda} for profile {profile}")
    sys.exit(1)

if torch.cuda.is_available():
    print(f"torch.cuda.get_device_name(0) = {torch.cuda.get_device_name(0)}")
    print(f"torch.cuda.get_device_capability(0) = {torch.cuda.get_device_capability(0)}")
else:
    print("torch.cuda.is_available() = False")

try:
    import triton
except Exception as exc:
    print(f"triton import failed: {exc}")
    sys.exit(1)

print(f"triton.__version__ = {triton.__version__}")
PY
}

ensure_cuda_pytorch_stack() {
    local stack_description="${TORCH_VERSION}, ${TORCHVISION_VERSION}"
    if [ -n "$TORCHAUDIO_VERSION" ]; then
        stack_description="${stack_description}, ${TORCHAUDIO_VERSION}"
    else
        stack_description="${stack_description}, torchaudio intentionally skipped"
    fi

    echo "Installing/verifying CUDA profile ${CUDA_PROFILE}: ${stack_description}"

    if python - "$TORCH_VERSION" "$TORCHVISION_VERSION" "$TORCHAUDIO_VERSION" <<'PY'
import sys
from importlib.metadata import version, PackageNotFoundError

expected = {
    "torch": sys.argv[1],
    "torchvision": sys.argv[2],
}
if sys.argv[3]:
    expected["torchaudio"] = sys.argv[3]

for package, expected_version in expected.items():
    try:
        installed = version(package)
    except PackageNotFoundError:
        sys.exit(1)
    if installed != expected_version:
        sys.exit(1)
PY
    then
        echo "  -> Selected PyTorch CUDA stack already installed"
    else
        install_args=(
            "torch==${TORCH_VERSION}"
            "torchvision==${TORCHVISION_VERSION}"
        )
        if [ -n "$TORCHAUDIO_VERSION" ]; then
            install_args+=("torchaudio==${TORCHAUDIO_VERSION}")
        fi

        "$COMFYUI_PYTHON" -m pip install --no-cache-dir --upgrade --force-reinstall \
            "${install_args[@]}" \
            --index-url "$PYTORCH_INDEX_URL"
    fi

    if [ -z "$TORCHAUDIO_VERSION" ]; then
        echo "  -> Removing torchaudio in latest CUDA 13 mode; no protected matching wheel is selected"
        "$COMFYUI_PYTHON" -m pip uninstall -y torchaudio >/dev/null 2>&1 || true
    fi

    audit_pytorch_cuda_stack
}

if [ "$COMFYUI_USE_LATEST" = "true" ]; then
    COMFYUI_VERSION="${COMFYUI_VERSION:-$(resolve_latest_semver_tag "$COMFYUI_REPO_URL" "refs/tags/v*")}"
    MANAGER_VERSION="${MANAGER_VERSION:-$(resolve_latest_semver_tag "$MANAGER_REPO_URL" "refs/tags/*")}"
    echo "COMFYUI_USE_LATEST=true resolved to stable ComfyUI ${COMFYUI_VERSION}"
    echo "Latest stable ComfyUI-Manager resolved to ${MANAGER_VERSION}"
else
    COMFYUI_VERSION="${COMFYUI_VERSION:-$COMFYUI_DEFAULT_VERSION}"
    MANAGER_VERSION="${MANAGER_VERSION:-3.37.1}"
fi

install_selected_comfyui() {
    local selected_version="$1"
    local mode_label="$2"
    local install_args=(
        --workspace /comfyui
        install
        --version "$selected_version"
        --nvidia
        --skip-torch-or-directml
    )

    if [ -d "/comfyui/.git" ]; then
        echo "Existing ComfyUI checkout found; using comfy install --restore for ${selected_version}."
        install_args+=(--restore)
    fi

    echo "Installing ComfyUI ${selected_version} (${mode_label})..."
    COMFY_SKIP_FETCH_REGISTRY=1 /usr/bin/yes | comfy "${install_args[@]}"
}

# Check if already initialized (for persistent storage)
ALREADY_INITIALIZED=false
if [ -f "/comfyui/.initialized" ]; then
    echo "✅ Main initialization already done - checking ComfyUI-Manager version..."
    ALREADY_INITIALIZED=true
fi

INSTALLED_COMFYUI_VERSION="$(read_installed_comfyui_version || true)"
EXPECTED_COMFYUI_VERSION="$(normalize_version "$COMFYUI_VERSION")"
COMFYUI_NEEDS_INSTALL=false

if [ "$ALREADY_INITIALIZED" = false ]; then
    COMFYUI_NEEDS_INSTALL=true
elif [ "$COMFYUI_USE_LATEST" = "true" ]; then
    # Latest mode intentionally refreshes the core checkout on every start.
    COMFYUI_NEEDS_INSTALL=true
elif [ -z "$INSTALLED_COMFYUI_VERSION" ]; then
    echo "⚠️  Could not detect installed ComfyUI version; reinstalling ${COMFYUI_VERSION}."
    COMFYUI_NEEDS_INSTALL=true
elif [ "$(normalize_version "$INSTALLED_COMFYUI_VERSION")" != "$EXPECTED_COMFYUI_VERSION" ]; then
    echo "⚠️  Installed ComfyUI ${INSTALLED_COMFYUI_VERSION} does not match selected ${COMFYUI_VERSION}; reinstalling."
    COMFYUI_NEEDS_INSTALL=true
else
    echo "✅ Installed ComfyUI ${INSTALLED_COMFYUI_VERSION} matches selected ${COMFYUI_VERSION}."
fi

if [ "$COMFYUI_NEEDS_INSTALL" = true ]; then
    cd /
    # COMFY_SKIP_FETCH_REGISTRY=1 prevents the slow "FETCH ComfyRegistry Data" during init
    # The registry fetch will happen when ComfyUI actually starts

    if [ "$COMFYUI_USE_LATEST" = "true" ]; then
        install_selected_comfyui "$COMFYUI_VERSION" "latest stable release"
    else
        install_selected_comfyui "${COMFYUI_VERSION:-v0.3.56}" "stable"
    fi

    INSTALLED_COMFYUI_VERSION="$(read_installed_comfyui_version || true)"
    if [ "$(normalize_version "$INSTALLED_COMFYUI_VERSION")" != "$EXPECTED_COMFYUI_VERSION" ]; then
        echo "❌ ComfyUI install ended on ${INSTALLED_COMFYUI_VERSION:-unknown}, expected ${COMFYUI_VERSION}."
        exit 1
    fi
fi

use_comfyui_python_environment

# Copy extra_model_paths.yaml for network volume support
if [ -f "/etc/extra_model_paths.yaml" ] && [ ! -f "/comfyui/extra_model_paths.yaml" ]; then
    echo "📋 Copying extra_model_paths.yaml for network volume support..."
    cp /etc/extra_model_paths.yaml /comfyui/extra_model_paths.yaml
fi

# Install the selected CUDA PyTorch stack before any custom-node requirements.
ensure_cuda_pytorch_stack

if [ "$ALREADY_INITIALIZED" = false ]; then
    echo "Installing HuggingFace CLI for fast model downloads..."
    pip_install_runtime "huggingface-hub[cli,hf_transfer]"
fi
export HF_HUB_ENABLE_HF_TRANSFER=1

update_node_repo() {
    local repo_dir="$1"

    if [ -d "$repo_dir/.git" ]; then
        echo "Updating ${repo_dir}..."
        git -C "$repo_dir" pull --ff-only || echo "  -> git pull failed for ${repo_dir}, continuing with existing checkout"
    fi
}

install_node_requirements() {
    local repo_dir="$1"
    shift

    if [ -f "${repo_dir}/requirements.txt" ]; then
        echo "  -> ${repo_dir}..."
        pip_install_requirements_runtime "${repo_dir}/requirements.txt" "$@"
    fi
}

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
    # MANAGER_VERSION was resolved from the latest non-beta semver tag above.
    MANAGER_NEEDS_INSTALL=false

    if [ -d "ComfyUI-Manager" ]; then
        # For latest mode, always update to get the newest version
        echo "   🔄 Updating ComfyUI-Manager to latest..."
        cd ComfyUI-Manager
        git fetch --tags --force origin
        git checkout --force "$MANAGER_VERSION"
        git reset --hard "$MANAGER_VERSION"
        cd ..
        MANAGER_NEEDS_INSTALL=false
    else
        MANAGER_NEEDS_INSTALL=true
    fi

    if [ "$MANAGER_NEEDS_INSTALL" = true ]; then
        rm -rf ComfyUI-Manager
        echo "   Installing ComfyUI-Manager (latest) from Comfy-Org..."
        git clone --branch "$MANAGER_VERSION" --depth 1 "$MANAGER_REPO_URL"
    fi

    # Install dependencies
    echo "   📦 Installing ComfyUI-Manager dependencies..."
    if [ -f "ComfyUI-Manager/requirements.txt" ]; then
        pip_install_requirements_runtime ComfyUI-Manager/requirements.txt
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
        git clone --branch ${MANAGER_VERSION} --depth 1 "$MANAGER_REPO_URL"

        # Install dependencies
        echo "📦 Installing ComfyUI-Manager dependencies..."
        if [ -f "ComfyUI-Manager/requirements.txt" ]; then
            pip_install_requirements_runtime ComfyUI-Manager/requirements.txt
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

write_manager_config() {
    local config_path="$1"
    mkdir -p "$(dirname "$config_path")"
    cat > "$config_path" << 'MANAGEREOF'
[default]
security_level = weak
network_mode = public
use_uv = True
allow_git_url_install = false
allow_pip_install = false
MANAGEREOF
    echo "   [OK] ComfyUI-Manager policy config created at $config_path"
}

# Manager v3.38+ reads /comfyui/user/__manager/config.ini when ComfyUI has
# the system user API; older versions read /comfyui/user/default/ComfyUI-Manager.
# The custom-node-local config path is kept for legacy compatibility.
write_manager_config "/comfyui/user/__manager/config.ini"
write_manager_config "/comfyui/user/default/ComfyUI-Manager/config.ini"
write_manager_config "/comfyui/custom_nodes/ComfyUI-Manager/config.ini"

# Custom nodes are refreshed on every startup so persistent volumes can
# pick up upstream fixes. Missing repos are still cloned on demand.
if [ "$ALREADY_INITIALIZED" = true ]; then
    echo "==================================================================="
    echo "✅ ComfyUI-Manager verified/fixed - refreshing custom nodes"
    echo "   (SageAttention & JupyterLab will still be checked)"
    echo "==================================================================="
else
    echo "🧩 Installing other custom nodes..."
fi

# Install WAN Video Wrapper.
if [ "$COMFYUI_USE_LATEST" = "true" ]; then
    echo "Installing/updating ComfyUI-WanVideoWrapper to latest-stable pinned commit..."
    sync_repo_ref "ComfyUI-WanVideoWrapper" "$WAN_WRAPPER_REPO_URL" "$LATEST_WAN_WRAPPER_REF"
    log_repo_sha "ComfyUI-WanVideoWrapper"
elif [ ! -d "ComfyUI-WanVideoWrapper" ]; then
    echo "Installing ComfyUI-WanVideoWrapper v1.3.0..."
    git clone https://github.com/kijai/ComfyUI-WanVideoWrapper.git
    cd ComfyUI-WanVideoWrapper
    git checkout d9def84332e50af26ec5cde080d4c3703b837520
    cd ..
fi

# Install ComfyUI-KJNodes.
if [ "$COMFYUI_USE_LATEST" = "true" ]; then
    echo "Installing/updating ComfyUI-KJNodes to latest-stable pinned commit..."
    sync_repo_ref "ComfyUI-KJNodes" "$KJNODES_REPO_URL" "$LATEST_KJNODES_REF"
    log_repo_sha "ComfyUI-KJNodes"
elif [ ! -d "ComfyUI-KJNodes" ]; then
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
else
    update_node_repo "ComfyUI-VideoHelperSuite"
fi

# Install masquerade-nodes-comfyui
if [ ! -d "masquerade-nodes-comfyui" ]; then
    echo "Installing masquerade-nodes-comfyui..."
    git clone https://github.com/BadCafeCode/masquerade-nodes-comfyui.git
else
    update_node_repo "masquerade-nodes-comfyui"
fi

# Install ComfyLiterals
if [ ! -d "ComfyLiterals" ]; then
    echo "Installing ComfyLiterals..."
    git clone https://github.com/M1kep/ComfyLiterals.git
else
    update_node_repo "ComfyLiterals"
fi

# Install ComfyUI_Fill-Nodes
if [ ! -d "ComfyUI_Fill-Nodes" ]; then
    echo "Installing ComfyUI_Fill-Nodes..."
    git clone https://github.com/filliptm/ComfyUI_Fill-Nodes.git
else
    update_node_repo "ComfyUI_Fill-Nodes"
fi

# Install ComfyUI_LayerStyle
if [ ! -d "ComfyUI_LayerStyle" ]; then
    echo "Installing ComfyUI_LayerStyle..."
    git clone https://github.com/chflame163/ComfyUI_LayerStyle.git
else
    update_node_repo "ComfyUI_LayerStyle"
fi

# Install ComfyUI_LayerStyle_Advance
if [ ! -d "ComfyUI_LayerStyle_Advance" ]; then
    echo "Installing ComfyUI_LayerStyle_Advance..."
    git clone https://github.com/chflame163/ComfyUI_LayerStyle_Advance.git
else
    update_node_repo "ComfyUI_LayerStyle_Advance"
fi

# Install ComfyUI_performance-report (skip if using latest ComfyUI - incompatible with new execute signature)
if [ "$COMFYUI_USE_LATEST" != "true" ]; then
    if [ ! -d "ComfyUI_performance-report" ]; then
        echo "Installing ComfyUI_performance-report..."
        git clone https://github.com/njlent/ComfyUI_performance-report.git
    else
        update_node_repo "ComfyUI_performance-report"
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
        git clone https://${GITHUB_TOKEN}@github.com/njlent/ComfyUI_Upscale-utils.git || true
        if [ -d "ComfyUI_Upscale-utils" ]; then
            echo "  ✅ ComfyUI_Upscale-utils installed successfully"
            install_node_requirements "ComfyUI_Upscale-utils"
        else
            echo "  ❌ ComfyUI_Upscale-utils installation failed"
        fi
    else
        echo "⏭️  Skipping ComfyUI_Upscale-utils (private repo) - GITHUB_TOKEN not set"
    fi
elif [ -n "$GITHUB_TOKEN" ]; then
    update_node_repo "ComfyUI_Upscale-utils"
fi

# Install LanPaint
if [ ! -d "LanPaint" ]; then
    echo "Installing LanPaint..."
    git clone https://github.com/scraed/LanPaint.git
else
    update_node_repo "LanPaint"
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
else
    update_node_repo "ComfyUI-Custom-Scripts"
fi

# Install ComfyUI-basic_data_handling
if [ ! -d "ComfyUI-basic_data_handling" ]; then
    echo "Installing ComfyUI-basic_data_handling..."
    git clone https://github.com/StableLlama/ComfyUI-basic_data_handling.git
else
    update_node_repo "ComfyUI-basic_data_handling"
fi

# Install ComfyUI-mxToolkit
if [ ! -d "ComfyUI-mxToolkit" ]; then
    echo "Installing ComfyUI-mxToolkit..."
    git clone https://github.com/Smirnov75/ComfyUI-mxToolkit.git
else
    update_node_repo "ComfyUI-mxToolkit"
fi

# Install ComfyUI-Easy-Use
if [ ! -d "ComfyUI-Easy-Use" ]; then
    echo "Installing ComfyUI-Easy-Use..."
    git clone https://github.com/yolain/ComfyUI-Easy-Use.git
else
    update_node_repo "ComfyUI-Easy-Use"
fi

# Install ComfyUI_essentials
if [ ! -d "ComfyUI_essentials" ]; then
    echo "Installing ComfyUI_essentials..."
    git clone https://github.com/cubiq/ComfyUI_essentials.git
else
    update_node_repo "ComfyUI_essentials"
fi

# Install ComfyUI-Wan-VACE-Prep (no external dependencies)
if [ ! -d "ComfyUI-Wan-VACE-Prep" ]; then
    echo "Installing ComfyUI-Wan-VACE-Prep..."
    git clone https://github.com/stuttlepress/ComfyUI-Wan-VACE-Prep.git
else
    update_node_repo "ComfyUI-Wan-VACE-Prep"
fi

# Install ComfyUI-WanAnimatePreprocess
if [ ! -d "ComfyUI-WanAnimatePreprocess" ]; then
    echo "Installing ComfyUI-WanAnimatePreprocess..."
    git clone https://github.com/kijai/ComfyUI-WanAnimatePreprocess.git
else
    update_node_repo "ComfyUI-WanAnimatePreprocess"
fi

# Install comfyui_controlnet_aux
if [ ! -d "comfyui_controlnet_aux" ]; then
    echo "Installing comfyui_controlnet_aux..."
    git clone https://github.com/Fannovel16/comfyui_controlnet_aux.git
else
    update_node_repo "comfyui_controlnet_aux"
fi

# Install comfyui_lum3on-upscale (PRIVATE REPO - requires LUMEON_GITHUB_TOKEN env var)
# Set LUMEON_GITHUB_TOKEN in RunPod environment variables to enable this
if [ ! -d "comfyui_lum3on-upscale" ]; then
    if [ -n "$LUMEON_GITHUB_TOKEN" ]; then
        echo "Installing comfyui_lum3on-upscale (private repo)..."
        git clone https://${LUMEON_GITHUB_TOKEN}@github.com/LumeonLAB/comfyui_lum3on-upscale.git || true
        if [ -d "comfyui_lum3on-upscale" ]; then
            echo "  ✅ comfyui_lum3on-upscale installed successfully"
        else
            echo "  ❌ comfyui_lum3on-upscale installation failed"
        fi
    else
        echo "⏭️  Skipping comfyui_lum3on-upscale (private repo) - LUMEON_GITHUB_TOKEN not set"
    fi
elif [ -n "$LUMEON_GITHUB_TOKEN" ]; then
    update_node_repo "comfyui_lum3on-upscale"
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
pip_install_runtime \
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
    pip_install_requirements_runtime ComfyUI-KJNodes/requirements.txt librosa
fi

# ComfyUI-VideoHelperSuite dependencies
install_node_requirements "ComfyUI-VideoHelperSuite"

# ComfyUI_Fill-Nodes dependencies
install_node_requirements "ComfyUI_Fill-Nodes"

# ComfyUI_LayerStyle dependencies
# Requires opencv-contrib-python for guidedFilter function
if [ -f "ComfyUI_LayerStyle/requirements.txt" ]; then
    echo "  → ComfyUI_LayerStyle..."
    pip_install_requirements_runtime ComfyUI_LayerStyle/requirements.txt
    # Install opencv-contrib-python for guidedFilter (replaces opencv-python)
    pip_install_runtime opencv-contrib-python
fi

# ComfyUI_LayerStyle_Advance dependencies
# Requires specific timm version for RotaryEmbedding compatibility
if [ -f "ComfyUI_LayerStyle_Advance/requirements.txt" ]; then
    echo "  → ComfyUI_LayerStyle_Advance..."
    pip_install_requirements_runtime ComfyUI_LayerStyle_Advance/requirements.txt
    # Pin timm to compatible version (0.9.x has RotaryEmbedding)
    pip_install_runtime "timm>=0.9.0,<1.0.0"
fi

# ComfyUI_performance-report dependencies (skip if using latest ComfyUI)
if [ "$COMFYUI_USE_LATEST" != "true" ] && [ -f "ComfyUI_performance-report/requirements.txt" ]; then
    echo "  → ComfyUI_performance-report..."
    pip_install_requirements_runtime ComfyUI_performance-report/requirements.txt
fi

# ComfyUI-MatAnyone dependencies (torch is already installed, just need omegaconf)
if [ -d "ComfyUI-MatAnyone" ]; then
    echo "  → ComfyUI-MatAnyone..."
    # omegaconf is the main dependency (torch is already installed)
    pip_install_runtime omegaconf
    if [ -f "ComfyUI-MatAnyone/requirements.txt" ]; then
        # Also install from requirements.txt in case there are other deps
        pip_install_requirements_runtime ComfyUI-MatAnyone/requirements.txt
    fi
fi

# ComfyUI-Easy-Use dependencies
install_node_requirements "ComfyUI-Easy-Use"

# ComfyUI_essentials dependencies
install_node_requirements "ComfyUI_essentials"

# ComfyUI-mxToolkit dependencies
install_node_requirements "ComfyUI-mxToolkit"

# ComfyUI-basic_data_handling dependencies
install_node_requirements "ComfyUI-basic_data_handling"

# ComfyUI-WanAnimatePreprocess dependencies
install_node_requirements "ComfyUI-WanAnimatePreprocess"

# comfyui_controlnet_aux dependencies
install_node_requirements "comfyui_controlnet_aux"

# comfyui_lum3on-upscale dependencies
install_node_requirements "comfyui_lum3on-upscale"

# ComfyUI core audio dependencies (for nodes_audio.py, nodes_lt_audio.py, nodes_audio_encoder.py)
echo "  → ComfyUI core audio dependencies..."
pip_install_runtime librosa soundfile

# FLUX custom node dependencies (only if DOWNLOAD_FLUX=true)
if [ "$DOWNLOAD_FLUX" = "true" ]; then
    echo "  → FLUX custom nodes dependencies..."

    # ComfyUI-GGUF dependencies
    if [ -f "ComfyUI-GGUF/requirements.txt" ]; then
        echo "    → ComfyUI-GGUF..."
        pip_install_requirements_runtime ComfyUI-GGUF/requirements.txt
    fi

    # rgthree-comfy dependencies
    if [ -f "rgthree-comfy/requirements.txt" ]; then
        echo "    → rgthree-comfy..."
        pip_install_requirements_runtime rgthree-comfy/requirements.txt
    fi

    # ComfyUI_UltimateSDUpscale dependencies
    if [ -f "ComfyUI_UltimateSDUpscale/requirements.txt" ]; then
        echo "    → ComfyUI_UltimateSDUpscale..."
        pip_install_requirements_runtime ComfyUI_UltimateSDUpscale/requirements.txt
    fi

    # ComfyUI-Detail-Daemon dependencies
    if [ -f "ComfyUI-Detail-Daemon/requirements.txt" ]; then
        echo "    → ComfyUI-Detail-Daemon..."
        pip_install_requirements_runtime ComfyUI-Detail-Daemon/requirements.txt
    fi

    # ComfyUI-DyPE dependencies
    if [ -f "ComfyUI-DyPE/requirements.txt" ]; then
        echo "    → ComfyUI-DyPE..."
        pip_install_requirements_runtime ComfyUI-DyPE/requirements.txt
    fi

    # ComfyUI-Flux-Continuum dependencies
    if [ -f "ComfyUI-Flux-Continuum/requirements.txt" ]; then
        echo "    → ComfyUI-Flux-Continuum..."
        pip_install_requirements_runtime ComfyUI-Flux-Continuum/requirements.txt
    fi
fi

echo "✅ Custom nodes and dependencies installed!"
echo "PyTorch CUDA stack audit after custom node dependency installs:"
audit_pytorch_cuda_stack

# ============================================================================
# SageAttention wheel and source-build helpers
# ============================================================================
SAGE2_SM120_WHEEL_FILENAME="sageattention-2.2.0+cu130torch2.12.1sm120-cp312-cp312-linux_x86_64.whl"
SAGE2_SM120_WHEEL_SHA256="8f45c7db35d5cc44a40df6d7821c5be4057ff98843dbf941b90f241e23e81eda"
SAGE2_SM120_WHEEL_URL="${SAGE2_SM120_WHEEL_URL:-https://huggingface.co/yo9otatara/prebuilt_wheels/resolve/main/sageattention-2.2.0%2Bcu130torch2.12.1sm120-cp312-cp312-linux_x86_64.whl}"

SAGE3_SM120_WHEEL_FILENAME="sageattn3-1.0.0+cu130torch2.12.1sm120-cp312-cp312-linux_x86_64.whl"
SAGE3_SM120_WHEEL_SHA256="1da00b96bc5519ffa91120170a0e815478a89aa09eeaf7a68c22241ccf3f990d"
SAGE3_SM120_WHEEL_URL="${SAGE3_SM120_WHEEL_URL:-https://huggingface.co/yo9otatara/prebuilt_wheels/resolve/main/sageattn3-1.0.0%2Bcu130torch2.12.1sm120-cp312-cp312-linux_x86_64.whl}"

download_and_install_verified_wheel() {
    local package_label="$1"
    local filename="$2"
    local url="$3"
    local expected_sha256="$4"
    local wheel_path="/tmp/${filename}"
    local actual_sha256

    rm -f "$wheel_path"
    echo "Downloading ${package_label} wheel to ${wheel_path}"
    curl -fL --retry 3 --retry-delay 2 -o "$wheel_path" "$url"

    actual_sha256="$(sha256sum "$wheel_path" | awk '{print $1}')"
    if [ "$actual_sha256" != "$expected_sha256" ]; then
        echo "Hash verification failed for ${package_label}"
        echo "  expected: ${expected_sha256}"
        echo "  actual:   ${actual_sha256}"
        rm -f "$wheel_path"
        return 1
    fi

    echo "Hash verified for ${package_label}: ${actual_sha256}"
    "$COMFYUI_PYTHON" -m pip install --no-cache-dir --no-deps --force-reinstall "$wheel_path"
}

verify_sage2_import() {
    python - <<'PY'
import sys

try:
    import triton
    print(f"  [OK] Triton {triton.__version__}")
except Exception as exc:
    print(f"  [FAIL] Triton import failed: {exc}")
    sys.exit(1)

try:
    from sageattention import sageattn
    print("  [OK] sageattention.sageattn import")
except Exception as exc:
    print(f"  [FAIL] SageAttention import failed: {exc}")
    sys.exit(1)
PY
}

verify_sage3_import() {
    python - <<'PY'
import sys

try:
    from sageattn3 import sageattn3_blackwell
    print("  [OK] sageattn3.sageattn3_blackwell import")
except Exception as exc:
    print(f"  [FAIL] SageAttention3 import failed: {exc}")
    sys.exit(1)
PY
}

smoke_sage2_cuda() {
    python - <<'PY'
import sys
import torch
from sageattention import sageattn

if not torch.cuda.is_available():
    print("CUDA is not available for SageAttention smoke test")
    sys.exit(1)

device = torch.device("cuda:0")
q = torch.randn((1, 1, 16, 64), device=device, dtype=torch.float16)
k = torch.randn((1, 1, 16, 64), device=device, dtype=torch.float16)
v = torch.randn((1, 1, 16, 64), device=device, dtype=torch.float16)
out = sageattn(q, k, v, tensor_layout="HND", is_causal=False)
torch.cuda.synchronize()
print(f"SageAttention CUDA smoke output shape = {tuple(out.shape)}")
PY
}

smoke_sage3_cuda() {
    python - <<'PY'
import sys
import torch
from sageattn3 import sageattn3_blackwell

if not torch.cuda.is_available():
    print("CUDA is not available for SageAttention3 smoke test")
    sys.exit(1)

device = torch.device("cuda:0")
q = torch.randn((1, 2, 128, 128), device=device, dtype=torch.bfloat16)
k = torch.randn((1, 2, 128, 128), device=device, dtype=torch.bfloat16)
v = torch.randn((1, 2, 128, 128), device=device, dtype=torch.bfloat16)
out = sageattn3_blackwell(q, k, v, is_causal=False)
torch.cuda.synchronize()
print(f"SageAttention3 CUDA smoke output shape = {tuple(out.shape)}, dtype = {out.dtype}")
PY
}

build_sageattention_from_source_current_gpu() {
    local arch_label="$1"
    local arch_list
    local build_result

    arch_list="$(python - <<'PY'
import sys
import torch

if not torch.cuda.is_available():
    print("CUDA is not available; cannot infer TORCH_CUDA_ARCH_LIST for SageAttention source build", file=sys.stderr)
    sys.exit(1)

major, minor = torch.cuda.get_device_capability(0)
print(f"{major}.{minor}")
PY
)"

    echo ""
    echo "==================================================================="
    echo "Building SageAttention from source for ${arch_label} (SM ${arch_list})"
    echo "==================================================================="
    echo "Installing build dependencies (wheel, setuptools, ninja)..."
    pip_install_runtime wheel setuptools ninja

    cd /tmp
    if [ -d "SageAttention" ]; then
        rm -rf SageAttention
    fi

    echo "Cloning SageAttention repository..."
    git clone https://github.com/thu-ml/SageAttention.git
    cd SageAttention

    export TORCH_CUDA_ARCH_LIST="$arch_list"
    export EXT_PARALLEL=4
    export NVCC_APPEND_FLAGS="--threads 8"
    export MAX_JOBS=32

    build_result=0
    "$COMFYUI_PYTHON" -m pip install . --no-cache-dir --no-build-isolation || build_result=$?

    cd /
    rm -rf /tmp/SageAttention

    if [ $build_result -ne 0 ]; then
        echo "SageAttention source build failed"
        return "$build_result"
    fi

    echo "SageAttention source build succeeded for SM ${arch_list}"
}

# ============================================================================
# GPU_TYPE Configuration - Set in RunPod Environment Variables
# ============================================================================
# GPU_TYPE=H200    - Build SageAttention from source with SM90 kernels (Hopper)
# GPU_TYPE=H100    - Build SageAttention from source with SM90 kernels (Hopper)
# GPU_TYPE=5090    - Blackwell SM120 family
# GPU_TYPE=6000    - Use prebuilt wheel (RTX Pro 6000 Ada)
# GPU_TYPE=auto    - Auto-detect from nvidia-smi (default)
# SAGE_ATTENTION_BACKEND=auto|both|sage2|sage3|source|off
# ============================================================================
: "${GPU_TYPE:=auto}"
: "${SAGE_ATTENTION_BACKEND:=auto}"

SAGE_ATTENTION_BACKEND="$(printf '%s' "$SAGE_ATTENTION_BACKEND" | tr '[:upper:]' '[:lower:]')"
case "$SAGE_ATTENTION_BACKEND" in
    auto|both|sage2|sage3|source|off)
        ;;
    *)
        echo "Unsupported SAGE_ATTENTION_BACKEND=${SAGE_ATTENTION_BACKEND}"
        echo "Supported values: auto, both, sage2, sage3, source, off"
        exit 1
        ;;
esac

SAGE_RUNTIME_HANDLED=false

# Quick check: skip SageAttention install if already importable
SAGE_ALREADY_INSTALLED=false
if [ "$SAGE_ATTENTION_BACKEND" = "off" ]; then
    echo "==================================================================="
    echo "SageAttention disabled by SAGE_ATTENTION_BACKEND=off"
    echo "==================================================================="
    SAGE_RUNTIME_HANDLED=true
elif [ "$SAGE_ATTENTION_BACKEND" = "sage2" ] && python -c "from sageattention import sageattn" 2>/dev/null; then
    echo "==================================================================="
    echo "✅ SageAttention already installed - skipping installation"
    echo "==================================================================="
    SAGE_ALREADY_INSTALLED=true
fi

if [ "$SAGE_ALREADY_INSTALLED" = false ] && [ "$SAGE_RUNTIME_HANDLED" = false ]; then

echo "==================================================================="
echo "⚡ SageAttention2++ Installation Starting"
echo "==================================================================="
echo "📦 Installing SageAttention dependencies..."
echo ""

# SageAttention uses the Triton package resolved by the selected PyTorch wheel.

echo "Using Triton from the selected PyTorch CUDA stack."
echo "Triton will be audited after SageAttention verification."
pip_install_runtime packaging

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
            GPU_TYPE="BLACKWELL_SM120"
            echo "   → RTX PRO Blackwell workstation GPU - will build from source (SM120)"

        # 3. GeForce RTX 50-series (Blackwell consumer) - needs source build for SM120
        elif echo "$DETECTED_GPU_UPPER" | grep -qE "RTX 5090|RTX 5080|RTX 5070|RTX 5060"; then
            GPU_TYPE="BLACKWELL_SM120"
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

case "$GPU_TYPE" in
    PRO_BLACKWELL|RTX50|5090|pro_blackwell|rtx50)
        GPU_TYPE="BLACKWELL_SM120"
        ;;
esac

echo "   Final GPU_TYPE=$GPU_TYPE"
SAGE_VERIFY_CUDA_CALL=false
SAGE_VERIFY_SM90=false
SAGE_EFFECTIVE_BACKEND="$SAGE_ATTENTION_BACKEND"

if [ "$SAGE_EFFECTIVE_BACKEND" = "auto" ]; then
    if [ "$COMFYUI_USE_LATEST" = "true" ] && [ "$GPU_TYPE" = "BLACKWELL_SM120" ]; then
        SAGE_EFFECTIVE_BACKEND="both"
    else
        SAGE_EFFECTIVE_BACKEND="sage2"
    fi
fi

echo "   SAGE_ATTENTION_BACKEND=${SAGE_ATTENTION_BACKEND} (effective: ${SAGE_EFFECTIVE_BACKEND})"

if [ "$SAGE_EFFECTIVE_BACKEND" = "sage2" ] && python -c "from sageattention import sageattn" 2>/dev/null; then
    echo "==================================================================="
    echo "SageAttention already installed - skipping installation"
    echo "==================================================================="
    SAGE_RUNTIME_HANDLED=true
fi

if [ "$SAGE_EFFECTIVE_BACKEND" = "source" ]; then
    build_sageattention_from_source_current_gpu "$GPU_TYPE"
    verify_sage2_import
    case "$GPU_TYPE" in
        BLACKWELL_SM120)
            smoke_sage2_cuda
            ;;
    esac
    SAGE_RUNTIME_HANDLED=true
fi

if [ "$SAGE_RUNTIME_HANDLED" = false ]; then
    case "$SAGE_EFFECTIVE_BACKEND" in
        both|sage2|sage3)
            if [ "$COMFYUI_USE_LATEST" = "true" ] && [ "$CUDA_PROFILE" = "cu130" ] && [ "$GPU_TYPE" = "BLACKWELL_SM120" ]; then
                if [ "$SAGE_EFFECTIVE_BACKEND" = "both" ] || [ "$SAGE_EFFECTIVE_BACKEND" = "sage2" ]; then
                    if ! (
                        download_and_install_verified_wheel "SageAttention" "$SAGE2_SM120_WHEEL_FILENAME" "$SAGE2_SM120_WHEEL_URL" "$SAGE2_SM120_WHEEL_SHA256" &&
                        verify_sage2_import &&
                        smoke_sage2_cuda
                    ); then
                        if [ "$SAGE_ATTENTION_BACKEND" = "sage2" ]; then
                            echo "SageAttention SM120 wheel failed; falling back to source build for SAGE_ATTENTION_BACKEND=sage2"
                        else
                            echo "SageAttention SM120 wheel failed"
                            exit 1
                        fi
                    else
                        SAGE_RUNTIME_HANDLED=true
                    fi
                fi

                if [ "$SAGE_EFFECTIVE_BACKEND" = "both" ] || [ "$SAGE_EFFECTIVE_BACKEND" = "sage3" ]; then
                    download_and_install_verified_wheel "SageAttention3" "$SAGE3_SM120_WHEEL_FILENAME" "$SAGE3_SM120_WHEEL_URL" "$SAGE3_SM120_WHEEL_SHA256"
                    verify_sage3_import
                    smoke_sage3_cuda
                    SAGE_RUNTIME_HANDLED=true
                fi
            elif [ "$SAGE_EFFECTIVE_BACKEND" = "both" ] || [ "$SAGE_EFFECTIVE_BACKEND" = "sage3" ]; then
                echo "SAGE_ATTENTION_BACKEND=${SAGE_EFFECTIVE_BACKEND} requires COMFYUI_USE_LATEST=true, CUDA profile cu130, and an SM120 Blackwell GPU."
                exit 1
            fi
            ;;
    esac
fi

# Determine installation method based on GPU type
if [ "$SAGE_RUNTIME_HANDLED" = false ]; then
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
        pip_install_runtime wheel setuptools ninja

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
        "$COMFYUI_PYTHON" -m pip install . --no-cache-dir --no-build-isolation

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
        pip_install_runtime wheel setuptools ninja

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
        "$COMFYUI_PYTHON" -m pip install . --no-cache-dir --no-build-isolation

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

    BLACKWELL_SM120|PRO_BLACKWELL|RTX50|pro_blackwell|rtx50)
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
        pip_install_runtime wheel setuptools ninja

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
        "$COMFYUI_PYTHON" -m pip install . --no-cache-dir --no-build-isolation

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
        pip_install_runtime "$SAGE_WHEEL_URL"

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
        pip_install_runtime "$SAGE_WHEEL_URL"

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

case "$GPU_TYPE" in
    BLACKWELL_SM120|PRO_BLACKWELL|RTX50|pro_blackwell|rtx50)
        SAGE_VERIFY_CUDA_CALL=true
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

if [ "$SAGE_VERIFY_CUDA_CALL" = true ]; then
    echo "Running SM120 SageAttention CUDA smoke test..."
    python - <<'PY'
import sys
import torch
from sageattention import sageattn

if not torch.cuda.is_available():
    print("CUDA is not available for SageAttention smoke test")
    sys.exit(1)

device = torch.device("cuda:0")
q = torch.randn((1, 1, 16, 64), device=device, dtype=torch.float16)
k = torch.randn((1, 1, 16, 64), device=device, dtype=torch.float16)
v = torch.randn((1, 1, 16, 64), device=device, dtype=torch.float16)
out = sageattn(q, k, v, tensor_layout="HND", is_causal=False)
torch.cuda.synchronize()
print(f"SageAttention CUDA smoke output shape = {tuple(out.shape)}")
PY
fi

fi  # End of legacy SageAttention install/verification path

fi  # End of SAGE_ALREADY_INSTALLED=false block


echo "📓 Installing JupyterLab with full functionality..."
pip_install_runtime \
    jupyterlab \
    ipykernel \
    jupyter-server-terminals \
    ipywidgets \
    matplotlib \
    pandas \
    notebook \
    jupyter-archive

echo "Final PyTorch CUDA stack audit after all runtime package installs:"
audit_pytorch_cuda_stack

# Register Python kernel explicitly for JupyterLab
echo "🔧 Registering Python kernel..."
"$COMFYUI_PYTHON" -m ipykernel install --name="python3" --display-name="Python 3 (ipykernel)" --sys-prefix

# Verify kernel installation
echo "✅ Installed kernels:"
"$COMFYUI_JUPYTER" kernelspec list

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
