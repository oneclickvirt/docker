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

is_valid_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

is_port_in_use() {
    local port="$1"
    if command -v ss >/dev/null 2>&1 && ss -H -ltn "sport = :${port}" 2>/dev/null | grep -q .; then
        return 0
    fi
    if command -v netstat >/dev/null 2>&1 && netstat -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${port}$"; then
        return 0
    fi
    if command -v lsof >/dev/null 2>&1 && lsof -nP -iTCP:"${port}" -sTCP:LISTEN >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

check_nginx() {
    if ! [ -x "$(command -v nginx)" ]; then
        _green "\n Install nginx.\n "
        ${PACKAGE_INSTALL[int]} nginx
    fi
}

check_dig() {
    if ! command -v dig >/dev/null 2>&1; then
        _green "Installing dig (dnsutils/bind-utils)..."
        if command -v apt-get >/dev/null 2>&1; then
            ${PACKAGE_INSTALL[int]} dnsutils
        elif command -v yum >/dev/null 2>&1 || command -v dnf >/dev/null 2>&1; then
            ${PACKAGE_INSTALL[int]} bind-utils
        elif command -v apk >/dev/null 2>&1; then
            ${PACKAGE_INSTALL[int]} bind-tools
        elif command -v pacman >/dev/null 2>&1; then
            ${PACKAGE_INSTALL[int]} bind
        fi
    fi
}

check_openssl() {
    if ! command -v openssl >/dev/null 2>&1; then
        _green "Installing openssl..."
        ${PACKAGE_INSTALL[int]} openssl
    fi
}

check_adb() {
    if command -v adb >/dev/null 2>&1; then
        return 0
    fi
    _green "Installing adb..."
    case "$SYSTEM" in
        Debian|Ubuntu)
            ${PACKAGE_INSTALL[int]} adb || ${PACKAGE_INSTALL[int]} android-tools-adb
            ;;
        CentOS|Fedora)
            ${PACKAGE_INSTALL[int]} android-tools
            ;;
        Arch|Alpine)
            ${PACKAGE_INSTALL[int]} android-tools
            ;;
        *)
            ${PACKAGE_INSTALL[int]} adb || ${PACKAGE_INSTALL[int]} android-tools
            ;;
    esac
    if ! command -v adb >/dev/null 2>&1; then
        _red "adb is required but could not be installed."
        _red "adb 为必需组件，但安装失败。"
        exit 1
    fi
}

ensure_ws_scrcpy() {
    if [ -d /root/ws-scrcpy ]; then
        return 0
    fi
    if command -v git >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
        if git clone https://github.com/NetrisTV/ws-scrcpy.git /root/ws-scrcpy && (cd /root/ws-scrcpy && npm install); then
            return 0
        fi
        _red "Failed to prepare ws-scrcpy."
        _red "准备 ws-scrcpy 失败。"
        exit 1
    fi
    _red "/root/ws-scrcpy does not exist. Run create_android.sh first or install git and npm before running oneandroid.sh directly."
    _red "/root/ws-scrcpy 不存在。请先执行 create_android.sh，或安装 git 与 npm 后再直接运行 oneandroid.sh。"
    exit 1
}

build_reverse_proxy() {
    _green "Build reverse proxy."
    _green "Do you want to bind a URL? (yes/no): "
    reading "你需要绑定网址吗？(yes/no)" choice "${ANDROID_BIND_DOMAIN:-no}"
    choice_lower=$(echo "$choice" | tr '[:upper:]' '[:lower:]')
    if [ "$choice_lower" == "yes" ]; then
        while true; do
            _green "Enter the domain name to bind to (format: www.example.com): "
            reading "输入你绑定本机IPV4地址的网址(如 www.example.com)：" domain_name "${ANDROID_DOMAIN:-}"
            resolved_ip=$(dig +short "$domain_name" | head -1)
            if [ "$resolved_ip" != "$IPV4" ]; then
                _red "Error: $domain_name is not bound to the local IP address."
                exit 1
            else
                break
            fi
        done
    else
        domain_name="$IPV4"
    fi
    if openssl passwd -help 2>&1 | grep -q -- " -1"; then
        hashed_password=$(openssl passwd -1 "$user_password")
    elif openssl passwd -help 2>&1 | grep -q -- " -crypt"; then
        hashed_password=$(openssl passwd -crypt "$user_password")
    elif openssl passwd -help 2>&1 | grep -q -- " -apr1"; then
        hashed_password=$(openssl passwd -apr1 "$user_password")
    else
        echo "Error: openssl 不支持 -1、-crypt 或 -apr1，无法生成密码。" >&2
        exit 1
    fi
    echo "$user_name:$hashed_password" > /etc/nginx/passwd_scrcpy_web
    tee /etc/nginx/sites-available/reverse-proxy <<EOF
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
    ln -s /etc/nginx/sites-available/reverse-proxy /etc/nginx/sites-enabled/ 2>/dev/null || true
    nginx -t
    if [ $? -ne 0 ]; then
        _red "Error: There is an error in the reverse proxy configuration file. Please check："
        _yellow "https://zipline.diced.tech/docs/guides/nginx/nginx-no-ssl"
        exit 1
    fi
    if command -v systemctl >/dev/null 2>&1; then
        systemctl restart nginx
    else
        service nginx restart 2>/dev/null || nginx -s reload 2>/dev/null || nginx
    fi
}

if ! command -v docker >/dev/null 2>&1; then
    _yellow "There is no Docker environment on this machine, please execute the main installation first."
    _yellow "没有Docker环境，请先执行主体安装"
    exit 1
fi
name="${1:-android}"
selected_tag="${2:-8.1.0-latest}"
user_name="${3:-onea}"
user_password="${4:-oneclick}"
ws_scrcpy_service_preexisting=false
ws_scrcpy_runner_preexisting=false
[ -f /etc/systemd/system/ws-scrcpy.service ] && ws_scrcpy_service_preexisting=true
[ -f /root/ws-scrcpy/nohup-ws-scrcpy.sh ] && ws_scrcpy_runner_preexisting=true
cleanup_android_partial() {
    docker rm -f "$name" >/dev/null 2>&1 || true
    local redroid_images
    redroid_images=$(docker images | awk '/redroid/ {print $3}')
    if [ -n "$redroid_images" ]; then
        docker rmi $redroid_images >/dev/null 2>&1 || true
    fi
    rm -rf /etc/nginx/sites-enabled/reverse-proxy
    rm -rf /etc/nginx/sites-available/reverse-proxy
    rm -rf /etc/nginx/passwd_scrcpy_web
    if [ "$ws_scrcpy_service_preexisting" = "false" ]; then
        if command -v systemctl >/dev/null 2>&1; then
            systemctl stop ws-scrcpy.service >/dev/null 2>&1 || true
            systemctl daemon-reload >/dev/null 2>&1 || true
        fi
        rm -rf /etc/systemd/system/ws-scrcpy.service
    fi
    [ "$ws_scrcpy_runner_preexisting" = "false" ] && rm -rf /root/ws-scrcpy/nohup-ws-scrcpy.sh
    rm -rf /root/android_info
}
if [[ ! "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]]; then
    _red "Invalid container name: ${name}"
    _red "容器名称非法: ${name}"
    exit 1
fi
if [[ ! "$selected_tag" =~ ^[A-Za-z0-9_.-]+$ ]]; then
    _red "Invalid Android image tag: ${selected_tag}"
    _red "Android 镜像标签非法: ${selected_tag}"
    exit 1
fi
check_ipv4
check_nginx
check_dig
check_openssl
check_adb
if docker inspect "$name" >/dev/null 2>&1; then
    _yellow "Container $name already exists, please remove it before creating a new one."
    _yellow "容器 $name 已存在，请先删除后再重新创建。"
    exit 1
fi
if is_port_in_use 5555; then
    _red "Port 5555 is already in use."
    _red "端口 5555 已被占用。"
    exit 1
fi
ensure_ws_scrcpy
android_data_dir="/root/android/data"
if [ -d "$android_data_dir" ] && [ -n "$(find "$android_data_dir" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]; then
    case "${ANDROID_RESET_DATA:-}" in
        [Tt][Rr][Uu][Ee]|1|[Yy]|[Yy][Ee][Ss])
            rm -rf "$android_data_dir"
            _yellow "ANDROID_RESET_DATA=true detected, existing Android data was removed."
            _yellow "检测到 ANDROID_RESET_DATA=true，已清理旧 Android 数据。"
            ;;
        *)
            _yellow "Existing Android data found at $android_data_dir, reusing it. Set ANDROID_RESET_DATA=true for a clean data directory."
            _yellow "检测到 $android_data_dir 已有数据，本次将复用。如需清空请设置 ANDROID_RESET_DATA=true。"
            ;;
    esac
fi
# rm -rf /root/scrcpy_web/data
if [ ! -d "$android_data_dir" ]; then
    mkdir -p "$android_data_dir"
fi
# if [ ! -d "/root/scrcpy_web/data" ]; then
#     mkdir -p "/root/scrcpy_web/data"
# fi
# https://hub.docker.com/r/redroid/redroid/tags
if ! docker run -d \
    --name "${name}" \
    --restart=unless-stopped \
    --memory-swappiness=0 \
    --privileged --pull always \
    -p 5555:5555 \
    -v /root/android/data:/data \
    "redroid/redroid:${selected_tag}" \
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
    redroid.gpu.mode=guest; then
    _yellow "The container $name failed to create and the script will exit."
    _yellow "容器 $name 创建失败，脚本将退出。"
    exit 1
fi
sleep 5
# 守护进程似乎无法识别npm项目，待修复
if command -v systemctl >/dev/null 2>&1 && [ ! -f /etc/systemd/system/ws-scrcpy.service ]; then
    if ! curl -fsSL https://raw.githubusercontent.com/oneclickvirt/docker/main/extra_scripts/ws-scrcpy.service -o /etc/systemd/system/ws-scrcpy.service || \
       ! curl -fsSL https://raw.githubusercontent.com/oneclickvirt/docker/main/extra_scripts/nohup-ws-scrcpy.sh -o /root/ws-scrcpy/nohup-ws-scrcpy.sh; then
        _red "Failed to download ws-scrcpy service files."
        _red "下载 ws-scrcpy 服务文件失败。"
        cleanup_android_partial
        exit 1
    fi
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
    if ! systemctl start ws-scrcpy.service || ! systemctl enable ws-scrcpy.service; then
        _red "Failed to start ws-scrcpy.service."
        _red "启动 ws-scrcpy.service 失败。"
        cleanup_android_partial
        exit 1
    fi
elif command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload
    if ! systemctl restart ws-scrcpy.service; then
        _red "Failed to restart ws-scrcpy.service."
        _red "重启 ws-scrcpy.service 失败。"
        cleanup_android_partial
        exit 1
    fi
else
    if ! curl -fsSL https://raw.githubusercontent.com/oneclickvirt/docker/main/extra_scripts/nohup-ws-scrcpy.sh -o /root/ws-scrcpy/nohup-ws-scrcpy.sh; then
        _red "Failed to download nohup-ws-scrcpy.sh."
        _red "下载 nohup-ws-scrcpy.sh 失败。"
        cleanup_android_partial
        exit 1
    fi
    chmod +x /root/ws-scrcpy/nohup-ws-scrcpy.sh
    env_path=$(echo $PATH)
    sed -i "7s|.*|export PATH=${env_path}|" /root/ws-scrcpy/nohup-ws-scrcpy.sh
    (cd /root/ws-scrcpy && nohup bash nohup-ws-scrcpy.sh > /root/ws-scrcpy.log 2>&1 &)
fi
# 不再使用docker进行web-scrcpy映射，使用上面的守护进程进行映射
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
        status=$(docker inspect -f '{{.State.Status}}' "$container" 2>/dev/null)
        if [ "$status" != "running" ]; then
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
pkill -x adb 2>/dev/null || killall adb 2>/dev/null || true
rm -rf adb-nohup.out
nohup adb connect localhost:5555 > adb-nohup.out &
sleep 5
output=$(cat adb-nohup.out)
if [ $? -ne 0 ] || [[ $output == *"failed to connect to"* ]]; then
    cleanup_android_partial
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
_green "Successful installation, the above address login encounter page display 502, wait 1~2 minutes and then refresh to load the page!"
_green "安装成功，上述地址登录遇到网页显示502的，等待1~2分钟后再刷新即可加载页面"
