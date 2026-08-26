#!/bin/bash
# from
# https://github.com/oneclickvirt/docker
# 2026.08.27

_red() { echo -e "\033[31m\033[01m$*\033[0m"; }
_green() { echo -e "\033[32m\033[01m$*\033[0m"; }
_yellow() { echo -e "\033[33m\033[01m$*\033[0m"; }
_blue() { echo -e "\033[36m\033[01m$*\033[0m"; }
is_noninteractive() {
    case "${noninteractive:-}" in
        [Tt][Rr][Uu][Ee]|1|[Yy]|[Yy][Ee][Ss]) return 0 ;;
    esac
    return 1
}
reading() {
    local prompt="$1"
    local var_name="$2"
    local default_value="${3:-}"
    if is_noninteractive; then
        printf -v "$var_name" '%s' "$default_value"
        _yellow "noninteractive=true detected, using default for ${var_name}: ${default_value:-<empty>}"
    else
        read -rp "$(_green "$prompt")" "$var_name"
    fi
}
export DEBIAN_FRONTEND=noninteractive
utf8_locale=$(locale -a 2>/dev/null | grep -i -m 1 -E "UTF-8|utf8")
if [[ -z "$utf8_locale" ]]; then
    echo "No UTF-8 locale found"
else
    export LC_ALL="$utf8_locale"
    export LANG="$utf8_locale"
    export LANGUAGE="$utf8_locale"
    echo "Locale set to $utf8_locale"
fi
if [ "$(id -u)" != "0" ]; then
    _red "This script must be run as root" 1>&2
    exit 1
fi
if [ ! -d /usr/local/bin ]; then
    mkdir -p /usr/local/bin
fi

without_cdn="false"
if [[ "${WITHOUTCDN^^}" == "TRUE" ]]; then
    without_cdn="true"
fi
# 支持的环境变量（一键非交互安装）：
#   noninteractive=true     - 使用默认值跳过所有交互提示
#   WITHOUTCDN=true          - 禁用 CDN 加速
#   CN=true                  - 强制使用中国镜像源
#   CN=false                 - 强制不使用中国镜像源（跳过检测）
#   NEED_DISK_LIMIT=y/n      - 是否启用容器磁盘大小限制（btrfs）
#   DOCKER_INSTALL_PATH=...  - Docker 数据目录（默认 /var/lib/docker）
#   DOCKER_POOL_SIZE=20      - Docker 存储池大小（单位 GB，需 NEED_DISK_LIMIT=y）
#   DOCKER_LOOP_FILE=...     - Docker loop 文件路径（默认 /opt/docker-pool.img）

temp_file_apt_fix="/tmp/apt_fix.txt"
REGEX=("debian" "ubuntu" "centos|red hat|kernel|oracle linux|alma|rocky" "'amazon linux'" "fedora" "arch" "alpine")
RELEASE=("Debian" "Ubuntu" "CentOS" "CentOS" "Fedora" "Arch" "Alpine")
PACKAGE_UPDATE=("! apt-get update && apt-get --fix-broken install -y && apt-get update" "apt-get update" "yum -y update" "yum -y update" "yum -y update" "pacman -Sy" "apk update")
PACKAGE_INSTALL=("apt-get -y install" "apt-get -y install" "yum -y install" "yum -y install" "yum -y install" "pacman -Sy --noconfirm --needed" "apk add --no-cache")
PACKAGE_REMOVE=("apt-get -y remove" "apt-get -y remove" "yum -y remove" "yum -y remove" "yum -y remove" "pacman -Rsc --noconfirm" "apk del")
PACKAGE_UNINSTALL=("apt-get -y autoremove" "apt-get -y autoremove" "yum -y autoremove" "yum -y autoremove" "yum -y autoremove" "" "")
CMD=("$(grep -i pretty_name /etc/os-release 2>/dev/null | cut -d \" -f2)" "$(hostnamectl 2>/dev/null | grep -i system | cut -d : -f2)" "$(lsb_release -sd 2>/dev/null)" "$(grep -i description /etc/lsb-release 2>/dev/null | cut -d \" -f2)" "$(grep . /etc/redhat-release 2>/dev/null)" "$(grep . /etc/issue 2>/dev/null | cut -d \\ -f1 | sed '/^[ ]*$/d')" "$(grep -i pretty_name /etc/os-release 2>/dev/null | cut -d \" -f2)")
SYS="${CMD[0]}"
[[ -n $SYS ]] || exit 1
for ((int = 0; int < ${#REGEX[@]}; int++)); do
    if [[ $(echo "$SYS" | tr '[:upper:]' '[:lower:]') =~ ${REGEX[int]} ]]; then
        SYSTEM="${RELEASE[int]}"
        [[ -n $SYSTEM ]] && break
    fi
done
detect_virtualization() {
    VIRT_TYPE=""
    if [ -f "/proc/1/environ" ]; then
        if grep -q "container=lxc" /proc/1/environ 2>/dev/null; then
            VIRT_TYPE="lxc"
        elif grep -q "container=docker" /proc/1/environ 2>/dev/null; then
            VIRT_TYPE="docker"
        fi
    fi
    if [ -z "$VIRT_TYPE" ]; then
        if [ -f "/.dockerenv" ]; then
            VIRT_TYPE="docker"
        elif [ -d "/var/lib/lxc" ] && [ -f "/proc/self/cgroup" ] && grep -q "lxc" /proc/self/cgroup 2>/dev/null; then
            VIRT_TYPE="lxc"
        fi
    fi
    echo "$VIRT_TYPE" > /usr/local/bin/docker_virt_type
}

check_storage_driver_support() {
    local driver="$1"
    case "$driver" in
        "btrfs")
            if command -v btrfs >/dev/null 2>&1; then
                return 0
            fi
            return 1
            ;;
        *)
            return 1
            ;;
    esac
}

install_storage_driver() {
    local driver="$1"
    local need_reboot=false
    case "$driver" in
        "btrfs")
            if ! command -v btrfs >/dev/null 2>&1; then
                _yellow "Installing btrfs-progs..."
                ${PACKAGE_INSTALL[int]} btrfs-progs
                modprobe btrfs || true
                if ! check_storage_driver_support "btrfs"; then
                    _yellow "btrfs module could not be loaded. Need reboot."
                    need_reboot=true
                fi
            fi
            ;;
    esac
    if [ "$need_reboot" = true ]; then
        echo "$driver" > /usr/local/bin/docker_storage_reboot
        _green "Storage driver $driver installed. System will reboot in 5 seconds to load kernel modules."
        sleep 5
        reboot
        exit 0
    fi
}

setup_docker_btrfs_loop() {
    local pool_size_gb="$1"
    local loop_file="$2"
    local mount_point="$3"
    _yellow "Setting up Docker btrfs loop filesystem..."
    local loop_dir=$(dirname "$loop_file")
    if [ ! -d "$loop_dir" ]; then
        mkdir -p "$loop_dir"
    fi
    if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet docker; then
        systemctl stop docker
    elif command -v rc-service >/dev/null 2>&1 && rc-service docker status >/dev/null 2>&1; then
        rc-service docker stop
    fi
    # 若 loop 文件已存在且已挂载，则跳过格式化以避免损坏已有数据
    if [ -f "$loop_file" ] && losetup -j "$loop_file" 2>/dev/null | grep -q "$loop_file"; then
        _green "Loop file $loop_file already exists and is attached, skipping creation."
        loop_device=$(losetup -j "$loop_file" | cut -d: -f1)
        mkdir -p "$mount_point"
        mount "$loop_device" "$mount_point" 2>/dev/null || true
        echo "$loop_device" > /usr/local/bin/docker_loop_device
        echo "$loop_file" > /usr/local/bin/docker_loop_file
        echo "$mount_point" > /usr/local/bin/docker_mount_point
        return
    fi
    if [ -d "$mount_point" ] && [ "$(ls -A "$mount_point" 2>/dev/null)" ]; then
        _yellow "Backing up existing Docker data..."
        mv "$mount_point" "${mount_point}.backup.$(date +%Y%m%d-%H%M%S)"
    fi
    _yellow "Creating ${pool_size_gb}GB loop file at $loop_file..."
    fallocate -l "${pool_size_gb}G" "$loop_file"
    loop_device=$(losetup --find --show "$loop_file")
    _green "Loop device created: $loop_device"
    _yellow "Creating btrfs filesystem on $loop_device..."
    mkfs.btrfs -f "$loop_device"
    mkdir -p "$mount_point"
    mount "$loop_device" "$mount_point"
    if ! grep -q "$loop_file" /etc/fstab; then
        echo "$loop_file $mount_point btrfs loop,defaults 0 0" >> /etc/fstab
    fi
    chmod 755 "$mount_point"
    _green "Docker btrfs loop filesystem setup completed"
    echo "$loop_device" > /usr/local/bin/docker_loop_device
    echo "$loop_file" > /usr/local/bin/docker_loop_file
    echo "$mount_point" > /usr/local/bin/docker_mount_point
}

try_storage_drivers() {
    local virt_type=$(cat /usr/local/bin/docker_virt_type 2>/dev/null || echo "")
    need_disk_limit="false"
    if [ -f /usr/local/bin/docker_need_disk_limit ]; then
        need_disk_limit=$(cat /usr/local/bin/docker_need_disk_limit)
    fi
    if [ "$need_disk_limit" != "true" ]; then
        _yellow "Using overlay2 storage driver for standard installation."
        _yellow "标准安装使用overlay2存储驱动。"
        echo "overlay2" > /usr/local/bin/docker_storage_driver
        return 0
    fi
    if [[ "$virt_type" == "lxc" || "$virt_type" == "docker" ]]; then
        _yellow "Detected virtualization: $virt_type. Using overlay2 storage driver."
        echo "overlay2" > /usr/local/bin/docker_storage_driver
        return 0
    fi
    if [ -f /usr/local/bin/docker_storage_reboot ]; then
        local reboot_driver=$(cat /usr/local/bin/docker_storage_reboot)
        rm -f /usr/local/bin/docker_storage_reboot
        _green "System rebooted. Checking storage driver: $reboot_driver"
        if check_storage_driver_support "$reboot_driver"; then
            echo "$reboot_driver" > /usr/local/bin/docker_storage_driver
            return 0
        else
            _yellow "Storage driver $reboot_driver still not available after reboot. Falling back to overlay2."
            echo "overlay2" > /usr/local/bin/docker_storage_driver
            return 0
        fi
    fi
    if [ -f /usr/local/bin/docker_storage_driver ]; then
        _green "Docker storage driver already configured: $(cat /usr/local/bin/docker_storage_driver)"
        return 0
    fi
    if check_storage_driver_support "btrfs"; then
        _green "btrfs is available, using btrfs storage driver."
        echo "btrfs" > /usr/local/bin/docker_storage_driver
        return 0
    else
        _yellow "Trying to install storage driver: btrfs"
        install_storage_driver "btrfs"
        if check_storage_driver_support "btrfs"; then
            echo "btrfs" > /usr/local/bin/docker_storage_driver
            return 0
        else
            _yellow "btrfs installation failed. Falling back to overlay2."
            echo "overlay2" > /usr/local/bin/docker_storage_driver
            return 0
        fi
    fi
}

statistics_of_run_times() {
    COUNT=$(curl -4 -ksm1 "https://hits.spiritlhl.net/docker?action=hit&title=Hits&title_bg=%23555555&count_bg=%2324dde1&edge_flat=false" 2>/dev/null ||
        curl -6 -ksm1 "https://hits.spiritlhl.net/docker?action=hit&title=Hits&title_bg=%23555555&count_bg=%2324dde1&edge_flat=false" 2>/dev/null)
    # 检测 grep 是否支持 -P 选项
    if echo "test" | grep -P "test" >/dev/null 2>&1; then
        TODAY=$(echo "$COUNT" | grep -oP '"daily":\s*[0-9]+' | sed 's/"daily":\s*\([0-9]*\)/\1/')
        TOTAL=$(echo "$COUNT" | grep -oP '"total":\s*[0-9]+' | sed 's/"total":\s*\([0-9]*\)/\1/')
    else
        # BusyBox 兼容方法
        TODAY=$(echo "$COUNT" | sed -n 's/.*"daily":[[:space:]]*\([0-9]*\).*/\1/p')
        TOTAL=$(echo "$COUNT" | sed -n 's/.*"total":[[:space:]]*\([0-9]*\).*/\1/p')
    fi
}

check_update() {
    _yellow "Updating package management sources"
    if command -v apt-get >/dev/null 2>&1; then
        apt_update_output=$(apt-get update 2>&1)
        echo "$apt_update_output" >"$temp_file_apt_fix"
        if grep -q 'NO_PUBKEY' "$temp_file_apt_fix"; then
            public_keys=$(grep -oE 'NO_PUBKEY [0-9A-F]+' "$temp_file_apt_fix" | awk '{ print $2 }')
            joined_keys=$(echo "$public_keys" | paste -sd " ")
            _yellow "No Public Keys: ${joined_keys}"
            apt-key adv --keyserver keyserver.ubuntu.com --recv-keys ${joined_keys}
            apt-get update
            if [ $? -eq 0 ]; then
                _green "Fixed"
            fi
        fi
        rm "$temp_file_apt_fix"
    elif command -v apk >/dev/null 2>&1; then
        apk update
    else
        ${PACKAGE_UPDATE[int]}
    fi
}

check_interface() {
    if [ -z "$interface_2" ]; then
        interface=${interface_1}
        return
    elif [ -n "$interface_1" ] && [ -n "$interface_2" ]; then
        if ! grep -q "$interface_1" "/etc/network/interfaces" && ! grep -q "$interface_2" "/etc/network/interfaces" && [ -f "/etc/network/interfaces.d/50-cloud-init" ]; then
            if grep -q "$interface_1" "/etc/network/interfaces.d/50-cloud-init" || grep -q "$interface_2" "/etc/network/interfaces.d/50-cloud-init"; then
                if ! grep -q "$interface_1" "/etc/network/interfaces.d/50-cloud-init" && grep -q "$interface_2" "/etc/network/interfaces.d/50-cloud-init"; then
                    interface=${interface_2}
                    return
                elif ! grep -q "$interface_2" "/etc/network/interfaces.d/50-cloud-init" && grep -q "$interface_1" "/etc/network/interfaces.d/50-cloud-init"; then
                    interface=${interface_1}
                    return
                fi
            fi
        fi
        if grep -q "$interface_1" "/etc/network/interfaces"; then
            interface=${interface_1}
            return
        elif grep -q "$interface_2" "/etc/network/interfaces"; then
            interface=${interface_2}
            return
        else
            interfaces_list=$(ip addr show | awk '/^[0-9]+: [^lo]/ {print $2}' | cut -d ':' -f 1)
            interface=""
            for iface in $interfaces_list; do
                if [[ "$iface" = "$interface_1" || "$iface" = "$interface_2" ]]; then
                    interface="$iface"
                fi
            done
            if [ -z "$interface" ]; then
                interface="eth0"
            fi
            return
        fi
    else
        interface="eth0"
        return
    fi
    _red "Physical interface not found, exit execution"
    _red "找不到物理接口，退出执行"
    exit 1
}

is_private_ipv6() {
    ! is_public_ipv6 "${1:-}"
}

is_public_ipv6() {
    local address="${1:-}"
    command -v python3 >/dev/null 2>&1 || return 1
    python3 - "$address" <<'PY'
import ipaddress
import sys

try:
    address = ipaddress.IPv6Address(sys.argv[1])
except ValueError:
    raise SystemExit(1)

global_unicast = ipaddress.IPv6Network("2000::/3")
non_public = (
    ipaddress.IPv6Network("2001::/32"),       # Teredo
    ipaddress.IPv6Network("2001:2::/48"),     # benchmarking
    ipaddress.IPv6Network("2001:10::/28"),    # ORCHID
    ipaddress.IPv6Network("2001:20::/28"),    # ORCHIDv2
    ipaddress.IPv6Network("2001:db8::/32"),   # documentation
    ipaddress.IPv6Network("2002::/16"),       # 6to4
    ipaddress.IPv6Network("3fff::/20"),       # documentation
)
usable = (
    address in global_unicast
    and address.is_global
    and not address.is_private
    and not address.is_multicast
    and not any(address in prefix for prefix in non_public)
)
raise SystemExit(0 if usable else 1)
PY
}

# A host can hold a /128 on its primary uplink and a delegated prefix on a
# bridge or tunnel at the same time. Prefer the widest locally bound public
# CIDR so the later bridge allocation has the largest safe parent to inspect.
# Keep a lone /128 as a fallback: it still proves IPv6 connectivity even
# though it cannot provide independently routed container addresses.
select_public_ipv6_cidr() {
    local candidate address prefix prefix_number best_cidr="" best_prefix=129
    while IFS= read -r candidate; do
        [[ -n "$candidate" ]] || continue
        address="${candidate%/*}"
        prefix="${candidate##*/}"
        [[ "$prefix" =~ ^[0-9]+$ ]] || continue
        prefix_number=$((10#$prefix))
        (( prefix_number <= 128 )) || continue
        if is_public_ipv6 "$address" && (( prefix_number < best_prefix )); then
            best_cidr="$candidate"
            best_prefix=$prefix_number
        fi
    done < <(ip -6 -o addr show scope global 2>/dev/null | awk '$0 !~ / tentative/ {print $4}')
    [[ -n "$best_cidr" ]] || return 1
    printf '%s\n' "$best_cidr"
}

ipv6_cidr_prefix_length() {
    local cidr="${1:-}" prefix
    [[ "$cidr" == */* ]] || return 1
    prefix="${cidr##*/}"
    [[ "$prefix" =~ ^[0-9]+$ ]] || return 1
    (( 10#$prefix <= 128 )) || return 1
    printf '%s\n' "$prefix"
}

docker_ipv6_subnet_has_live_address() {
    local subnet="$1"
    command -v python3 >/dev/null 2>&1 || return 2
    ip -6 -o addr show 2>/dev/null | awk '$0 !~ / tentative/ {print $4}' | \
        python3 -c '
import ipaddress
import sys

network = ipaddress.IPv6Network(sys.argv[1], strict=False)
for raw in sys.stdin:
    try:
        address = ipaddress.IPv6Interface(raw.strip()).ip
    except ValueError:
        continue
    if address.version == 6 and address in network:
        raise SystemExit(0)
raise SystemExit(1)
' "$subnet"
}

# A child of the uplink's on-link prefix is not a safe Docker bridge subnet.
# Docker may reject it even when the exact child contains no host address, so
# include connected IPv6 routes as well as addresses in the overlap check.
docker_ipv6_subnet_overlaps_host() {
    local subnet="$1"
    command -v python3 >/dev/null 2>&1 || return 2
    {
        ip -6 -o addr show 2>/dev/null | awk '$0 !~ / tentative/ {print $4}'
        ip -6 route show table all 2>/dev/null | awk '$1 ~ /^[0-9A-Fa-f:]+\/[0-9]+$/ {print $1}'
    } | python3 -c '
import ipaddress
import sys

try:
    candidate = ipaddress.IPv6Network(sys.argv[1], strict=False)
except ValueError:
    raise SystemExit(2)
for raw in sys.stdin:
    try:
        network = ipaddress.IPv6Network(raw.strip(), strict=False)
    except ValueError:
        continue
    if candidate.overlaps(network):
        raise SystemExit(0)
raise SystemExit(1)
' "$subnet"
}

docker_ipv6_ula_candidate() {
    local index="$1"
    python3 - "$index" <<'PY'
import ipaddress
import sys

base = ipaddress.IPv6Network("fd42:5339:296f:1d00::/56")
index = int(sys.argv[1])
print(ipaddress.IPv6Network((int(base.network_address) + (index << 64), 64)))
PY
}

docker_ipv6_ula_gateway() {
    python3 - "$1" <<'PY'
import ipaddress
import sys

network = ipaddress.IPv6Network(sys.argv[1], strict=False)
print(ipaddress.IPv6Address(int(network.network_address) + 1))
PY
}

docker_ipv6_ula_is_safe() {
    local subnet="$1"
    command -v python3 >/dev/null 2>&1 || return 1
    python3 - "$subnet" <<'PY'
import ipaddress
import sys

try:
    network = ipaddress.IPv6Network(sys.argv[1], strict=False)
except ValueError:
    raise SystemExit(1)
raise SystemExit(0 if network.prefixlen == 64 and network.subnet_of(ipaddress.IPv6Network("fc00::/7")) else 1)
PY
}

docker_ipv6_network_ipv6_subnet() {
    command -v python3 >/dev/null 2>&1 || return 1
    docker network inspect ipv6_net 2>/dev/null | python3 -c '
import ipaddress
import json
import sys

try:
    payload = json.load(sys.stdin)
except (json.JSONDecodeError, OSError):
    raise SystemExit(1)
for network in payload if isinstance(payload, list) else [payload]:
    for config in (network.get("IPAM", {}).get("Config", []) if isinstance(network, dict) else []):
        try:
            subnet = ipaddress.ip_network(config.get("Subnet"), strict=False)
        except (TypeError, ValueError):
            continue
        if subnet.version == 6:
            print(subnet)
            raise SystemExit(0)
raise SystemExit(1)
'
}

# Reuse an existing ipv6_net only when it is demonstrably the ULA NAT66
# bridge created by this installer. Its own connected route must not be fed
# back into the host-overlap check, because that route is expected to overlap.
docker_ipv6_ula_state_matches_network() {
    local recorded_mode="$1" recorded_subnet="$2" network_subnet="$3"
    [[ "$recorded_mode" == "nat" && "$recorded_subnet" == "$network_subnet" ]] || return 1
    docker_ipv6_ula_is_safe "$network_subnet"
}

configure_docker_ipv6_nat66() {
    local subnet="$1" postrouting forward nft_table="oneclickvirt_docker_ipv6"
    docker_ipv6_ula_is_safe "$subnet" || return 1
    # Docker still manages its bridge policy through iptables on most hosts,
    # including iptables-nft. Prefer that path so the NAT66 allowance joins
    # the same forwarding policy instead of depending on base-chain ordering.
    if command -v ip6tables >/dev/null 2>&1; then
        ip6tables -C FORWARD -s "$subnet" -j ACCEPT 2>/dev/null || ip6tables -A FORWARD -s "$subnet" -j ACCEPT 2>/dev/null || return 1
        ip6tables -C FORWARD -d "$subnet" -j ACCEPT 2>/dev/null || ip6tables -A FORWARD -d "$subnet" -j ACCEPT 2>/dev/null || return 1
        ip6tables -t nat -C POSTROUTING -s "$subnet" ! -d "$subnet" -j MASQUERADE 2>/dev/null || \
            ip6tables -t nat -A POSTROUTING -s "$subnet" ! -d "$subnet" -j MASQUERADE 2>/dev/null || return 1
        ip6tables -t nat -C POSTROUTING -s "$subnet" ! -d "$subnet" -j MASQUERADE 2>/dev/null && \
            ip6tables -C FORWARD -s "$subnet" -j ACCEPT 2>/dev/null && \
            ip6tables -C FORWARD -d "$subnet" -j ACCEPT 2>/dev/null
        return
    fi
    if command -v nft >/dev/null 2>&1 && nft list ruleset >/dev/null 2>&1; then
        nft add table ip6 "$nft_table" 2>/dev/null || true
        nft "add chain ip6 ${nft_table} forward { type filter hook forward priority filter; policy accept; }" 2>/dev/null || true
        nft "add chain ip6 ${nft_table} postrouting { type nat hook postrouting priority srcnat; policy accept; }" 2>/dev/null || true
        postrouting=$(nft list chain ip6 "$nft_table" postrouting 2>/dev/null || true)
        forward=$(nft list chain ip6 "$nft_table" forward 2>/dev/null || true)
        if ! grep -Fq "ip6 saddr ${subnet}" <<<"$postrouting" || ! grep -Fq 'masquerade' <<<"$postrouting"; then
            nft add rule ip6 "$nft_table" postrouting ip6 saddr "$subnet" ip6 daddr != "$subnet" masquerade 2>/dev/null || return 1
        fi
        if ! grep -Fq "ip6 daddr ${subnet} accept" <<<"$forward"; then
            nft add rule ip6 "$nft_table" forward ip6 daddr "$subnet" accept 2>/dev/null || return 1
        fi
        if ! grep -Fq "ip6 saddr ${subnet} accept" <<<"$forward"; then
            nft add rule ip6 "$nft_table" forward ip6 saddr "$subnet" accept 2>/dev/null || return 1
        fi
        postrouting=$(nft list chain ip6 "$nft_table" postrouting 2>/dev/null || true)
        forward=$(nft list chain ip6 "$nft_table" forward 2>/dev/null || true)
        grep -Fq "ip6 saddr ${subnet}" <<<"$postrouting" && \
            grep -Fq 'masquerade' <<<"$postrouting" && \
            grep -Fq "ip6 daddr ${subnet} accept" <<<"$forward" && \
            grep -Fq "ip6 saddr ${subnet} accept" <<<"$forward"
        return
    fi
    return 1
}

install_docker_ipv6_nat66_service() {
    local helper=/usr/local/bin/docker-ipv6-nat.sh
    cat > "$helper" <<'EOF'
#!/bin/bash
# OneClickVirt Docker IPv6 NAT66 restore helper.
set -u

state_dir=/usr/local/bin
mode=$(tr -d '[:space:]' <"${state_dir}/docker_ipv6_network_mode" 2>/dev/null || true)
subnet=$(tr -d '[:space:]' <"${state_dir}/docker_ipv6_subnet" 2>/dev/null || true)
[[ "$mode" == nat && -n "$subnet" ]] || exit 0

python3 - "$subnet" <<'PY'
import ipaddress
import sys
try:
    network = ipaddress.IPv6Network(sys.argv[1], strict=False)
except ValueError:
    raise SystemExit(1)
raise SystemExit(0 if network.prefixlen == 64 and network.subnet_of(ipaddress.IPv6Network("fc00::/7")) else 1)
PY

if command -v ip6tables >/dev/null 2>&1; then
    ip6tables -C FORWARD -s "$subnet" -j ACCEPT 2>/dev/null || ip6tables -A FORWARD -s "$subnet" -j ACCEPT || exit 1
    ip6tables -C FORWARD -d "$subnet" -j ACCEPT 2>/dev/null || ip6tables -A FORWARD -d "$subnet" -j ACCEPT || exit 1
    ip6tables -t nat -C POSTROUTING -s "$subnet" ! -d "$subnet" -j MASQUERADE 2>/dev/null || \
        ip6tables -t nat -A POSTROUTING -s "$subnet" ! -d "$subnet" -j MASQUERADE || exit 1
    exit 0
fi

command -v nft >/dev/null 2>&1 && nft list ruleset >/dev/null 2>&1 || exit 1
nft_table=oneclickvirt_docker_ipv6
nft add table ip6 "$nft_table" 2>/dev/null || true
nft "add chain ip6 ${nft_table} forward { type filter hook forward priority filter; policy accept; }" 2>/dev/null || true
nft "add chain ip6 ${nft_table} postrouting { type nat hook postrouting priority srcnat; policy accept; }" 2>/dev/null || true
postrouting=$(nft list chain ip6 "$nft_table" postrouting 2>/dev/null || true)
forward=$(nft list chain ip6 "$nft_table" forward 2>/dev/null || true)
grep -Fq "ip6 saddr ${subnet}" <<<"$postrouting" || \
    nft add rule ip6 "$nft_table" postrouting ip6 saddr "$subnet" ip6 daddr != "$subnet" masquerade || exit 1
grep -Fq "ip6 daddr ${subnet} accept" <<<"$forward" || \
    nft add rule ip6 "$nft_table" forward ip6 daddr "$subnet" accept || exit 1
grep -Fq "ip6 saddr ${subnet} accept" <<<"$forward" || \
    nft add rule ip6 "$nft_table" forward ip6 saddr "$subnet" accept || exit 1
exit 0
EOF
    chmod 700 "$helper"
    if command -v systemctl >/dev/null 2>&1; then
        cat > /etc/systemd/system/docker-ipv6-nat.service <<'EOF'
[Unit]
Description=Restore OneClickVirt Docker IPv6 NAT66 rules
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/docker-ipv6-nat.sh

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload 2>/dev/null || true
        systemctl enable --now docker-ipv6-nat.service 2>/dev/null || \
            _yellow "Could not enable docker-ipv6-nat.service; verify NAT66 after reboot"
        return 0
    fi
    if command -v rc-update >/dev/null 2>&1 && command -v rc-service >/dev/null 2>&1; then
        cat > /etc/init.d/docker-ipv6-nat <<'EOF'
#!/sbin/openrc-run
# OneClickVirt Docker IPv6 NAT66 restore service.

description="Restore OneClickVirt Docker IPv6 NAT66 rules"

depend() {
    need net
    after docker
}

start() {
    ebegin "$description"
    /usr/local/bin/docker-ipv6-nat.sh
    eend $?
}
EOF
        chmod 700 /etc/init.d/docker-ipv6-nat
        rc-update add docker-ipv6-nat default 2>/dev/null || true
        rc-service docker-ipv6-nat restart 2>/dev/null || \
            _yellow "Could not start docker-ipv6-nat OpenRC service; verify NAT66 after reboot"
        return 0
    fi
    _yellow "No service manager found; verify Docker IPv6 NAT66 rules after reboot"
}

docker_ipv6_ula_overlaps_docker_network() {
    local subnet="$1"
    python3 - "$subnet" <<'PY'
import ipaddress
import json
import subprocess
import sys

candidate = ipaddress.IPv6Network(sys.argv[1], strict=False)
try:
    ids = subprocess.check_output(["docker", "network", "ls", "-q"], text=True, stderr=subprocess.DEVNULL).splitlines()
except (OSError, subprocess.CalledProcessError):
    ids = []
for network_id in ids:
    try:
        payload = subprocess.check_output(["docker", "network", "inspect", network_id], text=True, stderr=subprocess.DEVNULL)
        data = json.loads(payload)
    except (OSError, subprocess.CalledProcessError, json.JSONDecodeError):
        continue
    for network in data if isinstance(data, list) else [data]:
        for config in (network.get("IPAM", {}).get("Config", []) if isinstance(network, dict) else []):
            try:
                existing = ipaddress.ip_network(config.get("Subnet"), strict=False)
            except (TypeError, ValueError):
                continue
            if existing.version == 6 and candidate.overlaps(existing):
                raise SystemExit(0)
raise SystemExit(1)
PY
}

# When the provider only advertises an on-link /64 (common with SLAAC), keep
# Docker's bridge on a private ULA and use NAT66 for outbound IPv6. Public
# /128 assignment remains available through a delegated routed prefix, but we
# never pretend an on-link child is an independent Docker subnet.
create_docker_ula_ipv6_network() {
    local public_parent="$1" ula gateway index existing_ula recorded_mode recorded_subnet
    if docker network inspect ipv6_net >/dev/null 2>&1; then
        existing_ula=$(docker_ipv6_network_ipv6_subnet 2>/dev/null || true)
        recorded_mode=$(tr -d '[:space:]' </usr/local/bin/docker_ipv6_network_mode 2>/dev/null || true)
        recorded_subnet=$(tr -d '[:space:]' </usr/local/bin/docker_ipv6_subnet 2>/dev/null || true)
        if ! docker_ipv6_ula_state_matches_network "$recorded_mode" "$recorded_subnet" "$existing_ula"; then
            _yellow "Existing ipv6_net is not the installer-managed ULA NAT66 network; preserving its current mode"
            _yellow "现有 ipv6_net 不是安装器托管的 ULA NAT66 网络，保留其当前模式"
            return 1
        fi
        if ! configure_docker_ipv6_nat66 "$existing_ula"; then
            _yellow "Could not verify NAT66 for existing ipv6_net; preserving its current mode"
            return 1
        fi
        printf '%s\n' "$existing_ula" > /usr/local/bin/docker_ipv6_subnet
        printf '%s\n' nat > /usr/local/bin/docker_ipv6_network_mode
        printf '%s\n' "$public_parent" > /usr/local/bin/docker_ipv6_public_parent
        install_docker_ipv6_nat66_service
        return 0
    fi
    for index in $(seq 0 255); do
        ula=$(docker_ipv6_ula_candidate "$index" 2>/dev/null || true)
        gateway=$(docker_ipv6_ula_gateway "$ula" 2>/dev/null || true)
        [[ -n "$ula" && -n "$gateway" ]] || continue
        docker_ipv6_subnet_overlaps_host "$ula" && continue
        docker_ipv6_ula_overlaps_docker_network "$ula" && continue
        if docker network create --ipv6 \
            --subnet=172.26.0.0/16 \
            --subnet="$ula" --gateway="$gateway" ipv6_net >/dev/null 2>&1; then
            if ! configure_docker_ipv6_nat66 "$ula"; then
                docker network rm ipv6_net >/dev/null 2>&1 || true
                _yellow "Docker ULA bridge was created but NAT66 could not be installed"
                return 1
            fi
            printf '%s\n' "$ula" > /usr/local/bin/docker_ipv6_subnet
            printf '%s\n' nat > /usr/local/bin/docker_ipv6_network_mode
            printf '%s\n' "$public_parent" > /usr/local/bin/docker_ipv6_public_parent
            install_docker_ipv6_nat66_service
            _green "Docker IPv6 network uses isolated ULA ${ula}; outbound NAT66 is enabled"
            _green "Docker IPv6 网络使用隔离 ULA ${ula}，已启用出站 NAT66"
            return 0
        fi
    done
    return 1
}

docker_ipv6_normalize_public_parent() {
    local cidr="${1:-}" address
    [[ "$cidr" == */* ]] || return 1
    address="${cidr%/*}"
    is_public_ipv6 "$address" || return 1
    python3 - "$cidr" <<'PY'
import ipaddress
import sys

try:
    network = ipaddress.IPv6Network(sys.argv[1], strict=False)
except ValueError:
    raise SystemExit(1)
if network.prefixlen >= 128:
    raise SystemExit(1)
print(network)
PY
}

docker_ipv6_network_has_attached_containers() {
    docker ps -aq --filter 'network=ipv6_net' 2>/dev/null | grep -q '[^[:space:]]'
}

docker_ipv6_manual_state_matches_network() {
    local recorded_mode="$1" recorded_subnet="$2" network_subnet="$3" recorded_parent="$4"
    [[ "$recorded_mode" == "manual" && "$recorded_subnet" == "$network_subnet" && -n "$recorded_parent" ]] || return 1
    docker_ipv6_ula_is_safe "$network_subnet" || return 1
    docker_ipv6_normalize_public_parent "$recorded_parent" >/dev/null
}

docker_ipv6_network_bridge() {
    local bridge network_id
    bridge=$(docker network inspect -f '{{index .Options "com.docker.network.bridge.name"}}' ipv6_net 2>/dev/null || true)
    if [[ -z "$bridge" || "$bridge" == '<no value>' ]]; then
        network_id=$(docker network inspect -f '{{.Id}}' ipv6_net 2>/dev/null || true)
        [[ "$network_id" =~ ^[[:xdigit:]]{12,}$ ]] || return 1
        bridge="br-${network_id:0:12}"
    fi
    [[ "$bridge" =~ ^[[:alnum:]_.-]+$ ]] || return 1
    ip link show dev "$bridge" >/dev/null 2>&1 || return 1
    printf '%s\n' "$bridge"
}

# The IPv6 default route identifies the NDP-facing uplink more reliably than
# the first physical NIC. This matters on PVE bridges and tunnel hosts where
# the interface carrying the public prefix is not named eth0.
docker_ipv6_uplink_interface() {
    local uplink selected
    uplink=$(ip -6 route show default 2>/dev/null | awk '
        /^default / {
            for (i = 1; i < NF; i++) {
                if ($i == "dev") {
                    print $(i + 1)
                    exit
                }
            }
        }
    ')
    if [[ -n "$uplink" ]] && ip link show dev "$uplink" >/dev/null 2>&1; then
        printf '%s\n' "$uplink"
        return 0
    fi

    selected=$(select_public_ipv6_cidr 2>/dev/null || true)
    [[ "$selected" == */* ]] || return 1
    # A host can put the same IPv6 address on a /128 uplink and a delegated
    # prefix bridge. Match the complete address/CIDR so PVE-style delegated
    # bridges are selected instead of the narrower address on another link.
    uplink=$(ip -6 -o addr show scope global 2>/dev/null | awk -v cidr="$selected" '$4 == cidr {print $2; exit}')
    [[ -n "$uplink" ]] || return 1
    printf '%s\n' "$uplink"
}

docker_ipv6_uplink_supports_ndp() {
    local uplink="$1" link_info
    [[ -n "$uplink" ]] || return 1
    link_info=$(ip -d link show dev "$uplink" 2>/dev/null || ip link show dev "$uplink" 2>/dev/null || true)
    grep -q 'link/ether' <<<"$link_info"
}

docker_ipv6_clear_manual_state() {
    rm -f \
        /usr/local/bin/docker_ipv6_manual_subnet \
        /usr/local/bin/docker_ipv6_manual_gateway \
        /usr/local/bin/docker_ipv6_manual_bridge \
        /usr/local/bin/docker_ipv6_allocations \
        /usr/local/bin/docker_ipv6_targets \
        /usr/local/bin/docker_ipv6_ndp_required \
        /usr/local/bin/docker_ipv6_uplink
}

# Docker refuses every public child that overlaps a host route. Keep Docker's
# IPAM on a private ULA bridge, then give containers public /128 addresses
# through explicit host routes after they start. This preserves SLAAC,
# delegated prefixes, PVE bridges, and tunnels without touching host network
# manager files.
create_docker_manual_ipv6_network() {
    local public_parent="$1" normalized_parent manual_subnet gateway bridge uplink
    local recorded_mode recorded_subnet recorded_parent index created=false ndp_required=false

    normalized_parent=$(docker_ipv6_normalize_public_parent "$public_parent" 2>/dev/null || true)
    [[ -n "$normalized_parent" ]] || return 1
    command -v nsenter >/dev/null 2>&1 || {
        _yellow "nsenter is required for routed Docker IPv6 attachment"
        return 1
    }
    uplink=$(docker_ipv6_uplink_interface 2>/dev/null || true)
    [[ -n "$uplink" ]] || {
        _yellow "Could not determine the IPv6 uplink for routed Docker IPv6"
        return 1
    }

    if docker network inspect ipv6_net >/dev/null 2>&1; then
        manual_subnet=$(docker_ipv6_network_ipv6_subnet 2>/dev/null || true)
        recorded_mode=$(tr -d '[:space:]' </usr/local/bin/docker_ipv6_network_mode 2>/dev/null || true)
        recorded_subnet=$(tr -d '[:space:]' </usr/local/bin/docker_ipv6_subnet 2>/dev/null || true)
        recorded_parent=$(tr -d '[:space:]' </usr/local/bin/docker_ipv6_public_parent 2>/dev/null || true)
        if ! docker_ipv6_manual_state_matches_network "$recorded_mode" "$recorded_subnet" "$manual_subnet" "$recorded_parent"; then
            _yellow "Existing ipv6_net is not the installer-managed routed IPv6 network; preserving its current mode"
            _yellow "现有 ipv6_net 不是安装器托管的手动路由 IPv6 网络，保留其当前模式"
            return 1
        fi
        if [[ "$recorded_parent" != "$normalized_parent" ]]; then
            _yellow "The public IPv6 parent changed from ${recorded_parent} to ${normalized_parent}; preserving existing routed allocations"
            _yellow "公网 IPv6 父前缀已变化，保留现有手动路由地址分配，不自动接管"
            return 1
        fi
        bridge=$(tr -d '[:space:]' </usr/local/bin/docker_ipv6_manual_bridge 2>/dev/null || true)
        if [[ -z "$bridge" ]] || ! ip link show dev "$bridge" >/dev/null 2>&1; then
            bridge=$(docker_ipv6_network_bridge 2>/dev/null || true)
        fi
        [[ -n "$bridge" ]] || return 1
        gateway=$(tr -d '[:space:]' </usr/local/bin/docker_ipv6_manual_gateway 2>/dev/null || true)
        [[ -n "$gateway" ]] || gateway=$(docker_ipv6_ula_gateway "$manual_subnet" 2>/dev/null || true)
    else
        for index in $(seq 0 255); do
            manual_subnet=$(docker_ipv6_ula_candidate "$index" 2>/dev/null || true)
            gateway=$(docker_ipv6_ula_gateway "$manual_subnet" 2>/dev/null || true)
            [[ -n "$manual_subnet" && -n "$gateway" ]] || continue
            docker_ipv6_subnet_overlaps_host "$manual_subnet" && continue
            docker_ipv6_ula_overlaps_docker_network "$manual_subnet" && continue
            if docker network create --ipv6 \
                --subnet=172.26.0.0/16 \
                --subnet="$manual_subnet" --gateway="$gateway" ipv6_net >/dev/null 2>&1; then
                created=true
                break
            fi
        done
        [[ "$created" == true ]] || return 1
        bridge=$(docker_ipv6_network_bridge 2>/dev/null || true)
        if [[ -z "$bridge" ]]; then
            docker network rm ipv6_net >/dev/null 2>&1 || true
            _yellow "Could not identify the newly created Docker IPv6 bridge"
            return 1
        fi
    fi

    if docker_ipv6_uplink_supports_ndp "$uplink"; then
        ndp_required=true
    fi
    printf '%s\n' "$manual_subnet" > /usr/local/bin/docker_ipv6_subnet
    printf '%s\n' manual > /usr/local/bin/docker_ipv6_network_mode
    printf '%s\n' "$normalized_parent" > /usr/local/bin/docker_ipv6_public_parent
    printf '%s\n' "$manual_subnet" > /usr/local/bin/docker_ipv6_manual_subnet
    printf '%s\n' "$gateway" > /usr/local/bin/docker_ipv6_manual_gateway
    printf '%s\n' "$bridge" > /usr/local/bin/docker_ipv6_manual_bridge
    printf '%s\n' "$uplink" > /usr/local/bin/docker_ipv6_uplink
    printf '%s\n' "$ndp_required" > /usr/local/bin/docker_ipv6_ndp_required
    [[ -f /usr/local/bin/docker_ipv6_allocations ]] || : > /usr/local/bin/docker_ipv6_allocations
    [[ -f /usr/local/bin/docker_ipv6_targets ]] || : > /usr/local/bin/docker_ipv6_targets
    chmod 600 /usr/local/bin/docker_ipv6_allocations
    chmod 644 /usr/local/bin/docker_ipv6_targets
    install_docker_manual_ipv6_attach_helper
    install_docker_manual_ipv6_restore_service
    _green "Docker IPv6 network uses routed /128 attachment: internal=${manual_subnet}, public parent=${normalized_parent}"
    _yellow "Docker IPAM remains isolated; public IPv6 addresses are attached after each container starts"
    return 0
}

check_ipv6() {
    IPV6=""
    IPV6_CIDR=""
    local candidate
    candidate=$(select_public_ipv6_cidr || true)
    if [[ -n "$candidate" ]]; then
        IPV6_CIDR="$candidate"
        IPV6="${candidate%/*}"
    fi
    if [[ -n "$IPV6_CIDR" ]]; then
        _green "Locally bound public IPv6 detected: ${IPV6} (${IPV6_CIDR})"
    else
        _yellow "No locally bound public IPv6 prefix found; skipping independent IPv6 setup"
    fi
    printf '%s\n' "$IPV6" >/usr/local/bin/docker_check_ipv6
    printf '%s\n' "$IPV6_CIDR" >/usr/local/bin/docker_check_ipv6_cidr
}

check_cdn() {
    local o_url=$1
    local shuffled_cdn_urls=("${cdn_urls[@]}")
    if command -v shuf >/dev/null 2>&1; then
        shuffled_cdn_urls=($(shuf -e "${cdn_urls[@]}"))
    fi
    for cdn_url in "${shuffled_cdn_urls[@]}"; do
        if curl -4 -sL -k "$cdn_url$o_url" --max-time 6 | grep -q "success" >/dev/null 2>&1; then
            export cdn_success_url="$cdn_url"
            return
        fi
        sleep 0.5
    done
    export cdn_success_url=""
}

check_cdn_file() {
    if [[ "$without_cdn" == "true" ]]; then
        export cdn_success_url=""
        _yellow "WITHOUTCDN=TRUE detected, CDN disabled"
        return
    fi
    check_cdn "https://raw.githubusercontent.com/spiritLHLS/ecs/main/back/test"
    if [ -n "$cdn_success_url" ]; then
        _yellow "CDN available, using CDN"
    else
        _yellow "No CDN available, no use CDN"
    fi
}

get_system_arch() {
    local sysarch="$(uname -m)"
    if [ "${sysarch}" = "unknown" ] || [ "${sysarch}" = "" ]; then
        local sysarch="$(arch)"
    fi
    case "${sysarch}" in
    "i386" | "i686" | "x86_64")
        system_arch="x86"
        ;;
    "armv8" | "armv8l" | "aarch64")
        system_arch="arch"
        ;;
    "armv7l" | "armhf")
        system_arch="arm"
        ;;
    *)
        system_arch=""
        ;;
    esac
}

ndpresponder_image_matches_architecture() {
    local expected="$1"
    local actual="$2"
    case "$expected:$actual" in
        amd64:amd64|amd64:x86_64|arm64:arm64|arm64:aarch64|arm:arm|arm:armhf|arm:armv7) return 0 ;;
    esac
    return 1
}

ndpresponder_supports_target_file() {
    local image="$1" help_output
    help_output=$(docker run --rm "$image" --help 2>&1 || true)
    grep -Eq -- '(^|[[:space:],])--target-file([[:space:],=]|$)' <<<"$help_output"
}

ndpresponder_image_supports_required_features() {
    if [[ "${NDPRESPONDER_TARGET_FILE_REQUIRED:-false}" != true ]]; then
        return 0
    fi
    if ndpresponder_supports_target_file "$1"; then
        return 0
    fi
    _yellow "Responder image does not support --target-file; a source build is required for routed IPv6"
    _yellow "Responder 镜像不支持 --target-file；手动路由 IPv6 需要从源码构建新版程序"
    return 1
}

docker_ndpresponder_is_installer_owned() {
    local image
    [[ "$(tr -d '[:space:]' </usr/local/bin/docker_ndpresponder_owned 2>/dev/null || true)" == true ]] && return 0
    image=$(docker inspect -f '{{.Config.Image}}' ndpresponder 2>/dev/null || true)
    case "$image" in
        spiritlhl/ndpresponder_*|localhost/oneclickvirt-ndpresponder:*) return 0 ;;
    esac
    return 1
}

docker_ndpresponder_existing_image() {
    local image
    docker inspect ndpresponder >/dev/null 2>&1 || return 1
    image=$(docker inspect -f '{{.Config.Image}}' ndpresponder 2>/dev/null || true)
    [[ -n "$image" && "$image" != '<no value>' ]] || return 1
    printf '%s\n' "$image"
}

quarantine_incompatible_docker_ndpresponder() {
    local existing_image
    [[ "${NDPRESPONDER_TARGET_FILE_REQUIRED:-false}" == true ]] || return 0
    existing_image=$(docker_ndpresponder_existing_image 2>/dev/null || true)
    [[ -n "$existing_image" ]] || return 0
    if ndpresponder_supports_target_file "$existing_image"; then
        return 0
    fi
    if ! docker_ndpresponder_is_installer_owned; then
        _yellow "Existing ndpresponder is not installer-managed and lacks --target-file; preserving it"
        return 1
    fi
    _yellow "Existing ndpresponder lacks --target-file; removing it to stop an incompatible restart loop"
    _yellow "已有 ndpresponder 不支持 --target-file，正在移除以停止不兼容的重启循环"
    docker update --restart=no ndpresponder >/dev/null 2>&1 || true
    docker rm -f ndpresponder >/dev/null 2>&1 || true
    rm -f /usr/local/bin/docker_ndpresponder_owned
}

# Resolve a responder image without trusting a registry tag's architecture.
# ARMv7 has no published tag, so it intentionally follows the source-build
# path. Keep this function free of container mutation: callers may only remove
# an existing responder after this returns a verified image.
resolve_ndpresponder_image() {
    local expected_arch="$1"
    local registry_image="$2"
    local source_image source_url image_arch
    NDPRESPONDER_IMAGE=""

    if [[ -n "$registry_image" ]]; then
        _yellow "Pulling ndpresponder image: ${registry_image}"
        if docker pull "$registry_image" >/dev/null 2>&1; then
            image_arch=$(docker image inspect -f '{{.Architecture}}' "$registry_image" 2>/dev/null || true)
            if ndpresponder_image_matches_architecture "$expected_arch" "$image_arch" && \
               ndpresponder_image_supports_required_features "$registry_image"; then
                NDPRESPONDER_IMAGE="$registry_image"
                return 0
            fi
            _yellow "Responder image ${registry_image} is ${image_arch:-unknown}, expected ${expected_arch}; building a local responder image instead"
        else
            _yellow "Could not pull a responder image for ${expected_arch}; building a local responder image instead"
        fi
    else
        _yellow "No published responder image is configured for ${expected_arch}; building a local responder image instead"
    fi

    source_image="localhost/oneclickvirt-ndpresponder:${expected_arch}"
    source_url="${NDPRESPONDER_SOURCE_URL:-https://github.com/oneclickvirt/ndpresponder.git}"
    _yellow "Building ndpresponder from source: ${source_url}"
    if ! docker build --tag "$source_image" "$source_url"; then
        _yellow "Could not build a responder image from source; preserving any existing responder"
        return 1
    fi
    image_arch=$(docker image inspect -f '{{.Architecture}}' "$source_image" 2>/dev/null || true)
    if ! ndpresponder_image_matches_architecture "$expected_arch" "$image_arch"; then
        _yellow "Locally built responder image ${source_image} is ${image_arch:-unknown}, expected ${expected_arch}; preserving any existing responder"
        return 1
    fi
    if ! ndpresponder_image_supports_required_features "$source_image"; then
        _yellow "The source-built responder is missing the required target-file capability; preserving any existing responder"
        _yellow "源码构建的 ndpresponder 缺少所需的 target-file 能力，将保留已有 responder"
        return 1
    fi
    NDPRESPONDER_IMAGE="$source_image"
    return 0
}

start_docker_manual_ndpresponder() {
    local ndp_required uplink ndp_image ndp_status expected_arch registry_ndp_image
    local target_file

    [[ "$(tr -d '[:space:]' </usr/local/bin/docker_ipv6_network_mode 2>/dev/null || true)" == manual ]] || return 0
    ndp_required=$(tr -d '[:space:]' </usr/local/bin/docker_ipv6_ndp_required 2>/dev/null || true)
    if [[ "$ndp_required" != true ]]; then
        _green "Routed Docker IPv6 uses a non-Ethernet uplink; NDP responder is not required"
        return 0
    fi
    uplink=$(tr -d '[:space:]' </usr/local/bin/docker_ipv6_uplink 2>/dev/null || true)
    target_file=/usr/local/bin/docker_ipv6_targets
    [[ -n "$uplink" && -f "$target_file" ]] || {
        _yellow "Routed Docker IPv6 NDP state is incomplete"
        return 1
    }

    case "$system_arch" in
        x86)
            registry_ndp_image="spiritlhl/ndpresponder_x86"
            expected_arch="amd64"
            ;;
        arch)
            registry_ndp_image="spiritlhl/ndpresponder_aarch64"
            expected_arch="arm64"
            ;;
        arm)
            registry_ndp_image=""
            expected_arch="arm"
            ;;
        *)
            _yellow "Unsupported responder architecture: ${system_arch:-unknown}"
            return 1
            ;;
    esac

    if docker inspect ndpresponder >/dev/null 2>&1 && ! docker_ndpresponder_is_installer_owned; then
        _yellow "An existing ndpresponder is not installer-managed; preserving it instead of replacing it"
        _yellow "已有 ndpresponder 不属于安装器管理范围，保留现状，不替换其配置"
        return 1
    fi

    NDPRESPONDER_TARGET_FILE_REQUIRED=true
    quarantine_incompatible_docker_ndpresponder || return 1
    if ! resolve_ndpresponder_image "$expected_arch" "$registry_ndp_image"; then
        return 1
    fi
    ndp_image="$NDPRESPONDER_IMAGE"

    if docker inspect ndpresponder >/dev/null 2>&1; then
        docker update --restart=no ndpresponder >/dev/null 2>&1 || true
        docker rm -f ndpresponder >/dev/null 2>&1 || return 1
    fi
    if ! docker run -d \
        --restart on-failure:3 \
        --cpus 0.02 \
        --memory 64M \
        --label io.oneclickvirt.docker.ipv6-managed=true \
        --cap-drop=ALL \
        --cap-add=NET_RAW \
        --cap-add=NET_ADMIN \
        --network host \
        --volume "$target_file:/etc/ndpresponder-targets:ro" \
        --name ndpresponder \
        "$ndp_image" \
        -i "$uplink" --target-file /etc/ndpresponder-targets; then
        _yellow "Failed to create ndpresponder for routed Docker IPv6"
        return 1
    fi
    for _ndp_attempt in 1 2 3; do
        sleep 1
        ndp_status=$(docker inspect -f '{{.State.Status}}' ndpresponder 2>/dev/null || true)
        [[ "$ndp_status" == running ]] && break
    done
    if [[ "$ndp_status" == running ]]; then
        printf '%s\n' true > /usr/local/bin/docker_ndpresponder_owned
        _green "NDP responder started for routed Docker IPv6"
        return 0
    fi
    _yellow "ndpresponder is not running: $(docker logs --tail 20 ndpresponder 2>&1 || true)"
    docker update --restart=no ndpresponder >/dev/null 2>&1 || true
    docker rm -f ndpresponder >/dev/null 2>&1 || true
    rm -f /usr/local/bin/docker_ndpresponder_owned
    return 1
}

install_docker_manual_ipv6_attach_helper() {
    local helper=/usr/local/bin/docker-ipv6-attach.sh
    cat > "$helper" <<'EOF'
#!/bin/bash
# Installer-owned routed IPv6 attachment for Docker's isolated ULA bridge.
set -u

state_dir=/usr/local/bin
runtime=docker
parent_file="${state_dir}/docker_ipv6_public_parent"
subnet_file="${state_dir}/docker_ipv6_manual_subnet"
gateway_file="${state_dir}/docker_ipv6_manual_gateway"
bridge_file="${state_dir}/docker_ipv6_manual_bridge"
map_file="${state_dir}/docker_ipv6_allocations"
target_file="${state_dir}/docker_ipv6_targets"
mode_file="${state_dir}/docker_ipv6_network_mode"
lock_dir="${map_file}.lock"

fail() { printf '%s\n' "$*" >&2; return 1; }
valid_name() { [[ "${1:-}" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]]; }

read_state() {
    mode=$(tr -d '[:space:]' <"$mode_file" 2>/dev/null || true)
    parent=$(tr -d '[:space:]' <"$parent_file" 2>/dev/null || true)
    subnet=$(tr -d '[:space:]' <"$subnet_file" 2>/dev/null || true)
    gateway=$(tr -d '[:space:]' <"$gateway_file" 2>/dev/null || true)
    bridge=$(tr -d '[:space:]' <"$bridge_file" 2>/dev/null || true)
    [[ "$mode" == manual && -n "$parent" && -n "$subnet" && -n "$gateway" && -n "$bridge" ]] || \
        fail "Docker routed IPv6 state is incomplete"
}

valid_ipv6_in_parent() {
    python3 - "$1" "$2" <<'PY'
import ipaddress
import sys
try:
    address = ipaddress.IPv6Address(sys.argv[1])
    parent = ipaddress.IPv6Network(sys.argv[2], strict=False)
except ValueError:
    raise SystemExit(1)
raise SystemExit(0 if address in parent and not address.is_unspecified and not address.is_multicast else 1)
PY
}

allocate_address() {
    python3 - "$parent" "$map_file" "$gateway" <<'PY'
import ipaddress
import subprocess
import sys

parent = ipaddress.IPv6Network(sys.argv[1], strict=False)
used = set()
try:
    with open(sys.argv[2], encoding="utf-8") as handle:
        for line in handle:
            fields = line.split()
            if len(fields) >= 2:
                used.add(ipaddress.IPv6Address(fields[1]))
except (OSError, ValueError):
    pass
try:
    used.add(ipaddress.IPv6Address(sys.argv[3]))
except ValueError:
    pass
try:
    output = subprocess.check_output(["ip", "-6", "-o", "addr", "show"], text=True, stderr=subprocess.DEVNULL)
except (OSError, subprocess.CalledProcessError):
    output = ""
for line in output.splitlines():
    fields = line.split()
    if len(fields) < 4:
        continue
    try:
        address = ipaddress.IPv6Interface(fields[3]).ip
    except ValueError:
        continue
    if address in parent:
        used.add(address)
try:
    routes = subprocess.check_output(["ip", "-6", "route", "show", "default"], text=True, stderr=subprocess.DEVNULL)
except (OSError, subprocess.CalledProcessError):
    routes = ""
for line in routes.splitlines():
    fields = line.split()
    for index, field in enumerate(fields[:-1]):
        if field != "via":
            continue
        try:
            gateway = ipaddress.IPv6Address(fields[index + 1])
        except ValueError:
            continue
        if gateway in parent:
            used.add(gateway)
start = int(parent.network_address) + (0x1000 if parent.prefixlen <= 112 else 1)
limit = min(int(parent.broadcast_address), start + 1_000_000)
for value in range(start, limit + 1):
    candidate = ipaddress.IPv6Address(value)
    if candidate not in used and candidate != parent.network_address:
        print(candidate)
        raise SystemExit(0)
raise SystemExit(1)
PY
}

sync_targets() {
    local tmp rc
    tmp=$(mktemp "${target_file}.tmp.XXXXXX") || return 1
    awk 'NF >= 2 {print $2 "/128"}' "$map_file" | sort -u >"$tmp"
    chmod 644 "$tmp"
    if cat "$tmp" >"$target_file"; then
        rm -f "$tmp"
        return 0
    fi
    rc=$?
    rm -f "$tmp"
    return "$rc"
}

replace_mapping() {
    local name="$1" address="$2" tmp
    tmp=$(mktemp "${map_file}.tmp.XXXXXX") || return 1
    awk -v name="$name" '$1 != name {print}' "$map_file" 2>/dev/null >"$tmp" || true
    printf '%s %s\n' "$name" "$address" >>"$tmp"
    chmod 600 "$tmp"
    mv -f "$tmp" "$map_file" || return 1
    sync_targets
}

acquire_lock() {
    local attempt
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
        mkdir "$lock_dir" 2>/dev/null && return 0
        sleep 0.1
    done
    fail "Timed out waiting for the Docker IPv6 allocation lock"
}

release_lock() {
    rmdir "$lock_dir" 2>/dev/null || true
}

find_container_iface() {
    local name="$1" pid="$2" ula iface
    ula=$($runtime inspect -f '{{range .NetworkSettings.Networks}}{{.GlobalIPv6Address}}{{"\n"}}{{end}}' "$name" 2>/dev/null | awk '/:/{print; exit}' || true)
    if [[ -n "$ula" ]]; then
        iface=$(nsenter -t "$pid" -n ip -o -6 addr show 2>/dev/null | awk -v target="$ula" '$4 ~ ("^" target "/") {print $2; exit}' || true)
        [[ -n "$iface" ]] && {
            printf '%s\n' "$iface"
            return 0
        }
    fi
    nsenter -t "$pid" -n ip -o link show 2>/dev/null | awk -F': ' '$2 !~ /^lo(@|:|$)/ {gsub(/@.*$/, "", $2); iface=$2} END {if (iface != "") print iface}'
}

attach_one_locked() {
    local name="$1" requested="${2:-}" pid address iface
    pid=$($runtime inspect -f '{{.State.Pid}}' "$name" 2>/dev/null || true)
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
    address=$(awk -v name="$name" '$1 == name {print $2; exit}' "$map_file" 2>/dev/null || true)
    if [[ -n "$requested" ]]; then
        valid_ipv6_in_parent "$requested" "$parent" || {
            fail "Requested IPv6 is outside the routed parent: $requested"
            return 1
        }
        if awk -v name="$name" -v address="$requested" '$1 != name && $2 == address {found=1} END {exit found ? 0 : 1}' "$map_file" 2>/dev/null; then
            fail "Requested IPv6 is already allocated: $requested"
            return 1
        fi
        address="$requested"
    fi
    [[ -n "$address" ]] || address=$(allocate_address) || return 1
    valid_ipv6_in_parent "$address" "$parent" || return 1
    iface=$(find_container_iface "$name" "$pid")
    [[ -n "$iface" ]] || {
        fail "Unable to find the IPv6 network interface for $name"
        return 1
    }
    nsenter -t "$pid" -n ip link set "$iface" up || return 1
    nsenter -t "$pid" -n ip -6 addr replace "$address/128" dev "$iface" || return 1
    nsenter -t "$pid" -n ip -6 route replace default via "$gateway" dev "$iface" || return 1
    ip -6 route replace "$address/128" dev "$bridge" || return 1
    replace_mapping "$name" "$address" || return 1
    printf '%s\n' "$address"
}

attach_one() {
    local name="$1" requested="${2:-}" rc
    valid_name "$name" || return 1
    read_state || return 1
    [[ -f "$map_file" ]] || : >"$map_file"
    [[ -f "$target_file" ]] || : >"$target_file"
    acquire_lock || return 1
    attach_one_locked "$name" "$requested"
    rc=$?
    release_lock
    return "$rc"
}

prune_stale_mappings_locked() {
    local name address tmp changed=false
    [[ -f "$map_file" ]] || return 0
    tmp=$(mktemp "${map_file}.tmp.XXXXXX") || return 1
    while read -r name address; do
        [[ -n "$name" && -n "$address" ]] || continue
        if valid_name "$name" && valid_ipv6_in_parent "$address" "$parent" && \
           "$runtime" inspect "$name" >/dev/null 2>&1; then
            printf '%s %s\n' "$name" "$address" >>"$tmp"
            continue
        fi
        changed=true
        if valid_ipv6_in_parent "$address" "$parent"; then
            ip -6 route del "$address/128" dev "$bridge" 2>/dev/null || true
        fi
    done <"$map_file"
    if [[ "$changed" == true ]]; then
        chmod 600 "$tmp"
        mv -f "$tmp" "$map_file" || return 1
        sync_targets
        return $?
    fi
    rm -f "$tmp"
    return 0
}

restore_all() {
    local name address rc=0
    read_state || return 1
    [[ -f "$map_file" ]] || return 0
    [[ -f "$target_file" ]] || : >"$target_file"
    acquire_lock || return 1
    prune_stale_mappings_locked || rc=1
    while read -r name address; do
        [[ -n "$name" && -n "$address" ]] || continue
        [[ "$($runtime inspect -f '{{.State.Running}}' "$name" 2>/dev/null || true)" == true ]] || continue
        attach_one_locked "$name" "$address" >/dev/null || {
            printf 'Failed to restore IPv6 for %s\n' "$name" >&2
            rc=1
        }
    done <"$map_file"
    release_lock
    return "$rc"
}

watch_all() {
    local interval="${DOCKER_IPV6_WATCH_INTERVAL:-2}" mode
    [[ "$interval" =~ ^[1-9][0-9]*$ ]] || interval=2
    while :; do
        mode=$(tr -d '[:space:]' <"$mode_file" 2>/dev/null || true)
        [[ "$mode" == manual ]] || exit 0
        restore_all || true
        sleep "$interval"
    done
}

remove_one_locked() {
    local name="$1" old_address tmp
    old_address=$(awk -v name="$name" '$1 == name {print $2; exit}' "$map_file" 2>/dev/null || true)
    tmp=$(mktemp "${map_file}.tmp.XXXXXX") || return 1
    awk -v name="$name" '$1 != name {print}' "$map_file" 2>/dev/null >"$tmp" || true
    chmod 600 "$tmp"
    mv -f "$tmp" "$map_file" || return 1
    sync_targets || return 1
    if [[ -n "$old_address" ]]; then
        ip -6 route del "$old_address/128" dev "$bridge" 2>/dev/null || true
    fi
}

remove_one() {
    local name="$1" rc
    valid_name "$name" || return 1
    read_state || return 1
    [[ -f "$map_file" ]] || : >"$map_file"
    [[ -f "$target_file" ]] || : >"$target_file"
    acquire_lock || return 1
    remove_one_locked "$name"
    rc=$?
    release_lock
    return "$rc"
}

case "${1:-}" in
    --restore-all) restore_all ;;
    --watch) watch_all ;;
    --remove)
        name="${2:-}"
        remove_one "$name"
        ;;
    *)
        [[ -n "${1:-}" ]] || {
            printf 'usage: %s <container> [IPv6] | --restore-all | --watch | --remove <container>\n' "$0" >&2
            exit 2
        }
        attach_one "$@"
        ;;
esac
EOF
    chmod 700 "$helper"
}

install_docker_manual_ipv6_restore_service() {
    if command -v systemctl >/dev/null 2>&1; then
        cat > /etc/systemd/system/docker-ipv6-attach.service <<'EOF'
[Unit]
Description=Restore OneClickVirt Docker routed IPv6 addresses
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/docker-ipv6-attach.sh --watch
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload 2>/dev/null || true
        systemctl enable --now docker-ipv6-attach.service 2>/dev/null || \
            _yellow "Could not start docker-ipv6-attach.service; rerun the installer after a reboot"
        return 0
    fi
    if command -v rc-update >/dev/null 2>&1 && command -v rc-service >/dev/null 2>&1; then
        cat > /etc/init.d/docker-ipv6-attach <<'EOF'
#!/sbin/openrc-run
# OneClickVirt Docker routed IPv6 restore service.

description="Restore OneClickVirt Docker routed IPv6 addresses"
command="/usr/local/bin/docker-ipv6-attach.sh"
command_args="--watch"
command_background=true
pidfile="/run/docker-ipv6-attach.pid"

depend() {
    need net docker
    after docker
}
EOF
        chmod 700 /etc/init.d/docker-ipv6-attach
        rc-update add docker-ipv6-attach default 2>/dev/null || true
        rc-service docker-ipv6-attach restart 2>/dev/null || \
            _yellow "Could not start docker-ipv6-attach OpenRC service; rerun the installer after a reboot"
        return 0
    fi
    _yellow "No service manager found; routed Docker IPv6 addresses must be restored manually after reboot"
}

check_china() {
    _yellow "IP area being detected ......"
    if [[ "${CN^^}" == "TRUE" ]]; then
        _yellow "CN=TRUE detected, using Chinese mirrors"
        CN=true
        return
    elif [[ "${CN^^}" == "FALSE" ]]; then
        _yellow "CN=FALSE detected, skipping Chinese mirrors"
        return
    fi
    if [[ -z "${CN}" ]]; then
        if [[ $(curl -m 6 -s https://ipapi.co/json | grep 'China') != "" ]]; then
            _yellow "根据ipapi.co提供的信息，当前IP可能在中国"
            if is_noninteractive; then
                _yellow "noninteractive=true detected, using Chinese mirrors for China IP"
                input="y"
            else
                read -e -r -p "是否选用中国镜像完成相关组件安装? ([y]/n) " input
            fi
            case $input in
            [yY][eE][sS] | [yY])
                echo "使用中国镜像"
                CN=true
                ;;
            [nN][oO] | [nN])
                echo "不使用中国镜像"
                ;;
            *)
                echo "使用中国镜像"
                CN=true
                ;;
            esac
        fi
    fi
}

update_docker_ipv6_sysctl() {
    local sysctl_config="$1" key value config_file temp_file
    key="${sysctl_config%%=*}"
    value="${sysctl_config#*=}"
    config_file="/etc/sysctl.d/99-oneclickvirt-docker-ipv6.conf"
    mkdir -p /etc/sysctl.d || return 1
    temp_file=$(mktemp "${config_file}.XXXXXX") || return 1
    {
        printf '%s\n' '# Managed by OneClickVirt Docker IPv6. Remove this file to revert installer-owned settings.'
        if [[ -f "$config_file" ]]; then
            awk -v target="$key" 'index($0, target "=") != 1 && $0 !~ /^# Managed by OneClickVirt Docker IPv6\./ {print}' "$config_file"
        fi
        printf '%s\n' "$sysctl_config"
    } >"$temp_file" || {
        rm -f "$temp_file"
        return 1
    }
    chmod 644 "$temp_file"
    mv -f "$temp_file" "$config_file" || return 1
    sysctl -w "$key=$value" >/dev/null 2>&1
}

if [ ! -d /usr/local/bin ]; then
    mkdir -p /usr/local/bin
fi
statistics_of_run_times
_green "脚本当天运行次数:${TODAY}，累计运行次数:${TOTAL}"
check_update
install_packages_once() {
    local packages=("$@")
    if [ "${#packages[@]}" -eq 0 ]; then
        return 0
    fi
    _yellow "Installing packages: ${packages[*]}"
    ${PACKAGE_INSTALL[int]} "${packages[@]}"
}

base_packages=()
command -v sudo >/dev/null 2>&1 || base_packages+=("sudo")
command -v curl >/dev/null 2>&1 || base_packages+=("curl")
command -v wget >/dev/null 2>&1 || base_packages+=("wget")
command -v jq >/dev/null 2>&1 || base_packages+=("jq")
if ! command -v python3 >/dev/null 2>&1; then
    if [[ "$SYSTEM" == "Arch" ]]; then
        base_packages+=("python")
    else
        base_packages+=("python3")
    fi
fi
command -v dos2unix >/dev/null 2>&1 || base_packages+=("dos2unix")
command -v bc >/dev/null 2>&1 || base_packages+=("bc")
command -v fallocate >/dev/null 2>&1 || base_packages+=("util-linux")
command -v openssl >/dev/null 2>&1 || base_packages+=("openssl")
command -v netstat >/dev/null 2>&1 || base_packages+=("net-tools")
if ! command -v ip >/dev/null 2>&1; then
    if [[ "$SYSTEM" == "CentOS" || "$SYSTEM" == "Fedora" ]]; then
        base_packages+=("iproute")
    else
        base_packages+=("iproute2")
    fi
fi
install_packages_once "${base_packages[@]}"
if ! command -v lshw >/dev/null 2>&1; then
    _yellow "Installing lshw"
    if [[ "$SYSTEM" == "Alpine" ]]; then
        _yellow "Alpine does not have lshw package, skipping..."
    else
        ${PACKAGE_INSTALL[int]} lshw
    fi
fi
if ! command -v ipcalc >/dev/null 2>&1; then
    _yellow "Installing ipcalc"
    if [[ "$SYSTEM" == "Alpine" ]]; then
        ${PACKAGE_INSTALL[int]} ipcalc-ng
    else
        ${PACKAGE_INSTALL[int]} ipcalc
    fi
fi
if ! command -v lxcfs >/dev/null 2>&1; then
    _yellow "Installing lxcfs"
    if [[ "$SYSTEM" == "Alpine" ]]; then
        _yellow "lxcfs not available on Alpine, skipping..."
    else
        ${PACKAGE_INSTALL[int]} lxcfs
    fi
fi
if ! command -v crontab >/dev/null 2>&1; then
    _yellow "Installing crontab"
    if [[ "$SYSTEM" == "Alpine" ]]; then
        ${PACKAGE_INSTALL[int]} dcron
        if command -v rc-update >/dev/null 2>&1; then
            rc-update add dcron default
            rc-service dcron start
        fi
    elif [[ "$SYSTEM" == "Arch" ]]; then
        ${PACKAGE_INSTALL[int]} cronie
        if command -v systemctl >/dev/null 2>&1; then
            systemctl enable cronie
            systemctl start cronie
        fi
    else
        ${PACKAGE_INSTALL[int]} cron
        if [[ $? -ne 0 ]]; then
            ${PACKAGE_INSTALL[int]} cronie
        fi
    fi
fi
check_china
cdn_urls=("https://cdn0.spiritlhl.top/" "http://cdn1.spiritlhl.net/" "http://cdn2.spiritlhl.net/" "http://cdn3.spiritlhl.net/" "http://cdn4.spiritlhl.net/")
if [[ "$without_cdn" == "true" ]]; then
    cdn_success_url=""
else
    check_cdn_file
fi
get_system_arch
if ! curl -fsSLk "${cdn_success_url}https://raw.githubusercontent.com/oneclickvirt/docker/main/scripts/ssh_bash.sh" -o ssh_bash.sh; then
    _red "Failed to download ssh_bash.sh"
    _red "下载 ssh_bash.sh 失败"
    exit 1
fi
if ! curl -fsSLk "${cdn_success_url}https://raw.githubusercontent.com/oneclickvirt/docker/main/scripts/ssh_sh.sh" -o ssh_sh.sh; then
    _red "Failed to download ssh_sh.sh"
    _red "下载 ssh_sh.sh 失败"
    exit 1
fi
chmod +x ssh_bash.sh ssh_sh.sh
dos2unix ssh_bash.sh ssh_sh.sh >/dev/null 2>&1 || true

if [[ "$SYSTEM" == "Alpine" ]]; then
    interface_1=$(ip -o link show | awk -F': ' '$2 !~ /^(lo|docker|veth)/ {print $2; exit}')
    interface_2=$(ip -o link show | awk -F': ' '$2 !~ /^(lo|docker|veth)/ {count++; if(count==2) {print $2; exit}}')
else
    interface_1=$(lshw -C network | awk '/logical name:/{print $3}' | sed -n '1p')
    interface_2=$(lshw -C network | awk '/logical name:/{print $3}' | sed -n '2p')
fi
check_interface
if [ ! -f /usr/local/bin/docker_mac_address ] || [ ! -s /usr/local/bin/docker_mac_address ] || [ "$(sed -e '/^[[:space:]]*$/d' /usr/local/bin/docker_mac_address)" = "" ]; then
    mac_address=$(ip -o link show dev ${interface} | awk '{print $17}')
    echo "$mac_address" >/usr/local/bin/docker_mac_address
fi
mac_address=$(cat /usr/local/bin/docker_mac_address)

if [ ! -f /usr/local/bin/docker_main_ipv4 ]; then
    main_ipv4=$(ip -4 addr show | grep global | awk '{print $2}' | cut -d '/' -f1 | head -n 1)
    echo "$main_ipv4" >/usr/local/bin/docker_main_ipv4
fi
main_ipv4=$(cat /usr/local/bin/docker_main_ipv4)
if [ ! -f /usr/local/bin/docker_ipv4_address ]; then
    ipv4_address=$(ip addr show | awk '/inet .*global/ && !/inet6/ {print $2}' | sed -n '1p')
    echo "$ipv4_address" >/usr/local/bin/docker_ipv4_address
fi
ipv4_address=$(cat /usr/local/bin/docker_ipv4_address)
if [ ! -f /usr/local/bin/docker_ipv4_gateway ]; then
    ipv4_gateway=$(ip route | awk '/default/ {print $3}' | sed -n '1p')
    echo "$ipv4_gateway" >/usr/local/bin/docker_ipv4_gateway
fi
ipv4_gateway=$(cat /usr/local/bin/docker_ipv4_gateway)
if [ ! -f /usr/local/bin/docker_ipv4_subnet ]; then
    if [[ "$SYSTEM" == "Arch" ]] || [[ "$SYSTEM" == "Alpine" ]]; then
        # For Arch and Alpine, calculate netmask from CIDR prefix
        ipv4_prefixlen=$(echo "$ipv4_address" | cut -d '/' -f 2)
        case $ipv4_prefixlen in
            8) ipv4_subnet="255.0.0.0" ;;
            9) ipv4_subnet="255.128.0.0" ;;
            10) ipv4_subnet="255.192.0.0" ;;
            11) ipv4_subnet="255.224.0.0" ;;
            12) ipv4_subnet="255.240.0.0" ;;
            13) ipv4_subnet="255.248.0.0" ;;
            14) ipv4_subnet="255.252.0.0" ;;
            15) ipv4_subnet="255.254.0.0" ;;
            16) ipv4_subnet="255.255.0.0" ;;
            17) ipv4_subnet="255.255.128.0" ;;
            18) ipv4_subnet="255.255.192.0" ;;
            19) ipv4_subnet="255.255.224.0" ;;
            20) ipv4_subnet="255.255.240.0" ;;
            21) ipv4_subnet="255.255.248.0" ;;
            22) ipv4_subnet="255.255.252.0" ;;
            23) ipv4_subnet="255.255.254.0" ;;
            24) ipv4_subnet="255.255.255.0" ;;
            25) ipv4_subnet="255.255.255.128" ;;
            26) ipv4_subnet="255.255.255.192" ;;
            27) ipv4_subnet="255.255.255.224" ;;
            28) ipv4_subnet="255.255.255.240" ;;
            29) ipv4_subnet="255.255.255.248" ;;
            30) ipv4_subnet="255.255.255.252" ;;
            31) ipv4_subnet="255.255.255.254" ;;
            32) ipv4_subnet="255.255.255.255" ;;
            *) ipv4_subnet="255.255.255.0" ;;
        esac
    else
        # 检测 grep 是否支持 -P 选项
        if echo "test" | grep -P "test" >/dev/null 2>&1; then
            ipv4_subnet=$(ipcalc -n "$ipv4_address" | grep -oP 'Netmask:\s+\K.*' | awk '{print $1}')
        else
            # BusyBox 兼容方法
            ipv4_subnet=$(ipcalc -n "$ipv4_address" | grep 'Netmask:' | awk '{print $2}')
        fi
    fi
    echo "$ipv4_subnet" >/usr/local/bin/docker_ipv4_subnet
fi
ipv4_subnet=$(cat /usr/local/bin/docker_ipv4_subnet)
ipv4_prefixlen=$(echo "$ipv4_address" | cut -d '/' -f 2)

_green "Do you need Docker with container disk size limitation? (Support btrfs storage driver)"
_green "是否需要支持容器硬盘大小限制的Docker环境？（支持btrfs存储驱动）"
_blue "If you choose 'y', you can limit the disk space for each container"
_blue "If you choose 'n', standard Docker installation without disk limits"
_blue "如果选择 'y'，可以为每个容器限制磁盘空间"
_blue "如果选择 'n'，则为标准Docker安装，无磁盘限制"
if [[ -n "${NEED_DISK_LIMIT}" ]]; then
    _yellow "NEED_DISK_LIMIT=${NEED_DISK_LIMIT} detected, skipping prompt"
    need_disk_limit="${NEED_DISK_LIMIT}"
elif is_noninteractive; then
    _yellow "noninteractive=true detected, using default disk limit choice: n"
    need_disk_limit="n"
else
    reading "Do you need container disk size limitation? ([n]/y): " need_disk_limit
fi
_green "Where do you want to install Docker? (Enter to default: /var/lib/docker):"
if [[ -n "${DOCKER_INSTALL_PATH}" ]]; then
    _yellow "DOCKER_INSTALL_PATH=${DOCKER_INSTALL_PATH} detected, skipping prompt"
    docker_install_path="${DOCKER_INSTALL_PATH}"
else
    reading "Docker安装路径？（回车则默认：/var/lib/docker）：" docker_install_path
fi
if [ -z "$docker_install_path" ]; then
    docker_install_path="/var/lib/docker"
fi
case "$(echo "${need_disk_limit:-n}" | tr '[:upper:]' '[:lower:]')" in
    y|yes|true|1)
        need_disk_limit="y"
        ;;
    *)
        need_disk_limit="n"
        ;;
esac
if [ "$need_disk_limit" = "y" ]; then
    echo "true" > /usr/local/bin/docker_need_disk_limit
    if [[ -n "${DOCKER_POOL_SIZE}" ]] && [[ "${DOCKER_POOL_SIZE}" =~ ^[1-9][0-9]*$ ]]; then
        _yellow "DOCKER_POOL_SIZE=${DOCKER_POOL_SIZE} detected, skipping prompt"
        docker_pool_size="${DOCKER_POOL_SIZE}"
    elif is_noninteractive; then
        docker_pool_size="20"
        _yellow "noninteractive=true detected, using default Docker pool size: ${docker_pool_size}GB"
    else
        while true; do
            _green "How large a Docker storage pool is needed? (unit: GB, e.g., enter 20 for 20G):"
            reading "需要多大的Docker存储池？（单位GB，例如输入20表示20G）：" docker_pool_size
            if [[ "$docker_pool_size" =~ ^[1-9][0-9]*$ ]]; then
                break
            else
                _yellow "Invalid input, please enter a positive integer."
                _yellow "输入无效，请输入一个正整数。"
            fi
        done
    fi
    _green "Where do you want to store the Docker loop file? (Enter to default: /opt/docker-pool.img):"
    if [[ -n "${DOCKER_LOOP_FILE}" ]]; then
        _yellow "DOCKER_LOOP_FILE=${DOCKER_LOOP_FILE} detected, skipping prompt"
        docker_loop_file="${DOCKER_LOOP_FILE}"
    else
        reading "Docker循环文件存储位置？（回车则默认：/opt/docker-pool.img）：" docker_loop_file
    fi
    if [ -z "$docker_loop_file" ]; then
        docker_loop_file="/opt/docker-pool.img"
    fi
else
    echo "false" > /usr/local/bin/docker_need_disk_limit
    docker_pool_size=""
    docker_loop_file=""
    _green "Will install standard Docker without container disk size limitation"
    _green "将安装标准Docker，无容器磁盘大小限制功能"
fi
detect_virtualization
try_storage_drivers

run_linuxmirrors_docker_installer() {
    local installer_url="$1"
    shift
    local installer_tmp installer_status
    installer_tmp=$(mktemp)
    if ! curl -fsSL "$installer_url" -o "$installer_tmp"; then
        rm -f "$installer_tmp"
        _red "Failed to download Docker installation script: $installer_url"
        _red "下载 Docker 安装脚本失败: $installer_url"
        return 1
    fi
    bash "$installer_tmp" "$@" | awk '/脚本运行完毕，更多使用教程详见官网/ {exit} {print}'
    installer_status=${PIPESTATUS[0]}
    rm -f "$installer_tmp"
    if [ "$installer_status" -ne 0 ] && [ "$installer_status" -ne 141 ]; then
        _red "Docker installation script failed with status ${installer_status}"
        _red "Docker 安装脚本执行失败，状态码 ${installer_status}"
        return "$installer_status"
    fi
}

install_docker_and_compose() {
    _green "This may stay for 2~3 minutes, please be patient..."
    _green "此处可能会停留2~3分钟，请耐心等待。。。"
    sleep 1
    need_disk_limit="false"
    if [ -f /usr/local/bin/docker_need_disk_limit ]; then
        need_disk_limit=$(cat /usr/local/bin/docker_need_disk_limit)
    fi
    if [ "$need_disk_limit" = "true" ] && [ -n "$docker_pool_size" ] && [ -n "$docker_loop_file" ]; then
        setup_docker_btrfs_loop "$docker_pool_size" "$docker_loop_file" "$docker_install_path"
    fi
    if ! command -v docker >/dev/null 2>&1; then
        _yellow "Installing docker"
        if [[ "$SYSTEM" == "Alpine" ]]; then
            _green "Installing Docker on Alpine Linux..."
            apk update
            apk add docker docker-compose docker-cli-compose
            if command -v rc-update >/dev/null 2>&1; then
                rc-update add docker boot
                rc-service docker start
            fi
        elif [[ -z "${CN}" || "${CN}" != true ]]; then
            if ! run_linuxmirrors_docker_installer "https://raw.githubusercontent.com/SuperManito/LinuxMirrors/main/DockerInstallation.sh" \
                --source download.docker.com \
                --source-registry registry.hub.docker.com \
                --protocol http \
                --install-latest true \
                --close-firewall true \
                --ignore-backup-tips; then
                exit 1
            fi
        else
            if ! run_linuxmirrors_docker_installer "https://gitee.com/SuperManito/LinuxMirrors/raw/main/DockerInstallation.sh" \
                --source mirrors.tencent.com/docker-ce \
                --source-registry registry.hub.docker.com \
                --protocol http \
                --install-latest true \
                --close-firewall true \
                --ignore-backup-tips; then
                exit 1
            fi
        fi
    fi
    if ! command -v docker-compose >/dev/null 2>&1; then
        if [[ "$SYSTEM" == "Alpine" ]]; then
            _yellow "docker-compose should already be installed with docker package on Alpine"
        elif [[ "$SYSTEM" == "Arch" ]]; then
            _yellow "Installing docker-compose via pacman"
            ${PACKAGE_INSTALL[int]} docker-compose
        elif [[ -z "${CN}" || "${CN}" != true ]]; then
            _yellow "Installing docker-compose"
            if ! curl -fL "${cdn_success_url}https://github.com/docker/compose/releases/latest/download/docker-compose-linux-$(uname -m)" -o /usr/local/bin/docker-compose; then
                _red "Failed to download docker-compose"
                _red "下载 docker-compose 失败"
                exit 1
            fi
            chmod +x /usr/local/bin/docker-compose
            if ! docker-compose --version; then
                _red "docker-compose installation verification failed"
                _red "docker-compose 安装校验失败"
                exit 1
            fi
        fi
    fi
    local daemon_json="/etc/docker/daemon.json"
    if [ ! -f "$daemon_json" ]; then
        mkdir -p /etc/docker
        echo "{}" > "$daemon_json"
    fi
    local temp_json=$(mktemp)
    storage_driver="overlay2"
    if [ "$need_disk_limit" = "true" ] && [ -f /usr/local/bin/docker_storage_driver ]; then
        storage_driver=$(cat /usr/local/bin/docker_storage_driver)
    fi
    jq --arg driver "$storage_driver" '.["storage-driver"] = $driver' "$daemon_json" > "$temp_json" && mv "$temp_json" "$daemon_json"
    if [ "$need_disk_limit" = "true" ] && [ "$storage_driver" = "btrfs" ] && [ "$docker_install_path" != "/var/lib/docker" ]; then
        temp_json=$(mktemp)
        jq --arg path "$docker_install_path" '.["data-root"] = $path' "$daemon_json" > "$temp_json" && mv "$temp_json" "$daemon_json"
    fi
    if [ "$need_disk_limit" = "true" ] && [ "$storage_driver" = "btrfs" ]; then
        _green "Docker storage driver set to btrfs with disk limitation support"
        _green "Docker存储驱动设置为btrfs，支持磁盘限制功能"
    else
        _green "Docker storage driver set to $storage_driver (standard installation)"
        _green "Docker存储驱动设置为$storage_driver（标准安装）"
    fi
    sleep 1
}

adapt_ipv6() {
    local uplink
    uplink=$(docker_ipv6_uplink_interface 2>/dev/null || true)
    [[ -n "$uplink" ]] || {
        _yellow "Could not determine the IPv6 uplink; leaving host network configuration unchanged"
        return 1
    }

    # Do not rewrite cloud-init, ifupdown, NetworkManager, systemd-networkd,
    # addresses, routes, or link-local IPv6 state. Forwarding requires
    # accept_ra=2 only on the actual IPv6 uplink so SLAAC routes survive.
    if ! update_docker_ipv6_sysctl "net.ipv6.conf.all.forwarding=1" || \
       ! update_docker_ipv6_sysctl "net.ipv6.conf.${uplink}.accept_ra=2"; then
        _yellow "Could not enable IPv6 forwarding without changing host network files"
        return 1
    fi
    printf "%s\n" "$uplink" > /usr/local/bin/docker_ipv6_uplink
    _green "Configured Docker IPv6 forwarding without modifying host network files"
    _green "已配置 Docker IPv6 转发，未改写宿主机网络配置文件"
    return 0
}

docker_build_ipv6() {
    local public_parent public_parent_prefix network_mode existing_subnet

    check_ipv6
    public_parent="$IPV6_CIDR"
    if [[ -z "$public_parent" ]]; then
        _yellow "No locally bound public IPv6 CIDR found; independent IPv6 remains disabled"
        return 0
    fi
    if ! adapt_ipv6; then
        return 1
    fi

    if docker network inspect ipv6_net >/dev/null 2>&1; then
        network_mode=$(tr -d "[:space:]" </usr/local/bin/docker_ipv6_network_mode 2>/dev/null || true)
        case "$network_mode" in
            nat)
                existing_subnet=$(docker_ipv6_network_ipv6_subnet 2>/dev/null || true)
                if ! docker_ipv6_ula_state_matches_network "$network_mode" "$(tr -d "[:space:]" </usr/local/bin/docker_ipv6_subnet 2>/dev/null || true)" "$existing_subnet"; then
                    _yellow "Existing ipv6_net does not match installer NAT66 state; preserving it unchanged"
                    return 1
                fi
                configure_docker_ipv6_nat66 "$existing_subnet" || return 1
                printf "%s\n" "$public_parent" > /usr/local/bin/docker_ipv6_public_parent
                install_docker_ipv6_nat66_service
                printf "%s\n" 1 > /usr/local/bin/docker_build_ipv6
                return 0
                ;;
            manual)
                if ! create_docker_manual_ipv6_network "$public_parent"; then
                    return 1
                fi
                if ! start_docker_manual_ndpresponder; then
                    _yellow "Routed Docker IPv6 network is ready, but NDP responder is not ready for public attachment"
                    return 1
                fi
                printf "%s\n" 1 > /usr/local/bin/docker_build_ipv6
                return 0
                ;;
            *)
                _yellow "Existing ipv6_net is not installer-managed; preserving it and skipping IPv6 migration"
                _yellow "现有 ipv6_net 不属于安装器管理范围，保留现状并跳过 IPv6 迁移"
                return 1
                ;;
        esac
    fi

    public_parent_prefix=$(ipv6_cidr_prefix_length "$public_parent" 2>/dev/null || true)
    if [[ ! "$public_parent_prefix" =~ ^[0-9]+$ ]]; then
        _yellow "Could not parse the local public IPv6 CIDR: $public_parent"
        return 1
    fi
    if (( public_parent_prefix == 128 )); then
        _yellow "Host IPv6 is a lone /128; using isolated ULA NAT66 for outbound IPv6"
        if ! create_docker_ula_ipv6_network "$public_parent"; then
            _yellow "Could not create Docker ULA NAT66 network"
            return 1
        fi
        printf "%s\n" 1 > /usr/local/bin/docker_build_ipv6
        return 0
    fi

    if ! create_docker_manual_ipv6_network "$public_parent"; then
        _yellow "Could not prepare routed public IPv6; falling back to isolated ULA NAT66"
        if ! create_docker_ula_ipv6_network "$public_parent"; then
            _yellow "Could not create Docker ULA NAT66 fallback network"
            return 1
        fi
        printf "%s\n" 1 > /usr/local/bin/docker_build_ipv6
        return 0
    fi
    if ! start_docker_manual_ndpresponder; then
        _yellow "Routed Docker IPv6 waits for a healthy NDP responder before public addresses are attached"
        return 1
    fi
    printf "%s\n" 1 > /usr/local/bin/docker_build_ipv6
    return 0
}

check_and_adapt_ipv6() {
    if ! command -v docker >/dev/null 2>&1; then
        _yellow "Docker is not ready; skipping independent IPv6 setup"
        return 1
    fi
    docker_build_ipv6
}

setup_dns_check() {
    if [ ! -f "/usr/local/bin/check-dns.sh" ]; then
        if ! wget "${cdn_success_url}https://raw.githubusercontent.com/oneclickvirt/docker/main/extra_scripts/check-dns.sh" -O /usr/local/bin/check-dns.sh; then
            _yellow "Failed to download check-dns.sh, skipping DNS keepalive service setup."
            _yellow "下载 check-dns.sh 失败，跳过 DNS 保活服务配置。"
            rm -f /usr/local/bin/check-dns.sh
            return
        fi
        chmod +x /usr/local/bin/check-dns.sh
        if command -v systemctl >/dev/null 2>&1; then
            if ! wget "${cdn_success_url}https://raw.githubusercontent.com/oneclickvirt/docker/main/extra_scripts/check-dns.service" -O /etc/systemd/system/check-dns.service; then
                _yellow "Failed to download check-dns.service, skipping systemd DNS keepalive service setup."
                _yellow "下载 check-dns.service 失败，跳过 systemd DNS 保活服务配置。"
                rm -f /etc/systemd/system/check-dns.service
                return
            fi
            chmod +x /etc/systemd/system/check-dns.service
            systemctl daemon-reload
            systemctl enable check-dns.service
            systemctl start check-dns.service
        elif command -v rc-update >/dev/null 2>&1; then
            _yellow "Alpine uses OpenRC, DNS check service needs manual setup if required"
        fi
    fi
}

ensure_docker_ready() {
    local attempt
    if command -v systemctl >/dev/null 2>&1; then
        systemctl restart docker 2>/dev/null || true
    elif command -v rc-service >/dev/null 2>&1; then
        rc-service docker restart 2>/dev/null || true
    fi
    for attempt in 1 2 3 4 5; do
        if docker info >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    _yellow "Docker daemon is not ready; independent IPv6 setup was skipped"
    return 1
}

cleanup_and_finish() {
    rm -f /usr/local/bin/ifupdown_installed.txt
    _green "Docker environment installed. IPv6 setup did not rewrite host network files or require a host reboot."
    _green "Docker 环境已安装。IPv6 配置未改写宿主网络文件，也不需要重启宿主机。"
}

main() {
    install_docker_and_compose
    if ensure_docker_ready; then
        check_and_adapt_ipv6 || _yellow "Independent IPv6 was not enabled; IPv4 NAT and port mappings remain available"
    else
        _yellow "Docker is unavailable after installation; skip independent IPv6 setup"
    fi
    setup_dns_check
    cleanup_and_finish
}

main
