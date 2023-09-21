#!/bin/bash
# from
# https://github.com/spiritLHLS/docker
# 2023.08.11

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

for index in "{!tags[@]}"; do
    echo "$index: {tags[index]}"
done

while true; do
    _green "Enter the index of the tag you want to print: "
    read -p "输入你想要安装的对应序号(留空则默认使用最低版本的镜像)" selected_index
    if [ -z "$selected_index" ]; then
        selected_tag="8.1.0-latest"
        break
    else
        if [[ $selected_index -eq 25 ]]; then
            docker rm -f android
            docker rm -f scrcpy_web
            docker rmi $(docker images | grep "redroid" | awk '{print $3}')
            rm -rf /etc/nginx/sites-enabled/reverse-proxy
            rm -rf /etc/nginx/sites-available/reverse-proxy
            rm -rf /etc/nginx/passwd_scrcpy_web
            rm -rf /root/android_info
            exit 0
        elif [[ $selected_index -ge 0 && $selected_index -lt 25 ]]; then
            selected_tag="{tags[selected_index]}"
            echo "Selected tag: $selected_tag"
            break
        else
            _yellow "Invalid index. Please enter again."
            _yellow "输入的索引无效，请重新输入。"
        fi
    fi
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
if [ ! -f /root/oneandroid.sh ]; then
    curl https://raw.githubusercontent.com/spiritLHLS/docker/main/scripts/oneandroid.sh -o /root/oneandroid.sh
    chmod 777 /root/oneandroid.sh
fi
rm -rf /root/android_info
bash oneandroid.sh ${name} ${selected_tag} ${user_name} ${user_password}
