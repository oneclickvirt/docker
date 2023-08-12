#!/bin/bash
# from 
# https://github.com/spiritLHLS/docker
# 2023.08.12


cd /root >/dev/null 2>&1
_red() { echo -e "\033[31m\033[01m$@\033[0m"; }
_green() { echo -e "\033[32m\033[01m$@\033[0m"; }
_yellow() { echo -e "\033[33m\033[01m$@\033[0m"; }
_blue() { echo -e "\033[36m\033[01m$@\033[0m"; }
reading(){ read -rp "$(_green "$1")" "$2"; }
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

if ! command -v docker > /dev/null 2>&1; then
    _yellow "There is no Docker environment on this machine, please execute the main installation first."
    _yellow "没有Docker环境，请先执行主体安装"
    exit 1
fi

check_ipv4(){
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

${PACKAGE_INSTALL[int]} ca-certificates
${PACKAGE_INSTALL[int]} gnupg
${PACKAGE_INSTALL[int]} lsb-release
check_ipv4
docker pull guacamole/guacd
docker pull guacamole/guacamole
docker run --name guacamoledb -e MYSQL_ROOT_PASSWORD=password -e MYSQL_DATABASE=guacdb -d mysql/mysql-server
mkdir -p /opt/guacamole/mysql
docker run --rm guacamole/guacamole /opt/guacamole/bin/initdb.sh --mysql > /opt/guacamole/mysql/01-initdb.sql
docker cp /opt/guacamole/mysql/01-initdb.sql guacamoledb:/docker-entrypoint-initdb.d
docker exec -it guacamoledb bash <<EOF
cd /docker-entrypoint-initdb.d/
ls
mysql -u root -p guacdb < 01-initdb.sql
mysql -u root -p -e "create user 'admin'@'%' identified by 'password';"
mysql -u root -p -e "grant SELECT,UPDATE,INSERT,DELETE on guacdb.* to 'admin'@'%';"
mysql -u root -p -e "flush privileges;"
exit
EOF
docker logs guacamoledb
docker run --name guacamole-server -d guacamole/guacd
docker logs --tail 10 guacamole-server
docker run --name guacamole-client --link guacamole-server:guacd --link guacamoledb:mysql -e MYSQL_DATABASE=guacdb -e MYSQL_USER=guacadmin -e MYSQL_PASSWORD=password -d -p 80:8080 guacamole/guacamole

_yellow "guacamole目前的信息："
_blue "用户名-username: guacadmin"
_blue "密码-password: guacadmin"
_blue "登录地址-website：http://${IPV4}:80/guacamole"
