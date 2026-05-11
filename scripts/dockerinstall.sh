#!/bin/bash
# from
# https://github.com/oneclickvirt/docker
# 2026.02.28

_red() { echo -e "\033[31m\033[01m$@\033[0m"; }
_green() { echo -e "\033[32m\033[01m$@\033[0m"; }
_yellow() { echo -e "\033[33m\033[01m$@\033[0m"; }
_blue() { echo -e "\033[36m\033[01m$@\033[0m"; }
reading() { read -rp "$(_green "$1")" "$2"; }
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
#   WITHOUTCDN=true          - 禁用 CDN 加速
#   CN=true                  - 强制使用中国镜像源
#   CN=false                 - 强制不使用中国镜像源（跳过检测）
#   IPV6_MAXIMUM_SUBSET=y/n  - 是否使用 IPv6 最大子网范围（SLAAC 场景）
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
touch /etc/cloud/cloud-init.disabled

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
    if [ -d "$mount_point" ] && [ "$(ls -A $mount_point 2>/dev/null)" ]; then
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

rebuild_cloud_init() {
    if [ -f "/etc/cloud/cloud.cfg" ]; then
        chattr -i /etc/cloud/cloud.cfg
        if grep -q "preserve_hostname: true" "/etc/cloud/cloud.cfg"; then
            :
        else
            # 检测 sed 是否支持 -E 选项
            if echo "test" | sed -E 's/test/test/' >/dev/null 2>&1; then
                sed -E -i 's/preserve_hostname:[[:space:]]*false/preserve_hostname: true/g' "/etc/cloud/cloud.cfg"
            else
                # BusyBox 兼容方法，使用基本正则表达式
                sed -i 's/preserve_hostname:[[:space:]]*false/preserve_hostname: true/g' "/etc/cloud/cloud.cfg"
            fi
            echo "change preserve_hostname to true"
        fi
        if grep -q "disable_root: false" "/etc/cloud/cloud.cfg"; then
            :
        else
            # 检测 sed 是否支持 -E 选项
            if echo "test" | sed -E 's/test/test/' >/dev/null 2>&1; then
                sed -E -i 's/disable_root:[[:space:]]*true/disable_root: false/g' "/etc/cloud/cloud.cfg"
            else
                # BusyBox 兼容方法，使用基本正则表达式
                sed -i 's/disable_root:[[:space:]]*true/disable_root: false/g' "/etc/cloud/cloud.cfg"
            fi
            echo "change disable_root to false"
        fi
        chattr -i /etc/cloud/cloud.cfg
        content=$(cat /etc/cloud/cloud.cfg)
        line_number=$(grep -n "^system_info:" "/etc/cloud/cloud.cfg" | cut -d ':' -f 1)
        if [ -n "$line_number" ]; then
            lines_after_system_info=$(echo "$content" | sed -n "$((line_number + 1)),\$p")
            if [ -n "$lines_after_system_info" ]; then
                updated_content=$(echo "$content" | sed "$((line_number + 1)),\$d")
                echo "$updated_content" >"/etc/cloud/cloud.cfg"
            fi
        fi
        sed -i '/^\s*- set-passwords/s/^/#/' /etc/cloud/cloud.cfg
        chattr +i /etc/cloud/cloud.cfg
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
    local address=$1
    local temp="0"
    if [[ ! -n $address ]]; then
        temp="1"
    fi
    if [[ -n $address && $address != *":"* ]]; then
        temp="2"
    fi
    if [[ $address == fe80:* ]]; then
        temp="3"
    fi
    if [[ $address == fc00:* || $address == fd00:* ]]; then
        temp="4"
    fi
    if [[ $address == 2001:db8* ]]; then
        temp="5"
    fi
    if [[ $address == ::1 ]]; then
        temp="6"
    fi
    if [[ $address == ::ffff:* ]]; then
        temp="7"
    fi
    if [[ $address == 2002:* ]]; then
        temp="8"
    fi
    # 仅匹配 Teredo 隧道地址 2001:0000::/32，不影响其他合法公网 2001: 地址
    if [[ $address == 2001:0000:* || $address == 2001:0:* ]]; then
        temp="9"
    fi
    if [ "$temp" -gt 0 ]; then
        return 0
    else
        return 1
    fi
}

check_ipv6() {
    IPV6=$(ip -6 addr show | grep global | awk '{print length, $2}' | sort -nr | head -n 1 | awk '{print $2}' | cut -d '/' -f1)
    if [ ! -f /usr/local/bin/docker_last_ipv6 ] || [ ! -s /usr/local/bin/docker_last_ipv6 ] || [ "$(sed -e '/^[[:space:]]*$/d' /usr/local/bin/docker_last_ipv6)" = "" ]; then
        ipv6_list=$(ip -6 addr show | grep global | awk '{print length, $2}' | sort -nr | awk '{print $2}')
        line_count=$(echo "$ipv6_list" | wc -l)
        if [ "$line_count" -ge 2 ]; then
            last_ipv6=$(echo "$ipv6_list" | tail -n 1)
            last_ipv6_prefix="${last_ipv6%:*}:"
            if [ "${last_ipv6_prefix}" = "${ipv6_gateway%:*}:" ]; then
                echo $last_ipv6 >/usr/local/bin/docker_last_ipv6
            fi
            _green "The local machine is bound to more than one IPV6 address"
            _green "本机绑定了不止一个IPV6地址"
        fi
    fi
    if is_private_ipv6 "$IPV6"; then
        IPV6=""
        API_NET=("ipv6.ip.sb" "https://ipget.net" "ipv6.ping0.cc" "https://api.my-ip.io/ip" "https://ipv6.icanhazip.com")
        for p in "${API_NET[@]}"; do
            response=$(curl -sLk6m8 "$p" | tr -d '[:space:]')
            if [ $? -eq 0 ] && ! (echo "$response" | grep -q "error"); then
                IPV6="$response"
                break
            fi
            sleep 1
        done
    fi
    echo $IPV6 >/usr/local/bin/docker_check_ipv6
}

check_cdn() {
    local o_url=$1
    local shuffled_cdn_urls=($(shuf -e "${cdn_urls[@]}"))
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
    "armv7l" | "armv8" | "armv8l" | "aarch64")
        system_arch="arch"
        ;;
    *)
        system_arch=""
        ;;
    esac
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
            read -e -r -p "是否选用中国镜像完成相关组件安装? ([y]/n) " input
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

update_sysctl() {
    sysctl_config="$1"
    key="${sysctl_config%%=*}"
    value="${sysctl_config#*=}"
    custom_conf="/etc/sysctl.d/99-custom.conf"
    mkdir -p /etc/sysctl.d
    use_etc_sysctl_conf=false
    if [ -f /etc/sysctl.conf ]; then
        if grep -q "/etc/sysctl.conf" /etc/sysctl.d/README* 2>/dev/null || \
           grep -q "/etc/sysctl.conf" /lib/systemd/system/sysctl.service 2>/dev/null; then
            use_etc_sysctl_conf=true
        fi
    fi
    if grep -q "^$sysctl_config" "$custom_conf" 2>/dev/null; then
        :
    elif grep -q "^#$sysctl_config" "$custom_conf" 2>/dev/null; then
        sed -i "s/^#$sysctl_config/$sysctl_config/" "$custom_conf"
    elif grep -q "^$key" "$custom_conf" 2>/dev/null; then
        sed -i "s|^$key.*|$sysctl_config|" "$custom_conf"
    else
        echo "$sysctl_config" >> "$custom_conf"
    fi
    if [ "$use_etc_sysctl_conf" = true ]; then
        if grep -q "^$sysctl_config" /etc/sysctl.conf; then
            :
        elif grep -q "^#$sysctl_config" /etc/sysctl.conf; then
            sed -i "s/^#$sysctl_config/$sysctl_config/" /etc/sysctl.conf
        elif grep -q "^$key" /etc/sysctl.conf; then
            sed -i "s|^$key.*|$sysctl_config|" /etc/sysctl.conf
        else
            echo "$sysctl_config" >> /etc/sysctl.conf
        fi
    fi
    sysctl -w "$key=$value" >/dev/null 2>&1
}

if [ ! -d /usr/local/bin ]; then
    mkdir -p /usr/local/bin
fi
rebuild_cloud_init
statistics_of_run_times
_green "脚本当天运行次数:${TODAY}，累计运行次数:${TOTAL}"
check_update
if ! command -v sudo >/dev/null 2>&1; then
    _yellow "Installing sudo"
    ${PACKAGE_INSTALL[int]} sudo
fi
if ! command -v curl >/dev/null 2>&1; then
    _yellow "Installing curl"
    ${PACKAGE_INSTALL[int]} curl
fi
if ! command -v wget >/dev/null 2>&1; then
    _yellow "Installing wget"
    ${PACKAGE_INSTALL[int]} wget
fi
if ! command -v jq >/dev/null 2>&1; then
    _yellow "Installing jq"
    ${PACKAGE_INSTALL[int]} jq
fi
if ! command -v dos2unix >/dev/null 2>&1; then
    _yellow "Installing dos2unix"
    ${PACKAGE_INSTALL[int]} dos2unix
fi
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
if [[ "$SYSTEM" == "CentOS" ]] && ! command -v sipcalc >/dev/null 2>&1; then
    ARCH=$(uname -m)
    if [[ "$ARCH" == "x86_64" ]]; then
        REL_PATH="x86_64/Packages/s/sipcalc-1.1.6-17.el8.x86_64.rpm"
    elif [[ "$ARCH" == "aarch64" ]]; then
        REL_PATH="aarch64/Packages/s/sipcalc-1.1.6-17.el8.aarch64.rpm"
    else
        echo "Unsupported architecture: $ARCH"
        exit 1
    fi
    FILENAME=$(basename "$REL_PATH")
    MIRRORS=(
        "https://dl.fedoraproject.org/pub/epel/8/Everything/$REL_PATH"
        "https://mirrors.aliyun.com/epel/8/Everything/$REL_PATH"
        "https://repo.huaweicloud.com/epel/8/Everything/$REL_PATH"
        "https://mirrors.tuna.tsinghua.edu.cn/epel/8/Everything/$REL_PATH"
    )
    echo "rpm detected — installing sipcalc from EPEL ($ARCH)"
    for URL in "${MIRRORS[@]}"; do
        echo "Trying $URL"
        if curl -fLO "$URL"; then
            echo "Downloaded sipcalc from: $URL"
            break
        else
            echo "Failed to download from: $URL"
        fi
    done
    if command -v dnf >/dev/null 2>&1; then
        dnf install -y "./$FILENAME"
    else
        yum install -y "./$FILENAME"
    fi
    rm -f "./$FILENAME"
    if ! command -v sipcalc >/dev/null 2>&1; then
        ${PACKAGE_INSTALL[int]} epel-release
        echo "sipcalc not found after install, trying fallback package installation..."
        ${PACKAGE_INSTALL[int]} sipcalc
    fi
elif [[ "$SYSTEM" != "Alpine" ]] && ! command -v sipcalc >/dev/null 2>&1; then
    ${PACKAGE_INSTALL[int]} sipcalc
fi
if [[ "$SYSTEM" == "Alpine" ]] && ! command -v sipcalc >/dev/null 2>&1; then
    _yellow "Alpine does not have sipcalc in official repos, will use ipcalc for calculations"
fi
if ! command -v bc >/dev/null 2>&1; then
    _yellow "Installing bc"
    ${PACKAGE_INSTALL[int]} bc
fi
if ! command -v ip >/dev/null 2>&1; then
    _yellow "Installing iproute2"
    ${PACKAGE_INSTALL[int]} iproute2
fi
if ! command -v rdisc6 >/dev/null 2>&1; then
    _blue "Installing ndisc6 package for IPv6 router discovery..."
    _green "正在安装 ndisc6 软件包用于 IPv6 路由器发现..."
    if [[ "$SYSTEM" == "Alpine" ]]; then
        ${PACKAGE_INSTALL[int]} ndisc6 || _yellow "ndisc6 not available on Alpine, skipping IPv6 router discovery"
    else
        ${PACKAGE_INSTALL[int]} ndisc6 || _yellow "Failed to install ndisc6, IPv6 router discovery will be skipped"
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
if ! command -v fallocate >/dev/null 2>&1; then
    _yellow "Installing util-linux"
    ${PACKAGE_INSTALL[int]} util-linux
fi
${PACKAGE_INSTALL[int]} net-tools
check_china
cdn_urls=("https://cdn0.spiritlhl.top/" "http://cdn1.spiritlhl.net/" "http://cdn2.spiritlhl.net/" "http://cdn3.spiritlhl.net/" "http://cdn4.spiritlhl.net/")
if [[ "$without_cdn" == "true" ]]; then
    cdn_success_url=""
else
    check_cdn_file
fi
get_system_arch
${PACKAGE_INSTALL[int]} openssl
curl -Lk ${cdn_success_url}https://raw.githubusercontent.com/oneclickvirt/docker/main/scripts/ssh_bash.sh -o ssh_bash.sh && chmod +x ssh_bash.sh && dos2unix ssh_bash.sh
curl -Lk ${cdn_success_url}https://raw.githubusercontent.com/oneclickvirt/docker/main/scripts/ssh_sh.sh -o ssh_sh.sh && chmod +x ssh_sh.sh && dos2unix ssh_sh.sh

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

if [ ! -f /usr/local/bin/docker_ipv6_prefixlen ] || [ ! -s /usr/local/bin/docker_ipv6_prefixlen ] || [ "$(sed -e '/^[[:space:]]*$/d' /usr/local/bin/docker_ipv6_prefixlen)" = "" ]; then
    ipv6_prefixlen=""
    if command -v ifconfig >/dev/null 2>&1; then
        # 检测 grep 是否支持 -P 选项
        if echo "test" | grep -P "test" >/dev/null 2>&1; then
            output=$(ifconfig ${interface} | grep -oP 'inet6 (?!fe80:).*prefixlen \K\d+')
        else
            # BusyBox 兼容方法
            output=$(ifconfig ${interface} | grep 'inet6' | grep -v 'fe80:' | sed -n 's/.*prefixlen \([0-9]*\).*/\1/p')
        fi
    else
        output=$(ip -6 addr show ${interface} | grep 'inet6' | grep -v 'fe80:' | awk '{print $2}' | cut -d'/' -f2)
    fi
    num_lines=$(echo "$output" | wc -l)
    if [ $num_lines -ge 2 ]; then
        ipv6_prefixlen=$(echo "$output" | sort -n | head -n 1)
    else
        ipv6_prefixlen=$(echo "$output" | head -n 1)
    fi
    if command -v rdisc6 >/dev/null 2>&1 && [ ! -f /usr/local/bin/docker_ipv6_real_prefixlen ]; then
        _blue "Attempting to get real IPv6 prefix from router advertisement..."
        _green "尝试从路由器通告中获取真实的 IPv6 前缀..."
        _blue "Using network interface: ${interface}"
        _green "正在使用网络接口: ${interface}"
        rdisc6_output=$(timeout 10 rdisc6 ${interface} 2>/dev/null)
        if [ -n "$rdisc6_output" ]; then
            # 检测 grep 是否支持 -P 选项
            if echo "test" | grep -P "test" >/dev/null 2>&1; then
                real_prefixlen=$(echo "$rdisc6_output" | grep -i "Prefix" | grep -oP '[:：]\s*[0-9a-fA-F:]+/\K\d+' | head -n 1)
            else
                # BusyBox 兼容方法
                real_prefixlen=$(echo "$rdisc6_output" | grep -i "Prefix" | sed -n 's/.*[:：][[:space:]]*[0-9a-fA-F:]*\/\([0-9]*\).*/\1/p' | head -n 1)
            fi
            if [ -n "$real_prefixlen" ] && [ "$real_prefixlen" -gt 0 ] && [ "$real_prefixlen" -le 128 ]; then
                _green "Found real IPv6 prefix length from router advertisement: /$real_prefixlen"
                _green "从路由器通告中发现真实的 IPv6 前缀长度: /$real_prefixlen"
                if [ -n "$ipv6_prefixlen" ] && [ "$ipv6_prefixlen" -gt "$real_prefixlen" ]; then
                    _yellow "Warning: Current interface prefix /$ipv6_prefixlen is smaller than router advertised /$real_prefixlen"
                    _yellow "警告: 当前接口前缀 /$ipv6_prefixlen 小于路由器通告的 /$real_prefixlen"
                    _blue "Using the larger prefix /$real_prefixlen from router advertisement"
                    _green "将使用路由器通告的更大前缀 /$real_prefixlen"
                    ipv6_prefixlen="$real_prefixlen"
                elif [ -z "$ipv6_prefixlen" ]; then
                    ipv6_prefixlen="$real_prefixlen"
                fi
                echo "$real_prefixlen" >/usr/local/bin/docker_ipv6_real_prefixlen
            else
                _yellow "Could not parse IPv6 prefix length on interface ${interface}"
                _yellow "无法从接口 ${interface} 中解析 IPv6 前缀长度"
            fi
        else
            _yellow "Could not get router advertisement response on interface ${interface} (timeout or no response)"
            _yellow "无法在接口 ${interface} 获取路由器通告响应(超时或无响应)"
        fi
    fi
    
    echo "$ipv6_prefixlen" >/usr/local/bin/docker_ipv6_prefixlen
fi
if [ -f /usr/local/bin/docker_ipv6_real_prefixlen ] && [ -s /usr/local/bin/docker_ipv6_real_prefixlen ]; then
    real_prefixlen=$(cat /usr/local/bin/docker_ipv6_real_prefixlen)
    ipv6_prefixlen="$real_prefixlen"
    _blue "Using real IPv6 prefix length: /$ipv6_prefixlen"
    _green "检测到的真实 IPv6 前缀长度: /$ipv6_prefixlen"
    echo "$ipv6_prefixlen" >/usr/local/bin/docker_ipv6_prefixlen
else
    ipv6_prefixlen=$(cat /usr/local/bin/docker_ipv6_prefixlen)
fi
if [ ! -f /usr/local/bin/docker_ipv6_gateway ] || [ ! -s /usr/local/bin/docker_ipv6_gateway ] || [ "$(sed -e '/^[[:space:]]*$/d' /usr/local/bin/docker_ipv6_gateway)" = "" ]; then
    output=$(ip -6 route show | awk '/default via/{print $3}')
    num_lines=$(echo "$output" | wc -l)
    ipv6_gateway=""
    if [ $num_lines -eq 1 ]; then
        ipv6_gateway="$output"
    elif [ $num_lines -ge 2 ]; then
        non_fe80_lines=$(echo "$output" | grep -v '^fe80')
        if [ -n "$non_fe80_lines" ]; then
            ipv6_gateway=$(echo "$non_fe80_lines" | head -n 1)
        else
            ipv6_gateway=$(echo "$output" | head -n 1)
        fi
    fi
    echo "$ipv6_gateway" >/usr/local/bin/docker_ipv6_gateway
    if [[ $ipv6_gateway == fe80* ]]; then
        ipv6_gateway_fe80="Y"
    else
        ipv6_gateway_fe80="N"
    fi
fi
if [ ! -f /usr/local/bin/docker_check_ipv6 ] || [ ! -s /usr/local/bin/docker_check_ipv6 ] || [ "$(sed -e '/^[[:space:]]*$/d' /usr/local/bin/docker_check_ipv6)" = "" ]; then
    check_ipv6
fi
if [ ! -f /usr/local/bin/docker_fe80_address ] || [ ! -s /usr/local/bin/docker_fe80_address ] || [ "$(sed -e '/^[[:space:]]*$/d' /usr/local/bin/docker_fe80_address)" = "" ]; then
    fe80_address=$(ip -6 addr show dev $interface | awk '/inet6 fe80/ {print $2}')
    echo "$fe80_address" >/usr/local/bin/docker_fe80_address
fi
ipv6_address=$(cat /usr/local/bin/docker_check_ipv6)
ipv6_prefixlen=$(cat /usr/local/bin/docker_ipv6_prefixlen)
ipv6_gateway=$(cat /usr/local/bin/docker_ipv6_gateway)
fe80_address=$(cat /usr/local/bin/docker_fe80_address)
if [[ -n "$ipv6_address" ]]; then 
    ipv6_address_without_last_segment="${ipv6_address%:*}:"
    mac_end_suffix=$(echo $mac_address | awk -F: '{print $4$5}')
    ipv6_end_suffix=${ipv6_address##*:}
    slaac_status=false
    if [[ $ipv6_address == *"ff:fe"* ]]; then
        _blue "Since the IPV6 address contains the ff:fe block, the probability is that the IPV6 address assigned out through SLAAC"
        _green "由于IPV6地址含有ff:fe块，大概率通过SLAAC分配出的IPV6地址"
        slaac_status=true
    elif [[ $ipv6_gateway == "fe80"* ]]; then
        _blue "Since IPV6 gateways begin with fe80, it is generally assumed that IPV6 addresses assigned through the SLAAC"
        _green "由于IPV6的网关是fe80开头，一般认为通过SLAAC分配出的IPV6地址"
        slaac_status=true
    elif [[ $ipv6_end_suffix == $mac_end_suffix ]]; then
        _blue "Since IPV6 addresses have the same suffix as mac addresses, the probability is that the IPV6 address assigned through the SLAAC"
        _green "由于IPV6的地址和mac地址后缀相同，大概率通过SLAAC分配出的IPV6地址"
        slaac_status=true
    fi
    if [[ $slaac_status == true ]] && [ ! -f /usr/local/bin/docker_slaac_status ]; then
        _blue "Since IPV6 addresses are assigned via SLAAC, the subsequent one-click script installation process needs to determine whether to use the largest subnet"
        _blue "If using the largest subnet make sure that the host is assigned an entire subnet and not just an IPV6 address"
        _blue "It is not possible to determine within the host computer how large a subnet the upstream has given to this machine, please ask the upstream technician for details."
        _green "由于是通过SLAAC分配出IPV6地址，所以后续一键脚本安装过程中需要判断是否使用最大子网"
        _green "若使用最大子网请确保宿主机被分配的是整个子网而不是仅一个IPV6地址"
        _green "无法在宿主机内部判断上游给了本机多大的子网，详情请询问上游技术人员"
        echo "" >/usr/local/bin/docker_slaac_status
    fi
    if [ -f /usr/local/bin/docker_slaac_status ] && [ ! -f /usr/local/bin/docker_maximum_subset ] && [ ! -f /usr/local/bin/fix_interfaces_ipv6_auto_type ]; then
        _blue "It is detected that IPV6 addresses are most likely to be dynamically assigned by SLAAC, and if there is no subsequent need to assign separate IPV6 addresses to VMs/containers, the following option is best selected n"
        _green "检测到IPV6地址大概率由SLAAC动态分配，若后续不需要分配独立的IPV6地址给虚拟机/容器，则下面选项最好选 n, 选择 y 有概率导致宿主机丢失网络"
        _blue "Is the maximum subnet range feasible with IPV6 used?([n]/y)"
        if [[ "${IPV6_MAXIMUM_SUBSET^^}" == "Y" || "${IPV6_MAXIMUM_SUBSET^^}" == "TRUE" ]]; then
            _yellow "IPV6_MAXIMUM_SUBSET=${IPV6_MAXIMUM_SUBSET} detected, using maximum IPv6 subnet"
            select_maximum_subset="y"
        elif [[ "${IPV6_MAXIMUM_SUBSET^^}" == "N" || "${IPV6_MAXIMUM_SUBSET^^}" == "FALSE" ]]; then
            _yellow "IPV6_MAXIMUM_SUBSET=${IPV6_MAXIMUM_SUBSET} detected, skipping maximum IPv6 subnet"
            select_maximum_subset="n"
        else
            reading "是否使用IPV6可行的最大子网范围？([n]/y)" select_maximum_subset
        fi
        if [ "$select_maximum_subset" = "y" ] || [ "$select_maximum_subset" = "Y" ]; then
            echo "true" >/usr/local/bin/docker_maximum_subset
        else
            echo "false" >/usr/local/bin/docker_maximum_subset
        fi
        echo "" >/usr/local/bin/fix_interfaces_ipv6_auto_type
    fi
    if [ ! -f /usr/local/bin/docker_maximum_subset ] || [ $(cat /usr/local/bin/docker_maximum_subset) = true ]; then
        ipv6_address_without_last_segment="${ipv6_address%:*}:"
        if [[ $ipv6_address != *:: && $ipv6_address_without_last_segment != *:: ]]; then
            # 检测 sipcalc 是否可用
            if command -v sipcalc >/dev/null 2>&1; then
                ipv6_address=$(sipcalc -i ${ipv6_address}/${ipv6_prefixlen} | grep "Subnet prefix (masked)" | cut -d ' ' -f 4 | cut -d '/' -f 1 | sed 's/:0:0:0:0:/::/' | sed 's/:0:0:0:/::/')
                ipv6_address="${ipv6_address%:*}:1"
                if [ "$ipv6_address" == "$ipv6_gateway" ]; then
                    ipv6_address="${ipv6_address%:*}:2"
                fi
                ipv6_address_without_last_segment="${ipv6_address%:*}:"
                if ping -c 1 -6 -W 3 $ipv6_address >/dev/null 2>&1; then
                    check_ipv6
                    ipv6_address=$(cat /usr/local/bin/docker_check_ipv6)
                    echo "${ipv6_address}" >/usr/local/bin/docker_check_ipv6
                fi
            else
                _yellow "sipcalc command not found, skipping IPv6 subnet calculation"
                _yellow "sipcalc 命令不存在，跳过 IPv6 子网计算"
            fi
        elif [[ $ipv6_address == *:: ]]; then
            ipv6_address="${ipv6_address}1"
            if [ "$ipv6_address" == "$ipv6_gateway" ]; then
                ipv6_address="${ipv6_address%:*}:2"
            fi
            echo "${ipv6_address}" >/usr/local/bin/docker_check_ipv6
        fi
    fi
fi
_green "Do you need Docker with container disk size limitation? (Support btrfs storage driver)"
_green "是否需要支持容器硬盘大小限制的Docker环境？（支持btrfs存储驱动）"
_blue "If you choose 'y', you can limit the disk space for each container"
_blue "If you choose 'n', standard Docker installation without disk limits"
_blue "如果选择 'y'，可以为每个容器限制磁盘空间"
_blue "如果选择 'n'，则为标准Docker安装，无磁盘限制"
if [[ -n "${NEED_DISK_LIMIT}" ]]; then
    _yellow "NEED_DISK_LIMIT=${NEED_DISK_LIMIT} detected, skipping prompt"
    need_disk_limit="${NEED_DISK_LIMIT}"
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
if [ "$need_disk_limit" = "y" ] || [ "$need_disk_limit" = "Y" ]; then
    echo "true" > /usr/local/bin/docker_need_disk_limit
    if [[ -n "${DOCKER_POOL_SIZE}" ]] && [[ "${DOCKER_POOL_SIZE}" =~ ^[1-9][0-9]*$ ]]; then
        _yellow "DOCKER_POOL_SIZE=${DOCKER_POOL_SIZE} detected, skipping prompt"
        docker_pool_size="${DOCKER_POOL_SIZE}"
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
            bash <(curl -sSL https://raw.githubusercontent.com/SuperManito/LinuxMirrors/main/DockerInstallation.sh) \
                --source download.docker.com \
                --source-registry registry.hub.docker.com \
                --protocol http \
                --install-latest true \
                --close-firewall true \
                --ignore-backup-tips | awk '/脚本运行完毕，更多使用教程详见官网/ {exit} {print}'
        else
            bash <(curl -sSL https://gitee.com/SuperManito/LinuxMirrors/raw/main/DockerInstallation.sh) \
                --source mirrors.tencent.com/docker-ce \
                --source-registry registry.hub.docker.com \
                --protocol http \
                --install-latest true \
                --close-firewall true \
                --ignore-backup-tips | awk '/脚本运行完毕，更多使用教程详见官网/ {exit} {print}'
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
            curl -L "${cdn_success_url}https://github.com/docker/compose/releases/latest/download/docker-compose-linux-$(uname -m)" -o /usr/local/bin/docker-compose
            chmod +x /usr/local/bin/docker-compose
            docker-compose --version
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
    if [ ! -f /usr/local/bin/docker_adapt_ipv6 ]; then
        echo "1" > /usr/local/bin/docker_adapt_ipv6
        if [ ! -z "$ipv6_address" ] && [ ! -z "$ipv6_prefixlen" ] && [ ! -z "$ipv6_gateway" ] && [ ! -z "$ipv6_address_without_last_segment" ] && [ ! -z "$interface" ] && [ ! -z "$ipv4_address" ] && [ ! -z "$ipv4_prefixlen" ] && [ ! -z "$ipv4_gateway" ] && [ ! -z "$ipv4_subnet" ] && [ ! -z "$fe80_address" ]; then
            network_manager=$(cat /usr/local/bin/docker_network_manager)
            case "$network_manager" in
                "systemd-networkd")
                    configure_systemd_networkd
                    ;;
                "NetworkManager")
                    configure_network_manager
                    ;;
                "networking")
                    configure_networking
                    ;;
                *)
                    configure_networking
                    ;;
            esac
            update_sysctl "net.ipv6.conf.all.forwarding=1"
            update_sysctl "net.ipv6.conf.all.proxy_ndp=1"
            update_sysctl "net.ipv6.conf.default.proxy_ndp=1"
            update_sysctl "net.ipv6.conf.docker0.proxy_ndp=1"
            update_sysctl "net.ipv6.conf.${interface}.proxy_ndp=1"
            if [ "$status_he" = true ]; then
                update_sysctl "net.ipv6.conf.he-ipv6.proxy_ndp=1"
            fi
            reboot_message="请重启服务器以启用新的网络配置"
            if [ -f /usr/local/bin/docker_storage_reboot ]; then
                reboot_message="${reboot_message}和存储驱动内核模块"
            fi
            _green "${reboot_message}，重启后等待20秒后请再次执行本脚本"
            exit 1
        fi
    fi
}

configure_systemd_networkd() {
    mkdir -p /etc/systemd/network/
    cat <<EOF > /etc/systemd/network/10-${interface}.network
[Match]
Name=${interface}

[Network]
Address=${ipv4_address}
Gateway=${ipv4_gateway}
DNS=8.8.8.8
DNS=8.8.4.4

Address=${ipv6_address}/${ipv6_prefixlen}
Gateway=${ipv6_gateway}
IPv6AcceptRA=no
IPv6ProxyNDP=yes
IPv6SendRA=yes

[IPv6SendRA]
EmitDNS=yes
DNS=2001:4860:4860::8888
DNS=2606:4700:4700::1111
EOF
    if command -v systemctl >/dev/null 2>&1; then
        systemctl restart systemd-networkd
    fi
}

configure_network_manager() {
    connection_name=$(nmcli -t -f NAME,DEVICE connection show | grep $interface | cut -d':' -f1)
    if [ -z "$connection_name" ]; then
        connection_name="${interface}-connection"
        nmcli connection add type ethernet con-name "$connection_name" ifname $interface
    fi
    nmcli connection modify "$connection_name" ipv4.method manual
    nmcli connection modify "$connection_name" ipv4.addresses $ipv4_address/$ipv4_prefixlen
    nmcli connection modify "$connection_name" ipv4.gateway $ipv4_gateway
    nmcli connection modify "$connection_name" ipv4.dns "8.8.8.8,8.8.4.4"
    nmcli connection modify "$connection_name" ipv6.method manual
    nmcli connection modify "$connection_name" ipv6.addresses $ipv6_address/$ipv6_prefixlen
    nmcli connection modify "$connection_name" ipv6.gateway $ipv6_gateway
    nmcli connection modify "$connection_name" ipv6.dns "2001:4860:4860::8888,2606:4700:4700::1111"
    nmcli connection up "$connection_name"
}

configure_networking() {
    if [[ "$SYSTEM" == "Alpine" ]]; then
        _yellow "Configuring Alpine networking..."
        cat <<EOF >/etc/network/interfaces
auto lo
iface lo inet loopback

auto $interface
iface $interface inet static
        address $ipv4_address
        netmask $ipv4_subnet
        gateway $ipv4_gateway
        dns-nameservers 8.8.8.8 8.8.4.4
EOF
        if [ ! -z "$ipv6_address" ] && [ ! -z "$ipv6_prefixlen" ]; then
            cat <<EOF >>/etc/network/interfaces

iface $interface inet6 static
        address $ipv6_address
        netmask $ipv6_prefixlen
        gateway $ipv6_gateway
EOF
        fi
        if command -v rc-service >/dev/null 2>&1; then
            rc-service networking restart
        fi
        return
    fi
    chattr -i /etc/network/interfaces
    if grep -q "auto he-ipv6" /etc/network/interfaces; then
        status_he=true
        temp_config=$(awk '/auto he-ipv6/{flag=1; print $0; next} flag && flag++<10' /etc/network/interfaces)
        cat <<EOF >/etc/network/interfaces
auto lo
iface lo inet loopback

auto $interface
iface $interface inet static
        address $ipv4_address
        gateway $ipv4_gateway
        netmask $ipv4_subnet
        dns-nameservers 8.8.8.8 8.8.4.4
        up ip addr del $fe80_address dev $interface
EOF
    elif [ -f /usr/local/bin/docker_last_ipv6 ] && [[ "${ipv6_gateway_fe80}" == "Y" ]]; then
        last_ipv6=$(cat /usr/local/bin/docker_last_ipv6)
        cat <<EOF >/etc/network/interfaces
auto lo
iface lo inet loopback

auto $interface
iface $interface inet static
        address $ipv4_address
        gateway $ipv4_gateway
        netmask $ipv4_subnet
        dns-nameservers 8.8.8.8 8.8.4.4

iface $interface inet6 static
        address ${last_ipv6}
        gateway ${ipv6_gateway}
        up sysctl -w "net.ipv6.conf.$interface.proxy_ndp=1"

iface $interface inet6 static
    address $ipv6_address/$ipv6_prefixlen
EOF
    elif [ -f /usr/local/bin/docker_last_ipv6 ] && [[ "${ipv6_gateway_fe80}" == "N" ]]; then
        last_ipv6=$(cat /usr/local/bin/docker_last_ipv6)
        cat <<EOF >/etc/network/interfaces
auto lo
iface lo inet loopback

auto $interface
iface $interface inet static
        address $ipv4_address
        gateway $ipv4_gateway
        netmask $ipv4_subnet
        dns-nameservers 8.8.8.8 8.8.4.4

iface $interface inet6 static
        address ${last_ipv6}
        gateway ${ipv6_gateway}
        up ip addr del $fe80_address dev $interface
        up sysctl -w "net.ipv6.conf.$interface.proxy_ndp=1"

iface $interface inet6 static
    address $ipv6_address/$ipv6_prefixlen
EOF
    else
        if [[ "${ipv6_gateway_fe80}" == "Y" ]]; then
            cat <<EOF >/etc/network/interfaces
auto lo
iface lo inet loopback

auto $interface
iface $interface inet static
        address $ipv4_address
        gateway $ipv4_gateway
        netmask $ipv4_subnet
        dns-nameservers 8.8.8.8 8.8.4.4

iface $interface inet6 static
        address $ipv6_address/$ipv6_prefixlen
        gateway $ipv6_gateway
        up sysctl -w "net.ipv6.conf.$interface.proxy_ndp=1"
EOF
        elif [[ "${ipv6_gateway_fe80}" == "N" ]]; then
            cat <<EOF >/etc/network/interfaces
auto lo
iface lo inet loopback

auto $interface
iface $interface inet static
        address $ipv4_address
        gateway $ipv4_gateway
        netmask $ipv4_subnet
        dns-nameservers 8.8.8.8 8.8.4.4

iface $interface inet6 static
        address $ipv6_address/$ipv6_prefixlen
        gateway $ipv6_gateway
        up ip addr del $fe80_address dev $interface
        up sysctl -w "net.ipv6.conf.$interface.proxy_ndp=1"
EOF
        fi
    fi
    if [ "$status_he" = true ]; then
        chattr -i /etc/network/interfaces
        sudo tee -a /etc/network/interfaces <<EOF
${temp_config}
EOF
    fi
    chattr +i /etc/network/interfaces
}

docker_build_ipv6() {
    if [ -f /usr/local/bin/docker_adapt_ipv6 ]; then
        _green "A new network has been detected that has rebooted the server to configure IPV6 and is testing IPV6 connectivity, please be patient!"
        _green "检测到已重启服务器配置IPV6的新网络，正在测试IPV6的连通性，请耐心等待"
        if [ ! -f /usr/local/bin/docker_build_ipv6 ]; then
            echo "1" >/usr/local/bin/docker_build_ipv6
            # 检测 sipcalc 是否可用
            if ! command -v sipcalc >/dev/null 2>&1; then
                _yellow "sipcalc command not found, IPv6 advanced configuration is not available"
                _yellow "sipcalc 命令不存在，IPv6 高级配置不可用"
                return 1
            fi
            if command -v systemctl >/dev/null 2>&1; then
                systemctl restart networking
            elif command -v rc-service >/dev/null 2>&1; then
                rc-service networking restart
            fi
            sleep 3
            ipv6_address=$(sipcalc -i ${ipv6_address}/${ipv6_prefixlen} | grep "Subnet prefix (masked)" | cut -d ' ' -f 4 | cut -d '/' -f 1 | sed 's/:0:0:0:0:/::/' | sed 's/:0:0:0:/::/')
            ipv6_address="${ipv6_address%:*}:1"
            if [ "$ipv6_address" == "$ipv6_gateway" ]; then
                ipv6_address="${ipv6_address%:*}:2"
            fi
            ipv6_address_without_last_segment="${ipv6_address%:*}:"
            if ping -c 1 -6 -W 3 $ipv6_address >/dev/null 2>&1; then
                check_ipv6
                echo "${ipv6_address}" >/usr/local/bin/docker_check_ipv6
            fi
            target_mask=${ipv6_prefixlen}
            # 确保 target_mask 有值且在合法范围内 [1, 128]
            if [ -z "$target_mask" ] || ! [[ "$target_mask" =~ ^[0-9]+$ ]]; then
                _red "Failed to get IPv6 prefix length"
                _red "无法获取 IPv6 前缀长度"
                return 1
            fi
            if [ "$target_mask" -lt 1 ] || [ "$target_mask" -gt 128 ]; then
                _red "IPv6 prefix length ${target_mask} is out of valid range [1, 128]"
                _red "IPv6 前缀长度 ${target_mask} 超出合法范围 [1, 128]"
                return 1
            fi
            echo "Before: target_mask = $target_mask"
            # 向上取整到下一个8的倍数（用于子网切分）
            # 注意：当 target_mask 已是8的倍数时，需额外加8以获得更细分的子网
            ((target_mask += 8 - (target_mask % 8)))
            # 确保 target_mask 不超过 IPv6 最大前缀长度 128
            if [ "$target_mask" -gt 128 ]; then
                _yellow "Warning: computed target_mask=${target_mask} exceeds IPv6 maximum prefix length 128, capping at 128"
                _yellow "警告: 计算出的 target_mask=${target_mask} 超过 IPv6 最大前缀长度 128，限制为 128"
                target_mask=128
            fi
            # 若 target_mask 不大于 ipv6_prefixlen，则无法进行有效分割
            if [ "$target_mask" -le "$ipv6_prefixlen" ]; then
                _yellow "Cannot split subnet: target_mask (/${target_mask}) must be larger than ipv6_prefixlen (/${ipv6_prefixlen}), skipping split"
                _yellow "无法切分子网：target_mask (/${target_mask}) 必须大于 ipv6_prefixlen (/${ipv6_prefixlen})，跳过切分"
                install_docker_and_compose
                return 0
            fi
            echo "After: target_mask = $target_mask"
            ipv6_subnet_2=$(sipcalc --v6split=${target_mask} ${ipv6_address}/${ipv6_prefixlen} | awk '/Network/{n++} n==2' | awk '{print $3}' | grep -v '^$')
            # 注意：当 ipv6_subnet_2 为空时，"${ipv6_subnet_2%:*}:" 会得到 ":"（非空），
            # 因此必须先检查 ipv6_subnet_2 本身是否为空
            if [ -n "$ipv6_subnet_2" ] && [ -n "$target_mask" ]; then
                ipv6_subnet_2_without_last_segment="${ipv6_subnet_2%:*}:"
                new_subnet="${ipv6_subnet_2}/${target_mask}"
                _green "Use cuted IPV6 subnet：${new_subnet}"
                _green "使用切分出来的IPV6子网：${new_subnet}"
            else
                _red "The ipv6 subnet 2: ${ipv6_subnet_2}"
                _red "The ipv6 target mask: ${target_mask}"
                return 1
            fi
            install_docker_and_compose
            if [ "$ipv6_prefixlen" -le 112 ]; then
                if [ ! -z "$ipv6_address" ] && [ ! -z "$ipv6_prefixlen" ] && [ ! -z "$ipv6_gateway" ] && [ ! -z "$new_subnet" ]; then
                    docker network create --ipv6 --subnet=172.26.0.0/16 --subnet=$new_subnet ipv6_net
                    if [ "$system_arch" = "x86" ]; then
                        if [ "$status_he" = true ]; then
                            docker run -d \
                                --restart always --cpus 0.02 --memory 64M \
                                -v /var/run/docker.sock:/var/run/docker.sock:ro \
                                --cap-drop=ALL --cap-add=NET_RAW --cap-add=NET_ADMIN \
                                --network host --name ndpresponder \
                                spiritlhl/ndpresponder_x86 -i he-ipv6 -N ipv6_net
                        else
                            docker run -d \
                                --restart always --cpus 0.02 --memory 64M \
                                -v /var/run/docker.sock:/var/run/docker.sock:ro \
                                --cap-drop=ALL --cap-add=NET_RAW --cap-add=NET_ADMIN \
                                --network host --name ndpresponder \
                                spiritlhl/ndpresponder_x86 -i ${interface} -N ipv6_net
                        fi
                    elif [ "$system_arch" = "arch" ]; then
                        if [ "$status_he" = true ]; then
                            docker run -d \
                                --restart always --cpus 0.02 --memory 64M \
                                -v /var/run/docker.sock:/var/run/docker.sock:ro \
                                --cap-drop=ALL --cap-add=NET_RAW --cap-add=NET_ADMIN \
                                --network host --name ndpresponder \
                                spiritlhl/ndpresponder_aarch64 -i he-ipv6 -N ipv6_net
                        else
                            docker run -d \
                                --restart always --cpus 0.02 --memory 64M \
                                -v /var/run/docker.sock:/var/run/docker.sock:ro \
                                --cap-drop=ALL --cap-add=NET_RAW --cap-add=NET_ADMIN \
                                --network host --name ndpresponder \
                                spiritlhl/ndpresponder_aarch64 -i ${interface} -N ipv6_net
                        fi
                    fi
                fi
            fi
            if ! command -v radvd >/dev/null 2>&1; then
                _yellow "Installing radvd"
                if [[ "$SYSTEM" == "Alpine" ]]; then
                    ${PACKAGE_INSTALL[int]} radvd
                    if command -v rc-update >/dev/null 2>&1; then
                        rc-update add radvd default
                        rc-service radvd start
                    fi
                else
                    ${PACKAGE_INSTALL[int]} radvd
                fi
            fi
            if [ "$status_he" = true ]; then
                config_content="interface he-ipv6 {
  AdvSendAdvert on;
  MinRtrAdvInterval 3;
  MaxRtrAdvInterval 10;
  prefix ${ipv6_address_without_last_segment}0/$ipv6_prefixlen {
    AdvOnLink on;
    AdvAutonomous on;
    AdvRouterAddr on;
  };
};"
            else
                config_content="interface $interface {
  AdvSendAdvert on;
  MinRtrAdvInterval 3;
  MaxRtrAdvInterval 10;
  prefix ${ipv6_address_without_last_segment}0/$ipv6_prefixlen {
    AdvOnLink on;
    AdvAutonomous on;
    AdvRouterAddr on;
  };
};"
            fi
            echo "$config_content" | sudo tee /etc/radvd.conf >/dev/null
            if command -v systemctl >/dev/null 2>&1; then
                systemctl restart radvd && systemctl enable radvd
            elif command -v rc-service >/dev/null 2>&1; then
                rc-service radvd restart
            fi
            update_sysctl "net.ipv6.conf.all.forwarding=1"
            update_sysctl "net.ipv6.conf.all.proxy_ndp=1"
            update_sysctl "net.ipv6.conf.default.proxy_ndp=1"
            echo '*/1 * * * * curl -m 6 -s ipv6.ip.sb && curl -m 6 -s ipv6.ip.sb' | crontab -
        fi
    fi
}

handle_networking() {
    network_manager=$(cat /usr/local/bin/docker_network_manager)
    case "$network_manager" in
        "systemd-networkd")
            if command -v systemctl >/dev/null 2>&1; then
                systemctl restart systemd-networkd
            fi
            ;;
        "NetworkManager")
            if command -v systemctl >/dev/null 2>&1; then
                systemctl restart NetworkManager
            fi
            ;;
        "networking")
            if command -v systemctl >/dev/null 2>&1; then
                systemctl restart networking
            elif command -v rc-service >/dev/null 2>&1; then
                rc-service networking restart
            fi
            ;;
        *)
            if command -v systemctl >/dev/null 2>&1; then
                systemctl restart networking 2>/dev/null || true
                systemctl restart systemd-networkd 2>/dev/null || true
                systemctl restart NetworkManager 2>/dev/null || true
            elif command -v rc-service >/dev/null 2>&1; then
                rc-service networking restart 2>/dev/null || true
            fi
            ;;
    esac
}

check_and_adapt_ipv6() {
    if [[ -n "$ipv6_address" ]]; then 
        if [ ! -f /usr/local/bin/docker_maximum_subset ] || [ $(cat /usr/local/bin/docker_maximum_subset) = true ]; then
            adapt_ipv6
            docker_build_ipv6
        fi
    fi
}

setup_dns_check() {
    if [ ! -f "/usr/local/bin/check-dns.sh" ]; then
        wget ${cdn_success_url}https://raw.githubusercontent.com/oneclickvirt/docker/main/extra_scripts/check-dns.sh -O /usr/local/bin/check-dns.sh
        chmod +x /usr/local/bin/check-dns.sh
        if command -v systemctl >/dev/null 2>&1; then
            wget ${cdn_success_url}https://raw.githubusercontent.com/oneclickvirt/docker/main/extra_scripts/check-dns.service -O /etc/systemd/system/check-dns.service
            chmod +x /etc/systemd/system/check-dns.service
            systemctl daemon-reload
            systemctl enable check-dns.service
            systemctl start check-dns.service
        elif command -v rc-update >/dev/null 2>&1; then
            _yellow "Alpine uses OpenRC, DNS check service needs manual setup if required"
        fi
    fi
}

detect_network_manager() {
    if command -v systemctl >/dev/null 2>&1; then
        if systemctl is-active --quiet systemd-networkd; then
            network_manager="systemd-networkd"
        elif systemctl is-active --quiet NetworkManager; then
            network_manager="NetworkManager"
        elif systemctl is-active --quiet networking; then
            network_manager="networking"
        else
            network_manager="networking"
        fi
    elif command -v rc-service >/dev/null 2>&1; then
        network_manager="networking"
    else
        network_manager="networking"
    fi
    echo "$network_manager" > /usr/local/bin/docker_network_manager
}

restart_services() {
    sysctl_path=$(which sysctl)
    ${sysctl_path} -p
    if command -v systemctl >/dev/null 2>&1; then
        systemctl restart docker
        sleep 4
        systemctl status docker 2>/dev/null
        if [ ! -z "$ipv6_address" ] && [ ! -z "$ipv6_prefixlen" ] && [ ! -z "$ipv6_gateway" ] && [ ! -z "$ipv6_address_without_last_segment" ]; then
            systemctl status radvd 2>/dev/null
        fi
    elif command -v rc-service >/dev/null 2>&1; then
        rc-service docker restart
        sleep 4
        rc-service docker status 2>/dev/null
        if [ ! -z "$ipv6_address" ] && [ ! -z "$ipv6_prefixlen" ] && [ ! -z "$ipv6_gateway" ] && [ ! -z "$ipv6_address_without_last_segment" ]; then
            rc-service radvd status 2>/dev/null
        fi
    fi
}

cleanup_and_finish() {
    rm -rf /usr/local/bin/ifupdown_installed.txt
    _green "Please run reboot to reboot the machine later. The environment has been installed"
    _green "请稍后执行 reboot 重启本机, 环境已安装完毕。"
}

main() {
    detect_network_manager
    check_and_adapt_ipv6
    install_docker_and_compose
    setup_dns_check
    handle_networking
    restart_services
    cleanup_and_finish
}

main
