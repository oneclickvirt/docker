#!/bin/bash
# from
# https://github.com/oneclickvirt/docker
# 2024.11.17

if [ "$(cat /etc/os-release | grep -E '^ID=' | cut -d '=' -f 2)" != "alpine" ]; then
  echo "This script only supports Alpine Linux."
  exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
  echo "This script must be executed with root privileges."
  exit 1
fi
config_dir="/etc/ssh/sshd_config.d/"
for file in "$config_dir"*
do
    if [ -f "$file" ] && [ -r "$file" ]; then
        if grep -q "PasswordAuthentication no" "$file"; then
            sed -i 's/PasswordAuthentication no/PasswordAuthentication yes/g' "$file"
            echo "File $file updated"
        fi
    fi
done

if [ "$interactionless" != "true" ]; then
    apk update
    apk add --no-cache openssh-server
    apk add --no-cache sshpass
    apk add --no-cache openssh-keygen
    apk add --no-cache bash
    apk add --no-cache curl
    apk add --no-cache wget
    apk add --no-cache cronie
    apk add --no-cache cron
    if [ -f "/etc/motd" ]; then
      echo '' >/etc/motd
      echo 'Related repo https://github.com/oneclickvirt/docker' >>/etc/motd
      echo '--by https://t.me/spiritlhl' >>/etc/motd
    fi
    cd /etc/ssh
    ssh-keygen -A
    sed -i '/^#PermitRootLogin\|PermitRootLogin/c PermitRootLogin yes' /etc/ssh/sshd_config
    sed -i '/^#PasswordAuthentication\|PasswordAuthentication/c PasswordAuthentication yes' /etc/ssh/sshd_config
    sed -i 's/#ListenAddress 0.0.0.0/ListenAddress 0.0.0.0/' /etc/ssh/sshd_config
    sed -i 's/#ListenAddress ::/ListenAddress ::/' /etc/ssh/sshd_config
    sed -i '/^#AddressFamily\|AddressFamily/c AddressFamily any' /etc/ssh/sshd_config
    sed -i "s/^#\?\(Port\).*/\1 22/" /etc/ssh/sshd_config
    sed -i -E 's/^#?(Port).*/\1 22/' /etc/ssh/sshd_config
    sed -E -i 's/preserve_hostname:[[:space:]]*false/preserve_hostname: true/g' /etc/cloud/cloud.cfg
    sed -E -i 's/disable_root:[[:space:]]*true/disable_root: false/g' /etc/cloud/cloud.cfg
    sed -E -i 's/ssh_pwauth:[[:space:]]*false/ssh_pwauth:   true/g' /etc/cloud/cloud.cfg
fi
/usr/sbin/sshd
rc-update add sshd default
if [ "$interactionless" != "true" ]; then
    echo root:"$1" | chpasswd root
    sed -i 's/.*precedence ::ffff:0:0\/96.*/precedence ::ffff:0:0\/96  100/g' /etc/gai.conf
fi
