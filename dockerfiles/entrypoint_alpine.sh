#!/bin/sh
# entrypoint_alpine.sh - 适用于 Alpine Linux
# from https://github.com/oneclickvirt/docker
# 2026.03.01

set -eu

# CVE-2026-31431 (copy-fail) 缓解：尝试卸载 algif_aead 模块
rmmod algif_aead 2>/dev/null || true

# 设置 root 密码（支持通过环境变量传入）
if [ -n "${ROOT_PASSWORD:-}" ]; then
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
        sed -i 's/PasswordAuthentication no/PasswordAuthentication yes/g' "$file" 2>/dev/null || {
            echo "Failed to update SSH configuration: $file" >&2
            exit 1
        }
        sed -i 's/PermitRootLogin prohibit-password/PermitRootLogin yes/g' "$file" 2>/dev/null || {
            echo "Failed to update SSH configuration: $file" >&2
            exit 1
        }
        sed -i 's/PermitRootLogin no/PermitRootLogin yes/g' "$file" 2>/dev/null || {
            echo "Failed to update SSH configuration: $file" >&2
            exit 1
        }
    done
fi

# 确保 sshd 主配置允许密码登录
if [ -f /etc/ssh/sshd_config ]; then
    sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/g' /etc/ssh/sshd_config 2>/dev/null || {
        echo "Failed to update /etc/ssh/sshd_config" >&2
        exit 1
    }
    sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/g' /etc/ssh/sshd_config 2>/dev/null || {
        echo "Failed to update /etc/ssh/sshd_config" >&2
        exit 1
    }
fi

# 确保 /var/run/sshd 存在
mkdir -p /var/run/sshd

# 生成 SSH host keys（如果不存在）
if ! ssh-keygen -A 2>/dev/null; then
    echo "Failed to generate SSH host keys" >&2
    exit 1
fi

# 启动 sshd
if ! /usr/sbin/sshd -t 2>/dev/null; then
    echo "Failed to validate sshd configuration" >&2
    exit 1
fi
if ! /usr/sbin/sshd 2>/dev/null; then
    echo "Failed to start sshd" >&2
    exit 1
fi
if command -v pgrep >/dev/null 2>&1; then
    pgrep -x sshd >/dev/null 2>&1 || { echo "Failed to start sshd" >&2; exit 1; }
elif command -v pidof >/dev/null 2>&1; then
    pidof sshd >/dev/null 2>&1 || { echo "Failed to start sshd" >&2; exit 1; }
else
    ps 2>/dev/null | awk '$NF == "sshd" { found=1 } END { exit(found ? 0 : 1) }' || {
        echo "Failed to start sshd" >&2
        exit 1
    }
fi

# 启动 crond
if command -v crond >/dev/null 2>&1; then
    if ! crond 2>/dev/null; then
        echo "Failed to start crond" >&2
        exit 1
    fi
fi

# IPv6 测试 cron（如果启用了独立 IPv6）
if [ "${IPV6_ENABLED:-}" = "true" ]; then
    command -v crontab >/dev/null 2>&1 || {
        echo "IPv6 keepalive requires crontab" >&2
        exit 1
    }
    cron_line="*/1 * * * * curl --noproxy '*' -6 -fsS --connect-timeout 6 --max-time 6 https://ipv6.ip.sb >/dev/null 2>&1"
    lock_dir=/run/oneclickvirt-ipv6-cron.lock
    acquired=false
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        if mkdir "$lock_dir" 2>/dev/null; then
            acquired=true
            break
        fi
        sleep 1
    done
    [ "$acquired" = true ] || {
        echo "Timed out waiting for the IPv6 keepalive cron lock" >&2
        exit 1
    }
    cleanup_cron_lock() { rmdir "$lock_dir" 2>/dev/null || true; }
    trap cleanup_cron_lock EXIT
    cron_tmp=$(mktemp /tmp/oneclickvirt-crontab.XXXXXX)
    cleanup_cron_tmp() { rm -f -- "$cron_tmp"; }
    trap 'cleanup_cron_tmp; cleanup_cron_lock' EXIT
    crontab -l >"$cron_tmp" 2>/dev/null || :
    if ! grep -Fqx "$cron_line" "$cron_tmp"; then
        printf '%s\n' "$cron_line" >>"$cron_tmp"
    fi
    if ! crontab "$cron_tmp"; then
        echo "Failed to install the IPv6 keepalive cron job" >&2
        exit 1
    fi
fi

# 保持容器运行
exec tail -f /dev/null
