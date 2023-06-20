#!/bin/sh
#from https://github.com/spiritLHLS/docker

if [ "$(cat /etc/os-release | grep -E '^ID=' | cut -d '=' -f 2)" != "alpine" ]
then
  echo "This script only supports Alpine Linux."
  exit 1
fi

if [ "$(id -u)" -ne 0 ]
then
  echo "This script must be executed with root privileges."
  exit 1
fi

apk update
apk add --no-cache wget curl openssh-server sshpass

if [ -f "/etc/motd" ]; then
    echo 'Related repo https://github.com/spiritLHLS/docker' >> /etc/motd
    echo '--by https://t.me/spiritlhl' >> /etc/motd
fi
cd /etc/ssh
ssh-keygen -A
sshport=22
sed -i.bak '/^#PermitRootLogin\|PermitRootLogin/c PermitRootLogin yes' /etc/ssh/sshd_config
sed -i.bak '/^#PasswordAuthentication\|PasswordAuthentication/c PasswordAuthentication yes' /etc/ssh/sshd_config
sed -i.bak '/^#ListenAddress\|ListenAddress/c ListenAddress 0.0.0.0' /etc/ssh/sshd_config
sed -i.bak '/^#AddressFamily\|AddressFamily/c AddressFamily any' /etc/ssh/sshd_config
sed -i.bak "s/^#\?Port.*/Port $sshport/" /etc/ssh/sshd_config
/usr/sbin/sshd

echo root:"$1" | chpasswd root

rm -f "$0"
