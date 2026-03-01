#!/bin/bash
# entrypoint.sh - 适用于 bash 系统（Debian/Ubuntu/AlmaLinux/RockyLinux/OpenEuler）
# from https://github.com/oneclickvirt/docker
# 2026.03.01

set -e

# 设置 root 密码（支持通过环境变量传入）
if [[ -n "$ROOT_PASSWORD" ]]; then
    echo "root:${ROOT_PASSWORD}" | chpasswd 2>/dev/null || true
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
ssh-keygen -A 2>/dev/null || true

# 启动 SSH 服务
if command -v systemctl >/dev/null 2>&1; then
    systemctl enable ssh 2>/dev/null || systemctl enable sshd 2>/dev/null || true
    service ssh start 2>/dev/null || service sshd start 2>/dev/null || /usr/sbin/sshd 2>/dev/null || true
else
    service ssh start 2>/dev/null || service sshd start 2>/dev/null || /usr/sbin/sshd 2>/dev/null || true
fi

# 启动 cron
if command -v cron >/dev/null 2>&1; then
    service cron start 2>/dev/null || true
elif command -v crond >/dev/null 2>&1; then
    service crond start 2>/dev/null || crond 2>/dev/null || true
fi

# IPv6 测试 cron（如果启用了独立 IPv6）
if [ "$IPV6_ENABLED" = "true" ]; then
    (crontab -l 2>/dev/null; echo "*/1 * * * * curl -m 6 -s ipv6.ip.sb >/dev/null 2>&1") | sort -u | crontab - 2>/dev/null || true
fi

# 保持容器运行
exec tail -f /dev/null
