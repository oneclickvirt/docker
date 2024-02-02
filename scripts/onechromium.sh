#!/bin/bash
# from
# https://github.com/spiritLHLS/docker
# 2024.02.02

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
if [ ! -d /usr/local/bin ]; then
    mkdir -p /usr/local/bin
fi

check_ipv4() {
    API_NET=("ip.sb" "ipget.net" "ip.ping0.cc" "https://ip4.seeip.org" "https://api.my-ip.io/ip" "https://ipv4.icanhazip.com" "api.ipify.org")
    for p in "${API_NET[@]}"; do
        response=$(curl -s4m8 "$p")
        sleep 1
        if [ $? -eq 0 ] && ! echo "$response" | grep -q "error"; then
            IP_API="$p"
            break
        fi
    done
    ! curl -s4m8 $IP_API | grep -q '\.' && red " ERROR：The host must have IPv4. " && exit 1
    IPV4=$(curl -s4m8 "$IP_API")
}

check_ipv4
if ! command -v docker >/dev/null 2>&1; then
    _yellow "There is no Docker environment on this machine, please execute the main installation first."
    _yellow "没有Docker环境，请先执行主体安装"
    exit 1
fi
_green "Can be opened more than one, as long as you correspond to the use of different web port and vnc port can be, because the container name and the port corresponds to the port, the port does not repeat the container name is not repeated can be opened more than one"
_green "可多开，只要你对应使用不同的web端口和vnc端口即可，因为容器名字是和端口对应的，端口不重复容器名字就不重复可多开"
_green "Browser access password: (leave blank to default to oneclick):"
reading "浏览器访问密码(留空则默认为oneclick):" password
_green "Browser http access port (default 3004 if left blank):"
reading "浏览器http访问端口(留空则默认3004):" http_port
_green "Browser https access port (default 3005 if left blank):"
reading "浏览器https访问端口(留空则默认3005):" https_port
_green "Set the maximum occupied memory, enter the number only (leave blank the default setting of 2G memory):"
reading "设置最大占用内存，仅输入数字(留空默认设置为2G内存):" shm_size
[[ -z "$http_port" ]] && http_port=3004
[[ -z "$https_port" ]] && https_port=3005
[[ -z "$password" ]] && password="oneclick" && echo $password > /usr/local/bin/password_${http_port}
[[ -z "$shm_size" ]] && shm_size="2"

docker run -d \
  --name=chromium_${http_port} \
  --security-opt seccomp=unconfined `#optional` \
  -e PUID=1000 \
  -e PGID=1000 \
  -e TZ=Etc/UTC \
  -e CHROME_CLI=https://www.spiritlhl.net/ `#optional` \
  -e PASSWORD=$(cat /usr/local/bin/password_${http_port}) \
  -p 0.0.0.0:${http_port}:3000 \
  -p 0.0.0.0:${https_port}:3001 \
  -v /usr/local/bin/config_${http_port}:/config \
  --shm-size="${shm_size}gb" \
  --restart unless-stopped \
  lscr.io/linuxserver/chromium:latest

_green "URL(http): http://${IPV4}:$http_port/"
_green "URL(https): https://${IPV4}:$https_port/"
_green "Password: $password"
_green "网址(http)：http://${IPV4}:$http_port/"
_green "网址(https)：https://${IPV4}:$https_port/"
_green "密码: $password"
