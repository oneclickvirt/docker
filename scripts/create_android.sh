#!/bin/bash
# from
# https://github.com/oneclickvirt/docker
# 2024.04.16

cd /root >/dev/null 2>&1
_red() { echo -e "\033[31m\033[01m$@\033[0m"; }
_green() { echo -e "\033[32m\033[01m$@\033[0m"; }
_yellow() { echo -e "\033[33m\033[01m$@\033[0m"; }
_blue() { echo -e "\033[36m\033[01m$@\033[0m"; }
reading() { read -rp "$(_green "$1")" "$2"; }
export DEBIAN_FRONTEND=noninteractive
utf8_locale=$(locale -a 2>/dev/null | grep -i -m 1 -E "UTF-8|utf8")
if [[ -z "$utf8_locale" ]]; then
    echo "No UTF-8 locale found"
else
    export LC_ALL="$utf8_locale"
    export LANG="$utf8_locale"
    export LANGUAGE="$utf8_locale"
    echo "Locale set to $utf8_locale"
fi
if [ "$(id -u)" != "0" ]; then
    _red "This script must be run as root" 1>&2
    exit 1
fi
REGEX=("debian" "ubuntu" "centos|red hat|kernel|oracle linux|alma|rocky" "'amazon linux'" "fedora" "arch")
RELEASE=("Debian" "Ubuntu" "CentOS" "CentOS" "Fedora" "Arch")
PACKAGE_UPDATE=("! apt-get update && apt-get --fix-broken install -y && apt-get update" "apt-get update" "yum -y update" "yum -y update" "yum -y update" "pacman -Sy")
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
if ! command -v docker >/dev/null 2>&1; then
    _yellow "There is no Docker environment on this machine, please execute the main installation first."
    _yellow "没有Docker环境，请先执行主体安装"
    exit 1
fi
image_name="redroid/redroid"
tags=($(curl -s "https://registry.hub.docker.com/v2/repositories/${image_name}/tags/" | jq -r '.results[].name'))
for index in "${!tags[@]}"; do
    echo "$index: ${tags[index]}"
done
while true; do
    _green "Enter the index of the tag you want to print: "
    reading "输入你想要安装的对应序号(留空则默认使用最低版本的镜像)" selected_index
    if [ -z "$selected_index" ]; then
        selected_tag="8.1.0-latest"
        break
    else
        if [[ $selected_index -ge 0 && $selected_index -lt ${#tags[@]} ]]; then
            selected_tag="${tags[selected_index]}"
            echo "Selected tag: $selected_tag"
            break
        else
            _yellow "Invalid index. Please enter again."
            _yellow "输入的索引无效，请重新输入。"
        fi
    fi
done
# _green "Please enter the name of the Android container: (the default name is android)"
# reading "请输入安卓容器的名字：(留空则默认名字是android)" name
# if [ -z "$name" ]; then
#     name="android"
# fi
name="android"
_green "Please enter the name of the web authentication: (leave it blank for the default name to be onea):"
reading "请输入web验证的名字：(留空则默认名字是onea)：" user_name
if [ -z "$user_name" ]; then
    user_name="onea"
fi
_green "Please enter the password for web authentication: (leave it blank or the default password is oneclick):"
reading "请输入web验证的密码：(留空则默认密码是oneclick)：" user_password
if [ -z "$user_password" ]; then
    user_password="oneclick"
fi
current_kernel_version=$(uname -r)
target_kernel_version="5.0"
if [[ "$(echo -e "$current_kernel_version\n$target_kernel_version" | sort -V | head -n 1)" == "$target_kernel_version" ]]; then
    echo "当前内核版本 $current_kernel_version 大于或等于 $target_kernel_version，无需升级。"
else
    echo "当前内核版本 $current_kernel_version 小于 $target_kernel_version，请自行升级系统"
fi
if ! dpkg -S linux-modules-extra-${current_kernel_version} >/dev/null 2>&1; then
    ${PACKAGE_INSTALL[int]} linux-modules-extra-${current_kernel_version}
fi
modprobe binder_linux devices="binder,hwbinder,vndbinder"
modprobe ashmem_linux
if [ ! -d /usr/local/bin ]; then
    mkdir -p /usr/local/bin
fi
if ! command -v npm >/dev/null 2>&1; then
    curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
    export NVM_DIR="$HOME/.nvm"
    [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"  # This loads nvm
    [ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"  # This loads nvm bash_completion
    nvm install 20
    echo "node version:"
    node -v
    echo "npm version:"
    npm -v
    npm install -g node-gyp
    _green "Please reboot the system to execute this script again to load the default environment configuration"
    _green "请重启本机再次执行本脚本，以加载默认环境配置"
    echo "1" > /usr/local/bin/reboot_from_android
    exit 1
fi
if [ ! -f /usr/local/bin/reboot_from_android ];then
    _green "Please reboot the system to execute this script again to load the default environment configuration"
    _green "请重启本机再次执行本脚本，以加载默认环境配置"
    echo "1" > /usr/local/bin/reboot_from_android
    exit 1
fi
if command -v npm >/dev/null 2>&1; then
    echo "node version:"
    node -v
    echo "npm version:"
    npm -v
    npm install -g node-gyp
fi
if ! command -v make >/dev/null 2>&1; then
    ${PACKAGE_INSTALL[int]} make
fi
if ! command -v adb >/dev/null 2>&1; then
    ${PACKAGE_INSTALL[int]} adb
fi
if ! command -v git >/dev/null 2>&1; then
    ${PACKAGE_INSTALL[int]} git
fi
${PACKAGE_INSTALL[int]} g++
if [ ! -d /root/ws-scrcpy ]; then
    git clone https://github.com/NetrisTV/ws-scrcpy.git
    cd /root/ws-scrcpy
    npm install
fi
if [ ! -f /root/oneandroid.sh ]; then
    curl https://raw.githubusercontent.com/oneclickvirt/docker/main/scripts/oneandroid.sh -o /root/oneandroid.sh
    chmod 777 /root/oneandroid.sh
fi
rm -rf /root/android_info
bash oneandroid.sh ${name} ${selected_tag} ${user_name} ${user_password}
