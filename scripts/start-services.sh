#!/usr/bin/env bash
set -euo pipefail

COMFY_PORT="${COMFY_PORT:-8188}"
JUPYTER_PORT="8189"
COMFY_LOG_LEVEL="${COMFY_LOG_LEVEL:-DEBUG}"
SAGE_ATTENTION_BACKEND="${SAGE_ATTENTION_BACKEND:-auto}"
SAGE_ATTENTION_BACKEND="$(printf '%s' "$SAGE_ATTENTION_BACKEND" | tr '[:upper:]' '[:lower:]')"
COMFYUI_PYTHON="${COMFYUI_PYTHON:-/comfyui/.venv/bin/python}"
COMFYUI_JUPYTER="${COMFYUI_JUPYTER:-/comfyui/.venv/bin/jupyter}"
COMFY_SAGE_ARGS=()

case "$SAGE_ATTENTION_BACKEND" in
    auto|both|sage2|source)
        COMFY_SAGE_ARGS=(--use-sage-attention)
        ;;
    sage3|off)
        ;;
    *)
        echo "Unsupported SAGE_ATTENTION_BACKEND=${SAGE_ATTENTION_BACKEND}" >&2
        exit 1
        ;;
esac

log_section() {
    echo ""
    echo "==================================================================="
    echo "$1"
    echo "==================================================================="
}

detect_runpod_pod_id() {
    if [ -n "${RUNPOD_POD_ID:-}" ]; then
        printf '%s\n' "$RUNPOD_POD_ID"
        return 0
    fi

    if [ -n "${POD_ID:-}" ]; then
        printf '%s\n' "$POD_ID"
        return 0
    fi

    # RunPod usually sets the container hostname to the pod id or a value that
    # begins with it. Keep this as a best-effort fallback for useful logs.
    local hostname_value
    hostname_value="$(hostname 2>/dev/null || true)"
    if printf '%s' "$hostname_value" | grep -Eq '^[a-z0-9]{8,}'; then
        printf '%s\n' "$hostname_value" | sed -E 's/^([a-z0-9]{8,}).*/\1/'
        return 0
    fi

    return 1
}

print_access_urls() {
    local pod_id="${1:-}"

    log_section "Service URLs"
    echo "ComfyUI local health: http://127.0.0.1:${COMFY_PORT}/"
    echo "JupyterLab local:     http://127.0.0.1:${JUPYTER_PORT}/"

    if [ -n "$pod_id" ]; then
        echo ""
        echo "RunPod ComfyUI:       https://${pod_id}-${COMFY_PORT}.proxy.runpod.net/"
        echo "RunPod JupyterLab:    https://${pod_id}-${JUPYTER_PORT}.proxy.runpod.net/"
        echo ""
        echo "Use the internal service port in the proxy URL. Do not use the mapped public port from the Connect tab."
    else
        echo ""
        echo "RunPod proxy format:  https://<pod-id>-${COMFY_PORT}.proxy.runpod.net/"
    fi
}

wait_for_http() {
    local name="$1"
    local url="$2"
    local timeout_seconds="${3:-180}"
    local started
    started="$(date +%s)"

    echo "Waiting for ${name}: ${url}"
    while true; do
        if curl -fsS --max-time 5 "$url" >/dev/null; then
            echo "${name} is reachable: ${url}"
            return 0
        fi

        if ! kill -0 "$COMFY_PID" 2>/dev/null; then
            echo "${name} process exited before readiness check passed." >&2
            wait "$COMFY_PID"
            return $?
        fi

        if [ $(( $(date +%s) - started )) -ge "$timeout_seconds" ]; then
            echo "${name} was not reachable after ${timeout_seconds}s: ${url}" >&2
            return 1
        fi

        sleep 2
    done
}

cleanup() {
    if [ -n "${JUPYTER_PID:-}" ] && kill -0 "$JUPYTER_PID" 2>/dev/null; then
        kill "$JUPYTER_PID" 2>/dev/null || true
    fi
    if [ -n "${COMFY_PID:-}" ] && kill -0 "$COMFY_PID" 2>/dev/null; then
        kill "$COMFY_PID" 2>/dev/null || true
    fi
}
trap cleanup TERM INT

log_section "WAN 2.2 RunPod Template - Starting Up"

/scripts/runtime-init.sh

if [ ! -x "$COMFYUI_PYTHON" ]; then
    echo "ComfyUI Python not found or not executable: ${COMFYUI_PYTHON}" >&2
    exit 1
fi

if [ ! -x "$COMFYUI_JUPYTER" ]; then
    echo "Jupyter executable not found in ComfyUI environment: ${COMFYUI_JUPYTER}" >&2
    exit 1
fi

TCMALLOC="$(ldconfig -p | grep -Po "libtcmalloc.so.\d" | head -n 1 || true)"
if [ -n "$TCMALLOC" ]; then
    export LD_PRELOAD="$TCMALLOC"
fi

chmod -R 777 /comfyui
chown -R root:root /comfyui

log_section "Starting JupyterLab on port ${JUPYTER_PORT}"
"$COMFYUI_JUPYTER" lab --config=/root/.jupyter/jupyter_lab_config.py > /var/log/jupyter.log 2>&1 &
JUPYTER_PID=$!
sleep 1
if kill -0 "$JUPYTER_PID" 2>/dev/null; then
    echo "JupyterLab running with PID ${JUPYTER_PID}"
else
    echo "JupyterLab may have failed. Check /var/log/jupyter.log"
fi

log_section "Model Download Check"
/scripts/download_models.sh

log_section "Starting ComfyUI on port ${COMFY_PORT}"
if [ "${#COMFY_SAGE_ARGS[@]}" -gt 0 ]; then
    echo "SageAttention startup flag: enabled (${SAGE_ATTENTION_BACKEND})"
else
    echo "SageAttention startup flag: disabled (${SAGE_ATTENTION_BACKEND})"
fi

"$COMFYUI_PYTHON" -u /comfyui/main.py \
    --disable-auto-launch \
    --disable-metadata \
    --listen 0.0.0.0 \
    --port "$COMFY_PORT" \
    --verbose "$COMFY_LOG_LEVEL" \
    --log-stdout \
    --enable-manager \
    "${COMFY_SAGE_ARGS[@]}" &
COMFY_PID=$!

if pod_id="$(detect_runpod_pod_id)"; then
    print_access_urls "$pod_id"
else
    print_access_urls ""
fi

wait_for_http "ComfyUI" "http://127.0.0.1:${COMFY_PORT}/" "${COMFY_STARTUP_TIMEOUT:-240}"
wait_for_http "ComfyUI system_stats" "http://127.0.0.1:${COMFY_PORT}/system_stats" "${COMFY_STARTUP_TIMEOUT:-240}"

log_section "ComfyUI Ready"
echo "ComfyUI is reachable on local port ${COMFY_PORT}."
echo "If RunPod Connect shows Access Denied, open the direct proxy URL printed above."

wait "$COMFY_PID"
