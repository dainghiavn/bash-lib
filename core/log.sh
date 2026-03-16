#!/usr/bin/env bash
# =============================================================================
# bash-lib/core/log.sh
# Logging: init, write, summary, rotation
# Log file tự động tạo tại /var/log/bash-lib/ hoặc /tmp/
# =============================================================================

[[ -n "${_BASHLIB_LOG_LOADED:-}" ]] && return 0
readonly _BASHLIB_LOG_LOADED=1

# ── Config (có thể override trước khi source) ─────────────────────────────────
BASHLIB_LOG_DIR="${BASHLIB_LOG_DIR:-/var/log/bash-lib}"
BASHLIB_LOG_FILE=""   # sẽ set trong log_init
BASHLIB_LOG_MAX="${BASHLIB_LOG_MAX:-50}"  # giữ tối đa N log files

# ── Init log file ─────────────────────────────────────────────────────────────
# Usage: log_init "tailscale-install"
log_init() {
    local name="${1:-script}"
    local timestamp
    timestamp=$(date +"%Y%m%d_%H%M%S")

    # Thử tạo thư mục log
    if mkdir -p "$BASHLIB_LOG_DIR" 2>/dev/null; then
        BASHLIB_LOG_FILE="${BASHLIB_LOG_DIR}/${name}-${timestamp}.log"
    else
        # Fallback về /tmp
        BASHLIB_LOG_DIR="/tmp/bash-lib-logs"
        mkdir -p "$BASHLIB_LOG_DIR" 2>/dev/null || BASHLIB_LOG_DIR="/tmp"
        BASHLIB_LOG_FILE="${BASHLIB_LOG_DIR}/${name}-${timestamp}.log"
    fi

    # Header log file
    cat > "$BASHLIB_LOG_FILE" <<EOF
# =============================================================
# Log: ${name}
# Started: $(date '+%Y-%m-%d %H:%M:%S %Z')
# Host: $(hostname)
# User: $(whoami)
# Script: ${BASH_SOURCE[-1]:-unknown}
# bash-lib version: main
# =============================================================
EOF

    # Rotate logs cũ
    _log_rotate "$BASHLIB_LOG_DIR" "$name"

    msg_debug "Log file: ${BASHLIB_LOG_FILE}"
}

# ── Write log entry ───────────────────────────────────────────────────────────
log_write() {
    [[ -z "${BASHLIB_LOG_FILE:-}" ]] && return 0
    local level="${1:-INFO}"
    local message="$2"
    local timestamp
    timestamp=$(date '+%H:%M:%S')

    printf "[%s] %-12s %s\n" "$timestamp" "${level}" "${message}" \
        >> "$BASHLIB_LOG_FILE" 2>/dev/null || true
}

# ── Log raw block (multi-line, không format) ──────────────────────────────────
log_block() {
    [[ -z "${BASHLIB_LOG_FILE:-}" ]] && return 0
    local title="${1:-block}"
    {
        echo "--- ${title} ---"
        cat
        echo "--- end ${title} ---"
    } >> "$BASHLIB_LOG_FILE" 2>/dev/null || true
}

# ── Log command output ────────────────────────────────────────────────────────
log_cmd() {
    [[ -z "${BASHLIB_LOG_FILE:-}" ]] && return 0
    local label="${1:-cmd}"; shift
    log_write "CMD" "${label}: $*"
    {
        echo "--- cmd: $* ---"
        "$@" 2>&1 || true
        echo "--- end cmd ---"
    } >> "$BASHLIB_LOG_FILE" 2>/dev/null || true
}

# ── Summary section ───────────────────────────────────────────────────────────
log_summary() {
    [[ -z "${BASHLIB_LOG_FILE:-}" ]] && return 0
    {
        echo ""
        echo "# ==========================================================="
        echo "# SUMMARY"
        echo "# Ended: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "# Duration: $(_log_duration)s"
        echo "# ==========================================================="
    } >> "$BASHLIB_LOG_FILE" 2>/dev/null || true
}

# ── Get log file path ─────────────────────────────────────────────────────────
get_log_file() {
    echo "${BASHLIB_LOG_FILE:-}"
}

# ── Rotate old logs ───────────────────────────────────────────────────────────
_log_rotate() {
    local dir="$1" prefix="$2"
    local max="${BASHLIB_LOG_MAX:-50}"

    # Giữ lại N file mới nhất, xóa phần còn lại
    local count
    count=$(find "$dir" -name "${prefix}-*.log" 2>/dev/null | wc -l)

    if (( count > max )); then
        find "$dir" -name "${prefix}-*.log" 2>/dev/null \
            | sort \
            | head -n $(( count - max )) \
            | xargs rm -f 2>/dev/null || true
    fi
}

# ── Duration tracking ─────────────────────────────────────────────────────────
_BASHLIB_START_TIME="${SECONDS}"

_log_duration() {
    echo $(( SECONDS - _BASHLIB_START_TIME ))
}

log_elapsed() {
    local elapsed=$(( SECONDS - _BASHLIB_START_TIME ))
    if (( elapsed < 60 )); then
        echo "${elapsed}s"
    else
        printf "%dm%ds" $(( elapsed/60 )) $(( elapsed%60 ))
    fi
}
