#!/bin/bash
# from
# https://github.com/oneclickvirt/docker
# 2026.03.01

# ./onedocker.sh name cpu memory password sshport startport endport <independent_ipv6> <system> <disk>

cd /root >/dev/null 2>&1 || exit 1
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

_red() { echo -e "\033[31m\033[01m$*\033[0m"; }
_green() { echo -e "\033[32m\033[01m$*\033[0m"; }
_yellow() { echo -e "\033[33m\033[01m$*\033[0m"; }
_blue() { echo -e "\033[36m\033[01m$*\033[0m"; }

supported_system() {
    case "$1" in
        ubuntu|debian|alpine|almalinux|rockylinux|openeuler) return 0 ;;
    esac
    return 1
}

system_choices() {
    echo "ubuntu / debian / alpine / almalinux / rockylinux / openeuler"
}

normalize_system_type() {
    local raw="${1:-}"
    local value
    value=$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
    value="${value#images:}"
    value="${value#docker.io/library/}"
    value="${value#library/}"
    value="${value#ghcr.io/oneclickvirt/docker:}"
    value="${value#spiritlhl:}"
    value="${value%%@*}"

    case "$value" in
        ubuntu|ubuntu[0-9]*|ubuntu/*|ubuntu:*|ubuntu-*|ubuntu_*) echo "ubuntu" ;;
        debian|debian[0-9]*|debian/*|debian:*|debian-*|debian_*) echo "debian" ;;
        alpine|alpine[0-9]*|alpine/*|alpine:*|alpine-*|alpine_*) echo "alpine" ;;
        almalinux|almalinux[0-9]*|almalinux/*|almalinux:*|almalinux-*|almalinux_*|alma|alma[0-9]*|alma/*|alma:*|alma-*|alma_*) echo "almalinux" ;;
        rockylinux|rockylinux[0-9]*|rockylinux/*|rockylinux:*|rockylinux-*|rockylinux_*|rocky|rocky[0-9]*|rocky/*|rocky:*|rocky-*|rocky_*) echo "rockylinux" ;;
        openeuler|openeuler[0-9]*|openeuler/*|openeuler:*|openeuler-*|openeuler_*|open-euler|open-euler[0-9]*|open-euler/*|open-euler:*|open-euler-*|open_euler|open_euler[0-9]*|open_euler/*|open_euler:*|open_euler-*) echo "openeuler" ;;
        *) return 1 ;;
    esac
}

official_image_for_system() {
    case "$1" in
        ubuntu) echo "ubuntu:latest" ;;
        debian) echo "debian:latest" ;;
        alpine) echo "alpine:latest" ;;
        almalinux) echo "almalinux:latest" ;;
        rockylinux) echo "rockylinux/rockylinux:9" ;;
        openeuler) echo "openeuler/openeuler:22.03" ;;
        *) echo "$1:latest" ;;
    esac
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
    if command -v docker >/dev/null 2>&1 && docker ps -q 2>/dev/null | while read -r cid; do docker port "$cid" 2>/dev/null; done | awk -v suffix=":${port}" '$0 ~ suffix "$" {found=1} END {exit found ? 0 : 1}'; then
        return 0
    fi
    return 1
}

ensure_port_available() {
    local port="$1"
    if is_port_in_use "$port"; then
        _red "Port ${port} is already in use."
        _red "端口 ${port} 已被占用。"
        exit 1
    fi
}

normalize_inputs() {
    local raw_system="$system"
    local normalized_system
    if ! normalized_system=$(normalize_system_type "$raw_system"); then
        _red "Unsupported system: ${raw_system}"
        _red "不支持的系统: ${raw_system}"
        _yellow "Available systems / 可选系统: $(system_choices)"
        _yellow "Version-like input is accepted, for example: debian11, debian/11, ubuntu20, almalinux9, rockylinux9, openeuler22.03"
        _yellow "支持带版本号写法，例如：debian11、debian/11、ubuntu20、almalinux9、rockylinux9、openeuler22.03"
        exit 1
    fi
    if [ "$raw_system" != "$normalized_system" ]; then
        _yellow "Normalized system '${raw_system}' to '${normalized_system}'"
        _yellow "已将系统 '${raw_system}' 归一化为 '${normalized_system}'"
    fi
    system="$normalized_system"
    if ! supported_system "$system"; then
        _red "Unsupported system: ${system}"
        _red "不支持的系统: ${system}"
        exit 1
    fi
    if [[ ! "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]]; then
        _red "Invalid container name: ${name}"
        _red "容器名称非法: ${name}"
        exit 1
    fi
    if [[ ! "$cpu" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        _yellow "Invalid CPU value '${cpu}', using 1"
        cpu="1"
    fi
    if [[ ! "$memory" =~ ^[1-9][0-9]*$ ]]; then
        _yellow "Invalid memory value '${memory}', using 512MB"
        memory="512"
    fi
    if ! is_valid_port "$sshport" || ! is_valid_port "$startport" || ! is_valid_port "$endport"; then
        _red "Invalid port range: ssh=${sshport}, ports=${startport}-${endport}"
        _red "端口参数非法: ssh=${sshport}, ports=${startport}-${endport}"
        exit 1
    fi
    if [ "$startport" -gt "$endport" ]; then
        _red "Invalid port range: startport must be <= endport"
        _red "端口范围非法: 起始端口必须小于等于结束端口"
        exit 1
    fi
    if [ "$sshport" -ge "$startport" ] && [ "$sshport" -le "$endport" ]; then
        _red "Invalid port range: sshport must not overlap with forwarded port range"
        _red "端口范围非法: SSH 端口不能落在转发端口范围内"
        exit 1
    fi
    ensure_port_available "$sshport"
    local range_size=$((endport - startport + 1))
    if [ "$range_size" -le 512 ]; then
        local port
        for ((port = startport; port <= endport; port++)); do
            ensure_port_available "$port"
        done
    else
        _yellow "Large forwarded port range detected, skipping per-port preflight and relying on docker run validation."
        _yellow "转发端口范围较大，跳过逐端口预检查，由 docker run 执行最终校验。"
    fi
    if [[ ! "$disk" =~ ^[0-9]+$ ]]; then
        _yellow "Invalid disk value '${disk}', using 0"
        disk="0"
    fi
    [[ "$independent_ipv6" = "y" ]] || independent_ipv6="n"
}

without_cdn="false"
if [[ "${WITHOUTCDN^^}" == "TRUE" ]]; then
    without_cdn="true"
fi

normalize_inputs

if ! command -v docker >/dev/null 2>&1; then
    _yellow "There is no Docker environment on this machine, please execute the main installation first."
    _yellow "没有Docker环境，请先执行主体安装"
    exit 1
fi
if docker inspect "$name" >/dev/null 2>&1; then
    _red "Container ${name} already exists, please remove it before creating a new one."
    _red "容器 ${name} 已存在，请先删除后再重新创建。"
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
    local shuffled_cdn_urls=("${cdn_urls[@]}")
    if command -v shuf >/dev/null 2>&1; then
        shuffled_cdn_urls=()
        while IFS= read -r cdn_url; do
            shuffled_cdn_urls+=("$cdn_url")
        done < <(shuf -e "${cdn_urls[@]}")
    fi
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
    if [[ "$without_cdn" == "true" ]]; then
        export cdn_success_url=""
        _yellow "WITHOUTCDN=TRUE detected, CDN disabled"
        return
    fi
    check_cdn "https://raw.githubusercontent.com/spiritLHLS/ecs/main/back/test"
    if [ -n "$cdn_success_url" ]; then
        _yellow "CDN available, using CDN"
    else
        _yellow "No CDN available, no use CDN"
    fi
}

check_lxcfs() {
    lxcfs_available="N"
    if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet lxcfs && [ -d "/var/lib/lxcfs/proc" ]; then
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
    local arch
    arch=$(uname -m)
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
    local arch
    local images
    local ghcr_manifest="ghcr.io/oneclickvirt/docker:${system_type}"
    arch=$(get_arch)
    local ghcr_arch="ghcr.io/oneclickvirt/docker:${system_type}-${arch}"
    local canonical_image="spiritlhl:${system_type}-${arch}"
    local official_image
    official_image=$(official_image_for_system "$system_type")
    images=$(docker images --format '{{.Repository}}:{{.Tag}}')
    for candidate in \
        "$ghcr_manifest" \
        "$ghcr_arch" \
        "$canonical_image" \
        "spiritlhl:${system_type}" \
        "$official_image" \
        "${system_type}:latest"; do
        [ -n "$candidate" ] || continue
        if echo "$images" | grep -Fxq "$candidate"; then
            _green "Image ${candidate} already exists"
            _green "镜像 ${candidate} 已存在"
            export image_name="$candidate"
            return 0
        fi
    done
    return 1
}

download_and_load_image() {
    local system_type=$1
    local arch
    arch=$(get_arch)
    local tar_filename="spiritlhl_${system_type}_${arch}.tar.gz"
    local canonical_image="spiritlhl:${system_type}-${arch}"
    local ghcr_manifest="ghcr.io/oneclickvirt/docker:${system_type}"
    local ghcr_arch="ghcr.io/oneclickvirt/docker:${system_type}-${arch}"
    local official_image
    official_image=$(official_image_for_system "$system_type")

    # 优先：从 GHCR 拉取多架构镜像；失败后再尝试架构专用 tag
    for ghcr_image in "$ghcr_manifest" "$ghcr_arch"; do
        _yellow "Trying to pull from GHCR: $ghcr_image"
        _yellow "尝试从 GHCR 拉取镜像: $ghcr_image"
        if docker pull "${ghcr_image}" 2>/dev/null; then
            docker tag "${ghcr_image}" "${canonical_image}" 2>/dev/null || true
            export image_name="${canonical_image}"
            _green "Image pulled from GHCR: ${ghcr_image}"
            _green "从 GHCR 拉取镜像成功: ${ghcr_image}"
            return 0
        fi
    done

    # 回退：通过 CDN/GitHub Releases 下载离线 tar 包
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

    # 最后回退：从 Docker Hub 拉取官方基础镜像
    _yellow "Trying to pull from Docker Hub: ${official_image}"
    _yellow "尝试从 Docker Hub 拉取镜像: ${official_image}"
    if docker pull "${official_image}"; then
        export image_name="${official_image}"
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
    local script_name
    
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
    
    _yellow "SSH script not found in container, preparing ${script_name}..."
    _yellow "容器内未找到SSH脚本，正在准备 ${script_name}..."

    local source_script=""
    local cleanup_source="false"
    for candidate in "/root/${script_name}" "$(dirname "$0")/${script_name}"; do
        if [ -f "$candidate" ] && [ -s "$candidate" ]; then
            source_script="$candidate"
            break
        fi
    done
    if [ -z "$source_script" ]; then
        local script_url="${cdn_success_url}https://raw.githubusercontent.com/oneclickvirt/docker/refs/heads/main/scripts/${script_name}"
        source_script="/tmp/${script_name}"
        cleanup_source="true"
        curl -fsSL "$script_url" -o "$source_script" --connect-timeout 10 --max-time 30
    fi

    if [ -f "$source_script" ] && [ -s "$source_script" ]; then
        if docker cp "$source_script" "${container_name}:/${script_name}"; then
            if [ "$system_type" = "alpine" ]; then
                docker exec "$container_name" sh -c "chmod +x /${script_name}"
            else
                docker exec "$container_name" bash -c "chmod +x /${script_name}"
            fi
            _green "SSH script copied to container successfully"
            _green "SSH脚本复制到容器成功"
            [ "$cleanup_source" = "true" ] && rm -f "$source_script"
            return 0
        else
            _red "Failed to copy SSH script to container"
            _red "复制SSH脚本到容器失败"
            [ "$cleanup_source" = "true" ] && rm -f "$source_script"
            return 1
        fi
    else
        _red "Failed to prepare SSH script"
        _red "准备SSH脚本失败"
        [ "$cleanup_source" = "true" ] && rm -f "$source_script" 2>/dev/null
        return 1
    fi
}

check_cdn_file
check_lxcfs
check_storage_driver
if docker network inspect ipv6_net &>/dev/null; then
    _green "ipv6_net exists in the Docker network"
    _green "ipv6_net 存在于 Docker 网络中"
    ipv6_net_status="Y"
else
    _yellow "ipv6_net does not exist in the Docker network"
    _yellow "ipv6_net 不存在于 Docker 网络中"
    ipv6_net_status="N"
fi
if docker inspect ndpresponder &>/dev/null; then
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
lxcfs_volumes=()
if [ "$lxcfs_available" = "Y" ]; then
    lxcfs_volumes=(
        --volume /var/lib/lxcfs/proc/cpuinfo:/proc/cpuinfo:rw
        --volume /var/lib/lxcfs/proc/diskstats:/proc/diskstats:rw
        --volume /var/lib/lxcfs/proc/meminfo:/proc/meminfo:rw
        --volume /var/lib/lxcfs/proc/stat:/proc/stat:rw
        --volume /var/lib/lxcfs/proc/swaps:/proc/swaps:rw
        --volume /var/lib/lxcfs/proc/uptime:/proc/uptime:rw
    )
fi

# 先检查镜像是否存在，不存在才下载
if ! check_image_exists "$system"; then
    download_and_load_image "$system"
fi
storage_opts=()
if [ "$btrfs_support" = "Y" ] && [ "$disk" != "0" ]; then
    storage_opts=(--storage-opt "size=${disk}G")
fi
if [ -n "$system" ] && [ "$system" = "alpine" ]; then
    if [ "$ndpresponder_status" = "Y" ] && [ "$ipv6_net_status" = "Y" ] && [ ! -z "$ipv6_address" ] && [ ! -z "$ipv6_address_without_last_segment" ] && [ "$independent_ipv6" = "y" ]; then
        if ! docker run -d \
            --cpus="${cpu}" \
            --memory="${memory}m" \
            --name "${name}" \
            --network=ipv6_net \
            -p "${sshport}:22" \
            -p "${startport}-${endport}:${startport}-${endport}" \
            --cap-add=MKNOD \
            -e ROOT_PASSWORD="${passwd}" \
            -e IPV6_ENABLED=true \
            "${storage_opts[@]}" \
            "${lxcfs_volumes[@]}" \
            "${image_name}"; then
            _red "Failed to create container: ${name}"
            _red "创建容器失败: ${name}"
            exit 1
        fi
    else
        if ! docker run -d \
            --cpus="${cpu}" \
            --memory="${memory}m" \
            --name "${name}" \
            -p "${sshport}:22" \
            -p "${startport}-${endport}:${startport}-${endport}" \
            --cap-add=MKNOD \
            -e ROOT_PASSWORD="${passwd}" \
            "${storage_opts[@]}" \
            "${lxcfs_volumes[@]}" \
            "${image_name}"; then
            _red "Failed to create container: ${name}"
            _red "创建容器失败: ${name}"
            exit 1
        fi
    fi
    if ! download_ssh_scripts "${name}" "${system}" || \
       ! docker exec "${name}" sh -c 'sh /ssh_sh.sh "$1"' sh "$passwd" || \
       ! docker exec "${name}" sh -c 'printf "%s\n" "root:$1" | chpasswd' sh "$passwd"; then
        _red "SSH initialization failed for ${name}, removing partial container."
        _red "${name} SSH 初始化失败，删除未完成容器。"
        docker rm -f "${name}" >/dev/null 2>&1 || true
        exit 1
    fi
    echo "$name $sshport $passwd $cpu $memory $startport $endport $disk" >>"$name"
else
    if [ "$ndpresponder_status" = "Y" ] && [ "$ipv6_net_status" = "Y" ] && [ ! -z "$ipv6_address" ] && [ ! -z "$ipv6_address_without_last_segment" ] && [ "$independent_ipv6" = "y" ]; then
        if ! docker run -d \
            --cpus="${cpu}" \
            --memory="${memory}m" \
            --name "${name}" \
            --network=ipv6_net \
            -p "${sshport}:22" \
            -p "${startport}-${endport}:${startport}-${endport}" \
            --cap-add=MKNOD \
            -e ROOT_PASSWORD="${passwd}" \
            -e IPV6_ENABLED=true \
            "${storage_opts[@]}" \
            "${lxcfs_volumes[@]}" \
            "${image_name}"; then
            _red "Failed to create container: ${name}"
            _red "创建容器失败: ${name}"
            exit 1
        fi
    else
        if ! docker run -d \
            --cpus="${cpu}" \
            --memory="${memory}m" \
            --name "${name}" \
            -p "${sshport}:22" \
            -p "${startport}-${endport}:${startport}-${endport}" \
            --cap-add=MKNOD \
            -e ROOT_PASSWORD="${passwd}" \
            "${storage_opts[@]}" \
            "${lxcfs_volumes[@]}" \
            "${image_name}"; then
            _red "Failed to create container: ${name}"
            _red "创建容器失败: ${name}"
            exit 1
        fi
    fi
    if ! download_ssh_scripts "${name}" "${system}" || \
       ! docker exec "${name}" bash -c 'bash /ssh_bash.sh "$1"' bash "$passwd" || \
       ! docker exec "${name}" bash -c 'printf "%s\n" "root:$1" | chpasswd' bash "$passwd"; then
        _red "SSH initialization failed for ${name}, removing partial container."
        _red "${name} SSH 初始化失败，删除未完成容器。"
        docker rm -f "${name}" >/dev/null 2>&1 || true
        exit 1
    fi
    echo "$name $sshport $passwd $cpu $memory $startport $endport $disk" >>"$name"
fi

cat "$name"
