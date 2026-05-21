#!/usr/bin/env bash
#
# Tutorial provision script for "Свой LLM для Cursor".
#
# Runs on the GPU instance after the container starts. The customer app's
# onstart wrapper exports two env vars before invoking us:
#
#   CC_PROVISION_URL   POST endpoint for stage updates
#                      (e.g. https://app.cloudcompute.ru/api/agent/provision)
#   CC_AGENT_TOKEN     bearer token authenticating us to that endpoint
#
# Both are optional — if absent, report_stage is a silent no-op so the
# script still works for local manual testing (e.g. via `bash provision.sh`
# inside a fresh container). Without report_stage the user has to inspect
# logs manually to grab the tunnel URL and API key.
#
# Stage IDs reported here MUST match manifest.yaml's provisioning.stages
# entries. The final stage (open_tunnel) includes three extra fields
# (tunnel_url, api_key, model_name) that the customer app surfaces in
# the "Connect to Cursor" UI card on the instance show page.

set -euo pipefail

CC_PROVISION_URL="${CC_PROVISION_URL:-}"
CC_AGENT_TOKEN="${CC_AGENT_TOKEN:-}"

# Model + serving config. Defaults target Qwen 2.5 Coder 32B AWQ — a 32B-class
# coding model quantized to INT4, peaks at ~22 GB VRAM, runs comfortably on a
# single RTX 4090 / A6000. Override any of these by exporting the env var
# *before* invoking the script (e.g. in a custom container's entrypoint, or
# manually inside a fresh container for testing variants).
MODEL_ID="${MODEL_ID:-Qwen/Qwen2.5-Coder-32B-Instruct-AWQ}"
# The name Cursor / OpenAI clients send in the request body. We expose a
# short stable name regardless of which checkpoint is actually loaded, so
# switching the underlying MODEL_ID later doesn't break user-saved Cursor
# settings.
SERVED_MODEL_NAME="${SERVED_MODEL_NAME:-qwen-2.5-coder-32b}"
VLLM_PORT="${VLLM_PORT:-8000}"

# Where vLLM and supporting tooling get installed. /workspace persists across
# Vast container restarts where /root does not, so prefer /workspace when it
# exists.
WORKDIR="${WORKDIR:-/workspace}"
mkdir -p "$WORKDIR"
LOG_DIR="${LOG_DIR:-/var/log}"
mkdir -p "$LOG_DIR"

VLLM_LOG="${LOG_DIR}/vllm.log"
TUNNEL_LOG="${LOG_DIR}/cloudflared.log"

# --- helpers --------------------------------------------------------------

# report_stage <stage_id> [extra_json_kv_pairs...]
#
# Best-effort POST to /api/agent/provision. The first arg is the stage id.
# Any remaining args are pre-formatted JSON key:value pairs that get
# concatenated into the body (e.g. `report_stage download_model
# '"progress_pct":42'`). Failures (network blips, 401, 422) are swallowed:
# a missed update is far preferable to crashing provisioning halfway
# through.
report_stage() {
    if [ -z "$CC_PROVISION_URL" ] || [ -z "$CC_AGENT_TOKEN" ]; then
        return 0
    fi
    local stage="$1"
    shift
    local extra=""
    for kv in "$@"; do
        extra="${extra},${kv}"
    done
    curl -fsS \
        -X POST "$CC_PROVISION_URL" \
        -H "Authorization: Bearer $CC_AGENT_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"stage\":\"${stage}\"${extra}}" \
        --max-time 5 \
        >/dev/null 2>&1 || true
}

log() {
    echo "[cc-provision] $*"
}

# Generate a random opaque API key in the form sk-cc-<32 hex>. vLLM treats it
# as a single shared secret — it doesn't validate against anything, just
# compares the Authorization header. We deliberately generate it here on
# the instance (not in the customer app) so the secret never leaves the
# GPU until provision.sh chooses to report it back, and it changes every
# time the user re-launches the instance.
generate_api_key() {
    # /dev/urandom + xxd is the most portable approach: openssl rand is
    # not always present on slimmed-down vLLM images.
    if command -v xxd >/dev/null 2>&1; then
        printf 'sk-cc-%s' "$(head -c 16 /dev/urandom | xxd -p -c 32)"
    else
        printf 'sk-cc-%s' "$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    fi
}

API_KEY="$(generate_api_key)"

# --- stage 1: install_runtime --------------------------------------------

log "stage: install_runtime"
report_stage install_runtime

# vLLM. The Vast `vllm` template ships with vLLM preinstalled, but we still
# `pip install -U` to make sure we pick up bugfixes the template hasn't been
# rebuilt for yet. Pip is a no-op when versions match. On a non-vLLM base
# image this is what actually installs vLLM (~5 min cold install).
pip install --no-cache-dir -U "vllm>=0.6.0" >/dev/null

# cloudflared: standalone static binary, no apt repo needed. ~30 MB. Used
# to open a free trycloudflare.com quick tunnel that gives us a public
# HTTPS URL pointing at localhost:VLLM_PORT — Cursor's "Add custom model"
# UI requires HTTPS, which Vast.ai's raw <ip>:<port> mappings can't
# provide.
CLOUDFLARED_BIN="/usr/local/bin/cloudflared"
if ! [ -x "$CLOUDFLARED_BIN" ]; then
    log "installing cloudflared"
    # amd64 is the only arch Vast.ai hosts use today; if that ever changes
    # we'll need to detect uname -m. Pin to a known-stable release rather
    # than 'latest' so the script is reproducible.
    curl -fsSL \
        "https://github.com/cloudflare/cloudflared/releases/download/2024.10.0/cloudflared-linux-amd64" \
        -o "$CLOUDFLARED_BIN"
    chmod +x "$CLOUDFLARED_BIN"
fi

# Kill any pre-existing process holding VLLM_PORT — the upstream Vast vllm
# template autostarts its own vLLM with a default model on first boot
# (DeepSeek-R1-Distill-Llama-8B at the time of writing). Without this we'd
# fail to bind 8000 and spend ages debugging. fuser exits non-zero when
# nothing's bound, hence the `|| true`.
log "freeing port ${VLLM_PORT} if held by another process"
fuser -k "${VLLM_PORT}/tcp" 2>/dev/null || true
sleep 2

# --- stage 2: download_model ---------------------------------------------
#
# vLLM auto-downloads weights from HuggingFace the first time you reference
# a HF model id. There's no good way to grab a percentage from inside the
# vLLM startup so we report a coarse 0%/100% transition. The model is
# ~20 GB; on a Vast host with a 500+ Mbps uplink (we filter for these in
# ApplicationsController) it takes ~5-7 minutes.

log "stage: download_model"
report_stage download_model '"progress_pct":0'

# Pre-download via huggingface-hub so we can decouple "weights on disk"
# from "vLLM startup" — that way if the model download fails we report it
# at the right stage, instead of having the user see a confusing
# "starting server" failure that actually originated in HF.
pip install --no-cache-dir -U "huggingface_hub[cli]>=0.26.0" >/dev/null

HF_HOME="${HF_HOME:-${WORKDIR}/hf-cache}"
mkdir -p "$HF_HOME"
export HF_HOME

if ! huggingface-cli download "$MODEL_ID" \
    --cache-dir "$HF_HOME" \
    > "${LOG_DIR}/hf-download.log" 2>&1; then
    log "huggingface-cli download failed; see ${LOG_DIR}/hf-download.log"
    tail_msg="$(tail -c 400 "${LOG_DIR}/hf-download.log" | tr -d '\r' | tr '\n' ' ' | sed 's/"/'"'"'/g')"
    report_stage download_model "\"message\":\"HF download failed: ${tail_msg}\""
    exit 1
fi

report_stage download_model '"progress_pct":100'

# --- stage 3: start_server -----------------------------------------------

log "stage: start_server"
report_stage start_server

# Launch vLLM as a background process. Key flags:
#   --api-key                 : require Authorization: Bearer <key> on every request
#   --served-model-name       : the model identifier clients see (decoupled from $MODEL_ID)
#   --max-model-len 16384     : Cursor + autocomplete don't push past 16k often.
#                               Bigger context = more KV cache memory; 16k keeps
#                               headroom on a 24 GB card.
#   --gpu-memory-utilization  : leave ~10% headroom so the AWQ kernel + cloudflared
#                               + cc-agent don't OOM the card mid-session.
#   --quantization awq_marlin : faster AWQ inference path on Ampere/Ada/Hopper.
nohup vllm serve "$MODEL_ID" \
    --host 0.0.0.0 \
    --port "$VLLM_PORT" \
    --api-key "$API_KEY" \
    --served-model-name "$SERVED_MODEL_NAME" \
    --max-model-len 16384 \
    --gpu-memory-utilization 0.90 \
    --quantization awq_marlin \
    > "$VLLM_LOG" 2>&1 &
VLLM_PID=$!

# Wait for vLLM to bind the port. Loading + quantizing 32B AWQ + warming
# the kernel takes 60-180s on a 4090. Bail early if the process dies.
VLLM_BIND_TIMEOUT_S=300
for _ in $(seq 1 "$VLLM_BIND_TIMEOUT_S"); do
    if curl -fsS --max-time 1 "http://127.0.0.1:${VLLM_PORT}/v1/models" \
        -H "Authorization: Bearer ${API_KEY}" >/dev/null 2>&1; then
        log "vLLM ready on port ${VLLM_PORT}"
        break
    fi
    if ! kill -0 "$VLLM_PID" 2>/dev/null; then
        log "vLLM exited before binding port ${VLLM_PORT}"
        tail_msg="$(tail -c 500 "$VLLM_LOG" | tr -d '\r' | tr '\n' ' ' | sed 's/"/'"'"'/g')"
        report_stage start_server "\"message\":\"vLLM crashed during startup: ${tail_msg}\""
        exit 1
    fi
    sleep 1
done

if ! kill -0 "$VLLM_PID" 2>/dev/null; then
    report_stage start_server "\"message\":\"vLLM died before completing startup\""
    exit 1
fi

# --- stage 4: open_tunnel ------------------------------------------------
#
# Cloudflare quick tunnel: free, no signup, no DNS. cloudflared connects
# outbound to Cloudflare's edge and gets back a random
# https://<words>.trycloudflare.com URL that proxies to our local
# VLLM_PORT. The URL appears in cloudflared's own logs as
# "Your quick Tunnel has been created! Visit it at:" followed by the URL
# a couple lines later. We tail the log and grep until we see it.

log "stage: open_tunnel"
report_stage open_tunnel

nohup "$CLOUDFLARED_BIN" tunnel \
    --no-autoupdate \
    --url "http://localhost:${VLLM_PORT}" \
    > "$TUNNEL_LOG" 2>&1 &
TUNNEL_PID=$!

TUNNEL_URL=""
TUNNEL_TIMEOUT_S=60
for _ in $(seq 1 "$TUNNEL_TIMEOUT_S"); do
    # The URL line in cloudflared's output looks like:
    #   |  https://random-words.trycloudflare.com                                   |
    # We grab the first matching trycloudflare.com URL — the banner repeats
    # it a couple times but they're all the same value.
    candidate="$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "$TUNNEL_LOG" 2>/dev/null | head -n 1 || true)"
    if [ -n "$candidate" ]; then
        TUNNEL_URL="$candidate"
        break
    fi
    if ! kill -0 "$TUNNEL_PID" 2>/dev/null; then
        log "cloudflared exited before producing a tunnel URL"
        tail_msg="$(tail -c 400 "$TUNNEL_LOG" | tr -d '\r' | tr '\n' ' ' | sed 's/"/'"'"'/g')"
        report_stage open_tunnel "\"message\":\"cloudflared failed: ${tail_msg}\""
        exit 1
    fi
    sleep 1
done

if [ -z "$TUNNEL_URL" ]; then
    log "cloudflared did not surface a URL within ${TUNNEL_TIMEOUT_S}s"
    report_stage open_tunnel "\"message\":\"cloudflared did not produce a trycloudflare URL in ${TUNNEL_TIMEOUT_S}s\""
    exit 1
fi

log "tunnel URL: ${TUNNEL_URL}"

# Final report: ship the three values the customer-app UI needs to render
# the "Connect to Cursor" card. We escape any quote in the values
# defensively, although our generator + cloudflared output are
# guaranteed-safe today. progress_pct:100 is what tells the controller
# that the final manifest stage is complete (see AgentProvisionController).
escape_json() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}
TUNNEL_URL_JSON="$(escape_json "$TUNNEL_URL")"
API_KEY_JSON="$(escape_json "$API_KEY")"
MODEL_NAME_JSON="$(escape_json "$SERVED_MODEL_NAME")"

report_stage open_tunnel \
    '"progress_pct":100' \
    "\"tunnel_url\":\"${TUNNEL_URL_JSON}\"" \
    "\"api_key\":\"${API_KEY_JSON}\"" \
    "\"model_name\":\"${MODEL_NAME_JSON}\""

log "provisioning complete"
log "  tunnel: ${TUNNEL_URL}"
log "  api key: ${API_KEY}"
log "  model name: ${SERVED_MODEL_NAME}"
log "vLLM PID: ${VLLM_PID}; cloudflared PID: ${TUNNEL_PID}"
exit 0
