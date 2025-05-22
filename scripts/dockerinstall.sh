#!/bin/bash
# from
# https://github.com/oneclickvirt/docker
# 2025.05.22

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
temp_file_apt_fix="/tmp/apt_fix.txt"
REGEX=("debian" "ubuntu" "centos|red hat|kernel|oracle linux|alma|rocky" "'amazon linux'" "fedora" "arch")
RELEASE=("Debian" "Ubuntu" "CentOS" "CentOS" "Fedora" "Arch")
PACKAGE_UPDATE=("! apt-get update && apt-get --fix-broken install -y && apt-get update" "apt-get update" "yum -y update" "yum -y update" "yum -y update" "pacman -Sy")
PACKAGE_INSTALL=("apt-get -y install" "apt-get -y install" "yum -y install" "yum -y install" "yum -y install" "pacman -Sy --noconfirm --needed")
PACKAGE_REMOVE=("apt-get -y remove" "apt-get -y remove" "yum -y remove" "yum -y remove" "yum -y remove" "pacman -Rsc --noconfirm")
PACKAGE_UNINSTALL=("apt-get -y autoremove" "apt-get -y autoremove" "yum -y autoremove" "yum -y autoremove" "yum -y autoremove" "")
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

rebuild_cloud_init() {
    if [ -f "/etc/cloud/cloud.cfg" ]; then
        chattr -i /etc/cloud/cloud.cfg
        if grep -q "preserve_hostname: true" "/etc/cloud/cloud.cfg"; then
            :
        else
            sed -E -i 's/preserve_hostname:[[:space:]]*false/preserve_hostname: true/g' "/etc/cloud/cloud.cfg"
            echo "change preserve_hostname to true"
        fi
        if grep -q "disable_root: false" "/etc/cloud/cloud.cfg"; then
            :
        else
            sed -E -i 's/disable_root:[[:space:]]*true/disable_root: false/g' "/etc/cloud/cloud.cfg"
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
    TODAY=$(echo "$COUNT" | grep -oP '"daily":\s*[0-9]+' | sed 's/"daily":\s*\([0-9]*\)/\1/')
    TOTAL=$(echo "$COUNT" | grep -oP '"total":\s*[0-9]+' | sed 's/"total":\s*\([0-9]*\)/\1/')
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
    # 输入为空
    if [[ ! -n $address ]]; then
        temp="1"
    fi
    # 输入不含:符号
    if [[ -n $address && $address != *":"* ]]; then
        temp="2"
    fi
    # 检查IPv6地址是否以fe80开头（链接本地地址）
    if [[ $address == fe80:* ]]; then
        temp="3"
    fi
    # 检查IPv6地址是否以fc00或fd00开头（唯一本地地址）
    if [[ $address == fc00:* || $address == fd00:* ]]; then
        temp="4"
    fi
    # 检查IPv6地址是否以2001:db8开头（文档前缀）
    if [[ $address == 2001:db8* ]]; then
        temp="5"
    fi
    # 检查IPv6地址是否以::1开头（环回地址）
    if [[ $address == ::1 ]]; then
        temp="6"
    fi
    # 检查IPv6地址是否以::ffff:开头（IPv4映射地址）
    if [[ $address == ::ffff:* ]]; then
        temp="7"
    fi
    # 检查IPv6地址是否以2002:开头（6to4隧道地址）
    if [[ $address == 2002:* ]]; then
        temp="8"
    fi
    # 检查IPv6地址是否以2001:开头（Teredo隧道地址）
    if [[ $address == 2001:* ]]; then
        temp="9"
    fi
    if [ "$temp" -gt 0 ]; then
        # 非公网情况
        return 0
    else
        # 其他情况为公网地址
        return 1
    fi
}

check_ipv6() {
    IPV6=$(ip -6 addr show | grep global | awk '{print length, $2}' | sort -nr | head -n 1 | awk '{print $2}' | cut -d '/' -f1)
    if [ ! -f /usr/local/bin/docker_last_ipv6 ] || [ ! -s /usr/local/bin/docker_last_ipv6 ] || [ "$(sed -e '/^[[:space:]]*$/d' /usr/local/bin/docker_last_ipv6)" = "" ]; then
        ipv6_list=$(ip -6 addr show | grep global | awk '{print length, $2}' | sort -nr | awk '{print $2}')
        line_count=$(echo "$ipv6_list" | wc -l)
        if [ "$line_count" -ge 2 ]; then
            # 获取最后一行的内容
            last_ipv6=$(echo "$ipv6_list" | tail -n 1)
            # 切分最后一个:之前的内容
            last_ipv6_prefix="${last_ipv6%:*}:"
            # 与${ipv6_gateway}比较是否相同
            if [ "${last_ipv6_prefix}" = "${ipv6_gateway%:*}:" ]; then
                echo $last_ipv6 >/usr/local/bin/docker_last_ipv6
            fi
            _green "The local machine is bound to more than one IPV6 address"
            _green "本机绑定了不止一个IPV6地址"
        fi
    fi
    if is_private_ipv6 "$IPV6"; then # 由于是内网IPV6地址，需要通过API获取外网地址
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
    for cdn_url in "${cdn_urls[@]}"; do
        if curl -sL -k "$cdn_url$o_url" --max-time 6 | grep -q "success" >/dev/null 2>&1; then
            export cdn_success_url="$cdn_url"
            return
        fi
        sleep 0.5
    done
    export cdn_success_url=""
}

check_cdn_file() {
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
    # 根据架构信息设置系统位数并下载文件,其余 * 包括了 x86_64
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
    if grep -q "^$sysctl_config" /etc/sysctl.conf; then
        if grep -q "^#$sysctl_config" /etc/sysctl.conf; then
            sed -i "s/^#$sysctl_config/$sysctl_config/" /etc/sysctl.conf
        fi
    else
        echo "$sysctl_config" >>/etc/sysctl.conf
    fi
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
    ${PACKAGE_INSTALL[int]} lshw
fi
if ! command -v ipcalc >/dev/null 2>&1; then
    _yellow "Installing ipcalc"
    ${PACKAGE_INSTALL[int]} ipcalc
fi
# https://pkgs.org/search/?q=sipcalc
if [[ "$RELEASE" == "CentOS" ]]; then
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
else
    ${PACKAGE_INSTALL[int]} sipcalc
fi
if ! command -v bc >/dev/null 2>&1; then
    _yellow "Installing bc"
    ${PACKAGE_INSTALL[int]} bc
fi
if ! command -v ip >/dev/null 2>&1; then
    _yellow "Installing iproute2"
    ${PACKAGE_INSTALL[int]} iproute2
fi
if ! command -v lxcfs >/dev/null 2>&1; then
    _yellow "Installing lxcfs"
    ${PACKAGE_INSTALL[int]} lxcfs
fi
if ! command -v crontab >/dev/null 2>&1; then
    _yellow "Installing crontab"
    ${PACKAGE_INSTALL[int]} cron
    if [[ $? -ne 0 ]]; then
        ${PACKAGE_INSTALL[int]} cronie
    fi
fi
${PACKAGE_INSTALL[int]} net-tools
check_china
cdn_urls=("https://cdn0.spiritlhl.top/" "http://cdn3.spiritlhl.net/" "http://cdn1.spiritlhl.net/" "https://ghproxy.com/" "http://cdn2.spiritlhl.net/")
check_cdn_file
get_system_arch
${PACKAGE_INSTALL[int]} openssl
curl -Lk ${cdn_success_url}https://raw.githubusercontent.com/oneclickvirt/docker/main/scripts/ssh_bash.sh -o ssh_bash.sh && chmod +x ssh_bash.sh && dos2unix ssh_bash.sh
curl -Lk ${cdn_success_url}https://raw.githubusercontent.com/oneclickvirt/docker/main/scripts/ssh_sh.sh -o ssh_sh.sh && chmod +x ssh_sh.sh && dos2unix ssh_sh.sh

# 检测物理接口
interface_1=$(lshw -C network | awk '/logical name:/{print $3}' | sed -n '1p')
interface_2=$(lshw -C network | awk '/logical name:/{print $3}' | sed -n '2p')
check_interface
if [ ! -f /usr/local/bin/docker_mac_address ] || [ ! -s /usr/local/bin/docker_mac_address ] || [ "$(sed -e '/^[[:space:]]*$/d' /usr/local/bin/docker_mac_address)" = "" ]; then
    mac_address=$(ip -o link show dev ${interface} | awk '{print $17}')
    echo "$mac_address" >/usr/local/bin/docker_mac_address
fi
mac_address=$(cat /usr/local/bin/docker_mac_address)

# 检测主IPV4相关信息
if [ ! -f /usr/local/bin/docker_main_ipv4 ]; then
    main_ipv4=$(ip -4 addr show | grep global | awk '{print $2}' | cut -d '/' -f1 | head -n 1)
    echo "$main_ipv4" >/usr/local/bin/docker_main_ipv4
fi
# 提取主IPV4地址
main_ipv4=$(cat /usr/local/bin/docker_main_ipv4)
if [ ! -f /usr/local/bin/docker_ipv4_address ]; then
    ipv4_address=$(ip addr show | awk '/inet .*global/ && !/inet6/ {print $2}' | sed -n '1p')
    echo "$ipv4_address" >/usr/local/bin/docker_ipv4_address
fi
# 提取IPV4地址 含子网长度
ipv4_address=$(cat /usr/local/bin/docker_ipv4_address)
if [ ! -f /usr/local/bin/docker_ipv4_gateway ]; then
    ipv4_gateway=$(ip route | awk '/default/ {print $3}' | sed -n '1p')
    echo "$ipv4_gateway" >/usr/local/bin/docker_ipv4_gateway
fi
# 提取IPV4网关
ipv4_gateway=$(cat /usr/local/bin/docker_ipv4_gateway)
if [ ! -f /usr/local/bin/docker_ipv4_subnet ]; then
    ipv4_subnet=$(ipcalc -n "$ipv4_address" | grep -oP 'Netmask:\s+\K.*' | awk '{print $1}')
    echo "$ipv4_subnet" >/usr/local/bin/docker_ipv4_subnet
fi
# 提取Netmask
ipv4_subnet=$(cat /usr/local/bin/docker_ipv4_subnet)
# 提取子网掩码
ipv4_prefixlen=$(echo "$ipv4_address" | cut -d '/' -f 2)

# 检测IPV6相关的信息
if [ ! -f /usr/local/bin/docker_ipv6_prefixlen ] || [ ! -s /usr/local/bin/docker_ipv6_prefixlen ] || [ "$(sed -e '/^[[:space:]]*$/d' /usr/local/bin/docker_ipv6_prefixlen)" = "" ]; then
    ipv6_prefixlen=""
    output=$(ifconfig ${interface} | grep -oP 'inet6 (?!fe80:).*prefixlen \K\d+')
    num_lines=$(echo "$output" | wc -l)
    if [ $num_lines -ge 2 ]; then
        ipv6_prefixlen=$(echo "$output" | sort -n | head -n 1)
    else
        ipv6_prefixlen=$(echo "$output" | head -n 1)
    fi
    echo "$ipv6_prefixlen" >/usr/local/bin/docker_ipv6_prefixlen
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
    # 判断fe80是否已加白
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
    # 判断是否存在SLAAC机制
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
    # 提示是否在SLAAC分配的情况下还使用最大IPV6子网范围
    if [ -f /usr/local/bin/docker_slaac_status ] && [ ! -f /usr/local/bin/docker_maximum_subset ] && [ ! -f /usr/local/bin/fix_interfaces_ipv6_auto_type ]; then
        # 大概率由SLAAC动态分配，需要询问使用的子网范围 仅本机IPV6 或 最大子网
        _blue "It is detected that IPV6 addresses are most likely to be dynamically assigned by SLAAC, and if there is no subsequent need to assign separate IPV6 addresses to VMs/containers, the following option is best selected n"
        _green "检测到IPV6地址大概率由SLAAC动态分配，若后续不需要分配独立的IPV6地址给虚拟机/容器，则下面选项最好选 n"
        _blue "Is the maximum subnet range feasible with IPV6 used?([n]/y)"
        reading "是否使用IPV6可行的最大子网范围？([n]/y)" select_maximum_subset
        if [ "$select_maximum_subset" = "y" ] || [ "$select_maximum_subset" = "Y" ]; then
            echo "true" >/usr/local/bin/docker_maximum_subset
        else
            echo "false" >/usr/local/bin/docker_maximum_subset
        fi
        echo "" >/usr/local/bin/fix_interfaces_ipv6_auto_type
    fi
    # 不存在SLAAC机制的情况下或存在时使用最大IPV6子网范围，需要重构IPV6地址
    if [ ! -f /usr/local/bin/docker_maximum_subset ] || [ $(cat /usr/local/bin/docker_maximum_subset) = true ]; then
        ipv6_address_without_last_segment="${ipv6_address%:*}:"
        if [[ $ipv6_address != *:: && $ipv6_address_without_last_segment != *:: ]]; then
            # 重构IPV6地址，使用该IPV6子网内的0001结尾的地址
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
        elif [[ $ipv6_address == *:: ]]; then
            ipv6_address="${ipv6_address}1"
            if [ "$ipv6_address" == "$ipv6_gateway" ]; then
                ipv6_address="${ipv6_address%:*}:2"
            fi
            echo "${ipv6_address}" >/usr/local/bin/docker_check_ipv6
        fi
    fi
fi

# docker 和 docker-compose 安装
install_docker_and_compose() {
    _green "This may stay for 2~3 minutes, please be patient..."
    _green "此处可能会停留2~3分钟，请耐心等待。。。"
    sleep 1
    if ! command -v docker >/dev/null 2>&1; then
        _yellow "Installing docker"
        if [[ -z "${CN}" || "${CN}" != true ]]; then
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
        if [[ -z "${CN}" || "${CN}" != true ]]; then
            _yellow "Installing docker-compose"
            curl -L "${cdn_success_url}https://github.com/docker/compose/releases/latest/download/docker-compose-linux-$(uname -m)" -o /usr/local/bin/docker-compose
            chmod +x /usr/local/bin/docker-compose
            docker-compose --version
        fi
    fi
    sleep 1
}

# 检测docker的配置文件
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
            # 设置允许IPV6转发
            sysctl_path=$(which sysctl)
            $sysctl_path -w net.ipv6.conf.all.forwarding=1
            $sysctl_path -w net.ipv6.conf.all.proxy_ndp=1
            $sysctl_path -w net.ipv6.conf.default.proxy_ndp=1
            $sysctl_path -w net.ipv6.conf.docker0.proxy_ndp=1
            $sysctl_path -w net.ipv6.conf.${interface}.proxy_ndp=1
            if [ "$status_he" = true ]; then
                $sysctl_path -w net.ipv6.conf.he-ipv6.proxy_ndp=1
            fi
            $sysctl_path -f
            _green "请重启服务器以启用新的网络配置，重启后等待20秒后请再次执行本脚本"
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
    systemctl restart systemd-networkd
}

configure_network_manager() {
    connection_name=$(nmcli -t -f NAME,DEVICE connection show | grep $interface | cut -d':' -f1)
    if [ -z "$connection_name" ]; then
        connection_name="${interface}-connection"
        nmcli connection add type ethernet con-name "$connection_name" ifname $interface
    fi
    # 配置IPv4
    nmcli connection modify "$connection_name" ipv4.method manual
    nmcli connection modify "$connection_name" ipv4.addresses $ipv4_address/$ipv4_prefixlen
    nmcli connection modify "$connection_name" ipv4.gateway $ipv4_gateway
    nmcli connection modify "$connection_name" ipv4.dns "8.8.8.8,8.8.4.4"
    # 配置IPv6
    nmcli connection modify "$connection_name" ipv6.method manual
    nmcli connection modify "$connection_name" ipv6.addresses $ipv6_address/$ipv6_prefixlen
    nmcli connection modify "$connection_name" ipv6.gateway $ipv6_gateway
    nmcli connection modify "$connection_name" ipv6.dns "2001:4860:4860::8888,2606:4700:4700::1111"
    # 重新加载
    nmcli connection up "$connection_name"
}

configure_networking() {
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
            systemctl restart networking
            sleep 3
            # 重构IPV6地址，使用该IPV6子网内的0001结尾的地址
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
            echo "Before: target_mask = $target_mask"
            ((target_mask += 8 - ($target_mask % 8)))
            echo "After: target_mask = $target_mask"
            ipv6_subnet_2=$(sipcalc --v6split=${target_mask} ${ipv6_address}/${ipv6_prefixlen} | awk '/Network/{n++} n==2' | awk '{print $3}' | grep -v '^$')
            ipv6_subnet_2_without_last_segment="${ipv6_subnet_2%:*}:"
            if [ -n "$ipv6_subnet_2_without_last_segment" ] && [ -n "$target_mask" ]; then
                new_subnet="${ipv6_subnet_2}/${target_mask}"
                _green "Use cuted IPV6 subnet：${new_subnet}"
                _green "使用切分出来的IPV6子网：${new_subnet}"
            else
                _red "The ipv6 subnet 2: ${ipv6_subnet_2}"
                _red "The ipv6 target mask: ${target_mask}"
                return false
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
                ${PACKAGE_INSTALL[int]} radvd
            fi
            if [ "$status_he" = true ]; then
                config_content="interface he-ipv6 {
  AdvSendAdvert on;
  MinRtrAdvInterval 3;
  MaxRtrAdvInterval 10;
  prefix $ipv6_address_without_last_segment/$ipv6_prefixlen {
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
  prefix $ipv6_address_without_last_segment/$ipv6_prefixlen {
    AdvOnLink on;
    AdvAutonomous on;
    AdvRouterAddr on;
  };
};"
            fi
            echo "$config_content" | sudo tee /etc/radvd.conf >/dev/null
            systemctl restart radvd
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
            systemctl restart systemd-networkd
            ;;
        "NetworkManager")
            systemctl restart NetworkManager
            ;;
        "networking")
            systemctl restart networking
            ;;
        *)
            systemctl restart networking 2>/dev/null || true
            systemctl restart systemd-networkd 2>/dev/null || true
            systemctl restart NetworkManager 2>/dev/null || true
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
        wget ${cdn_success_url}https://raw.githubusercontent.com/oneclickvirt/docker/main/extra_scripts/check-dns.service -O /etc/systemd/system/check-dns.service
        chmod +x /usr/local/bin/check-dns.sh
        chmod +x /etc/systemd/system/check-dns.service
        systemctl daemon-reload
        systemctl enable check-dns.service
        systemctl start check-dns.service
    fi
}

detect_network_manager() {
    if systemctl is-active --quiet systemd-networkd; then
        network_manager="systemd-networkd"
    elif systemctl is-active --quiet NetworkManager; then
        network_manager="NetworkManager"
    elif systemctl is-active --quiet networking; then
        network_manager="networking"
    else
        network_manager="networking"
    fi
    echo "$network_manager" > /usr/local/bin/docker_network_manager
}

restart_services() {
    sysctl_path=$(which sysctl)
    ${sysctl_path} -p
    systemctl restart docker
    sleep 4
    systemctl status docker 2>/dev/null
    if [ ! -z "$ipv6_address" ] && [ ! -z "$ipv6_prefixlen" ] && [ ! -z "$ipv6_gateway" ] && [ ! -z "$ipv6_address_without_last_segment" ]; then
        systemctl status radvd 2>/dev/null
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
