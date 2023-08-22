#!/bin/bash
# from
# https://github.com/spiritLHLS/docker
# 2023.08.17

# 起步10分钟
cd /root >/dev/null 2>&1
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
count=$(sudo egrep -c '(vmx|svm)' /proc/cpuinfo)
if [[ -z $count ]] || [[ $count -le 0 ]]; then
    _yellow "Virtualization is not supported, exit the program."
    _yellow "虚拟化不支持，退出程序。"
fi
${PACKAGE_INSTALL[int]} openssh-server
${PACKAGE_INSTALL[int]} openssh-client
container_name="${1:-test}"
windows_version="${2:-2019}"
rdp_port="${3:-33896}"
is_external_ip="${4:-N}"

_green "The following program will take at least 10 minutes to execute, so please be patient...."
_green "以下程序将执行至少10分钟，请耐心等待..."
is_external_ip_lower=$(echo "$is_external_ip" | tr '[:upper:]' '[:lower:]')
if [ "$is_external_ip_lower" = "y" ]; then
    rdp_address="0.0.0.0"
else
    rdp_address="127.0.0.1"
fi
docker run -d --privileged=true \
    --name windows_${container_name} \
    --device=/dev/kvm \
    --device=/dev/net/tun \
    -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
    --cap-add=NET_ADMIN \
    --cap-add=SYS_ADMIN \
    -p ${rdp_address}:${rdp_port}:3389 \
    spiritlhl/wds:${windows_version} /sbin/init
sleep 5
start_time=$(date +%s)
MAX_WAIT_TIME=10
while true; do
    current_time=$(date +%s)
    elapsed_time=$((current_time - start_time))
    if [ "$elapsed_time" -ge "$MAX_WAIT_TIME" ]; then
        break
    fi
    status=$(docker inspect -f '{{.State.Status}}' "windows_${container_name}" 2>/dev/null)
    if [ "$status" == "running" ]; then
        break
    fi
    _yellow "Please be patient while waiting for the container to start..."
    _yellow "等待容器启动中，请耐心等待..."
    sleep 2
done
docker exec -it windows_${container_name} bash -c "bash startup.sh 2>&1"
if [ "$is_external_ip_lower" = "y" ]; then
    _green "The RDP login address is: extranet IPV4 address:${rdp_port} login information and usage instructions are detailed at virt.spiritlhl.net"
    _green "RDP的登录地址为：外网IPV4地址:${rdp_port} 登录信息和使用说明详见 virt.spiritlhl.net"
else
    _green "The RDP login address is: 127.0.0.1:${rdp_port} login information and usage instructions are detailed at virt.spiritlhl.net"
    _green "RDP的登录地址为：127.0.0.1:${rdp_port} 登录信息和使用说明详见 virt.spiritlhl.net"
fi
echo ""
echo ""
