#!/bin/bash
# from
# https://github.com/oneclickvirt/docker
# 2024.04.16

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

check_nginx() {
    if ! [ -x "$(command -v nginx)" ]; then
        _green "\n Install nginx.\n "
        ${PACKAGE_INSTALL[int]} nginx
    fi
}

build_reverse_proxy() {
    _green "Build reverse proxy."
    _green "Do you want to bind a URL? (yes/no): "
    reading "你需要绑定网址吗？(yes/no)" choice
    choice_lower=$(echo "$choice" | tr '[:upper:]' '[:lower:]')
    if [ "$choice_lower" == "yes" ]; then
        while true; do
            _green "Enter the domain name to bind to (format: www.example.com): "
            reading "输入你绑定本机IPV4地址的网址(如 www.example.com)：" domain_name
            resolved_ip=$(dig +short $domain_name)
            if [ "$resolved_ip" != "$IPV4" ]; then
                red "Error: $domain_name is not bound to the local IP address."
                exit 1
            else
                break
            fi
        done
    else
        domain_name="$IPV4"
    fi
    hashed_password=$(openssl passwd -crypt $user_password)
    echo -e "$user_name:$hashed_password" >/etc/nginx/passwd_scrcpy_web
    sudo tee /etc/nginx/sites-available/reverse-proxy <<EOF
map \$http_upgrade \$connection_upgrade {
    default upgrade;
    '' close;
}
upstream websocket {
    # server 127.0.0.1:4888;
    server 127.0.0.1:8000;
}
server {
    listen 80;
    server_name $domain_name;
    auth_basic "Please input password:";
    auth_basic_user_file /etc/nginx/passwd_scrcpy_web;
    location / {
        add_header Access-Control-Allow-Origin *;
        add_header Access-Control-Allow-Methods 'GET, POST, OPTIONS';
        add_header Access-Control-Allow-Headers 'DNT,X-Mx-ReqToken,Keep-Alive,User-Agent,X-Requested-With,If-Modified-Since,Cache-Control,Content-Type,Authorization';
        if (\$request_method = 'OPTIONS') {
            return 204;
        }
        # proxy_pass http://localhost:4888;
        proxy_pass http://localhost:8000;
        proxy_set_header Host \$host; 
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
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

if ! command -v docker >/dev/null 2>&1; then
    _yellow "There is no Docker environment on this machine, please execute the main installation first."
    _yellow "没有Docker环境，请先执行主体安装"
    exit 1
fi
check_ipv4
check_nginx
rm -rf /root/android/data
rm -rf /root/scrcpy_web/data
if [ ! -d "/root/android/data" ]; then
    mkdir -p "/root/android/data"
fi
if [ ! -d "/root/scrcpy_web/data" ]; then
    mkdir -p "/root/scrcpy_web/data"
fi
name="${1:-android}"
selected_tag="${2:-'8.1.0-latest'}"
user_name="${3:-onea}"
user_password="${4:-oneclick}"
# https://hub.docker.com/r/redroid/redroid/tags
docker run -itd \
    --name ${name} \
    --memory-swappiness=0 \
    --privileged --pull always \
    -p 5555:5555 \
    -v /root/android/data:/data \
    redroid/redroid:${selected_tag} \
    androidboot.hardware=mt6891 \
    androidboot.redroid_gpu_mode=guest \
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
    redroid.gpu.mode=guest
sleep 5
# 守护进程似乎无法识别npm项目，待修复
if [ ! -f /etc/systemd/system/ws-scrcpy.service ]; then
    curl -s https://raw.githubusercontent.com/oneclickvirt/docker/main/extra_scripts/ws-scrcpy.service -o /etc/systemd/system/ws-scrcpy.service
    curl -s https://raw.githubusercontent.com/oneclickvirt/docker/main/extra_scripts/nohup-ws-scrcpy.sh -o /root/ws-scrcpy/nohup-ws-scrcpy.sh
    chmod +x /etc/systemd/system/ws-scrcpy.service
    chmod +x /root/ws-scrcpy/nohup-ws-scrcpy.sh
    if [ -f "/root/ws-scrcpy/nohup-ws-scrcpy.sh" ]; then
        env_path=$(echo $PATH)
        new_exec_start="export PATH=${env_path}"
        file_path="/root/ws-scrcpy/nohup-ws-scrcpy.sh"
        line_number=7
        sed -i "${line_number}s|.*|${new_exec_start}|" "$file_path"
    fi
    systemctl daemon-reload
    systemctl start ws-scrcpy.service
    systemctl enable ws-scrcpy.service
else 
    systemctl daemon-reload
    systemctl restart ws-scrcpy.service
fi
# 不再使用docker进行web-scrcpy映射，使用上面的守护进程进行映射
# docker run -itd \
#     --privileged \
#     -v /root/scrcpy_web/data:/data \
#     --name scrcpy_web \
#     -p 127.0.0.1:4888:8000/tcp \
#     --link ${name}:web_${name} \
#     emptysuns/scrcpy-web:v0.1
# emptysuns/scrcpy-web:v0.1
# maxduke/ws-scrcpy:latest
start_time=$(date +%s)
sleep 5
MAX_WAIT_TIME=16
CONTAINERS=("${name}") # 容器名称列表 "scrcpy_web" 
for container in "${CONTAINERS[@]}"; do
    status=$(docker inspect -f '{{.State.Status}}' "$container" 2>/dev/null)
    if [ "$status" != "running" ]; then
        _yellow "The container $container failed to start and the script will exit."
        _yellow "容器 $container 启动失败，脚本将退出。"
        exit 1
    fi
done
while true; do
    current_time=$(date +%s)
    elapsed_time=$((current_time - start_time))
    if [ "$elapsed_time" -ge "$MAX_WAIT_TIME" ]; then
        break
    fi
    all_successful=true
    for container in "${CONTAINERS[@]}"; do
        update_time=$(docker inspect -f '{{.State.FinishedAt}}' "$container" | date -u +%s)
        if [ "$((start_time - update_time))" -lt 15 ]; then
            all_successful=false
            break
        fi
    done
    if [ "$all_successful" = true ]; then
        break
    fi
    sleep 1
    echo "Please be patient while waiting for the container to start..."
    echo "等待容器启动中，请耐心等待..."
done
killall adb
rm -rf nohup.out
nohup adb connect localhost:5555 & 
sleep 5
output=$(cat nohup.out)
if [ $? -ne 0 ] || [[ $output == *"failed to connect to"* ]]; then
    docker rm -f android
    docker rm -f scrcpy_web
    docker rmi $(docker images | grep "redroid" | awk '{print $3}')
    rm -rf /etc/nginx/sites-enabled/reverse-proxy
    rm -rf /etc/nginx/sites-available/reverse-proxy
    rm -rf /etc/nginx/passwd_scrcpy_web
    rm -rf /root/android_info
    _yellow "连接失败，可能无法使用该安卓镜像，已自动清理环境退出程序"
    exit 1
fi
build_reverse_proxy
rm -rf /root/android_info
echo "$name $selected_tag $user_name $user_password http://${IPV4}:80" >>/root/android_info
_yellow "Current information:"
_yellow "目前的信息："
_blue "名字-name: $name"
_blue "安卓版本-version: $selected_tag"
_blue "用户名-username: $user_name"
_blue "密码-password: $user_password"
_blue "登录地址-website：http://${IPV4}:80"
