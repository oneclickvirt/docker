#!/bin/sh
# entrypoint_alpine.sh - 适用于 Alpine Linux
# from https://github.com/oneclickvirt/docker
# 2026.03.01

# 设置 root 密码（支持通过环境变量传入）
if [ -n "$ROOT_PASSWORD" ]; then
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
    sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/g' /etc/ssh/sshd_config 2>/dev/null || true
    sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/g' /etc/ssh/sshd_config 2>/dev/null || true
fi

# 确保 /var/run/sshd 存在
mkdir -p /var/run/sshd

# 生成 SSH host keys（如果不存在）
ssh-keygen -A 2>/dev/null || true

# 启动 sshd
/usr/sbin/sshd 2>/dev/null || true

# 启动 crond
crond 2>/dev/null || true

# IPv6 测试 cron（如果启用了独立 IPv6）
if [ "$IPV6_ENABLED" = "true" ]; then
    (crontab -l 2>/dev/null; echo "*/1 * * * * curl -m 6 -s ipv6.ip.sb >/dev/null 2>&1") | sort -u | crontab - 2>/dev/null || true
fi

# 保持容器运行
exec tail -f /dev/null
