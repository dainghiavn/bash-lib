#!/usr/bin/env bash
# =============================================================================
# bash-lib/network/basic.sh
# Network basics: internet, DNS, HTTPS, gateway, hop count, VLAN
# =============================================================================

[[ -n "${_BASHLIB_NET_BASIC_LOADED:-}" ]] && return 0
readonly _BASHLIB_NET_BASIC_LOADED=1

# ── Internet connectivity ─────────────────────────────────────────────────────
check_internet() {
    local timeout="${1:-5}"
    local targets=("1.1.1.1" "8.8.8.8" "9.9.9.9")

    for target in "${targets[@]}"; do
        if ping -c1 -W"$timeout" "$target" &>/dev/null; then
            msg_check "pass" "Internet" "ping ${target} OK"
            return 0
        fi
    done

    msg_check "fail" "Internet" "Không ping được — kiểm tra kết nối mạng"
    return 1
}

# ── DNS resolution ────────────────────────────────────────────────────────────
check_dns() {
    local host="${1:-controlplane.tailscale.com}"
    local timeout="${2:-5}"

    if getent hosts "$host" &>/dev/null; then
        local resolved
        resolved=$(getent hosts "$host" | awk '{print $1}' | head -1)
        msg_check "pass" "DNS" "Resolve ${host} → ${resolved}"
        return 0
    fi

    # Fallback dùng dig nếu có
    if command -v dig &>/dev/null; then
        if dig +short +time="$timeout" "$host" 2>/dev/null | grep -q '.'; then
            msg_check "pass" "DNS" "dig ${host} OK"
            return 0
        fi
    fi

    msg_check "fail" "DNS" "Không resolve được ${host}"
    return 1
}

# ── HTTPS reachability ────────────────────────────────────────────────────────
check_https() {
    local url="${1:-https://controlplane.tailscale.com/health}"
    local timeout="${2:-10}"

    if ! command -v curl &>/dev/null; then
        msg_check "skip" "HTTPS" "curl không có — bỏ qua"
        return 0
    fi

    local http_code
    # Bỏ -f flag để curl không exit non-zero với 4xx/5xx
    # Dùng --write-out thay vì -w để tránh format string issue
    http_code=$(curl -sL --max-time "$timeout" \
        --output /dev/null \
        --write-out "%{http_code}" \
        "$url" 2>/dev/null)

    # Trim whitespace/null bytes
    http_code="${http_code//[^0-9]/}"

    local host_only="${url#https://}"
    host_only="${host_only%%/*}"

    # 2xx = OK, 3xx = redirect (vẫn reach được), 4xx = server có phản hồi
    # Chỉ fail khi 000 (không kết nối được) hoặc 5xx (server lỗi)
    if [[ "$http_code" =~ ^[234][0-9]{2}$ ]]; then
        msg_check "pass" "HTTPS :443" "${host_only} → HTTP ${http_code}"
        return 0
    fi

    if [[ "$http_code" == "000" ]] || [[ -z "$http_code" ]]; then
        msg_check "fail" "HTTPS :443" "${host_only} → Không kết nối được (timeout/blocked)"
        return 1
    fi

    msg_check "warn" "HTTPS :443" "${host_only} → HTTP ${http_code}"
    return 0
}

# ── Default gateway ───────────────────────────────────────────────────────────
get_gateway() {
    local gw
    gw=$(ip route 2>/dev/null | awk '/^default/{print $3; exit}')
    echo "${gw:-}"
}

check_gateway() {
    local gw
    gw=$(get_gateway)

    if [[ -z "$gw" ]]; then
        msg_check "fail" "Default gateway" "Không tìm thấy — kiểm tra routing"
        return 1
    fi

    if ping -c1 -W3 "$gw" &>/dev/null; then
        msg_check "pass" "Default gateway" "${gw} reachable"
        return 0
    fi

    msg_check "warn" "Default gateway" "${gw} không ping được"
    return 1
}

# ── Hop count ─────────────────────────────────────────────────────────────────
# Đếm số hop đến internet — phát hiện firewall/NAT trung gian
count_hops() {
    local target="${1:-1.1.1.1}"
    local max_hops="${2:-10}"

    if ! command -v traceroute &>/dev/null; then
        # Fallback: dùng ping TTL
        NET_HOP_COUNT="unknown"
        msg_check "skip" "Hop count" "traceroute không có"
        return 0
    fi

    local hops
    hops=$(traceroute -n -m "$max_hops" -w1 "$target" 2>/dev/null \
        | grep -v "^traceroute" \
        | grep -v "^\*" \
        | tail -1 \
        | awk '{print $1}')

    NET_HOP_COUNT="${hops:-unknown}"

    if [[ "$hops" == "unknown" ]] || [[ -z "$hops" ]]; then
        msg_check "warn" "Hop count" "Không xác định được"
        return 0
    fi

    if (( hops <= 2 )); then
        msg_check "pass" "Hop count" "${hops} hops (kết nối trực tiếp)"
    elif (( hops <= 5 )); then
        msg_check "info" "Hop count" "${hops} hops (có thiết bị trung gian)"
    else
        msg_check "warn" "Hop count" "${hops} hops (nhiều tầng NAT/firewall)"
    fi
}

# ── External IP ───────────────────────────────────────────────────────────────
get_external_ip() {
    local ip=""
    local services=(
        "https://api.ipify.org"
        "https://ifconfig.me/ip"
        "https://icanhazip.com"
    )

    for svc in "${services[@]}"; do
        ip=$(curl -fsSL --max-time 5 "$svc" 2>/dev/null | tr -d '[:space:]')
        if [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            NET_EXTERNAL_IP="$ip"
            echo "$ip"
            return 0
        fi
    done

    NET_EXTERNAL_IP="unknown"
    echo "unknown"
}

# ── VLAN detection ────────────────────────────────────────────────────────────
detect_vlan() {
    local vlans=()
    local bridges=()

    # Tìm VLAN interfaces (vmbr0.100, eth0.10, etc.)
    # grep có thể return 1 nếu không match — dùng || true để tránh set -e exit
    local vlan_lines
    vlan_lines=$(ip link show 2>/dev/null \
        | grep -E "^\S+.*\.(eth|vmbr|bond|ens)" || true)

    if [[ -n "$vlan_lines" ]]; then
        while IFS= read -r line; do
            local iface
            iface=$(echo "$line" | awk '{print $2}' | tr -d ':')
            [[ -n "$iface" ]] && vlans+=("$iface")
        done <<< "$vlan_lines"
    fi

    # Tìm bridge interfaces
    local bridge_lines
    bridge_lines=$(ip link show type bridge 2>/dev/null \
        | grep "^[0-9]" || true)

    if [[ -n "$bridge_lines" ]]; then
        while IFS= read -r line; do
            local iface
            iface=$(echo "$line" | awk '{print $2}' | tr -d ':')
            [[ -n "$iface" ]] && bridges+=("$iface")
        done <<< "$bridge_lines"
    fi

    NET_VLANS=("${vlans[@]:-}")
    NET_BRIDGES=("${bridges[@]:-}")

    if [[ ${#vlans[@]} -gt 0 ]]; then
        msg_check "info" "VLAN detected" "${vlans[*]}"
    fi

    if [[ ${#bridges[@]} -gt 0 ]]; then
        msg_check "info" "Bridges" "${bridges[*]}"
    fi

    # Trả về 0 luôn — không để set -e bắt
    return 0
}

# ── Local IP / interface ──────────────────────────────────────────────────────
get_local_ip() {
    local iface="${1:-}"
    local ip

    if [[ -n "$iface" ]]; then
        ip=$(ip -4 addr show "$iface" 2>/dev/null \
            | awk '/inet /{gsub(/\/.*/, "", $2); print $2}' | head -1)
    else
        ip=$(ip route get 1.1.1.1 2>/dev/null \
            | awk '/src/{print $NF; exit}')
    fi

    echo "${ip:-unknown}"
}
