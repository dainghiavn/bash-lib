#!/usr/bin/env bash
# =============================================================================
# bash-lib/core/ui.sh
# UI helpers: colors, message functions, spinner, header, prompts
# Compatible: Bash 4+, Debian/Ubuntu/Alpine, Proxmox LXC host
# =============================================================================

# ── Guard: chỉ load 1 lần ────────────────────────────────────────────────────
[[ -n "${_BASHLIB_UI_LOADED:-}" ]] && return 0
readonly _BASHLIB_UI_LOADED=1

# ── Color codes ───────────────────────────────────────────────────────────────
# Dùng $'\e[' thay vì "\e[" để escape character được interpret đúng
# "\e[" chỉ là literal string — $'\e[' mới là ESC character thực sự
if [[ -t 1 ]] || [[ "${FORCE_COLOR:-0}" == "1" ]]; then
    readonly CL=$'\e[0m'      # reset
    readonly RD=$'\e[31m'     # red
    readonly GN=$'\e[32m'     # green
    readonly YW=$'\e[33m'     # yellow
    readonly BL=$'\e[34m'     # blue
    readonly CY=$'\e[36m'     # cyan
    readonly WH=$'\e[97m'     # white
    readonly DM=$'\e[2m'      # dim
    readonly BLD=$'\e[1m'     # bold

    # Semantic colors
    readonly C_OK="${GN}"
    readonly C_ERR="${RD}"
    readonly C_WARN="${YW}"
    readonly C_INFO="${CY}"
    readonly C_DIM="${DM}"
else
    # No color (pipe, non-interactive)
    readonly CL="" RD="" GN="" YW="" BL="" CY="" WH="" DM="" BLD=""
    readonly C_OK="" C_ERR="" C_WARN="" C_INFO="" C_DIM=""
fi

# Prefix icons
readonly ICON_OK="✓"
readonly ICON_ERR="✗"
readonly ICON_WARN="⚠"
readonly ICON_INFO="ℹ"
readonly ICON_ARROW="→"
readonly ICON_DOT="•"

# ── Message functions ─────────────────────────────────────────────────────────

msg_ok() {
    echo -e "  ${C_OK}${ICON_OK}${CL}  ${WH}${1}${CL}"
    _log_write "OK" "$1"
}

msg_info() {
    echo -e "  ${C_INFO}${ICON_INFO}${CL}  ${1}"
    _log_write "INFO" "$1"
}

msg_warn() {
    echo -e "  ${C_WARN}${ICON_WARN}${CL}  ${YW}${1}${CL}"
    _log_write "WARN" "$1"
}

msg_error() {
    echo -e "  ${C_ERR}${ICON_ERR}${CL}  ${RD}${1}${CL}" >&2
    _log_write "ERROR" "$1"
}

msg_debug() {
    [[ "${BASHLIB_DEBUG:-0}" == "1" ]] || return 0
    echo -e "  ${C_DIM}[DBG] ${1}${CL}" >&2
    _log_write "DEBUG" "$1"
}

# Plain text — không icon, dùng cho sub-items
msg_plain() {
    echo -e "       ${C_DIM}${ICON_ARROW}${CL} ${1}"
    _log_write "    " "$1"
}

# ── Preflight-specific: check result line ─────────────────────────────────────
# Usage: msg_check "pass|fail|warn|info|skip" "Label" "Detail"
msg_check() {
    local status="$1" label="$2" detail="${3:-}"
    local icon color

    case "$status" in
        pass)  icon="[${ICON_OK}]" color="${C_OK}"   ;;
        fail)  icon="[${ICON_ERR}]" color="${C_ERR}" ;;
        warn)  icon="[${ICON_WARN}]" color="${C_WARN}" ;;
        info)  icon="[${ICON_INFO}]" color="${C_INFO}" ;;
        skip)  icon="[−]"          color="${C_DIM}"  ;;
        *)     icon="[?]"          color="${CL}"     ;;
    esac

    printf "  %b%-4s%b  %-38s %b%s%b\n" \
        "$color" "$icon" "$CL" \
        "$label" \
        "$C_DIM" "$detail" "$CL"

    _log_write "CHECK:${status^^}" "${label} ${detail}"
}

# ── Section header ─────────────────────────────────────────────────────────────
msg_section() {
    local title="$1"
    echo ""
    echo -e "  ${BLD}${CY}── ${title} ${CL}${C_DIM}$(printf '─%.0s' {1..40})${CL}"
    _log_write "SECTION" "$title"
}

# ── Banner / App header ───────────────────────────────────────────────────────
header_info() {
    local app="${1:-Script}"
    local version="${2:-}"
    clear 2>/dev/null || true
    cat <<EOF

  ${BLD}${CY}╔══════════════════════════════════════════════╗${CL}
  ${BLD}${CY}║${CL}  ${WH}${BLD}${app}${CL}${version:+  ${C_DIM}${version}${CL}}
  ${BLD}${CY}║${CL}  ${C_DIM}Installer${CL}
  ${BLD}${CY}╚══════════════════════════════════════════════╝${CL}

EOF
    _log_write "HEADER" "=== ${app} ${version} ==="
}

# ── Divider ───────────────────────────────────────────────────────────────────
msg_divider() {
    echo -e "  ${C_DIM}$(printf '─%.0s' {1..50})${CL}"
}

# ── Spinner ───────────────────────────────────────────────────────────────────
_SPINNER_PID=""

spinner_start() {
    local msg="${1:-Working...}"
    local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    (
        local i=0
        while true; do
            printf "\r  ${C_INFO}%s${CL}  %s " "${frames[$i]}" "$msg"
            i=$(( (i+1) % ${#frames[@]} ))
            sleep 0.1
        done
    ) &
    _SPINNER_PID=$!
    disown "$_SPINNER_PID" 2>/dev/null || true
}

spinner_stop() {
    if [[ -n "$_SPINNER_PID" ]]; then
        kill "$_SPINNER_PID" 2>/dev/null || true
        wait "$_SPINNER_PID" 2>/dev/null || true
        _SPINNER_PID=""
        printf "\r%*s\r" "$(tput cols 2>/dev/null || echo 80)" ""
    fi
}

# ── Interactive prompts ───────────────────────────────────────────────────────

# Prompt yes/no — trả về 0 nếu yes, 1 nếu no
# Usage: prompt_yn "Question" [Y|N]  (default)
prompt_yn() {
    local question="$1"
    local default="${2:-Y}"
    local prompt_str

    if [[ "${default^^}" == "Y" ]]; then
        prompt_str="${GN}Y${CL}/${RD}n${CL}"
    else
        prompt_str="${RD}y${CL}/${GN}N${CL}"
    fi

    while true; do
        echo -en "\n  ${C_WARN}?${CL}  ${question} [${prompt_str}]: "
        read -r reply
        reply="${reply:-$default}"
        case "${reply^^}" in
            Y|YES) _log_write "PROMPT" "${question} → YES"; return 0 ;;
            N|NO)  _log_write "PROMPT" "${question} → NO";  return 1 ;;
            *)     msg_warn "Vui lòng nhập Y hoặc N" ;;
        esac
    done
}

# Prompt text input
# Usage: prompt_input "Label" "default_value" → sets REPLY
prompt_input() {
    local label="$1"
    local default="${2:-}"
    local hint="${default:+ (mặc định: ${C_DIM}${default}${CL})}"

    echo -en "\n  ${C_INFO}?${CL}  ${label}${hint}: "
    read -r REPLY
    REPLY="${REPLY:-$default}"
    _log_write "INPUT" "${label} → ${REPLY}"
}

# Prompt menu — chọn từ list
# Usage: prompt_menu "Title" "opt1" "opt2" ... → sets MENU_CHOICE (1-based)
prompt_menu() {
    local title="$1"; shift
    local options=("$@")
    local choice

    echo ""
    echo -e "  ${BLD}${title}${CL}"
    msg_divider

    local i=1
    for opt in "${options[@]}"; do
        echo -e "  ${C_INFO}[${i}]${CL}  ${opt}"
        (( i++ ))
    done
    echo ""

    while true; do
        echo -en "  ${C_WARN}?${CL}  Lựa chọn [1-${#options[@]}]: "
        read -r choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && \
           (( choice >= 1 && choice <= ${#options[@]} )); then
            MENU_CHOICE="$choice"
            _log_write "MENU" "${title} → [${choice}] ${options[$((choice-1))]}"
            return 0
        fi
        msg_warn "Vui lòng nhập số từ 1 đến ${#options[@]}"
    done
}

# ── Summary box ───────────────────────────────────────────────────────────────
# Usage: print_summary "Title" "key1" "val1" "key2" "val2" ...
print_summary() {
    local title="$1"; shift
    local pairs=("$@")

    echo ""
    echo -e "  ${BLD}${CY}╔══════════════════════════════════════════════╗${CL}"
    printf   "  ${BLD}${CY}║${CL}  %-44s${BLD}${CY}║${CL}\n" "${title}"
    echo -e  "  ${BLD}${CY}╠══════════════════════════════════════════════╣${CL}"

    local i=0
    while (( i < ${#pairs[@]} )); do
        local key="${pairs[$i]}"
        local val="${pairs[$((i+1))]}"
        printf "  ${BLD}${CY}║${CL}  ${C_DIM}%-18s${CL} %-24s${BLD}${CY}║${CL}\n" \
            "${key}:" "${val}"
        (( i+=2 ))
    done

    echo -e "  ${BLD}${CY}╚══════════════════════════════════════════════╝${CL}"
    echo ""
}

# ── Internal log bridge (gọi từ log.sh nếu đã load) ─────────────────────────
_log_write() {
    # Nếu log.sh chưa load → no-op
    if declare -f log_write &>/dev/null; then
        log_write "$1" "$2"
    fi
}
