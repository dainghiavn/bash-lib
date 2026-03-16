# bash-lib

> Bash helper library dùng chung cho các script Proxmox VE  
> **1 URL duy nhất** — import vào bất kỳ script nào trong 1 dòng

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
![Bash](https://img.shields.io/badge/Bash-4.0%2B-green)

---

## 📦 Import

```bash
source <(curl -fsSL https://raw.githubusercontent.com/dainghiavn/bash-lib/main/lib.sh)
```

**Core tự động load.** Gọi thêm nếu cần:

```bash
load_network   # Network checks: internet, DNS, UDP, NAT type
load_proxmox   # Proxmox helpers: LXC, TUN, storage, templates
```

---

## 📁 Cấu trúc

```
bash-lib/
├── lib.sh              ← Entry point duy nhất
├── core/
│   ├── ui.sh           ← msg_ok/info/error/warn, spinner, menu, header
│   ├── system.sh       ← check_root, OS detect, $STD, catch_errors
│   └── log.sh          ← log_init, log_write, rotation tự động
├── network/
│   ├── basic.sh        ← internet, DNS, HTTPS, gateway, hops, VLAN
│   └── udp_nat.sh      ← UDP port test, STUN, NAT type detection
└── proxmox/
    └── pve.sh          ← LXC create, TUN inject, storage, templates
```

---

## 🔧 Functions

### Core — UI

```bash
msg_ok    "Thông báo thành công"          # ✓ màu xanh
msg_info  "Thông báo thông tin"           # ℹ màu cyan
msg_warn  "Cảnh báo"                      # ⚠ màu vàng
msg_error "Lỗi"                           # ✗ màu đỏ
msg_check "pass|fail|warn|info" "Label" "Detail"  # preflight check line
msg_section "Tên section"                 # header phân cách
header_info "App Name" "version"         # banner đầu script

# Spinner
spinner_start "Đang xử lý..."
sleep 3
spinner_stop

# Prompts
prompt_yn    "Tiếp tục?" "Y"             # → return 0/1
prompt_input "CT ID" "200"               # → $REPLY
prompt_menu  "Chọn:" "opt1" "opt2"       # → $MENU_CHOICE

# Summary box
print_summary "Tiêu đề" "Key1" "Val1" "Key2" "Val2"
```

### Core — System

```bash
check_root                               # exit nếu không phải root
detect_os                                # set $OS_ID, $OS_VERSION, $OS_CODENAME
check_os_supported "debian" "ubuntu"    # exit nếu OS không hỗ trợ
check_deps curl wget nc                 # kiểm tra dependencies
ensure_deps curl wget nc                # tự cài nếu thiếu
check_disk_space "/var" 2048            # kiểm tra disk (MB)
check_ram 512                           # kiểm tra RAM free (MB)
is_proxmox_host                         # return 0 nếu là PVE host
is_lxc_container                        # return 0 nếu đang trong LXC
catch_errors                            # set -Eeuo pipefail + trap
version_gte "8.2" "7.0"                # so sánh version
$STD <command>                          # suppress output (VERBOSE=1 để xem)
```

### Core — Log

```bash
log_init "script-name"                  # tạo log file tại /var/log/bash-lib/
log_write "INFO" "message"              # ghi 1 dòng
log_block "title" <<< "multi-line"     # ghi block
get_log_file                            # in đường dẫn log file hiện tại
log_summary                             # ghi summary cuối session
log_elapsed                             # in thời gian đã chạy
```

### Network

```bash
load_network   # load trước khi dùng

check_internet                           # ping 1.1.1.1, 8.8.8.8
check_dns "controlplane.tailscale.com"  # DNS resolve
check_https "https://..."               # HTTP 2xx check
check_gateway                           # ping default gateway
count_hops "1.1.1.1" 10               # traceroute → $NET_HOP_COUNT
get_external_ip                         # → $NET_EXTERNAL_IP
detect_vlan                             # → $NET_VLANS[], $NET_BRIDGES[]
check_udp_port 41641 3                  # → $NET_UDP_41641 (open|blocked)
detect_nat_type 5                       # → $NET_NAT_TYPE (full_cone|symmetric|...)
check_tcp_443 "host.com"               # TCP fallback test
get_connection_mode                     # → $NET_CONN_MODE (direct|hybrid|derp_only)
```

### Proxmox

```bash
load_proxmox   # load trước khi dùng — chỉ trên PVE host

check_pve_version "7.0"                 # kiểm tra version PVE
check_pve_storage 3                     # kiểm tra disk (GB)
get_free_ctid 100                       # tìm CT ID trống từ 100
check_ctid_available 200               # → $PVE_CTID
ensure_template "debian" "12"          # download nếu chưa có → $PVE_TEMPLATE
create_lxc <ctid> <name> ...           # tạo LXC container
start_lxc <ctid> 30                    # start + chờ network
inject_tun_device <ctid>               # thêm TUN vào /etc/pve/lxc/<id>.conf
enable_ip_forward_host                 # sysctl ip_forward = 1
pct_exec_script <ctid> <url> ENV=val  # chạy script URL trong LXC
get_lxc_ip <ctid>                      # lấy IP của LXC
set_lxc_description <ctid> "App"      # ghi description
```

---

## 💡 Ví dụ sử dụng

### Script đơn giản

```bash
#!/usr/bin/env bash
BASHLIB_APP_NAME="my-script"
source <(curl -fsSL https://raw.githubusercontent.com/dainghiavn/bash-lib/main/lib.sh)

catch_errors
check_root

header_info "My App" "1.0"
msg_info "Bắt đầu..."
msg_ok "Hoàn tất!"
```

### Script với network check

```bash
#!/usr/bin/env bash
source <(curl -fsSL https://raw.githubusercontent.com/dainghiavn/bash-lib/main/lib.sh)
load_network

check_internet || { msg_error "Không có internet"; exit 1; }
check_dns "example.com"
check_udp_port 41641
detect_nat_type
msg_info "Connection mode: $(get_connection_mode)"
```

### Script Proxmox

```bash
#!/usr/bin/env bash
source <(curl -fsSL https://raw.githubusercontent.com/dainghiavn/bash-lib/main/lib.sh)
load_network
load_proxmox

check_root
check_pve_version "7.0"
check_pve_storage 2
CTID=$(get_free_ctid 100)
ensure_template "debian" "12"
create_lxc "$CTID" "my-app" "$PVE_TEMPLATE" "$PVE_STORAGE"
inject_tun_device "$CTID"
start_lxc "$CTID"
pct_exec_script "$CTID" "https://example.com/install.sh" "KEY=value"
```

---

## ⚙️ Override options

```bash
# Đặt trước khi source lib.sh
BASHLIB_APP_NAME="my-app"     # tên dùng trong log file
BASHLIB_LOG_DIR="/custom/log" # thư mục log tùy chỉnh
BASHLIB_NO_LOG=1              # tắt log file hoàn toàn
BASHLIB_VERBOSE=1             # hiện output đầy đủ thay vì suppress
BASHLIB_DEBUG=1               # hiện debug messages
```

---

## 📄 License

MIT © [dainghiavn](https://github.com/dainghiavn)
