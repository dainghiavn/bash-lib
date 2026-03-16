#!/usr/bin/env bash
# =============================================================================
# bash-lib/lib.sh  —  ENTRY POINT DUY NHẤT
#
# Cách dùng trong bất kỳ script nào:
#
#   source <(curl -fsSL https://raw.githubusercontent.com/YOUR_USERNAME/bash-lib/main/lib.sh)
#
# Core tự động load. Gọi thêm nếu cần:
#
#   load_network    # check internet, DNS, UDP, NAT type
#   load_proxmox    # Proxmox/LXC helpers
#
# Override trước khi source (tùy chọn):
#
#   BASHLIB_VERBOSE=1         # hiện output đầy đủ thay vì suppress
#   BASHLIB_DEBUG=1           # hiện debug messages
#   BASHLIB_LOG_DIR="/custom" # thư mục log tùy chỉnh
#   BASHLIB_NO_LOG=1          # tắt log file hoàn toàn
# =============================================================================

[[ -n "${_BASHLIB_LOADED:-}" ]] && return 0
readonly _BASHLIB_LOADED=1

# ── Base URL — trỏ về repo của bạn ───────────────────────────────────────────
readonly BASHLIB_BASE_URL="https://raw.githubusercontent.com/YOUR_USERNAME/bash-lib/main"
readonly BASHLIB_VERSION="main"

# ── Internal loader ───────────────────────────────────────────────────────────
_lib_load() {
    local module="$1"
    local url="${BASHLIB_BASE_URL}/${module}"

    # Thử load, báo lỗi rõ ràng nếu fail
    if ! source <(curl -fsSL --max-time 15 "$url" 2>/dev/null); then
        echo "[bash-lib] ERROR: Không load được module: ${module}" >&2
        echo "[bash-lib] URL: ${url}" >&2
        echo "[bash-lib] Kiểm tra: internet, GitHub URL, tên file" >&2
        return 1
    fi
}

# ── Load CORE (bắt buộc, luôn chạy) ─────────────────────────────────────────
_lib_load "core/log.sh"
_lib_load "core/ui.sh"
_lib_load "core/system.sh"

# Khởi tạo log ngay sau khi load (nếu không disable)
if [[ "${BASHLIB_NO_LOG:-0}" != "1" ]]; then
    log_init "${BASHLIB_APP_NAME:-script}"
fi

# ── Public functions: load theo yêu cầu ──────────────────────────────────────

# Gọi trong script khi cần network checks
load_network() {
    [[ -n "${_BASHLIB_NET_LOADED:-}" ]] && return 0
    _lib_load "network/basic.sh"
    _lib_load "network/udp_nat.sh"
    readonly _BASHLIB_NET_LOADED=1
    msg_debug "Network module loaded"
}

# Gọi trong script khi chạy trên Proxmox host
load_proxmox() {
    [[ -n "${_BASHLIB_PVE_MODULE_LOADED:-}" ]] && return 0

    if ! is_proxmox_host; then
        msg_warn "load_proxmox gọi nhưng không phải Proxmox host — skip"
        return 1
    fi

    _lib_load "proxmox/pve.sh"
    readonly _BASHLIB_PVE_MODULE_LOADED=1
    msg_debug "Proxmox module loaded"
}

# ── Version info ──────────────────────────────────────────────────────────────
bashlib_version() {
    echo "bash-lib ${BASHLIB_VERSION} — ${BASHLIB_BASE_URL}"
}

# ── Self-test (debug) ─────────────────────────────────────────────────────────
bashlib_selftest() {
    msg_section "bash-lib self-test"
    msg_ok   "Core loaded"
    msg_info "Version: $(bashlib_version)"
    msg_info "Log: $(get_log_file)"
    msg_info "OS: ${OS_ID:-unknown} (chạy detect_os() để fill)"
    msg_info "Proxmox host: $(is_proxmox_host && echo YES || echo NO)"
    msg_info "LXC container: $(is_lxc_container && echo YES || echo NO)"
}
