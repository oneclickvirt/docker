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

if ! command -v docker >/dev/null 2>&1; then
    _yellow "There is no Docker environment on this machine, please execute the main installation first."
    _yellow "没有Docker环境，请先执行主体安装"
    exit 1
fi

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

cleanup_guacamole() {
    docker rm -f guacamole-client guacamole-server guacamoledb >/dev/null 2>&1 || true
    if [ "${network_created:-false}" = "true" ]; then
        docker network rm "$GUACAMOLE_NETWORK" >/dev/null 2>&1 || true
    fi
}

sql_escape() {
    printf "%s" "$1" | sed "s/'/''/g"
}

GUACAMOLE_DB_NAME="${GUACAMOLE_DB_NAME:-guacdb}"
GUACAMOLE_DB_USER="${GUACAMOLE_DB_USER:-guacadmin}"
GUACAMOLE_MYSQL_ROOT_PASSWORD="${GUACAMOLE_MYSQL_ROOT_PASSWORD:-password}"
GUACAMOLE_MYSQL_PASSWORD="${GUACAMOLE_MYSQL_PASSWORD:-password}"
GUACAMOLE_PORT="${GUACAMOLE_PORT:-80}"
GUACAMOLE_NETWORK="${GUACAMOLE_NETWORK:-guacamole_net}"

if [[ ! "$GUACAMOLE_DB_NAME" =~ ^[A-Za-z0-9_]+$ ]] || [[ ! "$GUACAMOLE_DB_USER" =~ ^[A-Za-z0-9_]+$ ]]; then
    _red "GUACAMOLE_DB_NAME and GUACAMOLE_DB_USER may only contain letters, numbers, and underscores."
    _red "GUACAMOLE_DB_NAME 和 GUACAMOLE_DB_USER 只能包含字母、数字和下划线。"
    exit 1
fi
if [[ ! "$GUACAMOLE_NETWORK" =~ ^[A-Za-z0-9_.-]+$ ]]; then
    _red "GUACAMOLE_NETWORK may only contain letters, numbers, dots, underscores, and dashes."
    _red "GUACAMOLE_NETWORK 只能包含字母、数字、点、下划线和短横线。"
    exit 1
fi
if [[ ! "$GUACAMOLE_PORT" =~ ^[0-9]+$ ]] || [ "$GUACAMOLE_PORT" -lt 1 ] || [ "$GUACAMOLE_PORT" -gt 65535 ]; then
    _red "Invalid GUACAMOLE_PORT: $GUACAMOLE_PORT"
    _red "GUACAMOLE_PORT 非法: $GUACAMOLE_PORT"
    exit 1
fi
if is_port_in_use "$GUACAMOLE_PORT"; then
    _red "Port ${GUACAMOLE_PORT} is already in use."
    _red "端口 ${GUACAMOLE_PORT} 已被占用。"
    exit 1
fi

${PACKAGE_INSTALL[int]} ca-certificates gnupg lsb-release
check_ipv4
for existing_container in guacamoledb guacamole-server guacamole-client; do
    if docker inspect "$existing_container" >/dev/null 2>&1; then
        _yellow "Container $existing_container already exists, please remove it before reinstalling Guacamole."
        _yellow "容器 $existing_container 已存在，请先删除后再重新安装 Guacamole。"
        exit 1
    fi
done
if ! docker network inspect "$GUACAMOLE_NETWORK" >/dev/null 2>&1; then
    if ! docker network create "$GUACAMOLE_NETWORK" >/dev/null; then
        _red "Failed to create Docker network: $GUACAMOLE_NETWORK"
        _red "创建 Docker 网络失败: $GUACAMOLE_NETWORK"
        exit 1
    fi
    network_created=true
else
    network_created=false
fi
if ! docker pull mysql/mysql-server || ! docker pull guacamole/guacd || ! docker pull guacamole/guacamole; then
    _red "Failed to pull Guacamole/MySQL images"
    _red "拉取 Guacamole/MySQL 镜像失败"
    cleanup_guacamole
    exit 1
fi
if ! docker run --name guacamoledb \
    --network "$GUACAMOLE_NETWORK" \
    -e MYSQL_ROOT_PASSWORD="$GUACAMOLE_MYSQL_ROOT_PASSWORD" \
    -e MYSQL_DATABASE="$GUACAMOLE_DB_NAME" \
    -d mysql/mysql-server; then
    _red "Failed to create guacamoledb"
    _red "创建 guacamoledb 失败"
    cleanup_guacamole
    exit 1
fi
mysql_start_time=$(date +%s)
MYSQL_MAX_WAIT_TIME=120
while true; do
    status=$(docker inspect --format "{{.State.Health.Status}}" guacamoledb 2>/dev/null || echo "starting")
    if [ "$status" == "healthy" ]; then
        break
    fi
    current_time=$(date +%s)
    if [ "$((current_time - mysql_start_time))" -ge "$MYSQL_MAX_WAIT_TIME" ]; then
        _yellow "The MySQL container did not become healthy in time and the script will exit."
        _yellow "MySQL 容器未能在限定时间内进入 healthy 状态，脚本将退出。"
        cleanup_guacamole
        exit 1
    fi
    _yellow "Please be patient while waiting for the MySQL container to start..."
    _yellow "等待MySQL容器启动中，请耐心等待..."
    sleep 2
done
mkdir -p /opt/guacamole/mysql
if ! docker run --rm guacamole/guacamole /opt/guacamole/bin/initdb.sh --mysql >/opt/guacamole/mysql/temp-initdb.sql; then
    _red "Failed to generate Guacamole database schema"
    _red "生成 Guacamole 数据库结构失败"
    cleanup_guacamole
    exit 1
fi
if ! docker exec -i guacamoledb mysql -h localhost -u root -p"$GUACAMOLE_MYSQL_ROOT_PASSWORD" "$GUACAMOLE_DB_NAME" </opt/guacamole/mysql/temp-initdb.sql; then
    _red "Failed to initialize Guacamole database schema"
    _red "初始化 Guacamole 数据库结构失败"
    cleanup_guacamole
    exit 1
fi
escaped_mysql_password=$(sql_escape "$GUACAMOLE_MYSQL_PASSWORD")
if ! docker exec guacamoledb mysql -h localhost -u root -p"$GUACAMOLE_MYSQL_ROOT_PASSWORD" -e "CREATE USER IF NOT EXISTS '${GUACAMOLE_DB_USER}'@'%' IDENTIFIED BY '${escaped_mysql_password}'; GRANT SELECT,UPDATE,INSERT,DELETE ON \`${GUACAMOLE_DB_NAME}\`.* TO '${GUACAMOLE_DB_USER}'@'%'; FLUSH PRIVILEGES;"; then
    _red "Failed to create Guacamole database user"
    _red "创建 Guacamole 数据库用户失败"
    cleanup_guacamole
    exit 1
fi
sleep 3
docker logs guacamoledb
if ! docker run --name guacamole-server --network "$GUACAMOLE_NETWORK" -d guacamole/guacd; then
    _red "Failed to create guacamole-server"
    _red "创建 guacamole-server 失败"
    cleanup_guacamole
    exit 1
fi
docker logs --tail 10 guacamole-server
sleep 3
start_time=$(date +%s)
MAX_WAIT_TIME=6
CONTAINERS=("guacamoledb" "guacamole-server")
for container in "${CONTAINERS[@]}"; do
    status=$(docker inspect -f '{{.State.Status}}' "$container" 2>/dev/null)
    if [ "$status" != "running" ]; then
        _yellow "The container $container failed to start and the script will exit."
        _yellow "容器 $container 启动失败，脚本将退出。"
        cleanup_guacamole
        exit 1
    fi
    sleep 1
done
while true; do
    current_time=$(date +%s)
    elapsed_time=$((current_time - start_time))
    if [ "$elapsed_time" -ge "$MAX_WAIT_TIME" ]; then
        break
    fi
    all_successful=true
    for container in "${CONTAINERS[@]}"; do
        status=$(docker inspect -f '{{.State.Status}}' "$container" 2>/dev/null || echo "unknown")
        if [ "$status" != "running" ]; then
            all_successful=false
            break
        fi
    done
    if [ "$all_successful" = true ]; then
        break
    fi
    sleep 2
    echo "Please be patient while waiting for the container to start..."
    echo "等待容器启动中，请耐心等待..."
done
if ! docker run --name guacamole-client \
    --network "$GUACAMOLE_NETWORK" \
    -e GUACD_HOSTNAME=guacamole-server \
    -e MYSQL_HOSTNAME=guacamoledb \
    -e MYSQL_DATABASE="$GUACAMOLE_DB_NAME" \
    -e MYSQL_USER="$GUACAMOLE_DB_USER" \
    -e MYSQL_PASSWORD="$GUACAMOLE_MYSQL_PASSWORD" \
    -d -p "${GUACAMOLE_PORT}:8080" guacamole/guacamole; then
    _red "Failed to create guacamole-client"
    _red "创建 guacamole-client 失败"
    cleanup_guacamole
    exit 1
fi
sleep 3
_yellow "guacamole目前的信息："
_blue "用户名-username: guacadmin"
_blue "密码-password: guacadmin"
_blue "登录地址-website：http://${IPV4}:${GUACAMOLE_PORT}/guacamole"
