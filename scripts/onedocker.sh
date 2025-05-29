#!/bin/bash
# from
# https://github.com/oneclickvirt/docker
# 2025.05.29

# ./onedocker.sh name cpu memory password sshport startport endport <independent_ipv6> <system>
# <disk>

cd /root >/dev/null 2>&1
name="${1:-test}"
cpu="${2:-1}"
memory="${3:-512}"
passwd="${4:-123456}"
sshport="${5:-25000}"
startport="${6:-34975}"
endport="${7:-35000}"
independent_ipv6="${8:-N}"
independent_ipv6=$(echo "$independent_ipv6" | tr '[:upper:]' '[:lower:]')
system="${9:-debian}"

_red() { echo -e "\033[31m\033[01m$@\033[0m"; }
_green() { echo -e "\033[32m\033[01m$@\033[0m"; }
_yellow() { echo -e "\033[33m\033[01m$@\033[0m"; }
_blue() { echo -e "\033[36m\033[01m$@\033[0m"; }
if ! command -v docker >/dev/null 2>&1; then
    _yellow "There is no Docker environment on this machine, please execute the main installation first."
    _yellow "没有Docker环境，请先执行主体安装"
    exit 1
fi

check_china() {
    echo "IP area being detected ......"
    if [[ -z "${CN}" ]]; then
        if [[ $(curl -m 6 -s https://ipapi.co/json | grep 'China') != "" ]]; then
            echo "根据ipapi.co提供的信息，当前IP可能在中国，使用中国镜像完成相关组件安装"
            CN=true
        fi
    fi
}

check_cdn() {
    local o_url=$1
    local shuffled_cdn_urls=($(shuf -e "${cdn_urls[@]}")) # 打乱数组顺序
    for cdn_url in "${shuffled_cdn_urls[@]}"; do
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

check_lxcfs() {
    lxcfs_available="N"
    if systemctl is-active --quiet lxcfs && [ -d "/var/lib/lxcfs/proc" ]; then
        if [ -f "/var/lib/lxcfs/proc/cpuinfo" ] && [ -f "/var/lib/lxcfs/proc/meminfo" ] && [ -f "/var/lib/lxcfs/proc/stat" ]; then
            _green "lxcfs is available and running"
            _green "lxcfs 可用且正在运行"
            lxcfs_available="Y"
        else
            _yellow "lxcfs service is running but proc files are not available"
            _yellow "lxcfs 服务正在运行但 proc 文件不可用"
        fi
    else
        _yellow "lxcfs is not available or not running"
        _yellow "lxcfs 不可用或未运行"
    fi
}

get_arch() {
    local arch=$(uname -m)
    case $arch in
        x86_64)
            echo "amd64"
            ;;
        aarch64|arm64)
            echo "arm64"
            ;;
        *)
            echo "amd64" # 默认使用amd64
            ;;
    esac
}

download_and_load_image() {
    local system_type=$1
    local arch=$(get_arch)
    local tar_filename="spiritlhl_${system_type}_${arch}.tar.gz"
    local image_tag="spiritlhl:${system_type}"
    if docker images | grep -q "spiritlhl.*${system_type}"; then
        _green "Image spiritlhl:${system_type} already exists"
        _green "镜像 spiritlhl:${system_type} 已存在"
        return 0
    fi
    _yellow "Downloading ${system_type} image for ${arch} architecture..."
    _yellow "正在下载 ${system_type} 的 ${arch} 架构镜像..."
    local download_url=""
    case $system_type in
        "ubuntu")
            download_url="${cdn_success_url}https://github.com/oneclickvirt/docker/releases/download/ubuntu/spiritlhl_ubuntu_${arch}.tar.gz"
            ;;
        "debian")
            download_url="${cdn_success_url}https://github.com/oneclickvirt/docker/releases/download/debian/spiritlhl_debian_${arch}.tar.gz"
            ;;
        "alpine")
            download_url="${cdn_success_url}https://github.com/oneclickvirt/docker/releases/download/alpine/spiritlhl_alpine_${arch}.tar.gz"
            ;;
        "almalinux")
            download_url="${cdn_success_url}https://github.com/oneclickvirt/docker/releases/download/almalinux/spiritlhl_almalinux_${arch}.tar.gz"
            ;;
        "rockylinux")
            download_url="${cdn_success_url}https://github.com/oneclickvirt/docker/releases/download/rockylinux/spiritlhl_rockylinux_${arch}.tar.gz"
            ;;
        "openeuler")
            download_url="${cdn_success_url}https://github.com/oneclickvirt/docker/releases/download/openeuler/spiritlhl_openeuler_${arch}.tar.gz"
            ;;
        *)
            _red "Unsupported system type: $system_type"
            _red "不支持的系统类型: $system_type"
            exit 1
            ;;
    esac
    curl -L "$download_url" -o "$tar_filename" --connect-timeout 10 --max-time 300
    if [ -f "$tar_filename" ] && [ -s "$tar_filename" ]; then
        _yellow "Loading image from tar file..."
        _yellow "正在从tar文件加载镜像..."
        docker load < "$tar_filename"
        if [ $? -eq 0 ]; then
            _green "Image loaded successfully from tar file"
            _green "从tar文件加载镜像成功"
            rm -f "$tar_filename"
            return 0
        else
            _red "Failed to load image from tar file"
            _red "从tar文件加载镜像失败"
            rm -f "$tar_filename"
        fi
    else
        _yellow "Failed to download tar file or file is empty"
        _yellow "下载tar文件失败或文件为空"
        rm -f "$tar_filename" 2>/dev/null
    fi
    _yellow "Trying to pull image from Docker Hub: ${system_type}:latest"
    _yellow "尝试从Docker Hub拉取镜像: ${system_type}:latest"
    docker pull "${system_type}:latest"
    if [ $? -eq 0 ]; then
        docker tag "${system_type}:latest" "spiritlhl:${system_type}"
        _green "Image pulled and tagged successfully"
        _green "镜像拉取并标记成功"
        return 0
    else
        _red "Failed to pull image from Docker Hub"
        _red "从Docker Hub拉取镜像失败"
        exit 1
    fi
}

check_china
cdn_urls=("https://cdn0.spiritlhl.top/" "http://cdn1.spiritlhl.net/" "http://cdn2.spiritlhl.net/" "http://cdn3.spiritlhl.net/" "http://cdn4.spiritlhl.net/")
if [ "${CN}" == true ]; then
    check_cdn_file
fi
check_lxcfs
docker network inspect ipv6_net &>/dev/null
if [ $? -eq 0 ]; then
    _green "ipv6_net exists in the Docker network"
    _green "ipv6_net 存在于 Docker 网络中"
    ipv6_net_status="Y"
else
    _yellow "ipv6_net does not exist in the Docker network"
    _yellow "ipv6_net 不存在于 Docker 网络中"
    ipv6_net_status="N"
fi
docker inspect ndpresponder &>/dev/null
if [ $? -eq 0 ]; then
    container_status=$(docker inspect -f '{{.State.Status}}' ndpresponder)
    if [ "$container_status" == "running" ]; then
        _green "ndpresponder container exists and is running"
        _green "ndpresponder 容器存在且正在运行"
        ndpresponder_status="Y"
    else
        _yellow "ndpresponder Container exists but is not in running state"
        _yellow "ndpresponder 容器存在，但未在运行状态"
        ndpresponder_status="N"
    fi
else
    _yellow "ndpresponder container does not exist"
    _yellow "ndpresponder 容器不存在"
    ndpresponder_status="N"
fi
if [ -f /usr/local/bin/docker_check_ipv6 ] && [ -s /usr/local/bin/docker_check_ipv6 ] && [ "$(sed -e '/^[[:space:]]*$/d' /usr/local/bin/docker_check_ipv6)" != "" ]; then
    ipv6_address=$(cat /usr/local/bin/docker_check_ipv6)
    ipv6_address_without_last_segment="${ipv6_address%:*}:"
fi
lxcfs_volumes=""
if [ "$lxcfs_available" = "Y" ]; then
    lxcfs_volumes="--volume /var/lib/lxcfs/proc/cpuinfo:/proc/cpuinfo:rw \
        --volume /var/lib/lxcfs/proc/diskstats:/proc/diskstats:rw \
        --volume /var/lib/lxcfs/proc/meminfo:/proc/meminfo:rw \
        --volume /var/lib/lxcfs/proc/stat:/proc/stat:rw \
        --volume /var/lib/lxcfs/proc/swaps:/proc/swaps:rw \
        --volume /var/lib/lxcfs/proc/uptime:/proc/uptime:rw"
fi
download_and_load_image $system
if [ -n "$system" ] && [ "$system" = "alpine" ]; then
    if [ "$ndpresponder_status" = "Y" ] && [ "$ipv6_net_status" = "Y" ] && [ ! -z "$ipv6_address" ] && [ ! -z "$ipv6_address_without_last_segment" ] && [ "$independent_ipv6" = "y" ]; then
        docker run -d \
            --cpus=${cpu} \
            --memory=${memory}m \
            --name ${name} \
            --network=ipv6_net \
            -p ${sshport}:22 \
            -p ${startport}-${endport}:${startport}-${endport} \
            --cap-add=MKNOD \
            -e ROOT_PASSWORD=${passwd} \
            -e IPV6_ENABLED=true \
            ${lxcfs_volumes} \
            spiritlhl:alpine
        docker_use_ipv6=true
    else
        docker run -d \
            --cpus=${cpu} \
            --memory=${memory}m \
            --name ${name} \
            -p ${sshport}:22 \
            -p ${startport}-${endport}:${startport}-${endport} \
            --cap-add=MKNOD \
            -e ROOT_PASSWORD=${passwd} \
            ${lxcfs_volumes} \
            spiritlhl:alpine
        docker_use_ipv6=false
    fi
    docker exec -it ${name} sh -c "sh /ssh_sh.sh ${passwd}"
    docker exec -it ${name} sh -c "echo 'root:${passwd}' | chpasswd"
    echo "$name $sshport $passwd $cpu $memory $startport $endport $disk" >>"$name"
else
    if [ "$ndpresponder_status" = "Y" ] && [ "$ipv6_net_status" = "Y" ] && [ ! -z "$ipv6_address" ] && [ ! -z "$ipv6_address_without_last_segment" ] && [ "$independent_ipv6" = "y" ]; then
        docker run -d \
            --cpus=${cpu} \
            --memory=${memory}m \
            --name ${name} \
            --network=ipv6_net \
            -p ${sshport}:22 \
            -p ${startport}-${endport}:${startport}-${endport} \
            --cap-add=MKNOD \
            -e ROOT_PASSWORD=${passwd} \
            -e IPV6_ENABLED=true \
            ${lxcfs_volumes} \
            spiritlhl:${system}
        docker_use_ipv6=true
    else
        docker run -d \
            --cpus=${cpu} \
            --memory=${memory}m \
            --name ${name} \
            -p ${sshport}:22 \
            -p ${startport}-${endport}:${startport}-${endport} \
            --cap-add=MKNOD \
            -e ROOT_PASSWORD=${passwd} \
            ${lxcfs_volumes} \
            spiritlhl:${system}
        docker_use_ipv6=false
    fi
    docker exec -it ${name} bash -c "bash /ssh_bash.sh ${passwd}"
    docker exec -it ${name} bash -c "echo 'root:${passwd}' | chpasswd"
    echo "$name $sshport $passwd $cpu $memory $startport $endport $disk" >>"$name"
fi

cat "$name"
