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

# Tracks the stage we last *entered* so the trap-ERR handler below can
# attribute an unexpected failure to the right manifest stage. Updated by
# report_stage on every call. Initialized to the first stage so a crash
# during the very first lines (before report_stage runs) still has a
# sane stage to report.
CC_CURRENT_STAGE="install_runtime"

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

# vLLM `--max-model-len` cap on per-request prompt+completion tokens.
# Chosen by GPU VRAM since Cursor regularly stuffs 16k+ tokens of
# workspace context into a single chat completion (tested empirically
# in Composer / Agent mode — overflow surfaces as
# "This model's maximum context length is 16384 tokens" 400s).
#
# Per-token KV cache for Qwen 2.5 32B (GQA, 64 layers × 8 KV heads ×
# 128 head_dim × fp16) ≈ 256 KiB. The model itself is ~18 GiB AWQ
# INT4. Budget remaining at gpu_memory_utilization 0.90 is roughly
# (vram_gib × 0.90) − 18; one full request needs max_len × 256 KiB.
#
#   24 GiB card  → ~3.6 GiB KV → ~14k tokens → 16k cap is safe ceiling
#   40 GiB card  → ~18 GiB KV  → ~73k tokens → 32k is the model's
#                                 native sweet spot, leaves >2x
#                                 headroom for concurrent requests.
#   80 GiB+ card → way more headroom; we still cap at 32k because
#                  Qwen 2.5 32B's training context is 32k — beyond
#                  that needs YaRN scaling and quality drops.
#
# Detected via nvidia-smi at runtime so a single provision.sh works
# on the whole GPU lineup the customer-app filter (min_vram_gb=24 in
# config/applications.php) might land us on, instead of forcing the
# UI to either widen (kill cheap 4090 24G) or break Composer on small
# cards.
if command -v nvidia-smi >/dev/null 2>&1; then
    GPU_VRAM_MB=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 || echo 0)
else
    GPU_VRAM_MB=0
fi
if [ "${GPU_VRAM_MB:-0}" -ge 38000 ]; then
    MAX_MODEL_LEN_DEFAULT=32768
else
    MAX_MODEL_LEN_DEFAULT=16384
fi
MAX_MODEL_LEN="${MAX_MODEL_LEN:-$MAX_MODEL_LEN_DEFAULT}"

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
    local stage="$1"
    shift
    # Always update the stage tracker, even when reporting is disabled
    # (no env vars). The trap-ERR handler still needs an accurate stage
    # for its own log line in that case.
    CC_CURRENT_STAGE="$stage"

    if [ -z "$CC_PROVISION_URL" ] || [ -z "$CC_AGENT_TOKEN" ]; then
        return 0
    fi
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

# Sanitize an arbitrary string for inlining into a JSON value: strip CR,
# fold newlines to spaces, and replace double-quotes with single-quotes.
# Use this on every dynamic substring (log tails, error messages, command
# names) before splicing into a `"message":"..."` payload, otherwise a
# stray quote in the source produces invalid JSON and AgentProvisionController
# 422s the request.
json_escape() {
    printf '%s' "$1" | tr -d '\r' | tr '\n' ' ' | sed 's/"/'"'"'/g'
}

# trap-ERR handler — fires for any command that fails under `set -e` and
# wasn't already handled with explicit `report_stage ... "\"message\":...\""`
# + `exit 1`. Without this, an unexpected failure (e.g. `pip install` 503,
# `mkdir` -p on a read-only mount, a shell typo we never hit in testing)
# kills the script silently. The backend then has nothing on
# `provision_state.message` and only the 30-min OVERALL_TIMEOUT eventually
# flips the instance to ERROR — a window where the user is billed for
# nothing.
#
# Behaviour:
#   1. Disable the trap immediately to prevent recursion if anything
#      inside the handler also fails.
#   2. Capture exit code, line, and the command text BEFORE doing any
#      other work (later commands would clobber $? / $BASH_COMMAND).
#   3. POST a fatal `message` tagged to CC_CURRENT_STAGE. The customer
#      app's hasApplicationProvisioningFailed predicate picks this up
#      on the next polling tick and flips the instance to ERROR with
#      a clear message in seconds, not 30 minutes.
#   4. Re-exit with the original code so anything downstream observes
#      the same failure.
handle_uncaught_error() {
    # Capture $? BEFORE doing anything else — `trap - ERR`, `local`, and
    # parameter assignment all clobber $?. We need the exit code of the
    # actual failing command, which is what $? holds the moment trap
    # fires.
    local exit_code=$?
    trap - ERR

    local line_no="${1:-?}"
    local command_text
    command_text="$(json_escape "${2:-?}")"

    log "uncaught error at line ${line_no} (stage=${CC_CURRENT_STAGE}, exit=${exit_code}): ${2:-?}"

    report_stage "$CC_CURRENT_STAGE" \
        "\"message\":\"Скрипт упал на line ${line_no}: ${command_text} (exit ${exit_code})\""

    # Bash treats `exit 0` as success, but we got here BECAUSE something
    # failed — fall back to 1 if the captured code somehow ended up 0
    # (e.g. a `command not found` reported back as 127 by the shell but
    # zero'd out by an unusual interaction).
    if [ "$exit_code" -eq 0 ]; then
        exit_code=1
    fi
    exit "$exit_code"
}
trap 'handle_uncaught_error "$LINENO" "$BASH_COMMAND"' ERR

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
    tail_msg="$(json_escape "$(tail -c 400 "${LOG_DIR}/hf-download.log")")"
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
#   --max-model-len           : 16k on 24 GiB cards, 32k on 40 GiB+ — see
#                               MAX_MODEL_LEN auto-detect block above.
#                               Cursor's Composer regularly sends 16k+ tokens
#                               of workspace context, so 16k works only as
#                               a "tight floor" on 4090-class cards; 40 GiB+
#                               hosts get the full Qwen-native 32k.
#   --gpu-memory-utilization  : leave ~10% headroom so the AWQ kernel + cloudflared
#                               + cc-agent don't OOM the card mid-session.
#   --quantization awq_marlin : faster AWQ inference path on Ampere/Ada/Hopper.
#   --enable-auto-tool-choice + --tool-call-parser hermes :
#       Cursor's Composer / Agent always sends `tool_choice: "auto"`
#       on chat completions even when no tools are attached. Without
#       these two flags vLLM 400s every such request with
#       '"auto" tool choice requires --enable-auto-tool-choice and
#       --tool-call-parser to be set'. Qwen 2.5 (including Coder)
#       emits tool calls in the Hermes / ChatML <tool_call> format,
#       so `hermes` is the correct parser. With these flags vLLM
#       keeps accepting plain chat too (parser only kicks in when
#       the model actually emits a tool call), so there's no
#       downside for non-Agent users.
nohup vllm serve "$MODEL_ID" \
    --host 0.0.0.0 \
    --port "$VLLM_PORT" \
    --api-key "$API_KEY" \
    --served-model-name "$SERVED_MODEL_NAME" \
    --max-model-len "$MAX_MODEL_LEN" \
    --gpu-memory-utilization 0.90 \
    --quantization awq_marlin \
    --enable-auto-tool-choice \
    --tool-call-parser hermes \
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
        tail_msg="$(json_escape "$(tail -c 500 "$VLLM_LOG")")"
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
# a couple lines later.
#
# trycloudflare.com aggressively rate-limits new tunnel registrations from
# the same egress IP — Vast hosts can hit HTTP 429 / Error 1015 within
# seconds when the same datacenter recently spun up several quick
# tunnels. The retry loop below ABSORBS those 429s with exponential
# backoff instead of failing the whole instance launch. Tunnel creation
# is idempotent on Cloudflare's side, each attempt gets a fresh URL.

log "stage: open_tunnel"
report_stage open_tunnel

TUNNEL_URL=""
# Per-attempt cap: long enough for cloudflared to either succeed or
# reveal a 429, short enough that 4 attempts × this + backoff still
# fits comfortably under APPLICATION_PROVISION_OVERALL_TIMEOUT_MINUTES
# (30 min on the customer app side).
TUNNEL_ATTEMPT_TIMEOUT_S=60
TUNNEL_MAX_ATTEMPTS=4

# open_tunnel_attempt — runs cloudflared once, watches its log, returns:
#   0  TUNNEL_URL set and exported
#   1  process died / no URL — caller may retry
#   2  HTTP 429 / rate-limited — caller MUST back off before retrying
open_tunnel_attempt() {
    : > "$TUNNEL_LOG"

    nohup "$CLOUDFLARED_BIN" tunnel \
        --no-autoupdate \
        --url "http://localhost:${VLLM_PORT}" \
        > "$TUNNEL_LOG" 2>&1 &
    local pid=$!

    local elapsed=0
    while [ "$elapsed" -lt "$TUNNEL_ATTEMPT_TIMEOUT_S" ]; do
        local candidate
        candidate="$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "$TUNNEL_LOG" 2>/dev/null | head -n 1 || true)"
        if [ -n "$candidate" ]; then
            TUNNEL_URL="$candidate"
            TUNNEL_PID="$pid"
            return 0
        fi

        # 429 detection: cloudflared logs include "error code: 1015" and
        # "429" in different lines depending on Cloudflare's response.
        # Match either token to avoid relying on exact phrasing across
        # cloudflared versions.
        if grep -qE '(\b429\b|Too Many Requests|error code: ?1015)' "$TUNNEL_LOG" 2>/dev/null; then
            log "cloudflared rate-limited (HTTP 429) on attempt"
            kill "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
            return 2
        fi

        if ! kill -0 "$pid" 2>/dev/null; then
            log "cloudflared exited on attempt"
            return 1
        fi

        sleep 1
        elapsed=$((elapsed + 1))
    done

    # Timed out without URL or 429: kill and let caller retry.
    log "cloudflared attempt timed out without URL"
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    return 1
}

# Suppress both `set -e` AND the ERR trap for the retry block — we want
# a non-zero return from open_tunnel_attempt to drive our retry/backoff
# logic, NOT to kill the script.
#
# Why both: `trap - ERR` alone is NOT enough. `set -e` is what causes
# the shell to exit on a non-zero return; the ERR trap is just the hook
# that fires before the exit. Without `set +e` here, the very first
# `open_tunnel_attempt` returning 2 (HTTP 429) immediately exits
# provision.sh — silently, with no `report_stage open_tunnel
# "...message..."` ever sent to the backend, so the user sits at
# "stage: open_tunnel" until the backend's OVERALL_TIMEOUT (30 min)
# eventually flips the instance to ERROR. This was observed in
# production: a single 429 on attempt 1 killed the script before
# attempts 2–4 could run.
#
# Re-enable both on the way out so any subsequent failure (e.g. inside
# the report_stage block below) still gets caught by the global
# fatal handler.
set +e
trap - ERR
TUNNEL_LAST_RC=1
for attempt in $(seq 1 "$TUNNEL_MAX_ATTEMPTS"); do
    log "cloudflared attempt ${attempt}/${TUNNEL_MAX_ATTEMPTS}"

    open_tunnel_attempt
    TUNNEL_LAST_RC=$?

    if [ "$TUNNEL_LAST_RC" -eq 0 ]; then
        break
    fi

    if [ "$attempt" -lt "$TUNNEL_MAX_ATTEMPTS" ]; then
        # Exponential backoff for 429, linear for generic failures —
        # 429 is "trycloudflare hates this egress IP right now", needs
        # real wall-clock time; a generic process death usually
        # recovers on the next attempt without much wait.
        if [ "$TUNNEL_LAST_RC" -eq 2 ]; then
            sleep_for=$((30 * attempt))
        else
            sleep_for=$((5 * attempt))
        fi
        log "backing off ${sleep_for}s before retry"
        sleep "$sleep_for"
    fi
done
set -e
trap 'handle_uncaught_error "$LINENO" "$BASH_COMMAND"' ERR

if [ -z "$TUNNEL_URL" ]; then
    tail_msg="$(json_escape "$(tail -c 400 "$TUNNEL_LOG" 2>/dev/null || true)")"
    if [ "$TUNNEL_LAST_RC" -eq 2 ]; then
        report_stage open_tunnel "\"message\":\"cloudflared rate-limited (HTTP 429) by trycloudflare.com after ${TUNNEL_MAX_ATTEMPTS} retries: ${tail_msg}\""
    else
        report_stage open_tunnel "\"message\":\"cloudflared failed after ${TUNNEL_MAX_ATTEMPTS} retries: ${tail_msg}\""
    fi
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
