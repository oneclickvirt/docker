#!/bin/bash
# from
# https://github.com/spiritLHLS/docker
# 2023.11.06

REGEX=("debian" "ubuntu" "centos|red hat|kernel|oracle linux|alma|rocky" "'amazon linux'" "fedora" "arch")
RELEASE=("Debian" "Ubuntu" "CentOS" "CentOS" "Fedora" "Arch")
PACKAGE_UPDATE=("apt-get update" "apt-get update" "yum -y update" "yum -y update" "yum -y update" "pacman -Sy")
PACKAGE_INSTALL=("apt-get -y install" "apt-get -y install" "yum -y install" "yum -y install" "yum -y install" "pacman -Sy --noconfirm --needed")
PACKAGE_REMOVE=("apt-get -y remove" "apt-get -y remove" "yum -y remove" "yum -y remove" "yum -y remove" "pacman -Rsc --noconfirm")
PACKAGE_UNINSTALL=("apt-get -y autoremove" "apt-get -y autoremove" "yum -y autoremove" "yum -y autoremove" "yum -y autoremove" "")
CMD=("$(grep -i pretty_name /etc/os-release 2>/dev/null | cut -d \" -f2)" "$(hostnamectl 2>/dev/null | grep -i system | cut -d : -f2)" "$(lsb_release -sd 2>/dev/null)" "$(grep -i description /etc/lsb-release 2>/dev/null | cut -d \" -f2)" "$(grep . /etc/redhat-release 2>/dev/null)" "$(grep . /etc/issue 2>/dev/null | cut -d \\ -f1 | sed '/^[ ]*$/d')" "$(grep -i pretty_name /etc/os-release 2>/dev/null | cut -d \" -f2)")
SYS="${CMD[0]}"
temp_file_apt_fix="./apt_fix.txt"
[[ -n $SYS ]] || exit 1
for ((int = 0; int < ${#REGEX[@]}; int++)); do
    if [[ $(echo "$SYS" | tr '[:upper:]' '[:lower:]') =~ ${REGEX[int]} ]]; then
        SYSTEM="${RELEASE[int]}"
        [[ -n $SYSTEM ]] && break
    fi
done

remove_duplicate_lines() {
    chattr -i "$1"
    # 预处理：去除行尾空格和制表符
    sed -i 's/[ \t]*$//' "$1"
    # 去除重复行并跳过空行和注释行
    if [ -f "$1" ]; then
        awk '{ line = $0; gsub(/^[ \t]+/, "", line); gsub(/[ \t]+/, " ", line); if (!NF || !seen[line]++) print $0 }' "$1" >"$1.tmp" && mv -f "$1.tmp" "$1"
    fi
    chattr +i "$1"
}

${PACKAGE_UPDATE[int]}
if [ $? -ne 0 ]; then
    dpkg --configure -a
    ${PACKAGE_UPDATE[int]}
fi
if [ $? -ne 0 ]; then
    ${PACKAGE_INSTALL[int]} gnupg
fi
apt_update_output=$(apt-get update 2>&1)
echo "$apt_update_output" >"$temp_file_apt_fix"
if grep -q 'NO_PUBKEY' "$temp_file_apt_fix"; then
    public_keys=$(grep -oE 'NO_PUBKEY [0-9A-F]+' "$temp_file_apt_fix" | awk '{ print $2 }')
    joined_keys=$(echo "$public_keys" | paste -sd " ")
    echo "No Public Keys: ${joined_keys}"
    apt-key adv --keyserver keyserver.ubuntu.com --recv-keys ${joined_keys}
    apt-get update
    if [ $? -eq 0 ]; then
        echo "Fixed"
    fi
fi
rm "$temp_file_apt_fix"

install_required_modules() {
    modules=("dos2unix" "wget" "curl" "sudo" "sshpass" "openssh-server" "python3")
    for module in "${modules[@]}"; do
        if ! command -v $module >/dev/null 2>&1; then
            ${PACKAGE_INSTALL[int]} $module            
            if [ $? -ne 0 ]; then
                if command -v apt-get >/dev/null 2>&1; then
                    apt-get install -y $module --fix-missing
                fi
            fi
            echo "$module 已尝试过安装！"
        fi
    done
}
install_required_modules

if [ -f "/etc/motd" ]; then
    echo 'Related repo https://github.com/spiritLHLS/docker' >>/etc/motd
    echo '--by https://t.me/spiritlhl' >>/etc/motd
fi
sshport=22
service iptables stop 2>/dev/null
chkconfig iptables off 2>/dev/null
sysv-rc-conf iptables off 2>/dev/null
sed -i.bak '/^SELINUX=/cSELINUX=disabled' /etc/sysconfig/selinux
sed -i.bak '/^SELINUX=/cSELINUX=disabled' /etc/selinux/config
setenforce 0
echo root:"$1" | sudo chpasswd root
if [ -f /etc/ssh/sshd_config ]; then
    sed -i "s/^#\?Port.*/Port $sshport/g" /etc/ssh/sshd_config
    sed -i "s/^#\?PermitRootLogin.*/PermitRootLogin yes/g" /etc/ssh/sshd_config
    sed -i "s/^#\?PasswordAuthentication.*/PasswordAuthentication yes/g" /etc/ssh/sshd_config
    sed -i 's/#ListenAddress 0.0.0.0/ListenAddress 0.0.0.0/' /etc/ssh/sshd_config
    sed -i 's/#ListenAddress ::/ListenAddress ::/' /etc/ssh/sshd_config
    sed -i 's/#AddressFamily any/AddressFamily any/' /etc/ssh/sshd_config
    sed -i '/^#UsePAM\|UsePAM/c #UsePAM no' /etc/ssh/sshd_config
    sed -i "s/^#\?PubkeyAuthentication.*/PubkeyAuthentication no/g" /etc/ssh/sshd_config
    sed -i '/^AuthorizedKeysFile/s/^/#/' /etc/ssh/sshd_config
fi
if [ -f /etc/ssh/sshd_config.d/50-cloud-init.conf ]; then
    sed -i "s/^#\?Port.*/Port $sshport/g" /etc/ssh/sshd_config.d/50-cloud-init.conf
    sed -i "s/^#\?PermitRootLogin.*/PermitRootLogin yes/g" /etc/ssh/sshd_config.d/50-cloud-init.conf
    sed -i "s/^#\?PasswordAuthentication.*/PasswordAuthentication yes/g" /etc/ssh/sshd_config.d/50-cloud-init.conf
    sed -i 's/#ListenAddress 0.0.0.0/ListenAddress 0.0.0.0/' /etc/ssh/sshd_config.d/50-cloud-init.conf
    sed -i 's/#ListenAddress ::/ListenAddress ::/' /etc/ssh/sshd_config.d/50-cloud-init.conf
    sed -i 's/#AddressFamily any/AddressFamily any/' /etc/ssh/sshd_config.d/50-cloud-init.conf
    sed -i '/^#UsePAM\|UsePAM/c #UsePAM no' /etc/ssh/sshd_config.d/50-cloud-init.conf
    sed -i "s/^#\?PubkeyAuthentication.*/PubkeyAuthentication no/g" /etc/ssh/sshd_config.d/50-cloud-init.conf
    sed -i '/^AuthorizedKeysFile/s/^/#/' /etc/ssh/sshd_config.d/50-cloud-init.conf
fi
remove_duplicate_lines /etc/ssh/sshd_config
remove_duplicate_lines /etc/ssh/sshd_config.d/50-cloud-init.conf
service ssh restart
service sshd restart
systemctl restart sshd
systemctl restart ssh
rm -rf "$0"
