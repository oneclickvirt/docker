#!/bin/bash
# from 
# https://github.com/spiritLHLS/docker
# 2023.08.11


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

check_nginx(){
    if ! [ -x "$(command -v nginx)" ]; then
        green "\n Install nginx.\n "
        ${PACKAGE_INSTALL[int]} nginx
    fi
}

build_reverse_proxy{
green "\n Build reverse proxy. \n "
echo -n ${user_name} > /etc/nginx/passwd_scrcpy_web
openssl passwd ${user_password} >> /etc/nginx/passwd_scrcpy_web
sudo tee /etc/nginx/sites-available/reverse-proxy <<EOF
map $http_upgrade $connection_upgrade {
    default upgrade;
    '' close;
}
upstream websocket {
    server 127.0.0.1:4888;
}
server {
    listen 80;
    server_name test.com;
    #root /usr/share/nginx/html;
    auth_basic "Please input password:";
    auth_basic_user_file /etc/nginx/passwd_scrcpy_web;
    location / {
        add_header Access-Control-Allow-Origin *;
        add_header Access-Control-Allow-Methods 'GET, POST, OPTIONS';
        add_header Access-Control-Allow-Headers 'DNT,X-Mx-ReqToken,Keep-Alive,User-Agent,X-Requested-With,If-Modified-Since,Cache-Control,Content-Type,Authorization';
        if ($request_method = 'OPTIONS') {
            return 204;
        }
        proxy_pass http://websocket;
        proxy_set_header Host $host; 
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
    }
}
EOF
sudo ln -s /etc/nginx/sites-available/reverse-proxy /etc/nginx/sites-enabled/
sudo nginx -t
if [ $? -ne 0 ]; then
    red "Error: There is an error in the reverse proxy configuration file. Please check："
    yellow "https://zipline.diced.tech/docs/guides/nginx/nginx-no-ssl"
    exit 1
fi
sudo systemctl restart nginx
}

check_ipv4
check_nginx
current_kernel_version=$(uname -r)
target_kernel_version="5.0"
if [[ "$(echo -e "$current_kernel_version\n$target_kernel_version" | sort -V | head -n 1)" == "$target_kernel_version" ]]; then
    echo "当前内核版本 $current_kernel_version 大于或等于 $target_kernel_version，无需升级。"
else
    echo "当前内核版本 $current_kernel_version 小于 $target_kernel_version，请自行升级系统"
fi
if ! dpkg -S linux-modules-extra-${current_kernel_version} > /dev/null 2>&1; then
    ${PACKAGE_INSTALL[int]} linux-modules-extra-${current_kernel_version}
fi
modprobe binder_linux devices="binder,hwbinder,vndbinder"
modprobe ashmem_linux
if [ ! -d "/root/android/${selected_tag}/data" ]; then
    mkdir -p "/root/android/${selected_tag}/data"
fi
if [ ! -d "/root/scrcpy_web/${name}/data" ]; then
    mkdir -p "/root/scrcpy_web/${name}/data"
fi
name="${1:-android}"
selected_tag="${2:-'8.1.0-latest'}"
user_name="${3:-onea}"
user_password="${4:-oneclick}"
# https://hub.docker.com/r/redroid/redroid/tags
docker run -itd \
    --memory-swappiness=0 \
    --privileged --pull always \
    -v /root/android/${selected_tag}/data:/data \
    redroid/redroid:${selected_tag} \
    androidboot.hardware=mt6891 \
    ro.secure=0 \
    ro.boot.hwc=GLOBAL \
    ro.ril.oem.imei=861503068361145 \
    ro.ril.oem.imei1=861503068361145 \
    ro.ril.oem.imei2=861503068361148 \
    ro.ril.miui.imei0=861503068361148 \
    ro.product.manufacturer=Xiaomi \
    ro.build.product=chopin \
    redroid.width=720 \
    redroid.height=1280 \
    redroid.gpu.mode=guest \
    --name ${name}
docker run -itd \
  --privileged \
  -v /root/scrcpy_web/${name}/data:/data \
  --name scrcpy_web_${name} \
  -p 127.0.0.1:4888:8000/tcp \
  --link ${name}:web_${name} \
  emptysuns/scrcpy-web:v0.1
docker exec -it scrcpy_web_${name} adb connect web_${name}:5555
build_reverse_proxy
echo "$name $selected_tag $user_name $user_password http://${IPV4}:80" >> "$name"
_yellow "Current information:"
_yellow "目前的信息："
_blue "名字-name: $name"
_blue "安卓版本-version: $selected_tag"
_blue "用户名-username: $user_name"
_blue "密码-password: $user_password"
_blue "登录地址-website：http://${IPV4}:80"