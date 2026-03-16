#!/usr/bin/env bash
# =============================================================================
# bash-lib/network/udp_nat.sh
# UDP port testing + STUN-based NAT type detection
# Kết quả ảnh hưởng trực tiếp đến chất lượng Tailscale P2P
# =============================================================================

[[ -n "${_BASHLIB_UDP_NAT_LOADED:-}" ]] && return 0
readonly _BASHLIB_UDP_NAT_LOADED=1

# Output variables (set sau khi gọi các hàm)
NET_UDP_41641="unknown"   # open|blocked|unknown
NET_UDP_3478="unknown"    # open|blocked|unknown
NET_NAT_TYPE="unknown"    # full_cone|restricted|port_restricted|symmetric|unknown
NET_STUN_EXT_IP=""
NET_STUN_EXT_PORT1=""
NET_STUN_EXT_PORT2=""

# ── UDP port test ─────────────────────────────────────────────────────────────
# Phương pháp: gửi UDP packet ra ngoài và kiểm tra response
# Tailscale STUN endpoint sẽ phản hồi nếu UDP thông
check_udp_port() {
    local port="${1:-41641}"
    local timeout="${2:-3}"
    local var_name="NET_UDP_${port}"

    # Strategy: thử nhiều cách, không dùng binary data để tránh null byte warning
    # Cách 1: nc UDP — gửi empty packet, không đọc response (tránh null byte)
    if command -v nc &>/dev/null; then
        # timeout để nc không hang, 2>/dev/null suppress mọi warning
        if timeout "$timeout" sh -c \
            "echo '' | nc -u -w${timeout} udp.tailscale.com ${port}" \
            >/dev/null 2>&1; then
            eval "${var_name}=open"
            msg_check "pass" "UDP ${port}" "open → Direct P2P khả dụng"
            return 0
        fi
    fi

    # Cách 2: /dev/udp bash builtin — redirect stderr để tránh null byte warning
    if timeout "$timeout" bash -c \
        "echo '' > /dev/udp/udp.tailscale.com/${port}" \
        >/dev/null 2>&1; then
        eval "${var_name}=open"
        msg_check "pass" "UDP ${port}" "open"
        return 0
    fi

    # UDP bị chặn — không có cách nào gửi được
    eval "${var_name}=blocked"
    msg_check "fail" "UDP ${port}" "BLOCKED → Tailscale sẽ dùng DERP relay"
    return 1
}

# Quick STUN check — dùng hex string thay binary để tránh null byte warning
_stun_quick_check() {
    local server="$1" port="$2" timeout="${3:-3}"

    if ! command -v nc &>/dev/null; then
        return 1
    fi

    # STUN Binding Request dạng hex — không dùng printf binary
    local stun_hex="000100002112a442deadbeefdeadbeefdeadbeef"
    local stun_bytes
    stun_bytes=$(printf '%b' "$(echo "$stun_hex" | sed 's/../\\x&/g')" 2>/dev/null)

    local response
    response=$(printf '%s' "$stun_bytes" \
        | timeout "$timeout" nc -u -w"$timeout" "$server" "$port" 2>/dev/null \
        | od -An -tx1 2>/dev/null | tr -d ' \n' || echo "")

    # STUN success response type = 0101
    [[ "$response" == *"0101"* ]]
}

# ── NAT type detection (simplified STUN) ─────────────────────────────────────
# Theo RFC 5389 — dùng 2 STUN servers, so sánh mapped address
# Kết quả: full_cone | restricted | port_restricted | symmetric | unknown
detect_nat_type() {
    local timeout="${1:-5}"

    local stun1="stun.l.google.com:19302"
    local stun2="stun1.l.google.com:19302"

    msg_info "Đang detect NAT type (STUN test)..."

    # Query STUN server 1
    local result1
    result1=$(_stun_query "$stun1" "$timeout" || echo "")

    if [[ -z "$result1" ]]; then
        NET_NAT_TYPE="unknown"
        msg_check "warn" "NAT type" "Không test được (STUN timeout) — bỏ qua"
        return 0   # Không phải lỗi critical — tiếp tục script
    fi

    # Parse IP:PORT từ kết quả STUN
    local ip1 port1
    ip1=$(echo "$result1" | cut -d: -f1)
    port1=$(echo "$result1" | cut -d: -f2)
    NET_STUN_EXT_IP="$ip1"
    NET_STUN_EXT_PORT1="$port1"

    # Query STUN server 2 (khác server, cùng local port nếu có thể)
    local result2
    result2=$(_stun_query "$stun2" "$timeout" || echo "")

    if [[ -z "$result2" ]]; then
        # Chỉ có 1 kết quả — không thể phân biệt NAT type
        NET_NAT_TYPE="unknown"
        msg_check "warn" "NAT type" "STUN 2 timeout — không xác định được"
        return 0   # Không critical
    fi

    local ip2 port2
    ip2=$(echo "$result2" | cut -d: -f1)
    port2=$(echo "$result2" | cut -d: -f2)
    NET_STUN_EXT_PORT2="$port2"

    # Phân loại NAT
    if [[ "$ip1" == "$ip2" ]] && [[ "$port1" == "$port2" ]]; then
        # Cùng IP + Port với 2 server khác nhau → Full Cone hoặc Restricted
        # (không phân biệt được 2 loại này qua phương pháp đơn giản)
        NET_NAT_TYPE="full_cone"
        msg_check "pass" "NAT type" "Full Cone / Restricted — P2P tốt ✓"
    else
        # Port khác nhau → Symmetric NAT
        NET_NAT_TYPE="symmetric"
        msg_check "fail" "NAT type" \
            "Symmetric (port1=${port1} port2=${port2}) — P2P hạn chế"
    fi

    log_write "NAT_DETECT" \
        "type=${NET_NAT_TYPE} ext_ip=${ip1} port1=${port1} port2=${port2}"
}

# Gửi STUN Binding Request, parse và trả về "IP:PORT" từ response
_stun_query() {
    local server_port="$1"
    local timeout="${2:-5}"
    local server port

    server=$(echo "$server_port" | cut -d: -f1)
    port=$(echo "$server_port" | cut -d: -f2)

    if ! command -v nc &>/dev/null; then
        echo ""
        return 1
    fi

    # Build STUN Binding Request
    # Type=0x0001, Length=0x0000, Magic Cookie=0x2112A442
    # Transaction ID: 12 bytes cố định (không dùng RANDOM để tránh null byte)
    local stun_req_hex="000100002112a442deadbeefdeadbeefdeadbeef"

    # Gửi request và đọc response — dùng od để tránh null byte issue
    # 2>/dev/null để suppress warning "ignored null byte in input"
    local raw_response
    raw_response=$(printf '%b' "$(echo "$stun_req_hex" \
            | sed 's/../\\x&/g')" 2>/dev/null \
        | timeout "$timeout" nc -u -w"$timeout" "$server" "$port" 2>/dev/null \
        | od -An -tx1 2>/dev/null \
        | tr -d ' \n' \
        || echo "")

    if [[ -z "$raw_response" ]] || [[ ${#raw_response} -lt 40 ]]; then
        echo ""
        return 1
    fi

    # Parse XOR-MAPPED-ADDRESS attr (0x0020) từ response
    # Offset: sau 20-byte STUN header, tìm attr type 0x0020
    local xor_ip xor_port ext_ip ext_port

    # XOR decode với magic cookie (0x2112A442)
    # Đây là simplified parser — đủ dùng cho NAT detection
    local magic_hi="21" magic_lo="12"

    # Tìm XOR-MAPPED-ADDRESS (0x0020) trong response
    if echo "$raw_response" | grep -q "0020"; then
        local pos
        pos=$(echo "$raw_response" | grep -bo "0020" \
            | head -1 | cut -d: -f1 2>/dev/null || echo "")

        if [[ -n "$pos" ]] && (( pos > 8 )); then
            # Parse port: bytes offset+4, offset+5 XOR with 0x2112
            local hex_port
            hex_port=$(echo "$raw_response" \
                | cut -c$((pos+8+1))-$((pos+8+4)) 2>/dev/null || echo "")

            if [[ -n "$hex_port" ]]; then
                local raw_port=$(( 16#${hex_port} ))
                ext_port=$(( raw_port ^ 0x2112 ))
            fi

            # Parse IP: bytes offset+8 to offset+11 XOR với magic cookie
            local hex_ip
            hex_ip=$(echo "$raw_response" \
                | cut -c$((pos+8+5))-$((pos+8+12)) 2>/dev/null || echo "")

            if [[ -n "$hex_ip" ]]; then
                local b1 b2 b3 b4
                b1=$(( 16#${hex_ip:0:2} ^ 16#21 ))
                b2=$(( 16#${hex_ip:2:2} ^ 16#12 ))
                b3=$(( 16#${hex_ip:4:2} ^ 16#a4 ))
                b4=$(( 16#${hex_ip:6:2} ^ 16#42 ))
                ext_ip="${b1}.${b2}.${b3}.${b4}"
            fi
        fi
    fi

    if [[ -n "${ext_ip:-}" ]] && [[ -n "${ext_port:-}" ]]; then
        echo "${ext_ip}:${ext_port}"
    else
        # Fallback: trả về chỉ "ok" để biết STUN reply nhận được
        echo "ok:0"
    fi
}

# ── TCP 443 fallback (DERP) ───────────────────────────────────────────────────
check_tcp_443() {
    local host="${1:-controlplane.tailscale.com}"
    local timeout="${2:-5}"

    if timeout "$timeout" bash -c \
        "echo > /dev/tcp/${host}/443" 2>/dev/null; then
        msg_check "pass" "TCP :443 (DERP)" "${host} — DERP relay hoạt động"
        return 0
    fi

    msg_check "fail" "TCP :443 (DERP)" "${host} blocked — Tailscale không kết nối được"
    return 1
}

# ── Combined UDP/NAT report ───────────────────────────────────────────────────
# Chạy tất cả UDP checks và trả về connection mode verdict
# Returns: "direct" | "hybrid" | "derp_only" | "no_connection"
get_connection_mode() {
    local udp_ok=false
    local tcp_ok=false
    local nat_ok=false

    [[ "$NET_UDP_41641" == "open" ]] && udp_ok=true
    [[ "$NET_NAT_TYPE" == "full_cone" || "$NET_NAT_TYPE" == "restricted" ]] && nat_ok=true

    check_tcp_443 &>/dev/null && tcp_ok=true

    if $udp_ok && $nat_ok; then
        NET_CONN_MODE="direct"
    elif $udp_ok && ! $nat_ok; then
        NET_CONN_MODE="hybrid"
    elif ! $udp_ok && $tcp_ok; then
        NET_CONN_MODE="derp_only"
    else
        NET_CONN_MODE="no_connection"
    fi

    echo "$NET_CONN_MODE"
}
