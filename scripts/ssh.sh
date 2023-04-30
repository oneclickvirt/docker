#!/bin/bash
# by https://github.com/spiritLHLS/pve

REGEX=("debian" "ubuntu" "centos|red hat|kernel|oracle linux|alma|rocky" "'amazon linux'" "fedora" "arch")
RELEASE=("Debian" "Ubuntu" "CentOS" "CentOS" "Fedora" "Arch")
PACKAGE_UPDATE=("apt-get update" "apt-get update" "yum -y update" "yum -y update" "yum -y update" "pacman -Sy")
PACKAGE_INSTALL=("apt-get -y install" "apt-get -y install" "yum -y install" "yum -y install" "yum -y install" "pacman -Sy --noconfirm --needed")
PACKAGE_REMOVE=("apt-get -y remove" "apt-get -y remove" "yum -y remove" "yum -y remove" "yum -y remove" "pacman -Rsc --noconfirm")
PACKAGE_UNINSTALL=("apt-get -y autoremove" "apt-get -y autoremove" "yum -y autoremove" "yum -y autoremove" "yum -y autoremove" "")
CMD=("$(grep -i pretty_name /etc/os-release 2>/dev/null | cut -d \" -f2)" "$(hostnamectl 2>/dev/null | grep -i system | cut -d : -f2)" "$(lsb_release -sd 2>/dev/null)" "$(grep -i description /etc/lsb-release 2>/dev/null | cut -d \" -f2)" "$(grep . /etc/redhat-release 2>/dev/null)" "$(grep . /etc/issue 2>/dev/null | cut -d \\ -f1 | sed '/^[ ]*$/d')" "$(grep -i pretty_name /etc/os-release 2>/dev/null | cut -d \" -f2)") 
SYS="${CMD[0]}"
[[ -n $SYS ]] || exit 1
for ((int = 0; int < ${#REGEX[@]}; int++)); do
    if [[ $(echo "$SYS" | tr '[:upper:]' '[:lower:]') =~ ${REGEX[int]} ]]; then
        SYSTEM="${RELEASE[int]}"
        [[ -n $SYSTEM ]] && break
    fi
done
${PACKAGE_UPDATE[int]}
if ! command -v wget > /dev/null 2>&1; then
    ${PACKAGE_INSTALL[int]} wget
fi
if ! command -v curl > /dev/null 2>&1; then
    ${PACKAGE_INSTALL[int]} curl
fi
if ! command -v sudo > /dev/null 2>&1; then
    ${PACKAGE_INSTALL[int]} sudo
fi
sshport=22
service iptables stop 2> /dev/null ; chkconfig iptables off 2> /dev/null ;
sed -i.bak '/^SELINUX=/cSELINUX=disabled' /etc/sysconfig/selinux;
sed -i.bak '/^SELINUX=/cSELINUX=disabled' /etc/selinux/config;
setenforce 0;
echo root:"$1" |sudo chpasswd root;
apt-get install sshpass -y;
apt-get install openssh-server -y;
sed -i "s/^#\?Port.*/Port $sshport/g" /etc/ssh/sshd_config;
sed -i "s/^#\?PermitRootLogin.*/PermitRootLogin yes/g" /etc/ssh/sshd_config;
sed -i "s/^#\?PasswordAuthentication.*/PasswordAuthentication yes/g" /etc/ssh/sshd_config;
sed -i 's/#ListenAddress 0.0.0.0/ListenAddress 0.0.0.0/' /etc/ssh/sshd_config
sed -i 's/#ListenAddress ::/ListenAddress ::/' /etc/ssh/sshd_config
sed -i 's/#AddressFamily any/AddressFamily any/' /etc/ssh/sshd_config
service ssh restart
service sshd restart
rm -rf "$0"
