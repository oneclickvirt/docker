#!/bin/bash
# from
# https://github.com/oneclickvirt/docker
# 2024.11.17

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

if [ "$interactionless" != "true" ]; then
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
fi

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
    if command -v apt-get >/dev/null 2>&1; then
        ${PACKAGE_INSTALL[int]} cron 
    else
        ${PACKAGE_INSTALL[int]} cronie
    fi
}

if [ "$interactionless" != "true" ]; then
    install_required_modules
    if [ -f "/etc/motd" ]; then
        echo '' >/etc/motd
        echo 'Related repo https://github.com/oneclickvirt/docker' >>/etc/motd
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
    cd /etc/ssh
    ssh-keygen -A
    update_sshd_config() {
        local config_file="$1"
        if [ -f "$config_file" ]; then
            echo "updating $config_file"
            sudo sed -i "s/^#\?Port.*/Port 22/g" "$config_file"
            sudo sed -i "s/^#\?PermitRootLogin.*/PermitRootLogin yes/g" "$config_file"
            sudo sed -i "s/^#\?PasswordAuthentication.*/PasswordAuthentication yes/g" "$config_file"
            sudo sed -i 's/#ListenAddress 0.0.0.0/ListenAddress 0.0.0.0/' "$config_file"
            sudo sed -i 's/#ListenAddress ::/ListenAddress ::/' "$config_file"
            sudo sed -i 's/#AddressFamily any/AddressFamily any/' "$config_file"
            sudo sed -i "s/^#\?PubkeyAuthentication.*/PubkeyAuthentication no/g" "$config_file"
            sudo sed -i '/^#UsePAM\|UsePAM/c #UsePAM no' "$config_file"
            sudo sed -i '/^AuthorizedKeysFile/s/^/#/' "$config_file"
            sudo sed -i 's/^#[[:space:]]*KbdInteractiveAuthentication.*\|^KbdInteractiveAuthentication.*/KbdInteractiveAuthentication yes/' "$config_file"
        fi
    }
    update_sshd_config "/etc/ssh/sshd_config"
    remove_duplicate_lines /etc/ssh/sshd_config
    if [ -d /etc/ssh/sshd_config.d ]; then
        for config_file in /etc/ssh/sshd_config.d/*; do
            if [ -f "$config_file" ]; then
                update_sshd_config "$config_file"
                remove_duplicate_lines "$config_file"
            fi
        done
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
fi
service sshd restart
systemctl restart sshd
systemctl restart ssh
/usr/sbin/sshd || ssh-keygen -A && /usr/sbin/sshd 
service ssh restart
if [ "$interactionless" != "true" ]; then
    sed -i 's/.*precedence ::ffff:0:0\/96.*/precedence ::ffff:0:0\/96  100/g' /etc/gai.conf
fi
