#!/bin/bash
# from
# https://github.com/oneclickvirt/docker
# 2026.03.01

# ./onedocker.sh name cpu memory password sshport startport endport <independent_ipv6> <system> <disk>

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
disk="${10:-0}"

_red() { echo -e "\033[31m\033[01m$@\033[0m"; }
_green() { echo -e "\033[32m\033[01m$@\033[0m"; }
_yellow() { echo -e "\033[33m\033[01m$@\033[0m"; }
_blue() { echo -e "\033[36m\033[01m$@\033[0m"; }
if ! command -v docker >/dev/null 2>&1; then
    _yellow "There is no Docker environment on this machine, please execute the main installation first."
    _yellow "没有Docker环境，请先执行主体安装"
    exit 1
fi

cdn_urls=("https://cdn0.spiritlhl.top/" "http://cdn1.spiritlhl.net/" "http://cdn2.spiritlhl.net/" "http://cdn3.spiritlhl.net/" "http://cdn4.spiritlhl.net/")
cdn_success_url=""

check_storage_driver() {
    storage_driver="overlay2"
    if [ -f /usr/local/bin/docker_storage_driver ]; then
        storage_driver=$(cat /usr/local/bin/docker_storage_driver)
    fi
    
    if [ "$storage_driver" = "btrfs" ]; then
        btrfs_support="Y"
        _green "Detected btrfs storage driver, disk size limitation is supported"
        _green "检测到btrfs存储驱动，支持硬盘大小限制"
    else
        btrfs_support="N"
        if [ "$disk" != "0" ]; then
            _yellow "Current storage driver ($storage_driver) does not support disk size limitation, ignoring disk parameter"
            _yellow "当前存储驱动($storage_driver)不支持硬盘大小限制，忽略硬盘参数"
            disk="0"
        fi
    fi
}

check_cdn() {
    local o_url=$1
    local shuffled_cdn_urls=($(shuf -e "${cdn_urls[@]}")) # 打乱数组顺序
    for cdn_url in "${shuffled_cdn_urls[@]}"; do
        if curl -4 -sL -k "$cdn_url$o_url" --max-time 6 | grep -q "success" >/dev/null 2>&1; then
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

check_image_exists() {
    local system_type=$1
    local arch=$(get_arch)
    # 查找 GHCR 镜像（优先）
    if docker images --format '{{.Repository}}:{{.Tag}}' | grep -qx "ghcr.io/oneclickvirt/docker:${system_type}-${arch}"; then
        _green "Image ghcr.io/oneclickvirt/docker:${system_type}-${arch} already exists"
        _green "镜像 ghcr.io/oneclickvirt/docker:${system_type}-${arch} 已存在"
        export image_name="ghcr.io/oneclickvirt/docker:${system_type}-${arch}"
        return 0
    fi
    # 查找 spiritlhl:system-arch 格式
    if docker images --format '{{.Repository}}:{{.Tag}}' | grep -qx "spiritlhl:${system_type}-${arch}"; then
        _green "Image spiritlhl:${system_type}-${arch} already exists"
        _green "镜像 spiritlhl:${system_type}-${arch} 已存在"
        export image_name="spiritlhl:${system_type}-${arch}"
        return 0
    fi
    # 再查找 spiritlhl:system 格式（不含 arch）
    if docker images --format '{{.Repository}}:{{.Tag}}' | grep -qx "spiritlhl:${system_type}"; then
        _green "Image spiritlhl:${system_type} already exists"
        _green "镜像 spiritlhl:${system_type} 已存在"
        export image_name="spiritlhl:${system_type}"
        return 0
    fi
    # 最后查找 system:latest 格式
    if docker images --format '{{.Repository}}:{{.Tag}}' | grep -qx "${system_type}:latest"; then
        _green "Image ${system_type}:latest already exists"
        _green "镜像 ${system_type}:latest 已存在"
        export image_name="${system_type}:latest"
        return 0
    fi
    return 1
}

download_and_load_image() {
    local system_type=$1
    local arch=$(get_arch)
    local tar_filename="spiritlhl_${system_type}_${arch}.tar.gz"
    local canonical_image="spiritlhl:${system_type}-${arch}"

    # 优先：通过 CDN/GitHub Releases 下载离线 tar 包
    local github_url="https://github.com/oneclickvirt/docker/releases/download/${system_type}/${tar_filename}"
    local download_url="${cdn_success_url}${github_url}"
    _yellow "Downloading image tar: $download_url"
    _yellow "正在下载镜像 tar 包: $download_url"

    if curl -L --connect-timeout 15 --max-time 600 -o "/tmp/${tar_filename}" "$download_url" && \
       [[ -f "/tmp/${tar_filename}" ]] && [[ -s "/tmp/${tar_filename}" ]]; then
        _yellow "Loading image from tar file..."
        _yellow "正在从 tar 文件加载镜像..."
        if docker load < "/tmp/${tar_filename}"; then
            rm -f "/tmp/${tar_filename}"
            export image_name="${canonical_image}"
            _green "Image loaded successfully: ${image_name}"
            _green "镜像加载成功: ${image_name}"
            return 0
        else
            _yellow "Failed to load tar, removing..."
            _yellow "tar 加载失败，删除文件..."
            rm -f "/tmp/${tar_filename}"
        fi
    else
        _yellow "CDN/direct download failed: ${download_url}"
        _yellow "CDN/直连下载失败: ${download_url}"
        rm -f "/tmp/${tar_filename}" 2>/dev/null
    fi

    # 回退：从 GHCR 拉取镜像
    local ghcr_image="ghcr.io/oneclickvirt/docker:${system_type}-${arch}"
    _yellow "Trying to pull from GHCR: $ghcr_image"
    _yellow "尝试从 GHCR 拉取镜像: $ghcr_image"
    if docker pull "${ghcr_image}" 2>/dev/null; then
        docker tag "${ghcr_image}" "${canonical_image}" 2>/dev/null || true
        export image_name="${canonical_image}"
        _green "Image pulled from GHCR: ${ghcr_image}"
        _green "从 GHCR 拉取镜像成功: ${ghcr_image}"
        return 0
    fi

    # 最后回退：从 Docker Hub 拉取官方基础镜像
    _yellow "Trying to pull from Docker Hub: ${system_type}:latest"
    _yellow "尝试从 Docker Hub 拉取镜像: ${system_type}:latest"
    if docker pull "${system_type}:latest"; then
        export image_name="${system_type}:latest"
        _green "Image pulled from Docker Hub: ${image_name}"
        _green "从 Docker Hub 拉取镜像成功: ${image_name}"
        return 0
    fi

    _red "Failed to obtain image for ${system_type}"
    _red "无法获取 ${system_type} 的镜像，所有方法均失败"
    exit 1
}

download_ssh_scripts() {
    local container_name=$1
    local system_type=$2
    
    # 检查容器内是否已存在SSH脚本
    if [ "$system_type" = "alpine" ]; then
        if docker exec "$container_name" sh -c "[ -f /ssh_sh.sh ]" 2>/dev/null; then
            _green "SSH script already exists in container"
            _green "容器内SSH脚本已存在"
            return 0
        fi
        script_name="ssh_sh.sh"
    else
        if docker exec "$container_name" bash -c "[ -f /ssh_bash.sh ]" 2>/dev/null; then
            _green "SSH script already exists in container"
            _green "容器内SSH脚本已存在"
            return 0
        fi
        script_name="ssh_bash.sh"
    fi
    
    _yellow "SSH script not found in container, downloading..."
    _yellow "容器内未找到SSH脚本，正在下载..."
    
    # 构建下载URL
    local script_url="${cdn_success_url}https://raw.githubusercontent.com/oneclickvirt/docker/refs/heads/main/scripts/${script_name}"
    
    # 下载脚本到宿主机临时位置
    local temp_script="/tmp/${script_name}"
    curl -L "$script_url" -o "$temp_script" --connect-timeout 10 --max-time 30
    
    if [ -f "$temp_script" ] && [ -s "$temp_script" ]; then
        # 复制脚本到容器内
        docker cp "$temp_script" "${container_name}:/${script_name}"
        if [ $? -eq 0 ]; then
            # 给脚本添加执行权限
            if [ "$system_type" = "alpine" ]; then
                docker exec "$container_name" sh -c "chmod +x /${script_name}"
            else
                docker exec "$container_name" bash -c "chmod +x /${script_name}"
            fi
            _green "SSH script downloaded and copied to container successfully"
            _green "SSH脚本下载并复制到容器成功"
            rm -f "$temp_script"
            return 0
        else
            _red "Failed to copy SSH script to container"
            _red "复制SSH脚本到容器失败"
            rm -f "$temp_script"
            return 1
        fi
    else
        _red "Failed to download SSH script"
        _red "下载SSH脚本失败"
        rm -f "$temp_script" 2>/dev/null
        return 1
    fi
}

check_cdn_file
check_lxcfs
check_storage_driver
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

# 先检查镜像是否存在，不存在才下载
if ! check_image_exists $system; then
    download_and_load_image $system
fi
storage_opts=""
if [ "$btrfs_support" = "Y" ] && [ "$disk" != "0" ]; then
    storage_opts="--storage-opt size=${disk}G"
fi
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
            ${storage_opts} \
            ${lxcfs_volumes} \
            ${image_name}
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
            ${storage_opts} \
            ${lxcfs_volumes} \
            ${image_name}
        docker_use_ipv6=false
    fi
    # 下载SSH脚本（如果需要）
    download_ssh_scripts ${name} ${system}
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
            ${storage_opts} \
            ${lxcfs_volumes} \
            ${image_name}
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
            ${storage_opts} \
            ${lxcfs_volumes} \
            ${image_name}
        docker_use_ipv6=false
    fi
    # 下载SSH脚本（如果需要）
    download_ssh_scripts ${name} ${system}
    docker exec -it ${name} bash -c "bash /ssh_bash.sh ${passwd}"
    docker exec -it ${name} bash -c "echo 'root:${passwd}' | chpasswd"
    echo "$name $sshport $passwd $cpu $memory $startport $endport $disk" >>"$name"
fi

cat "$name"