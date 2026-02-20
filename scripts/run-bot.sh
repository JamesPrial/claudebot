#!/usr/bin/env bash
# run-bot.sh - Claudebot lifecycle orchestrator
# Runs the MCP server as a persistent Docker daemon (HTTP transport) so the
# Discord gateway stays open and the bot appears always-online. Uses repeated
# `claude -p --resume` calls to maintain a persistent session across poll cycles.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(dirname "$SCRIPT_DIR")"

# Load .env if present
if [[ -f "${PLUGIN_DIR}/.env" ]]; then
  set -a
  source "${PLUGIN_DIR}/.env"
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

# Create log directory
mkdir -p "$LOG_DIR"

# --- Pre-pull Docker images ---
log_info "Pre-pulling go-scream image"
docker pull --platform linux/arm64 ghcr.io/jamesprial/go-scream:latest || log_warn "Failed to pull go-scream image (voice screams may not work)"

log_info "Pre-pulling MCP Docker image"
docker pull --platform linux/arm64 ghcr.io/jamesprial/claudebot-mcp:latest 2>&1 | tail -1 >&2

# --- Start MCP daemon container ---
log_info "Starting MCP daemon" "port=${MCP_PORT}"
docker rm -f "$MCP_CONTAINER" >/dev/null 2>&1 || true
docker run -d --name "$MCP_CONTAINER" \
  --platform linux/arm64 \
  -p "${MCP_PORT}:8080" \
  -e CLAUDEBOT_DISCORD_TOKEN \
  -e CLAUDEBOT_DISCORD_GUILD_ID \
  ghcr.io/jamesprial/claudebot-mcp:latest

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

# Wait for Discord connection
log_info "Waiting for Discord connection"
for i in $(seq 1 30); do
  if docker logs "$MCP_CONTAINER" 2>&1 | grep -q "discord: connected as"; then
    log_info "MCP daemon connected to Discord"
    break
  fi
  if ! docker inspect -f '{{.State.Running}}' "$MCP_CONTAINER" 2>/dev/null | grep -q true; then
    log_error "MCP container exited unexpectedly"
    docker logs "$MCP_CONTAINER" 2>&1 | tail -20 >&2
    exit 1
  fi
  if [[ $i -eq 30 ]]; then
    log_warn "Timed out waiting for Discord connection, proceeding anyway"
  fi
  sleep 1
done

# --- Start MCP daemon log stream ---
log_info "Starting MCP daemon log stream"
docker logs -f --timestamps "$MCP_CONTAINER" >> "$MCP_LOG_FILE" 2>&1 &
MCP_LOG_PID=$!
log_debug "MCP log streamer started" "pid=${MCP_LOG_PID}"

# --- Generate runtime .mcp.json ---
RUNTIME_MCP_CONFIG="${PLUGIN_DIR}/.mcp.runtime.json"
cat > "$RUNTIME_MCP_CONFIG" <<EOF
{
  "mcpServers": {
    "discord": {
      "type": "http",
      "url": "http://localhost:${MCP_PORT}/mcp"
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
