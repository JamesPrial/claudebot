#!/usr/bin/env bash
# run-bot.sh - Claudebot lifecycle orchestrator (single-instance shell variant)
# Runs the discord-mcp server as a persistent Docker daemon (HTTP transport) so
# the Discord gateway stays open and the bot appears always-online. Uses repeated
# `claude -p --resume` calls to maintain a persistent session across poll cycles.
#
# Note: the primary runner is scripts/run_bot.py (used by claudebot-ctl for
# multi-instance management). This script is a thinner single-instance variant
# that reads .env from the plugin root.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="${PLUGIN_DIR}/.env"

# Load .env if present
if [[ -f "${ENV_FILE}" ]]; then
  set -a
  source "${ENV_FILE}"
  set +a
fi

# Structured logging
export CLAUDEBOT_LOG_LEVEL="${CLAUDEBOT_LOG_LEVEL:-INFO}"
export CLAUDEBOT_PLUGIN_DIR="$PLUGIN_DIR"
LOG_COMPONENT="run-bot"
source "${SCRIPT_DIR}/log-lib.sh"

POLL_TIMEOUT="${CLAUDEBOT_POLL_TIMEOUT:-30}"
MAX_CONSECUTIVE_FAILURES="${CLAUDEBOT_MAX_FAILURES:-5}"
MCP_PORT="${CLAUDEBOT_MCP_PORT:-8080}"
MCP_CONTAINER="claudebot-mcp-daemon"
LOG_DIR="${PLUGIN_DIR}/logs"
LOG_FILE="${LOG_DIR}/bot-$(date '+%Y%m%d').log"
MCP_LOG_FILE="${LOG_DIR}/mcp-$(date '+%Y%m%d').log"
SESSION_FILE="${PLUGIN_DIR}/.bot-session-id"
MCP_LOG_PID=""

SHUTTING_DOWN=false

cleanup() {
  # Guard against re-entry from EXIT after INT/TERM
  $SHUTTING_DOWN && return
  SHUTTING_DOWN=true

  log_info "Shutting down — killing child processes"

  # Kill MCP log streamer first to avoid broken-pipe noise
  if [[ -n "$MCP_LOG_PID" ]]; then
    kill "$MCP_LOG_PID" 2>/dev/null || true
  fi

  # Kill all processes in this process group (claude, docker, sleep)
  kill -- -$$ 2>/dev/null || true
  # Wait briefly for children to exit
  wait 2>/dev/null || true

  log_info "Stopping MCP daemon container"
  docker stop -t 10 "$MCP_CONTAINER" >/dev/null 2>&1 || true
  docker rm -f "$MCP_CONTAINER" >/dev/null 2>&1 || true

  if [[ -f "$SESSION_FILE" ]]; then
    log_info "Session ID preserved for restart recovery" "file=${SESSION_FILE}"
  fi
  log_info "Shutdown complete"
}
trap cleanup EXIT INT TERM

# --- Preflight checks ---
for var in CLAUDEBOT_DISCORD_TOKEN CLAUDEBOT_DISCORD_GUILD_ID; do
  if [[ -z "${!var:-}" ]]; then
    log_error "Required env var is not set" "var=${var}"
    exit 1
  fi
done

if ! command -v claude &>/dev/null; then
  log_error "claude CLI is not installed"
  exit 1
fi

if ! command -v docker &>/dev/null; then
  log_error "docker is not installed"
  exit 1
fi

if ! command -v curl &>/dev/null; then
  log_error "curl is not installed (needed for MCP daemon health probe)"
  exit 1
fi

# Create log directory
mkdir -p "$LOG_DIR"

# --- Ensure CLAUDEBOT_AUTH_TOKEN exists, generating + persisting if missing ---
if [[ -z "${CLAUDEBOT_AUTH_TOKEN:-}" ]]; then
  CLAUDEBOT_AUTH_TOKEN="$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')"
  export CLAUDEBOT_AUTH_TOKEN
  log_info "Generated new CLAUDEBOT_AUTH_TOKEN for MCP daemon"
  if [[ -f "$ENV_FILE" ]]; then
    # Strip any existing entry, then append the new one.
    tmp_env="$(mktemp)"
    grep -v '^CLAUDEBOT_AUTH_TOKEN=' "$ENV_FILE" > "$tmp_env" || true
    printf '\nCLAUDEBOT_AUTH_TOKEN=%s\n' "$CLAUDEBOT_AUTH_TOKEN" >> "$tmp_env"
    mv "$tmp_env" "$ENV_FILE"
    log_info "Persisted auth token to env file" "path=${ENV_FILE}"
  else
    log_warn "No .env file present; generated auth token will not persist across restarts"
  fi
fi

# --- Pre-pull discord-mcp Docker image ---
log_info "Pre-pulling discord-mcp Docker image"
docker pull --platform linux/arm64 ghcr.io/jamesprial/discord-mcp:latest 2>&1 | tail -1 >&2

# --- Start MCP daemon container ---
log_info "Starting MCP daemon" "port=${MCP_PORT}"
docker rm -f "$MCP_CONTAINER" >/dev/null 2>&1 || true

# discord-mcp uses lowercase pino log levels; map claudebot's uppercase convention.
mcp_log_level="$(printf '%s' "${CLAUDEBOT_LOG_LEVEL:-info}" | tr '[:upper:]' '[:lower:]')"
case "$mcp_log_level" in
  fatal|error|warn|info|debug|trace|silent) ;;
  *) mcp_log_level="info" ;;
esac

docker run -d --name "$MCP_CONTAINER" \
  --platform linux/arm64 \
  -p "${MCP_PORT}:8080" \
  -e "TRANSPORT=http" \
  -e "PORT=8080" \
  -e "HOST=0.0.0.0" \
  -e "AUTH_TOKEN=${CLAUDEBOT_AUTH_TOKEN}" \
  -e "DISCORD_TOKEN=${CLAUDEBOT_DISCORD_TOKEN}" \
  -e "GUILD_ID=${CLAUDEBOT_DISCORD_GUILD_ID}" \
  -e "WHISPER_MODEL_PATH=/tmp/whisper-placeholder" \
  -e "LOG_LEVEL=${mcp_log_level}" \
  ghcr.io/jamesprial/discord-mcp:latest

# Wait for container to be running
log_info "Waiting for MCP container to start"
for i in $(seq 1 30); do
  if docker inspect -f '{{.State.Running}}' "$MCP_CONTAINER" 2>/dev/null | grep -q true; then
    break
  fi
  if [[ $i -eq 30 ]]; then
    log_error "MCP container failed to start within 30s"
    docker logs "$MCP_CONTAINER" 2>&1 | tail -20 >&2
    exit 1
  fi
  sleep 1
done

# Wait for HTTP transport. discord-mcp connects to Discord BEFORE starting the
# HTTP listener, so any HTTP response (200/401/etc.) proves both Discord login
# succeeded and the MCP server is up.
log_info "Waiting for MCP HTTP transport to be ready"
http_ready=false
for i in $(seq 1 30); do
  if ! docker inspect -f '{{.State.Running}}' "$MCP_CONTAINER" 2>/dev/null | grep -q true; then
    log_error "MCP container exited unexpectedly during startup"
    docker logs "$MCP_CONTAINER" 2>&1 | tail -20 >&2
    exit 1
  fi
  code="$(curl -sS -o /dev/null -w '%{http_code}' \
    -H "Authorization: Bearer ${CLAUDEBOT_AUTH_TOKEN}" \
    "http://localhost:${MCP_PORT}/mcp" || echo "000")"
  if [[ -n "$code" && "$code" != "000" ]]; then
    log_info "MCP HTTP transport is ready" "probe_status=${code}"
    http_ready=true
    break
  fi
  sleep 1
done

if [[ "$http_ready" != true ]]; then
  log_warn "Timed out waiting for MCP HTTP transport, proceeding anyway"
fi

# Also check the daemon logs for the "discord ready" / "ready on http" signals.
if docker logs "$MCP_CONTAINER" 2>&1 | grep -q "discord ready"; then
  log_info "MCP daemon Discord client is ready"
elif docker logs "$MCP_CONTAINER" 2>&1 | grep -q "ready on http"; then
  log_info "MCP daemon HTTP transport reported ready (Discord status unknown)"
fi

# --- Start MCP daemon log stream ---
log_info "Starting MCP daemon log stream"
docker logs -f --timestamps "$MCP_CONTAINER" >> "$MCP_LOG_FILE" 2>&1 &
MCP_LOG_PID=$!
log_debug "MCP log streamer started" "pid=${MCP_LOG_PID}"

# --- Generate runtime .mcp.json (embeds the bearer token) ---
RUNTIME_MCP_CONFIG="${PLUGIN_DIR}/.mcp.runtime.json"
cat > "$RUNTIME_MCP_CONFIG" <<EOF
{
  "mcpServers": {
    "discord": {
      "type": "http",
      "url": "http://localhost:${MCP_PORT}/mcp",
      "headers": {
        "Authorization": "Bearer ${CLAUDEBOT_AUTH_TOKEN}"
      }
    }
  }
}
EOF
log_info "Generated runtime MCP config" "path=${RUNTIME_MCP_CONFIG}"

# --- Common claude flags ---
CLAUDE_FLAGS=(
  -p
  --plugin-dir "$PLUGIN_DIR"
  --mcp-config "$RUNTIME_MCP_CONFIG"
  --dangerously-skip-permissions
  --output-format json
)
log_debug "Claude flags configured" "plugin_dir=${PLUGIN_DIR}" "mcp_config=${RUNTIME_MCP_CONFIG}"

# --- Initialize or resume session ---
INIT_PROMPT="Session starting. Load the discord-bot skill and initialize. \
Read .claude/claudebot.local.md for channel config and .claude/memory/personality.md \
for current personality. Verify MCP connectivity by calling discord_get_guild."

SESSION_ID=""

# Check for existing session to resume
if [[ -f "$SESSION_FILE" ]]; then
  EXISTING_SESSION="$(cat "$SESSION_FILE")"
  log_info "Found existing session, attempting resume" "session=${EXISTING_SESSION}"

  if timeout 180 claude "${CLAUDE_FLAGS[@]}" --resume "$EXISTING_SESSION" \
    "$INIT_PROMPT" < /dev/null >>"$LOG_FILE" 2>&1; then
    SESSION_ID="$EXISTING_SESSION"
    log_info "Resumed session" "session=${SESSION_ID}"
  else
    log_warn "Failed to resume, starting fresh session"
    rm -f "$SESSION_FILE"
  fi
fi

if [[ -z "$SESSION_ID" ]]; then
  SESSION_ID="$(python3 -c 'import uuid; print(uuid.uuid4())')"
  log_info "Creating new session" "session=${SESSION_ID}"

  if ! timeout 180 claude "${CLAUDE_FLAGS[@]}" --session-id "$SESSION_ID" \
    "$INIT_PROMPT" < /dev/null >>"$LOG_FILE" 2>&1; then
    log_error "Failed to initialize session"
    exit 1
  fi

  log_info "Session initialized successfully"
fi

# Persist session ID for crash recovery
echo "$SESSION_ID" > "$SESSION_FILE"
log_debug "Session ID saved" "file=${SESSION_FILE}"

# --- Poll loop ---
log_info "Starting message poll loop" "interval=${POLL_TIMEOUT}s"

consecutive_failures=0

while true; do
  # Check that daemon is still running
  if ! docker inspect -f '{{.State.Running}}' "$MCP_CONTAINER" 2>/dev/null | grep -q true; then
    log_error "MCP daemon container died, exiting"
    exit 1
  fi

  # Check that MCP log streamer is still running
  if [[ -n "$MCP_LOG_PID" ]] && ! kill -0 "$MCP_LOG_PID" 2>/dev/null; then
    log_warn "MCP log streamer died, restarting"
    docker logs -f --timestamps "$MCP_CONTAINER" >> "$MCP_LOG_FILE" 2>&1 &
    MCP_LOG_PID=$!
  fi

  POLL_PROMPT="Poll for new Discord messages using discord_poll_messages \
with timeout_seconds=${POLL_TIMEOUT} and limit=10. Process any messages received."

  if timeout 120 claude "${CLAUDE_FLAGS[@]}" --resume "$SESSION_ID" \
    "$POLL_PROMPT" < /dev/null >>"$LOG_FILE" 2>&1; then
    consecutive_failures=0
  else
    consecutive_failures=$((consecutive_failures + 1))
    log_warn "Poll failed" "consecutive=${consecutive_failures}/${MAX_CONSECUTIVE_FAILURES}"

    if [[ $consecutive_failures -ge $MAX_CONSECUTIVE_FAILURES ]]; then
      log_error "Too many consecutive failures, exiting"
      exit 1
    fi

    # Backoff: sleep for (failures * 5) seconds, capped at POLL_TIMEOUT
    backoff=$((consecutive_failures * 5))
    [[ $backoff -gt $POLL_TIMEOUT ]] && backoff=$POLL_TIMEOUT
    log_info "Backing off" "seconds=${backoff}"
    sleep "$backoff"
    continue
  fi

  # Brief pause between polls
  sleep 2
done
