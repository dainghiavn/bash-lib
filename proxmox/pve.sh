#!/usr/bin/env bash
# =============================================================================
# bash-lib/proxmox/pve.sh
# Proxmox-specific: LXC create, TUN inject, storage, templates, preflight
# Chỉ dùng khi chạy trên Proxmox host (pveversion available)
# =============================================================================

[[ -n "${_BASHLIB_PVE_LOADED:-}" ]] && return 0
readonly _BASHLIB_PVE_LOADED=1

# ── Proxmox version check ─────────────────────────────────────────────────────
check_pve_version() {
    local min_version="${1:-7.0}"

    if ! command -v pveversion &>/dev/null; then
        msg_check "fail" "Proxmox VE" "pveversion không tìm thấy — không phải Proxmox host?"
        return 1
    fi

    local pve_version
    pve_version=$(pveversion | grep -oP 'pve-manager/\K[0-9]+\.[0-9]+' || echo "0.0")

    if version_gte "$pve_version" "$min_version"; then
        msg_check "pass" "Proxmox VE" "v${pve_version} (yêu cầu ≥ ${min_version})"
        PVE_VERSION="$pve_version"
        return 0
    fi

    msg_check "fail" "Proxmox VE" "v${pve_version} — cần nâng cấp lên ${min_version}+"
    return 1
}

# ── Storage check ─────────────────────────────────────────────────────────────
get_pve_storage() {
    # Lấy storage available đầu tiên có type local/dir/zfs
    pvesm status 2>/dev/null \
        | awk 'NR>1 && $2 ~ /^(dir|zfspool|lvmthin|btrfs)$/ && $5 > 0 {
            print $1; exit
          }' \
        || echo "local"
}

check_pve_storage() {
    local required_gb="${1:-3}"
    local storage
    storage=$(get_pve_storage)

    local avail_kb
    avail_kb=$(pvesm status 2>/dev/null \
        | awk -v s="$storage" '$1==s {print $6}' || echo "0")

    local avail_gb=$(( avail_kb / 1024 / 1024 ))

    PVE_STORAGE="$storage"
    PVE_STORAGE_FREE_GB="$avail_gb"

    if (( avail_gb < required_gb )); then
        msg_check "fail" "Storage (${storage})" \
            "${avail_gb}GB free — cần ${required_gb}GB"
        return 1
    fi

    msg_check "pass" "Storage (${storage})" "${avail_gb}GB free"
    return 0
}

# ── Free CT ID ────────────────────────────────────────────────────────────────
get_free_ctid() {
    local start="${1:-100}"
    local id="$start"

    # Lấy danh sách IDs đang dùng
    local used_ids
    used_ids=$(pvesh get /cluster/resources --type vm 2>/dev/null \
        | grep -oP '"vmid":\K[0-9]+' || pct list 2>/dev/null | awk 'NR>1{print $1}')

    while echo "$used_ids" | grep -q "^${id}$"; do
        (( id++ ))
    done

    echo "$id"
}

check_ctid_available() {
    local ctid="${1:-}"

    if [[ -z "$ctid" ]]; then
        local suggested
        suggested=$(get_free_ctid)
        msg_check "info" "CT ID" "Gợi ý: ${suggested}"
        PVE_CTID="$suggested"
        return 0
    fi

    if pct status "$ctid" &>/dev/null; then
        local name
        name=$(pct config "$ctid" 2>/dev/null | awk -F: '/^hostname/{print $2}' | tr -d ' ')
        msg_check "warn" "CT ID ${ctid}" "Đang dùng bởi: ${name:-unknown}"
        PVE_CTID=$(get_free_ctid "$((ctid+1))")
        msg_plain "Dùng CT ID thay thế: ${PVE_CTID}"
        return 1
    fi

    msg_check "pass" "CT ID ${ctid}" "Available"
    PVE_CTID="$ctid"
    return 0
}

# ── Template management ───────────────────────────────────────────────────────
get_template_list() {
    local storage="${1:-$(get_pve_storage)}"
    pvesm list "$storage" 2>/dev/null \
        | awk '/vztmpl/{print $1}' \
        | sort
}

find_template() {
    local os="${1:-debian}"
    local version="${2:-12}"
    local storage="${PVE_STORAGE:-$(get_pve_storage)}"

    get_template_list "$storage" \
        | grep -i "${os}" \
        | grep "${version}" \
        | tail -1
}

ensure_template() {
    local os="${1:-debian}"
    local version="${2:-12}"

    local template
    template=$(find_template "$os" "$version")

    if [[ -n "$template" ]]; then
        msg_check "pass" "Template" "${template##*/}"
        PVE_TEMPLATE="$template"
        return 0
    fi

    # Template chưa có — download
    msg_info "Template ${os}-${version} chưa có, đang tải..."

    $STD pveam update
    local available
    available=$(pveam available --section system 2>/dev/null \
        | grep -i "${os}" | grep "${version}" | tail -1 | awk '{print $2}')

    if [[ -z "$available" ]]; then
        msg_check "fail" "Template" "${os}-${version} không tìm thấy trong pveam"
        return 1
    fi

    $STD pveam download "${PVE_STORAGE:-local}" "$available"
    template=$(find_template "$os" "$version")

    if [[ -n "$template" ]]; then
        msg_check "pass" "Template" "Downloaded: ${template##*/}"
        PVE_TEMPLATE="$template"
        return 0
    fi

    msg_check "fail" "Template" "Download thất bại"
    return 1
}

# ── TUN device inject ─────────────────────────────────────────────────────────
# Thêm TUN device vào LXC config — bắt buộc cho Tailscale
inject_tun_device() {
    local ctid="${1:-$PVE_CTID}"
    local conf_file="/etc/pve/lxc/${ctid}.conf"

    if [[ ! -f "$conf_file" ]]; then
        msg_error "Không tìm thấy config file: ${conf_file}"
        return 1
    fi

    # Kiểm tra đã có TUN chưa
    if grep -q "lxc.cgroup2.devices.allow.*10:200" "$conf_file" 2>/dev/null; then
        msg_check "pass" "TUN device" "Đã được config (CT ${ctid})"
        return 0
    fi

    msg_info "Inject TUN device vào CT ${ctid}"

    cat >> "$conf_file" <<EOF

# Tailscale TUN device — added by bash-lib
lxc.cgroup2.devices.allow: c 10:200 rwm
lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file
EOF

    # Verify
    if grep -q "lxc.cgroup2.devices.allow.*10:200" "$conf_file"; then
        msg_check "pass" "TUN device" "Injected vào ${conf_file}"
        return 0
    fi

    msg_check "fail" "TUN device" "Inject thất bại"
    return 1
}

# ── ip_forward ────────────────────────────────────────────────────────────────
# Enable ip_forward trên host (cần cho Subnet Router / Exit Node)
enable_ip_forward_host() {
    local conf="/etc/sysctl.d/99-tailscale.conf"

    cat > "$conf" <<EOF
# Tailscale ip_forward — added by bash-lib
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF

    sysctl -p "$conf" &>/dev/null
    msg_check "pass" "ip_forward" "Enabled trên host"
}

# ── LXC creation ─────────────────────────────────────────────────────────────
# Tạo LXC mới với các thông số đã chọn
create_lxc() {
    local ctid="${1:-$PVE_CTID}"
    local hostname="${2:-tailscale}"
    local template="${3:-$PVE_TEMPLATE}"
    local storage="${4:-$PVE_STORAGE}"
    local ram="${5:-128}"
    local cpu="${6:-1}"
    local disk="${7:-2}"
    local bridge="${8:-vmbr0}"
    local unprivileged="${9:-1}"

    msg_info "Tạo LXC CT${ctid}: ${hostname}"

    $STD pct create "$ctid" "$template" \
        --hostname "$hostname" \
        --memory "$ram" \
        --cores "$cpu" \
        --rootfs "${storage}:${disk}" \
        --net0 "name=eth0,bridge=${bridge},ip=dhcp" \
        --unprivileged "$unprivileged" \
        --features "nesting=1" \
        --ostype debian \
        --start 0

    msg_ok "CT${ctid} created: ${hostname}"
}

# Start LXC và chờ network ready
start_lxc() {
    local ctid="${1:-$PVE_CTID}"
    local max_wait="${2:-30}"

    msg_info "Khởi động CT${ctid}..."
    pct start "$ctid"

    local elapsed=0
    while (( elapsed < max_wait )); do
        if pct exec "$ctid" -- ip route &>/dev/null; then
            msg_ok "CT${ctid} started — network ready"
            return 0
        fi
        sleep 2
        (( elapsed += 2 ))
    done

    msg_warn "CT${ctid} started nhưng network chưa sẵn sàng sau ${max_wait}s"
    return 1
}

# ── Execute script inside LXC ─────────────────────────────────────────────────
pct_exec_script() {
    local ctid="${1:-$PVE_CTID}"
    local script_url="$2"
    shift 2
    local env_vars=("$@")  # KEY=VALUE pairs để truyền vào LXC

    msg_info "Chạy install script trong CT${ctid}"

    # Build env string
    local env_cmd=""
    for var in "${env_vars[@]}"; do
        env_cmd+="export ${var}; "
    done

    # Download và chạy script trong LXC
    pct exec "$ctid" -- bash -c \
        "${env_cmd} bash <(curl -fsSL '${script_url}')"
}

# ── Write description ─────────────────────────────────────────────────────────
set_lxc_description() {
    local ctid="${1:-$PVE_CTID}"
    local app="${2:-App}"
    local extra="${3:-}"

    pct set "$ctid" --description \
"# ${app}
Installed by bash-lib installer
Date: $(date '+%Y-%m-%d %H:%M')
${extra}"
}

# ── Get LXC IP ────────────────────────────────────────────────────────────────
get_lxc_ip() {
    local ctid="${1:-$PVE_CTID}"
    local timeout="${2:-30}"
    local elapsed=0
    local ip=""

    while (( elapsed < timeout )); do
        ip=$(pct exec "$ctid" -- \
            ip -4 addr show eth0 2>/dev/null \
            | awk '/inet /{gsub(/\/.*/, "", $2); print $2}' \
            | head -1)

        if [[ -n "$ip" ]]; then
            echo "$ip"
            return 0
        fi
        sleep 2
        (( elapsed += 2 ))
    done

    echo ""
    return 1
}
