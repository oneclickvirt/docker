#!/bin/bash
# from
# https://github.com/oneclickvirt/docker
# 2024.05.22

# cd /root
_red() { echo -e "\033[31m\033[01m$@\033[0m"; }
_green() { echo -e "\033[32m\033[01m$@\033[0m"; }
_yellow() { echo -e "\033[33m\033[01m$@\033[0m"; }
_blue() { echo -e "\033[36m\033[01m$@\033[0m"; }
reading() { read -rp "$(_green "$1")" "$2"; }
utf8_locale=$(locale -a 2>/dev/null | grep -i -m 1 -E "utf8|UTF-8")
if [[ -z "$utf8_locale" ]]; then
    _yellow "No UTF-8 locale found"
else
    export LC_ALL="$utf8_locale"
    export LANG="$utf8_locale"
    export LANGUAGE="$utf8_locale"
    _green "Locale set to $utf8_locale"
fi
cd /root >/dev/null 2>&1

pre_check() {
    home_dir=$(eval echo "~$(whoami)")
    if [ "$home_dir" != "/root" ]; then
        _red "Current path is not /root, script will exit."
        _red "当前路径不是/root，脚本将退出。"
        exit 1
    fi
    if ! command -v docker >/dev/null 2>&1; then
        curl -L https://raw.githubusercontent.com/oneclickvirt/docker/main/scripts/pre_build.sh -o pre_build.sh
        chmod 777 pre_build.sh
        dos2unix pre_build.sh
        bash pre_build.sh
    fi
    if [ ! -f ssh_bash.sh ]; then
        curl -L https://raw.githubusercontent.com/oneclickvirt/docker/main/scripts/ssh_bash.sh -o ssh_bash.sh
        chmod 777 ssh_bash.sh
        dos2unix ssh_bash.sh
    fi
    if [ ! -f ssh_sh.sh ]; then
        curl -L https://raw.githubusercontent.com/oneclickvirt/docker/main/scripts/ssh_sh.sh -o ssh_sh.sh
        chmod 777 ssh_sh.sh
        dos2unix ssh_sh.sh
    fi
    if [ ! -f buildone.sh ]; then
        curl -L https://raw.githubusercontent.com/oneclickvirt/docker/main/scripts/onedocker.sh -o onedocker.sh
        chmod 777 onedocker.sh
        dos2unix onedocker.sh
    fi
}

check_log() {
    log_file="dclog"
    if [ -f "$log_file" ]; then
        _green "dclog file exists, content being read..."
        _green "dclog文件存在，正在读取内容..."
        while read line; do
            # echo "$line"
            last_line="$line"
        done <"$log_file"
        last_line_array=($last_line)
        container_name="${last_line_array[0]}"
        ssh_port="${last_line_array[1]}"
        password="${last_line_array[2]}"
        public_port_start="${last_line_array[5]}"
        public_port_end="${last_line_array[6]}"
        #         if lsmod | grep -q xfs; then
        #           disk="${last_line_array[7]}"
        #         fi
        container_prefix="${container_name%%[0-9]*}"
        container_num="${container_name##*[!0-9]}"
        _yellow "Current information about the last docker:"
        _blue "Container prefix: $container_prefix"
        _blue "Number of containers: $container_num"
        _blue "SSH port: $ssh_port"
        _blue "Extranet port start: $public_port_start"
        _blue "Extranet port end: $public_port_end"
    else
        _red "dclog file does not exist"
        _red "dclog文件不存在"
        container_prefix="dc"
        container_num=0
        ssh_port=25000
        public_port_end=35000
    fi

}

build_new_containers() {
    while true; do
        _green "How many more dockers do I need to generate? (Enter how many dockers to add):"
        reading "还需要生成几个小鸡？(输入新增几个小鸡)：" new_nums
        if [[ "$new_nums" =~ ^[1-9][0-9]*$ ]]; then
            break
        else
            _yellow "Invalid input, please enter a positive integer."
            _yellow "输入无效，请输入一个正整数。"
        fi
    done
    while true; do
        _green "How much memory is allocated per docker? (Memory size per docker, if 256MB of memory is requi_red, enter 256):"
        reading "每个小鸡分配多少内存？(每个小鸡内存大小，若需要256MB内存，输入256)：" memory_nums
        if [[ "$memory_nums" =~ ^[1-9][0-9]*$ ]]; then
            break
        else
            _yellow "Invalid input, please enter a positive integer."
            _yellow "输入无效，请输入一个正整数。"
        fi
    done
    while true; do
        _green "Which system do you want to use? Please enter 'debian' or 'alpine':"
        reading "您想使用哪个系统？请输入 'debian' 或 'alpine'：" system_input
        if [[ -z "$system_input" || "$system_input" == "debian" || "$system_input" == "alpine" ]]; then
            system=${system_input:-"debian"}
            break
        else
            _yellow "Invalid input, please enter 'debian' or 'alpine'."
            _yellow "输入无效，请输入 'debian' 或 'alpine'。"
        fi
    done
    while true; do
        _green "Need to attach a separate IPV6 address to each virtual machine?([N]/y)"
        reading "是否附加独立的IPV6地址？([N]/y)" independent_ipv6
        independent_ipv6=$(echo "$independent_ipv6" | tr '[:upper:]' '[:lower:]')
        if [ "$independent_ipv6" = "y" ] || [ "$independent_ipv6" = "n" ]; then
            break
        else
            _yellow "Invalid input, please enter y or n."
            _yellow "输入无效，请输入Y或者N。"
        fi
    done
    for ((i = 1; i <= $new_nums; i++)); do
        container_num=$(($container_num + 1))
        container_name="${container_prefix}${container_num}"
        ssh_port=$(($ssh_port + 1))
        public_port_start=$(($public_port_end + 1))
        public_port_end=$(($public_port_start + 25))
        ori=$(date | md5sum)
        passwd=${ori:2:9}
        ./onedocker.sh $container_name 1 $memory_nums $passwd $ssh_port $public_port_start $public_port_end $independent_ipv6 $system
        cat "$container_name" >>dclog
        rm -rf $container_name
    done
}

if ! command -v docker >/dev/null 2>&1; then
    _yellow "There is no Docker environment on this machine, please execute the main installation first."
    _yellow "没有Docker环境，请先执行主体安装"
    exit 1
fi
pre_check
check_log
build_new_containers
_green "Generating new dockers is complete"
_green "生成新的小鸡完毕"
check_log
