#!/bin/bash
# entrypoint.sh - 适用于 bash 系统（Debian/Ubuntu/AlmaLinux/RockyLinux/OpenEuler）
# from https://github.com/oneclickvirt/docker
# 2026.03.01

set -e

# CVE-2026-31431 (copy-fail) 缓解：尝试卸载 algif_aead 模块
rmmod algif_aead 2>/dev/null || true

# 设置 root 密码（支持通过环境变量传入）
if [[ -n "$ROOT_PASSWORD" ]]; then
    if ! printf "%s\n" "root:${ROOT_PASSWORD}" | chpasswd 2>/dev/null; then
        echo "Failed to set the root password" >&2
        exit 1
    fi
fi

# 修复 sshd_config.d/ 中的覆盖配置
config_dir="/etc/ssh/sshd_config.d/"
if [ -d "$config_dir" ]; then
    for file in "${config_dir}"*; do
        [ -f "$file" ] || continue
        sed -i 's/PasswordAuthentication no/PasswordAuthentication yes/g' "$file" 2>/dev/null || true
        sed -i 's/PermitRootLogin prohibit-password/PermitRootLogin yes/g' "$file" 2>/dev/null || true
        sed -i 's/PermitRootLogin no/PermitRootLogin yes/g' "$file" 2>/dev/null || true
    done
fi

# 确保 sshd 主配置允许密码登录
if [ -f /etc/ssh/sshd_config ]; then
    sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/g' /etc/ssh/sshd_config 2>/dev/null || true
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/g' /etc/ssh/sshd_config 2>/dev/null || true
    sed -i 's/^UsePAM yes/UsePAM no/g' /etc/ssh/sshd_config 2>/dev/null || true
fi

# 确保 sshd 运行目录存在
mkdir -p /var/run/sshd

# 生成 SSH host keys（如果不存在）
if ! ssh-keygen -A 2>/dev/null; then
    echo "Failed to generate SSH host keys" >&2
    exit 1
fi

# 启动 SSH 服务
start_sshd() {
    if command -v systemctl >/dev/null 2>&1; then
        systemctl enable ssh 2>/dev/null || systemctl enable sshd 2>/dev/null || :
        systemctl start ssh 2>/dev/null || systemctl start sshd 2>/dev/null || :
        systemctl is-active --quiet ssh 2>/dev/null || systemctl is-active --quiet sshd 2>/dev/null || :
    fi
    if command -v service >/dev/null 2>&1; then
        service ssh start 2>/dev/null || service sshd start 2>/dev/null || :
    fi
    if command -v /usr/sbin/sshd >/dev/null 2>&1; then
        /usr/sbin/sshd -t 2>/dev/null || return 1
        /usr/sbin/sshd 2>/dev/null || :
    fi
    if command -v pgrep >/dev/null 2>&1; then
        pgrep -x sshd >/dev/null 2>&1
    elif command -v pidof >/dev/null 2>&1; then
        pidof sshd >/dev/null 2>&1
    else
        ps 2>/dev/null | awk '$NF == "sshd" { found=1 } END { exit(found ? 0 : 1) }'
    fi
}
if ! start_sshd; then
    echo "Failed to start sshd" >&2
    exit 1
fi

# 启动 cron
if command -v cron >/dev/null 2>&1; then
    service cron start 2>/dev/null || true
elif command -v crond >/dev/null 2>&1; then
    service crond start 2>/dev/null || crond 2>/dev/null || true
fi

# IPv6 测试 cron（如果启用了独立 IPv6）
install_ipv6_keepalive() {
    [ "${IPV6_ENABLED:-}" = "true" ] || return 0
    [ -d /etc/cron.d ] || {
        echo "IPv6 keepalive requires /etc/cron.d" >&2
        return 1
    }
    local target=/etc/cron.d/oneclickvirt-ipv6-keepalive
    local temporary
    temporary=$(mktemp /etc/cron.d/.oneclickvirt-ipv6-keepalive.XXXXXX) || return 1
    if ! printf '%s\n' \
        '# Managed by OneClickVirt: IPv6 path keepalive' \
        'SHELL=/bin/sh' \
        'PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' \
        "*/1 * * * * root curl --noproxy '*' -6 -fsS --connect-timeout 6 --max-time 6 https://ipv6.ip.sb >/dev/null 2>&1" \
        >"$temporary"; then
        rm -f -- "$temporary"
        return 1
    fi
    if [ -e "$target" ] || [ -L "$target" ]; then
        if [ -L "$target" ] || [ ! -f "$target" ] || ! cmp -s "$temporary" "$target"; then
            echo "Refusing to replace an existing custom IPv6 keepalive file" >&2
            rm -f -- "$temporary"
            return 1
        fi
        rm -f -- "$temporary"
        return 0
    fi
    chmod 0644 "$temporary" || { rm -f -- "$temporary"; return 1; }
    if ! mv -- "$temporary" "$target"; then
        rm -f -- "$temporary"
        return 1
    fi
}
if ! install_ipv6_keepalive; then
    echo "Failed to install the IPv6 keepalive cron job" >&2
    exit 1
fi

# 保持容器运行
exec tail -f /dev/null
