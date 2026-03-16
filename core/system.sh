#!/usr/bin/env bash
# =============================================================================
# bash-lib/core/system.sh
# System helpers: root check, OS detect, error trapping, $STD, dependencies
# =============================================================================

[[ -n "${_BASHLIB_SYSTEM_LOADED:-}" ]] && return 0
readonly _BASHLIB_SYSTEM_LOADED=1

# ── $STD — suppress stdout khi không cần, vẫn log error ─────────────────────
# Usage: $STD apt-get install -y curl
# Set BASHLIB_VERBOSE=1 để thấy output đầy đủ
if [[ "${BASHLIB_VERBOSE:-0}" == "1" ]]; then
    STD=""
else
    STD="silent_run"
fi

silent_run() {
    local output
    if output=$("$@" 2>&1); then
        msg_debug "CMD OK: $*"
        return 0
    else
        local exit_code=$?
        msg_debug "CMD FAIL (${exit_code}): $*"
        msg_debug "Output: ${output}"
        # Log đầy đủ output vào file kể cả khi suppress
        _log_write "CMD_FAIL" "$* → exit=${exit_code}: ${output}"
        return "$exit_code"
    fi
}

# ── Error trap ────────────────────────────────────────────────────────────────
catch_errors() {
    set -Eeuo pipefail
    trap '_trap_error ${LINENO} "$BASH_COMMAND" $?' ERR
    trap '_trap_exit' EXIT
    trap '_trap_int' INT TERM
}

_trap_error() {
    local line="$1" cmd="$2" code="$3"
    spinner_stop 2>/dev/null || true
    echo ""
    msg_error "Lỗi không mong đợi tại dòng ${line}"
    msg_plain  "Lệnh   : ${cmd}"
    msg_plain  "Exit   : ${code}"
    msg_plain  "Script : ${BASH_SOURCE[1]:-unknown}"
    _log_write "TRAP_ERR" "line=${line} cmd=${cmd} exit=${code}"
    _print_log_location
}

_trap_exit() {
    local code=$?
    spinner_stop 2>/dev/null || true
    if [[ $code -ne 0 ]]; then
        _log_write "EXIT" "code=${code}"
        _print_log_location
    fi
}

_trap_int() {
    spinner_stop 2>/dev/null || true
    echo ""
    msg_warn "Bị ngắt bởi người dùng (Ctrl+C)"
    _log_write "INTERRUPT" "user interrupt"
    exit 130
}

_print_log_location() {
    if [[ -n "${BASHLIB_LOG_FILE:-}" ]]; then
        echo -e "\n  ${C_DIM}Log file: ${BASHLIB_LOG_FILE}${CL}"
    fi
}

# ── Root check ────────────────────────────────────────────────────────────────
check_root() {
    if [[ "$EUID" -ne 0 ]]; then
        msg_error "Script phải chạy với quyền root"
        msg_plain "Thử lại: sudo $0"
        exit 1
    fi
    msg_debug "Running as root: OK"
}

# ── OS detection ──────────────────────────────────────────────────────────────
# Sau khi gọi: các biến OS_ID, OS_VERSION, OS_CODENAME, OS_LIKE được set
detect_os() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck source=/dev/null
        source /etc/os-release
        OS_ID="${ID:-unknown}"
        OS_VERSION="${VERSION_ID:-unknown}"
        OS_CODENAME="${VERSION_CODENAME:-unknown}"
        OS_LIKE="${ID_LIKE:-${ID:-unknown}}"
    else
        OS_ID="unknown"
        OS_VERSION="unknown"
        OS_CODENAME="unknown"
        OS_LIKE="unknown"
    fi

    msg_debug "OS: ${OS_ID} ${OS_VERSION} (${OS_CODENAME}) like=${OS_LIKE}"
}

# Kiểm tra OS có trong danh sách hỗ trợ không
# Usage: check_os_supported "debian" "ubuntu" "raspbian"
check_os_supported() {
    local supported=("$@")
    detect_os

    for s in "${supported[@]}"; do
        if [[ "$OS_ID" == "$s" ]] || [[ "$OS_LIKE" == *"$s"* ]]; then
            msg_debug "OS supported: ${OS_ID}"
            return 0
        fi
    done

    msg_error "OS không được hỗ trợ: ${OS_ID} ${OS_VERSION}"
    msg_plain  "Hỗ trợ: ${supported[*]}"
    return 1
}

# ── Dependency check ──────────────────────────────────────────────────────────
# Usage: check_deps curl wget nc jq
check_deps() {
    local missing=()
    for dep in "$@"; do
        if ! command -v "$dep" &>/dev/null; then
            missing+=("$dep")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        msg_warn "Thiếu dependencies: ${missing[*]}"
        msg_plain "Cài bằng: apt-get install -y ${missing[*]}"
        return 1
    fi

    msg_debug "All deps found: $*"
    return 0
}

# Tự động cài dependencies còn thiếu
# Usage: ensure_deps curl wget nc
ensure_deps() {
    local missing=()
    for dep in "$@"; do
        command -v "$dep" &>/dev/null || missing+=("$dep")
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        msg_info "Cài dependencies: ${missing[*]}"
        $STD apt-get update -qq
        $STD apt-get install -y "${missing[@]}"
        msg_ok "Đã cài: ${missing[*]}"
    fi
}

# ── Proxmox host detection ────────────────────────────────────────────────────
# Trả về 0 nếu đang chạy trên Proxmox host
is_proxmox_host() {
    command -v pveversion &>/dev/null && return 0
    [[ -f /etc/pve/version ]] && return 0
    return 1
}

# Trả về 0 nếu đang chạy trong LXC container
is_lxc_container() {
    grep -qa "container=lxc" /proc/1/environ 2>/dev/null && return 0
    [[ -f /run/container_type ]] && grep -q "lxc" /run/container_type && return 0
    systemd-detect-virt --container 2>/dev/null | grep -q "lxc" && return 0
    return 1
}

# ── Disk space check ──────────────────────────────────────────────────────────
# Usage: check_disk_space "/path" 2048  (cần 2048 MB)
check_disk_space() {
    local path="${1:-/}"
    local required_mb="${2:-1024}"
    local available_mb

    available_mb=$(df -m "$path" 2>/dev/null | awk 'NR==2 {print $4}')

    if [[ -z "$available_mb" ]]; then
        msg_warn "Không đọc được disk space tại ${path}"
        return 1
    fi

    if (( available_mb < required_mb )); then
        msg_check "fail" "Disk space" \
            "${available_mb}MB free — cần ${required_mb}MB"
        return 1
    fi

    msg_check "pass" "Disk space" \
        "${available_mb}MB free (cần ${required_mb}MB)"
    return 0
}

# ── RAM check ─────────────────────────────────────────────────────────────────
# Usage: check_ram 512  (cần 512 MB free)
check_ram() {
    local required_mb="${1:-256}"
    local available_mb

    available_mb=$(free -m | awk '/^Mem/{print $7}')

    if (( available_mb < required_mb )); then
        msg_check "warn" "RAM free" \
            "${available_mb}MB — khuyến nghị ${required_mb}MB+"
        return 1
    fi

    msg_check "pass" "RAM free" "${available_mb}MB"
    return 0
}

# ── Arch check ────────────────────────────────────────────────────────────────
check_arch() {
    local required="${1:-x86_64}"
    local current
    current=$(uname -m)

    if [[ "$current" != "$required" ]]; then
        msg_check "warn" "Architecture" "${current} (yêu cầu ${required})"
        return 1
    fi

    msg_check "pass" "Architecture" "${current}"
    return 0
}

# ── Version compare ───────────────────────────────────────────────────────────
# Usage: version_gte "8.2" "8.0"  → true nếu 8.2 >= 8.0
version_gte() {
    printf '%s\n%s\n' "$2" "$1" | sort -V -C
}
