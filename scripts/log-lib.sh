#!/usr/bin/env bash
# log-lib.sh - Structured logging library for claudebot
# Source this file to get log_debug, log_info, log_warn, log_error functions.
#
# Environment:
#   CLAUDEBOT_LOG_LEVEL  - Minimum level to emit (DEBUG|INFO|WARN|ERROR, default INFO)
#   LOG_COMPONENT        - Tag for the component field (default "unknown")
#   CLAUDEBOT_PLUGIN_DIR - If set and logs/ exists, also appends to daily log file

_log_level_num() {
  case "$1" in
    DEBUG) echo 0 ;;
    INFO)  echo 1 ;;
    WARN)  echo 2 ;;
    ERROR) echo 3 ;;
    *)     echo 1 ;;
  esac
}

_log_emit() {
  local level="$1"; shift
  local msg="$1"; shift
  # Remaining args are key=value pairs

  local threshold="${CLAUDEBOT_LOG_LEVEL:-INFO}"
  local level_n; level_n=$(_log_level_num "$level")
  local thresh_n; thresh_n=$(_log_level_num "$threshold")
  [[ $level_n -lt $thresh_n ]] && return 0

  local component="${LOG_COMPONENT:-unknown}"
  local ts; ts="$(date -u '+%Y-%m-%dT%H:%M:%S')"
  local line="${ts} level=${level} component=${component} msg=\"${msg}\""

  # Append any extra key=value pairs
  for kv in "$@"; do
    line="${line} ${kv}"
  done

  # Always write to stderr
  echo "$line" >&2

  # Append to log file if plugin dir is available
  if [[ -n "${CLAUDEBOT_PLUGIN_DIR:-}" && -d "${CLAUDEBOT_PLUGIN_DIR}/logs" ]]; then
    echo "$line" >> "${CLAUDEBOT_PLUGIN_DIR}/logs/bot-$(date '+%Y%m%d').log"
  fi
}

log_debug() { _log_emit DEBUG "$@"; }
log_info()  { _log_emit INFO  "$@"; }
log_warn()  { _log_emit WARN  "$@"; }
log_error() { _log_emit ERROR "$@"; }
