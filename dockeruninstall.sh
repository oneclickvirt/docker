#!/bin/bash
# from
# https://github.com/oneclickvirt/docker
# 2026.03.01
# 完整卸载 Docker 环境及所有容器
# 支持的环境变量（一键非交互卸载）：
#   noninteractive=true - 跳过卸载确认提示，直接执行卸载
#   CONFIRM=yes         - 兼容旧用法

_red()    { echo -e "\033[31m\033[01m$*\033[0m"; }
_green()  { echo -e "\033[32m\033[01m$*\033[0m"; }
_yellow() { echo -e "\033[33m\033[01m$*\033[0m"; }
_blue()   { echo -e "\033[36m\033[01m$*\033[0m"; }

is_noninteractive() {
    case "${noninteractive:-}" in
        [Tt][Rr][Uu][Ee]|1|[Yy]|[Yy][Ee][Ss]) return 0 ;;
    esac
    return 1
}

if [ "$(id -u)" != "0" ]; then
    _red "This script must be run as root"
    exit 1
fi

echo ""
echo "======================================================"
_red "  ⚠  警告：即将卸载 Docker 全套环境"
echo "  包含：所有运行中/停止的容器、所有镜像、"
echo "  Docker 网络配置、systemd 服务、Docker 二进制及数据目录"
echo "  操作不可逆！"
echo "======================================================"
if is_noninteractive; then
    _yellow "noninteractive=true detected, skipping confirmation prompt"
elif [[ "${CONFIRM^^}" == "YES" ]]; then
    _yellow "CONFIRM=YES detected, skipping confirmation prompt"
else
    read -rp "$(_yellow "确认卸载？输入 yes 继续，其他任意键退出: ")" confirm
    if [[ "$confirm" != "yes" ]]; then
        _green "已取消"
        exit 0
    fi
fi

docker_loop_file=$(cat /usr/local/bin/docker_loop_file 2>/dev/null || true)
docker_loop_device=$(cat /usr/local/bin/docker_loop_device 2>/dev/null || true)
docker_mount_point=$(cat /usr/local/bin/docker_mount_point 2>/dev/null || true)

# ======== 1. 停止并删除所有容器 ========
_blue "[1/9] 停止并删除所有 Docker 容器..."
if command -v docker >/dev/null 2>&1; then
    containers=$(docker ps -aq 2>/dev/null || true)
    if [[ -n "$containers" ]]; then
        _yellow "  停止所有容器..."
        docker stop $containers 2>/dev/null || true
        _yellow "  删除所有容器..."
        docker rm -f $containers 2>/dev/null || true
        _green "  容器已清理"
    else
        _yellow "  无容器需要清理"
    fi
else
    _yellow "  docker 未找到，跳过容器删除"
fi

# ======== 2. 删除所有镜像 ========
_blue "[2/9] 删除所有 Docker 镜像..."
if command -v docker >/dev/null 2>&1; then
    images=$(docker images -q 2>/dev/null || true)
    if [[ -n "$images" ]]; then
        docker rmi -f $images 2>/dev/null || true
        _green "  镜像已清理"
    else
        _yellow "  无镜像需要清理"
    fi
fi

# ======== 3. 删除所有 Docker 网络 ========
_blue "[3/9] 清理 Docker 自定义网络..."
if command -v docker >/dev/null 2>&1; then
    networks=$(docker network ls --filter type=custom -q 2>/dev/null || true)
    if [[ -n "$networks" ]]; then
        docker network rm $networks 2>/dev/null || true
        _green "  自定义网络已清理"
    else
        _yellow "  无自定义网络需要清理"
    fi
    # 删除 Docker 网桥接口
    for br in docker0 br-; do
        for iface in $(ip link show 2>/dev/null | grep -o "${br}[^ ]*" | sed 's/:$//'); do
            if ip link show "$iface" >/dev/null 2>&1; then
                ip link set "$iface" down 2>/dev/null || true
                ip link delete "$iface" 2>/dev/null || true
                _yellow "  删除网络接口 $iface"
            fi
        done
    done
fi

# ======== 4. 删除 ndpresponder 和 IPv6 相关容器 ========
_blue "[4/9] 清理 ndpresponder 及 IPv6 网络配置..."
if command -v docker >/dev/null 2>&1; then
    docker rm -f ndpresponder 2>/dev/null || true
fi
# 删除 IPv6 相关 iptables 规则（仅删除我们添加的）
if command -v ip6tables >/dev/null 2>&1; then
    ip6tables -t nat -D POSTROUTING -s fd00::/80 ! -o docker0 -j MASQUERADE 2>/dev/null || true
    ip6tables -D FORWARD -s fd00::/80 -j ACCEPT 2>/dev/null || true
    ip6tables -D FORWARD -d fd00::/80 -j ACCEPT 2>/dev/null || true
fi
_green "  IPv6 配置已清理"

# ======== 5. 停止并禁用 systemd 服务 ========
_blue "[5/9] 停止并禁用 Docker systemd 服务..."
if command -v systemctl >/dev/null 2>&1; then
    for svc in docker docker.socket containerd check-dns radvd; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            systemctl stop "$svc" 2>/dev/null || true
            _yellow "  已停止 ${svc}"
        fi
        if systemctl is-enabled --quiet "$svc" 2>/dev/null; then
            systemctl disable "$svc" 2>/dev/null || true
        fi
    done
    # 删除我们安装的自定义服务文件
    for f in \
        /etc/systemd/system/check-dns.service \
        /usr/lib/systemd/system/check-dns.service; do
        [[ -f "$f" ]] && rm -f "$f" && _yellow "  删除 $f"
    done
    systemctl daemon-reload 2>/dev/null || true
    _green "  systemd 服务已清理"
fi

# ======== 6. 通过包管理器卸载 Docker ========
_blue "[6/9] 通过包管理器卸载 Docker..."
# 检测系统
SYS=""
if [[ -f /etc/os-release ]]; then
    SYS=$(grep -i pretty_name /etc/os-release 2>/dev/null | cut -d '"' -f2)
fi

if echo "$SYS" | grep -iq "ubuntu\|debian"; then
    if dpkg -l docker-ce >/dev/null 2>&1; then
        apt-get purge -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin 2>/dev/null || true
        apt-get autoremove -y 2>/dev/null || true
        _yellow "  已通过 apt 卸载 Docker"
    elif dpkg -l docker.io >/dev/null 2>&1; then
        apt-get purge -y docker.io 2>/dev/null || true
        apt-get autoremove -y 2>/dev/null || true
        _yellow "  已通过 apt 卸载 docker.io"
    fi
    # 删除源列表
    rm -f /etc/apt/sources.list.d/docker.list 2>/dev/null || true
    rm -f /etc/apt/keyrings/docker.gpg 2>/dev/null || true
    rm -f /etc/apt/keyrings/docker.asc 2>/dev/null || true
elif echo "$SYS" | grep -iq "centos\|alma\|rocky\|fedora\|openeuler"; then
    yum remove -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin 2>/dev/null || \
    dnf remove -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin 2>/dev/null || true
    _yellow "  已通过 yum/dnf 卸载 Docker"
    # 删除 yum 源
    rm -f /etc/yum.repos.d/docker-ce.repo 2>/dev/null || true
elif echo "$SYS" | grep -iq "alpine"; then
    apk del docker docker-cli docker-openrc 2>/dev/null || true
    _yellow "  已通过 apk 卸载 Docker"
elif echo "$SYS" | grep -iq "arch"; then
    pacman -Rsc --noconfirm docker 2>/dev/null || true
    _yellow "  已通过 pacman 卸载 Docker"
fi
_green "  包管理器卸载完成"

# ======== 7. 删除 Docker 数据目录 ========
_blue "[7/9] 删除 Docker 数据目录..."
if [[ -n "$docker_mount_point" ]] && mount | awk '{print $3}' | grep -Fxq "$docker_mount_point"; then
    umount "$docker_mount_point" 2>/dev/null || true
    _yellow "  卸载 $docker_mount_point"
fi
if [[ -n "$docker_loop_device" ]]; then
    losetup -d "$docker_loop_device" 2>/dev/null || true
    _yellow "  释放 loop 设备 $docker_loop_device"
elif [[ -n "$docker_loop_file" ]] && command -v losetup >/dev/null 2>&1; then
    for dev in $(losetup -j "$docker_loop_file" 2>/dev/null | cut -d: -f1); do
        losetup -d "$dev" 2>/dev/null || true
        _yellow "  释放 loop 设备 $dev"
    done
fi
if [[ -n "$docker_loop_file" ]]; then
    if [[ -f /etc/fstab ]]; then
        tmp_fstab=$(mktemp)
        awk -v loop_file="$docker_loop_file" '$1 != loop_file' /etc/fstab > "$tmp_fstab" && cat "$tmp_fstab" >/etc/fstab
        rm -f "$tmp_fstab"
    fi
    [[ -f "$docker_loop_file" ]] && rm -f "$docker_loop_file" && _yellow "  删除 $docker_loop_file"
fi

data_dirs=(
    /var/lib/docker
    /var/lib/containerd
    /etc/docker
    /run/docker
    /run/containerd
)
if [[ -n "$docker_mount_point" && "$docker_mount_point" != "/var/lib/docker" ]]; then
    data_dirs+=("$docker_mount_point")
fi
for dir in "${data_dirs[@]}"; do
    if [[ -d "$dir" ]]; then
        rm -rf "$dir"
        _yellow "  删除 $dir"
    fi
done
_green "  数据目录已清理"

# ======== 8. 删除本脚本安装的辅助文件 ========
_blue "[8/9] 删除辅助状态文件..."
for f in \
    /usr/local/bin/docker-compose \
    /usr/bin/docker-compose \
    /usr/local/bin/docker_main_ipv4 \
    /usr/local/bin/docker_ipv4_address \
    /usr/local/bin/docker_ipv4_gateway \
    /usr/local/bin/docker_ipv4_subnet \
    /usr/local/bin/docker_ipv6_address \
    /usr/local/bin/docker_ipv6_prefixlen \
    /usr/local/bin/docker_ipv6_real_prefixlen \
    /usr/local/bin/docker_ipv6_gateway \
    /usr/local/bin/docker_check_ipv6 \
    /usr/local/bin/docker_fe80_address \
    /usr/local/bin/docker_mac_address \
    /usr/local/bin/docker_virt_type \
    /usr/local/bin/docker_storage_driver \
    /usr/local/bin/docker_storage_reboot \
    /usr/local/bin/docker_need_disk_limit \
    /usr/local/bin/docker_loop_device \
    /usr/local/bin/docker_loop_file \
    /usr/local/bin/docker_mount_point \
    /usr/local/bin/docker_main_interface \
    /usr/local/bin/docker_network_manager \
    /usr/local/bin/docker_last_ipv6 \
    /usr/local/bin/docker_slaac_status \
    /usr/local/bin/docker_maximum_subset \
    /usr/local/bin/docker_adapt_ipv6 \
    /usr/local/bin/docker_build_ipv6 \
    /usr/local/bin/fix_interfaces_ipv6_auto_type \
    /usr/local/bin/ifupdown_installed.txt \
    /usr/local/bin/docker_cdn \
    /usr/local/bin/check-dns.sh; do
    [[ -f "$f" ]] && rm -f "$f" && _yellow "  删除 $f"
done
# 清理 /root 下的脚本文件
for f in \
    /root/ssh_bash.sh \
    /root/ssh_sh.sh \
    /root/onedocker.sh; do
    [[ -f "$f" ]] && rm -f "$f" && _yellow "  删除 $f"
done
# 清理 /tmp 残留
rm -f /tmp/spiritlhl_*.tar.gz 2>/dev/null || true
rm -f /tmp/ssh_bash.sh /tmp/ssh_sh.sh 2>/dev/null || true
_green "  状态文件已清理"

# ======== 9. 清理 sysctl 配置 ========
_blue "[9/9] 清理 sysctl 配置..."
for sysctl_file in /etc/sysctl.conf /etc/sysctl.d/99-custom.conf /etc/sysctl.d/99-docker.conf; do
    if [[ -f "$sysctl_file" ]]; then
        sed -i \
            -e '/^net\.ipv4\.ip_forward=/d' \
            -e '/^net\.ipv6\.conf\.all\.forwarding=/d' \
            -e '/^net\.ipv6\.conf\.all\.proxy_ndp=/d' \
            -e '/^net\.ipv6\.conf\.all\.accept_ra=/d' \
            -e '/^net\.ipv6\.conf\.default\.forwarding=/d' \
            -e '/^net\.ipv6\.conf\.default\.proxy_ndp=/d' \
            -e '/^net\.ipv6\.conf\.default\.accept_ra=/d' \
            -e '/^net\.ipv6\.conf\.docker0\.forwarding=/d' \
            -e '/^net\.ipv6\.conf\.docker0\.proxy_ndp=/d' \
            -e '/^net\.ipv6\.conf\.docker0\.accept_ra=/d' \
            -e '/^net\.ipv6\.conf\.[^.]*\.proxy_ndp=/d' \
            "$sysctl_file"
        _yellow "  清理 $sysctl_file 中的 Docker IPv6/sysctl 配置"
    fi
done
[[ -f /etc/sysctl.d/99-docker.conf ]] && rm -f /etc/sysctl.d/99-docker.conf
[[ -f /etc/radvd.conf ]] && rm -f /etc/radvd.conf && _yellow "  删除 /etc/radvd.conf"
if command -v crontab >/dev/null 2>&1; then
    tmp_cron=$(mktemp)
    if crontab -l >"$tmp_cron" 2>/dev/null; then
        grep -v 'ipv6.ip.sb' "$tmp_cron" | crontab - 2>/dev/null || true
    fi
    rm -f "$tmp_cron"
fi
sysctl --system >/dev/null 2>&1 || true
_green "  sysctl 已清理"

echo ""
echo "======================================================"
_green "  ✓ Docker 环境已完整卸载！"
echo "======================================================"
echo ""
echo "如需重新安装，执行："
echo "  bash <(wget -qO- https://raw.githubusercontent.com/oneclickvirt/docker/main/scripts/dockerinstall.sh)"
