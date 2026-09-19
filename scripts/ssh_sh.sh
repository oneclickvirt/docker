#!/bin/sh
# from
# https://github.com/oneclickvirt/docker
# 2026.03.01

# 容器内 SSH 初始化脚本（仅适用于 Alpine Linux）

if [ "$(grep -E '^ID=' /etc/os-release 2>/dev/null | cut -d= -f2)" != "alpine" ]; then
    echo "This script only supports Alpine Linux."
    exit 1
fi

passwd_input="${1:-123456}"

# 处理 sshd_config.d/ 中的覆盖配置
config_dir="/etc/ssh/sshd_config.d/"
if [ -d "$config_dir" ]; then
    for file in "${config_dir}"*; do
        [ -f "$file" ] || continue
        sed -i 's/PasswordAuthentication no/PasswordAuthentication yes/g' "$file"
        sed -i 's/PermitRootLogin prohibit-password/PermitRootLogin yes/g' "$file"
        sed -i 's/PermitRootLogin no/PermitRootLogin yes/g' "$file"
    done
fi

# 更新主 sshd_config
config_file="/etc/ssh/sshd_config"
if [ -f "$config_file" ]; then
    sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' "$config_file"
    sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' "$config_file"
    sed -i 's/#ListenAddress 0.0.0.0/ListenAddress 0.0.0.0/' "$config_file"
    sed -i 's/#Port 22/Port 22/' "$config_file"
fi

# 修复 cloud-init
if [ -f /etc/cloud/cloud.cfg ]; then
    sed -i 's/preserve_hostname:[[:space:]]*false/preserve_hostname: true/g' /etc/cloud/cloud.cfg
    sed -i 's/disable_root:[[:space:]]*true/disable_root: false/g' /etc/cloud/cloud.cfg
    sed -i 's/ssh_pwauth:[[:space:]]*false/ssh_pwauth:   true/g' /etc/cloud/cloud.cfg
fi

# 确保 /var/run/sshd 目录存在
if ! mkdir -p /var/run/sshd; then
    echo "Failed to create /var/run/sshd" >&2
    exit 1
fi

# 生成 SSH host keys
if ! ssh-keygen -A 2>/dev/null; then
    echo "Failed to generate SSH host keys" >&2
    exit 1
fi

# 设置 root 密码
if ! printf "%s\n" "root:${passwd_input}" | chpasswd 2>/dev/null; then
    echo "Failed to set the root password" >&2
    exit 1
fi

# 启动 sshd
if command -v rc-update >/dev/null 2>&1; then
    if ! rc-update add sshd default 2>/dev/null; then
        echo "Failed to enable sshd at boot" >&2
        exit 1
    fi
else
    echo "Warning: OpenRC is unavailable; sshd will not be registered for boot" >&2
fi
if ! /usr/sbin/sshd -t 2>/dev/null || ! /usr/sbin/sshd 2>/dev/null; then
    echo "Failed to start sshd" >&2
    exit 1
fi
if command -v pgrep >/dev/null 2>&1; then
    pgrep -x sshd >/dev/null 2>&1 || { echo "Failed to start sshd" >&2; exit 1; }
elif command -v pidof >/dev/null 2>&1; then
    pidof sshd >/dev/null 2>&1 || { echo "Failed to start sshd" >&2; exit 1; }
fi

# 设置 cron 保活
cron_line="* * * * * pgrep -x sshd>/dev/null||/usr/sbin/sshd"
if command -v crontab >/dev/null 2>&1; then
    cron_lock=/run/oneclickvirt-sshd-cron.lock
    cron_locked=false
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        if mkdir "$cron_lock" 2>/dev/null; then
            cron_locked=true
            break
        fi
        sleep 1
    done
    if [ "$cron_locked" = true ]; then
        if cron_tmp=$(mktemp /tmp/oneclickvirt-sshd-crontab.XXXXXX); then
            crontab -l >"$cron_tmp" 2>/dev/null || :
            grep -v "sshd" "$cron_tmp" >"${cron_tmp}.filtered" || :
            printf '%s\n' "$cron_line" >>"${cron_tmp}.filtered"
            if ! crontab "${cron_tmp}.filtered"; then
                echo "Warning: failed to install the SSH keepalive cron job" >&2
            fi
            rm -f -- "$cron_tmp" "${cron_tmp}.filtered"
        else
            echo "Warning: unable to create a temporary SSH keepalive crontab" >&2
        fi
        rmdir "$cron_lock" 2>/dev/null || true
    else
        echo "Warning: timed out waiting for the SSH keepalive cron lock" >&2
    fi
else
    echo "Warning: crontab is unavailable; SSH keepalive was not installed" >&2
fi
if command -v crond >/dev/null 2>&1 && ! crond 2>/dev/null; then
    echo "Warning: failed to start crond; SSH itself is still running" >&2
fi

# 更新 motd
if [ -f /etc/motd ]; then
    echo '' > /etc/motd
fi
echo 'Related repo https://github.com/oneclickvirt/docker' >> /etc/motd
echo '--by https://t.me/spiritlhl' >> /etc/motd

echo "SSH initialization completed (Alpine)"
