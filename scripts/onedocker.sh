#!/bin/bash
# from
# https://github.com/oneclickvirt/docker
# 2024.11.17

# ./onedocker.sh name cpu memory password sshport startport endport <independent_ipv6> <system>
# <disk>

cd /root >/dev/null 2>&1
name="${1:-test}"
cpu="${2:-1}"
memory="${3:-512}"
passwd="${4:-123456}"
sshport="${5:-25000}"
startport="${6:-34975}"
endport="${7:-35000}"
independent_ipv6="${8:-N}"
independent_ipv6=$(echo "$independent_ipv6" | tr '[:upper:]' '[:lower:]')
system="${9:-debian}"

_red() { echo -e "\033[31m\033[01m$@\033[0m"; }
_green() { echo -e "\033[32m\033[01m$@\033[0m"; }
_yellow() { echo -e "\033[33m\033[01m$@\033[0m"; }
_blue() { echo -e "\033[36m\033[01m$@\033[0m"; }
if ! command -v docker >/dev/null 2>&1; then
    _yellow "There is no Docker environment on this machine, please execute the main installation first."
    _yellow "没有Docker环境，请先执行主体安装"
    exit 1
fi

check_china() {
    echo "IP area being detected ......"
    if [[ -z "${CN}" ]]; then
        if [[ $(curl -m 6 -s https://ipapi.co/json | grep 'China') != "" ]]; then
            echo "根据ipapi.co提供的信息，当前IP可能在中国，使用中国镜像完成相关组件安装"
            CN=true
        else
            if [[ $? -ne 0 ]]; then
                if [[ $(curl -m 6 -s cip.cc) =~ "中国" ]]; then
                    echo "根据cip.cc提供的信息，当前IP可能在中国，使用中国镜像完成相关组件安装"
                    CN=true
                fi
            fi
        fi
    fi
}

check_cdn() {
    local o_url=$1
    for cdn_url in "${cdn_urls[@]}"; do
        if curl -sL -k "$cdn_url$o_url" --max-time 6 | grep -q "success" >/dev/null 2>&1; then
            export cdn_success_url="$cdn_url"
            return
        fi
        sleep 0.5
    done
    export cdn_success_url=""
}

check_cdn_file() {
    check_cdn "https://raw.githubusercontent.com/spiritLHLS/ecs/main/back/test"
    if [ -n "$cdn_success_url" ]; then
        _yellow "CDN available, using CDN"
    else
        _yellow "No CDN available, no use CDN"
    fi
}

# 检查是否为中国IP
check_china
cdn_urls=("https://cdn0.spiritlhl.top/" "http://cdn3.spiritlhl.net/" "http://cdn1.spiritlhl.net/" "https://ghproxy.com/" "http://cdn2.spiritlhl.net/")
if [ "${CN}" == true ]; then
    check_cdn_file
fi

# 查询名为ipv6_net的网络是否存在
docker network inspect ipv6_net &>/dev/null
if [ $? -eq 0 ]; then
    _green "ipv6_net exists in the Docker network"
    _green "ipv6_net 存在于 Docker 网络中"
    ipv6_net_status="Y"
else
    _yellow "ipv6_net does not exist in the Docker network"
    _yellow "ipv6_net 不存在于 Docker 网络中"
    ipv6_net_status="N"
fi

# 查询名为ndpresponder的容器是否存在且活跃
docker inspect ndpresponder &>/dev/null
if [ $? -eq 0 ]; then
    container_status=$(docker inspect -f '{{.State.Status}}' ndpresponder)
    if [ "$container_status" == "running" ]; then
        _green "ndpresponder container exists and is running"
        _green "ndpresponder 容器存在且正在运行"
        ndpresponder_status="Y"
    else
        _yellow "ndpresponder Container exists but is not in running state"
        _yellow "ndpresponder 容器存在，但未在运行状态"
        ndpresponder_status="N"
    fi
else
    _yellow "ndpresponder container does not exist"
    _yellow "ndpresponder 容器不存在"
    ndpresponder_status="N"
fi

if [ -f /usr/local/bin/docker_check_ipv6 ] && [ -s /usr/local/bin/docker_check_ipv6 ] && [ "$(sed -e '/^[[:space:]]*$/d' /usr/local/bin/docker_check_ipv6)" != "" ]; then
    ipv6_address=$(cat /usr/local/bin/docker_check_ipv6)
    ipv6_address_without_last_segment="${ipv6_address%:*}:"
fi
if [ -n "$system" ] && [ "$system" = "alpine" ]; then
    if [ ! -f ssh_sh.sh ]; then
        curl -Lk https://raw.githubusercontent.com/oneclickvirt/docker/main/scripts/ssh_sh.sh -o ssh_sh.sh
        chmod 777 ssh_sh.sh
        dos2unix ssh_sh.sh
    fi
    if [[ ! -f ChangeMirrors.sh && "${CN}" == true ]]; then
        curl -Lk https://gitee.com/SuperManito/LinuxMirrors/raw/main/ChangeMirrors.sh -o ChangeMirrors.sh
        chmod 777 ChangeMirrors.sh
        dos2unix ChangeMirrors.sh
    fi
    if [ "$ndpresponder_status" = "Y" ] && [ "$ipv6_net_status" = "Y" ] && [ ! -z "$ipv6_address" ] && [ ! -z "$ipv6_address_without_last_segment" ] && [ "$independent_ipv6" = "y" ]; then
        docker run -d \
            --cpus=${cpu} \
            --memory=${memory}m \
            --name ${name} \
            --network=ipv6_net \
            -p ${sshport}:22 \
            -p ${startport}-${endport}:${startport}-${endport} \
            --cap-add=MKNOD \
            --volume /var/lib/lxcfs/proc/cpuinfo:/proc/cpuinfo:rw \
            --volume /var/lib/lxcfs/proc/diskstats:/proc/diskstats:rw \
            --volume /var/lib/lxcfs/proc/meminfo:/proc/meminfo:rw \
            --volume /var/lib/lxcfs/proc/stat:/proc/stat:rw \
            --volume /var/lib/lxcfs/proc/swaps:/proc/swaps:rw \
            --volume /var/lib/lxcfs/proc/uptime:/proc/uptime:rw \
            alpine /bin/sh -c "source ~/.bashrc && tail -f /dev/null"
        docker_use_ipv6=true
    else
        docker run -d \
            --cpus=${cpu} \
            --memory=${memory}m \
            --name ${name} \
            -p ${sshport}:22 \
            -p ${startport}-${endport}:${startport}-${endport} \
            --cap-add=MKNOD \
            --volume /var/lib/lxcfs/proc/cpuinfo:/proc/cpuinfo:rw \
            --volume /var/lib/lxcfs/proc/diskstats:/proc/diskstats:rw \
            --volume /var/lib/lxcfs/proc/meminfo:/proc/meminfo:rw \
            --volume /var/lib/lxcfs/proc/stat:/proc/stat:rw \
            --volume /var/lib/lxcfs/proc/swaps:/proc/swaps:rw \
            --volume /var/lib/lxcfs/proc/uptime:/proc/uptime:rw \
            alpine /bin/sh -c "source ~/.bashrc && tail -f /dev/null"
        docker_use_ipv6=false
    fi
    docker cp ssh_sh.sh ${name}:/ssh_sh.sh
    docker exec -it ${name} sh -c "sh /ssh_sh.sh ${passwd}"
    docker exec -it ${name} bash -c "echo 'export interactionless=true' >> ~/.bashrc"
    docker exec -it ${name} bash -c "echo 'sh /ssh_sh.sh' >> ~/.bashrc"
    if [ "$docker_use_ipv6" = true ]; then
        docker exec -it ${name} sh -c "echo '*/1 * * * * curl -m 6 -s ipv6.ip.sb && curl -m 6 -s ipv6.ip.sb' | crontab -"
    fi
    if [ "${CN}" == true ]; then
        if [ -f ChangeMirrors.sh ]; then
            docker cp ChangeMirrors.sh ${name}:/ChangeMirrors.sh
            docker exec -it ${name} sh -c "sh /ChangeMirrors.sh --source mirrors.tuna.tsinghua.edu.cn --web-protocol http --intranet false --close-firewall true --backup true --updata-software false --clean-cache false --ignore-backup-tips"
            docker exec -it ${name} sh -c "rm -rf /ChangeMirrors.sh"
        fi
        docker exec -it ${name} sh -c "wget ${cdn_success_url}https://raw.githubusercontent.com/gdraheim/docker-systemctl-replacement/master/files/docker/systemctl3.py -O /bin/systemctl && chmod a+x /bin/systemctl"
    else
        docker exec -it ${name} sh -c "wget https://raw.githubusercontent.com/gdraheim/docker-systemctl-replacement/master/files/docker/systemctl3.py -O /bin/systemctl && chmod a+x /bin/systemctl"
    fi
    echo "$name $sshport $passwd $cpu $memory $startport $endport $disk" >>"$name"
else
    if [ ! -f ssh_bash.sh ]; then
        curl -L https://raw.githubusercontent.com/oneclickvirt/docker/main/scripts/ssh_bash.sh -o ssh_bash.sh
        chmod 777 ssh_bash.sh
        dos2unix ssh_bash.sh
    fi
    if [[ ! -f ChangeMirrors.sh && "${CN}" == true ]]; then
        curl -Lk https://gitee.com/SuperManito/LinuxMirrors/raw/main/ChangeMirrors.sh -o ChangeMirrors.sh
        chmod 777 ChangeMirrors.sh
        dos2unix ChangeMirrors.sh
    fi
    if [ "$ndpresponder_status" = "Y" ] && [ "$ipv6_net_status" = "Y" ] && [ ! -z "$ipv6_address" ] && [ ! -z "$ipv6_address_without_last_segment" ] && [ "$independent_ipv6" = "y" ]; then
        docker run -d \
            --cpus=${cpu} \
            --memory=${memory}m \
            --name ${name} \
            --network=ipv6_net \
            -p ${sshport}:22 \
            -p ${startport}-${endport}:${startport}-${endport} \
            --cap-add=MKNOD \
            --volume /var/lib/lxcfs/proc/cpuinfo:/proc/cpuinfo:rw \
            --volume /var/lib/lxcfs/proc/diskstats:/proc/diskstats:rw \
            --volume /var/lib/lxcfs/proc/meminfo:/proc/meminfo:rw \
            --volume /var/lib/lxcfs/proc/stat:/proc/stat:rw \
            --volume /var/lib/lxcfs/proc/swaps:/proc/swaps:rw \
            --volume /var/lib/lxcfs/proc/uptime:/proc/uptime:rw \
            ${system} /bin/bash -c "source ~/.bashrc && tail -f /dev/null"
        docker_use_ipv6=true
    else
        docker run -d \
            --cpus=${cpu} \
            --memory=${memory}m \
            --name ${name} \
            -p ${sshport}:22 \
            -p ${startport}-${endport}:${startport}-${endport} \
            --cap-add=MKNOD \
            --volume /var/lib/lxcfs/proc/cpuinfo:/proc/cpuinfo:rw \
            --volume /var/lib/lxcfs/proc/diskstats:/proc/diskstats:rw \
            --volume /var/lib/lxcfs/proc/meminfo:/proc/meminfo:rw \
            --volume /var/lib/lxcfs/proc/stat:/proc/stat:rw \
            --volume /var/lib/lxcfs/proc/swaps:/proc/swaps:rw \
            --volume /var/lib/lxcfs/proc/uptime:/proc/uptime:rw \
            ${system} /bin/bash -c "source ~/.bashrc && tail -f /dev/null"
        docker_use_ipv6=false
    fi
    docker cp ssh_bash.sh ${name}:/ssh_bash.sh
    docker exec -it ${name} bash -c "bash /ssh_bash.sh ${passwd}"
    docker exec -it ${name} bash -c "echo 'export interactionless=true' >> ~/.bashrc"
    docker exec -it ${name} bash -c "echo 'bash /ssh_bash.sh' >> ~/.bashrc"
    if [ "$docker_use_ipv6" = true ]; then
        docker exec -it ${name} bash -c "echo '*/1 * * * * curl -m 6 -s ipv6.ip.sb && curl -m 6 -s ipv6.ip.sb' | crontab -"
    fi
    if [ "${CN}" == true ]; then
        if [ -f ChangeMirrors.sh ]; then
            docker cp ChangeMirrors.sh ${name}:/ChangeMirrors.sh
            docker exec -it ${name} bash -c "bash /ChangeMirrors.sh --source mirrors.tuna.tsinghua.edu.cn --web-protocol http --intranet false --close-firewall true --backup true --updata-software false --clean-cache false --ignore-backup-tips"
            docker exec -it ${name} bash -c "rm -rf /ChangeMirrors.sh"
        fi
        docker exec -it ${name} bash -c "wget ${cdn_success_url}https://raw.githubusercontent.com/gdraheim/docker-systemctl-replacement/master/files/docker/systemctl3.py -O /bin/systemctl && chmod a+x /bin/systemctl"
    else
        docker exec -it ${name} bash -c "wget https://raw.githubusercontent.com/gdraheim/docker-systemctl-replacement/master/files/docker/systemctl3.py -O /bin/systemctl && chmod a+x /bin/systemctl"
    fi
    echo "$name $sshport $passwd $cpu $memory $startport $endport $disk" >>"$name"
fi

cat "$name"
