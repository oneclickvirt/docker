#!/bin/bash
# from
# https://github.com/oneclickvirt/docker
# 2026.02.28

cd /root >/dev/null 2>&1 || exit 1
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

check_ipv4() {
    API_NET=("ip.sb" "ipget.net" "ip.ping0.cc" "https://ip4.seeip.org" "https://api.my-ip.io/ip" "https://ipv4.icanhazip.com" "api.ipify.org")
    IPV4=""
    for p in "${API_NET[@]}"; do
        response=$(curl -s4m8 "$p" | tr -d '[:space:]')
        sleep 1
        if [ $? -eq 0 ] && echo "$response" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
            IP_API="$p"
            IPV4="$response"
            break
        fi
    done
    [ -z "$IPV4" ] && _red " ERROR：The host must have IPv4. " && exit 1
}

add_iptables_rule() {
    local chain="$1"
    shift
    iptables -C "$chain" "$@" 2>/dev/null || iptables -A "$chain" "$@"
}

check_ipv4
if ! command -v docker >/dev/null 2>&1; then
    _yellow "There is no Docker environment on this machine, please execute the main installation first."
    _yellow "没有Docker环境，请先执行主体安装"
    exit 1
fi
if ! command -v iptables >/dev/null 2>&1; then
    ${PACKAGE_INSTALL[int]} iptables
fi
# _green "Is a web client required? ([Y]/N): "
# reading "是否需要web客户端？([Y]/N): " is_web_client
# docker image pull rustdesk/rustdesk-server
# is_web_client_lower=$(echo "$is_web_client" | tr '[:upper:]' '[:lower:]')
# if [ "$is_web_client_lower" = "n" ]; then
#     web_hbbs_text=""
#     web_hbbr_text=""
# else
#     web_hbbs_text="-p 21118:21118"
#     web_hbbr_text="-p 21119:21119"
# fi
# --net=host
# -p 21115:21115 -p 21116:21116 -p 21116:21116/udp ${web_hbbs_text}
# -p 21117:21117 ${web_hbbr_text}
if docker inspect hbbs >/dev/null 2>&1; then
    docker start hbbs >/dev/null 2>&1 || true
else
    if ! docker run --restart unless-stopped --name hbbs --net=host -v "$(pwd):/root" -d rustdesk/rustdesk-server hbbs -r "${IPV4}:21117"; then
        _red "Failed to create hbbs"
        _red "创建 hbbs 失败"
        exit 1
    fi
fi
if docker inspect hbbr >/dev/null 2>&1; then
    docker start hbbr >/dev/null 2>&1 || true
else
    if ! docker run --restart unless-stopped --name hbbr --net=host -v "$(pwd):/root" -d rustdesk/rustdesk-server hbbr; then
        _red "Failed to create hbbr"
        _red "创建 hbbr 失败"
        exit 1
    fi
fi
add_iptables_rule INPUT -i lo -j ACCEPT
add_iptables_rule OUTPUT -o lo -j ACCEPT
add_iptables_rule INPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
add_iptables_rule INPUT -p tcp --match multiport --dports 21115:21119 -j ACCEPT
add_iptables_rule INPUT -p tcp --dport 8000 -j ACCEPT
add_iptables_rule INPUT -p udp --dport 21116 -j ACCEPT
${PACKAGE_INSTALL[int]} iptables-persistent
mkdir -p /etc/iptables
iptables-save >/etc/iptables/rules.v4
service netfilter-persistent restart 2>/dev/null || true
