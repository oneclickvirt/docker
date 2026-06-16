#!/bin/bash
# from
# https://github.com/oneclickvirt/docker
# 2026.03.01

# 批量开设 Docker 容器脚本
# 交互式创建多个 Linux 容器，记录到 dclog 日志文件

_red()    { echo -e "\033[31m\033[01m$*\033[0m"; }
_green()  { echo -e "\033[32m\033[01m$*\033[0m"; }
_yellow() { echo -e "\033[33m\033[01m$*\033[0m"; }
_blue()   { echo -e "\033[36m\033[01m$*\033[0m"; }
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
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
        read -rp "$(_green "$prompt")" "${var_name?}"
    fi
}
export DEBIAN_FRONTEND=noninteractive

without_cdn="false"
if [[ "${WITHOUTCDN^^}" == "TRUE" ]]; then
    without_cdn="true"
fi

if [ "$(id -u)" != "0" ]; then
    _red "This script must be run as root" 1>&2
    exit 1
fi

# ======== 切换到 /root ========
cd /root || exit 1

# ======== CDN 检测 ========
cdn_success_url=""
if [[ "$without_cdn" == "true" ]]; then
    _yellow "WITHOUTCDN=TRUE detected, CDN acceleration disabled"
else
    if [[ -f /usr/local/bin/docker_cdn ]]; then
        cdn_success_url=$(cat /usr/local/bin/docker_cdn)
    else
        ip_info=$(curl -sLk --connect-timeout 5 --max-time 10 "https://ipapi.co/json/" 2>/dev/null || true)
        if echo "$ip_info" | grep -q '"country": "CN"'; then
            cdn_success_url="https://cdn.spiritlhl.net/"
            echo "$cdn_success_url" > /usr/local/bin/docker_cdn
        fi
    fi
fi

# ======== 读取日志，恢复编号状态 ========
log_file="dclog"
container_prefix="dc"
container_num=0
ssh_port=25000
public_port_end=35000

is_positive_integer() {
    [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

is_nonnegative_integer() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

is_cpu_value() {
    [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]]
}

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

normalize_container_system_or_exit() {
    local raw="$1"
    local normalized
    if ! normalized=$(normalize_system_type "$raw"); then
        _red "Unsupported system: ${raw}"
        _red "不支持的系统: ${raw}"
        _yellow "Available systems / 可选系统: $(system_choices)"
        _yellow "Version-like input is accepted, for example: debian11, debian/11, ubuntu20, almalinux9, rockylinux9, openeuler22.03"
        _yellow "支持带版本号写法，例如：debian11、debian/11、ubuntu20、almalinux9、rockylinux9、openeuler22.03"
        return 1
    fi
    if [ "$raw" != "$normalized" ]; then
        _yellow "Normalized system '${raw}' to '${normalized}'"
        _yellow "已将系统 '${raw}' 归一化为 '${normalized}'"
    fi
    system_type="$normalized"
}

# ======== 检查依赖 ========
pre_check() {
    if ! command -v docker >/dev/null 2>&1; then
        _yellow "docker not found, running dockerinstall.sh..."
        if [[ -f "${SCRIPT_DIR}/dockerinstall.sh" ]]; then
            bash "${SCRIPT_DIR}/dockerinstall.sh"
        else
            local installer_tmp
            installer_tmp=$(mktemp)
            if ! curl -fsSL "${cdn_success_url}https://raw.githubusercontent.com/oneclickvirt/docker/main/scripts/dockerinstall.sh" -o "$installer_tmp"; then
                rm -f "$installer_tmp"
                _red "Failed to download dockerinstall.sh"
                _red "下载 dockerinstall.sh 失败"
                exit 1
            fi
            bash "$installer_tmp"
            rm -f "$installer_tmp"
        fi
    fi

    # 下载 onedocker.sh（如果不存在）
    if [[ ! -f /root/onedocker.sh ]]; then
        if [[ -f "${SCRIPT_DIR}/onedocker.sh" ]]; then
            cp "${SCRIPT_DIR}/onedocker.sh" /root/onedocker.sh
        elif ! curl -fsSL --connect-timeout 10 --max-time 60 \
            "${cdn_success_url}https://raw.githubusercontent.com/oneclickvirt/docker/main/scripts/onedocker.sh" \
            -o /root/onedocker.sh; then
            _red "Failed to prepare /root/onedocker.sh"
            _red "准备 /root/onedocker.sh 失败"
            exit 1
        fi
        chmod +x /root/onedocker.sh
    fi
    if [ ! -f ssh_bash.sh ]; then
        if [[ -f "${SCRIPT_DIR}/ssh_bash.sh" ]]; then
            cp "${SCRIPT_DIR}/ssh_bash.sh" ssh_bash.sh
        elif ! curl -fsSL "${cdn_success_url}https://raw.githubusercontent.com/oneclickvirt/docker/main/scripts/ssh_bash.sh" \
            -o ssh_bash.sh; then
            _red "Failed to prepare ssh_bash.sh"
            _red "准备 ssh_bash.sh 失败"
            exit 1
        fi
        chmod +x ssh_bash.sh
    fi
    if [ ! -f ssh_sh.sh ]; then
        if [[ -f "${SCRIPT_DIR}/ssh_sh.sh" ]]; then
            cp "${SCRIPT_DIR}/ssh_sh.sh" ssh_sh.sh
        elif ! curl -fsSL "${cdn_success_url}https://raw.githubusercontent.com/oneclickvirt/docker/main/scripts/ssh_sh.sh" \
            -o ssh_sh.sh; then
            _red "Failed to prepare ssh_sh.sh"
            _red "准备 ssh_sh.sh 失败"
            exit 1
        fi
        chmod +x ssh_sh.sh
    fi
}

check_log() {
    if [[ -f "$log_file" ]]; then
        local last_line
        last_line=$(tail -n 1 "$log_file" 2>/dev/null || true)
        if [[ -n "$last_line" ]]; then
            # 格式: <name> <sshport> <password> <cpu> <memory> <startport> <endport> <disk>
            local last_name last_ssh last_endport
            read -r last_name last_ssh _ _ _ _ last_endport _ <<< "$last_line"

            # 解析容器名前缀和编号（如 dc1 → prefix=dc, num=1）
            if [[ "$last_name" =~ ^([a-zA-Z]+)([0-9]+)$ ]]; then
                container_prefix="${BASH_REMATCH[1]}"
                container_num="${BASH_REMATCH[2]}"
            fi
            [[ "$last_ssh" =~ ^[0-9]+$ && "$last_ssh" -gt 0 ]] && ssh_port="$last_ssh"
            [[ "$last_endport" =~ ^[0-9]+$ && "$last_endport" -gt 0 ]] && public_port_end="$last_endport"

            _blue "Resuming from: prefix=${container_prefix}, num=${container_num}, last_ssh=${ssh_port}, last_endport=${public_port_end}"
        fi
    fi
}

# ======== 显示已有日志 ========
show_log() {
    if [[ -f "$log_file" ]]; then
        _blue "======================================================"
        _blue "  已有容器记录 / Existing container log:"
        _blue "======================================================"
        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ -z "$line" ]] && continue
            local n sshp pw cp mem sp ep dk
            read -r n sshp pw cp mem sp ep dk _ <<< "$line"
            _blue "  名称:${n}  SSH端口:${sshp}  密码:${pw}  CPU:${cp}  内存:${mem}MB  端口:${sp}-${ep}  磁盘:${dk}GB"
        done < "$log_file"
        echo
    fi
}

# ======== 交互式创建 ========
build_new_containers() {
    # 询问容器数量
    reading "需要新增几个容器？ (How many containers to create?) [default: 1]: " new_nums "${DOCKER_CREATE_COUNT:-1}"
    is_positive_integer "$new_nums" || new_nums=1

    # 询问内存大小
    reading "每个容器内存大小(MB) (Memory per container in MB) [default: 512]: " memory_nums "${DOCKER_MEMORY_MB:-512}"
    is_positive_integer "$memory_nums" || memory_nums=512

    # 询问 CPU
    reading "每个容器 CPU 核数 (CPU cores per container, e.g. 1 or 0.5) [default: 1]: " cpu_nums "${DOCKER_CPU:-1}"
    is_cpu_value "$cpu_nums" || cpu_nums=1

    # 询问磁盘限制（仅 btrfs 支持）
    disk_size=0
    storage_driver="overlay2"
    if [ -f /usr/local/bin/docker_storage_driver ]; then
        storage_driver=$(cat /usr/local/bin/docker_storage_driver)
    fi
    if [ "$storage_driver" = "btrfs" ]; then
        reading "磁盘限制(GB) (Disk limit in GB, 0=unlimited) [default: 0]: " disk_size "${DOCKER_DISK_GB:-0}"
        is_nonnegative_integer "$disk_size" || disk_size=0
    else
        _yellow "当前存储驱动($storage_driver)不支持硬盘大小限制，磁盘参数设为0"
        disk_size=0
    fi

    # 询问系统
    _blue "可选系统: $(system_choices)"
    while true; do
        reading "选择系统 (Choose system) [default: debian]: " system_type "${DOCKER_SYSTEM:-debian}"
        [[ -z "$system_type" ]] && system_type="debian"
        if normalize_container_system_or_exit "$system_type"; then
            break
        fi
        is_noninteractive && exit 1
    done

    # 询问是否分配独立 IPv6
    reading "是否附加独立的 IPv6 地址？([N]/y) (Attach independent IPv6?) " independent_ipv6 "${DOCKER_INDEPENDENT_IPV6:-n}"
    independent_ipv6=$(echo "$independent_ipv6" | tr '[:upper:]' '[:lower:]')
    [[ "$independent_ipv6" != "y" ]] && independent_ipv6="n"

    if [ $((ssh_port + new_nums)) -gt 65535 ] || [ $((public_port_end + new_nums * 25)) -gt 65535 ]; then
        _red "Port range is exhausted, please adjust existing dclog or create fewer containers."
        _red "端口范围不足，请调整已有 dclog 或减少本次创建数量。"
        exit 1
    fi

    _blue "======================================================"
    _blue "  开始批量创建 ${new_nums} 个容器  系统: ${system_type}"
    _blue "  内存: ${memory_nums}MB  CPU: ${cpu_nums}  磁盘: ${disk_size}GB  IPv6: ${independent_ipv6}"
    _blue "======================================================"

    local scripts_dir
    if [[ -f /root/onedocker.sh ]]; then
        scripts_dir="/root"
    elif [[ -f "$(dirname "$0")/onedocker.sh" ]]; then
        scripts_dir="$(dirname "$0")"
    else
        scripts_dir="/root"
    fi

    for ((i = 1; i <= new_nums; i++)); do
        container_num=$((container_num + 1))
        container_name="${container_prefix}${container_num}"
        ssh_port=$((ssh_port + 1))
        public_port_start=$((public_port_end + 1))
        public_port_end=$((public_port_start + 24))

        # 生成随机密码
        ori=$(date +%s%N | md5sum 2>/dev/null || date | md5sum)
        passwd="${ori:2:9}"

        _yellow "[${i}/${new_nums}] Creating container: ${container_name}  ssh:${ssh_port}  ports:${public_port_start}-${public_port_end}"

        if bash "${scripts_dir}/onedocker.sh" \
            "${container_name}" \
            "${cpu_nums}" \
            "${memory_nums}" \
            "${passwd}" \
            "${ssh_port}" \
            "${public_port_start}" \
            "${public_port_end}" \
            "${independent_ipv6}" \
            "${system_type}" \
            "${disk_size}"; then
            echo "${container_name} ${ssh_port} ${passwd} ${cpu_nums} ${memory_nums} ${public_port_start} ${public_port_end} ${disk_size}" >> "$log_file"
        else
            _red "Container ${container_name} creation failed, dclog was not updated."
            _red "容器 ${container_name} 创建失败，未写入 dclog。"
            exit 1
        fi
    done

    echo
    _green "======================================================"
    _green "  批量创建完成！所有容器信息已保存到: ${log_file}"
    _green "======================================================"
    echo
    _blue "查看所有容器: docker ps -a"
    _blue "查看日志文件: cat ${log_file}"
}

# ======== 主流程 ========
main() {
    pre_check
    check_log
    show_log
    build_new_containers
    check_log
}

main "$@"
