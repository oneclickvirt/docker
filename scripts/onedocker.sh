#!/bin/bash
# from
# https://github.com/spiritLHLS/docker
# 2023.10.09

# ./onedocker.sh name cpu memory password sshport startport endport <system> <independent_ipv6> <disk>

cd /root >/dev/null 2>&1
name="${1:-test}"
cpu="${2:-1}"
memory="${3:-512}"
passwd="${4:-123456}"
sshport="${5:-25000}"
startport="${6:-34975}"
endport="${7:-35000}"
system="${8:-debian}"
independent_ipv6="${9:-N}"
independent_ipv6=$(echo "$independent_ipv6" | tr '[:upper:]' '[:lower:]')

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
    _yellow "IP area being detected ......"
    if [[ -z "${CN}" ]]; then
        if [[ $(curl -m 6 -s https://ipapi.co/json | grep 'China') != "" ]]; then
            _yellow "根据ipapi.co提供的信息，当前IP可能在中国"
            read -e -r -p "是否选用中国镜像完成相关组件安装? ([y]/n) " input
            case $input in
            [yY][eE][sS] | [yY])
                echo "使用中国镜像"
                CN=true
                ;;
            [nN][oO] | [nN])
                echo "不使用中国镜像"
                ;;
            *)
                echo "使用中国镜像"
                CN=true
                ;;
            esac
        else
            if [[ $? -ne 0 ]]; then
                if [[ $(curl -m 6 -s cip.cc) =~ "中国" ]]; then
                    _yellow "根据cip.cc提供的信息，当前IP可能在中国"
                    read -e -r -p "是否选用中国镜像完成相关组件安装? [Y/n] " input
                    case $input in
                    [yY][eE][sS] | [yY])
                        echo "使用中国镜像"
                        CN=true
                        ;;
                    [nN][oO] | [nN])
                        echo "不使用中国镜像"
                        ;;
                    *)
                        echo "不使用中国镜像"
                        ;;
                    esac
                fi
            fi
        fi
    fi
}

# 检查是否为中国IP
check_china

# 查询名为ipv6_net的网络是否存在
docker network inspect ipv6_net &> /dev/null
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
docker inspect ndpresponder &> /dev/null
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
    if [ ! -f alpinessh.sh ]; then
        curl -L https://raw.githubusercontent.com/spiritLHLS/docker/main/scripts/alpinessh.sh -o alpinessh.sh
        chmod 777 alpinessh.sh
        dos2unix alpinessh.sh
    fi
    docker run -d \
        --cpus=${cpu} \
        --memory=${memory}m \
        --name ${name} \
        -p ${sshport}:22 \
        -p ${startport}-${endport}:${startport}-${endport} \
        --cap-add=MKNOD \
        alpine /bin/sh -c "tail -f /dev/null"
    docker cp alpinessh.sh ${name}:/alpinessh.sh
    docker exec -it ${name} sh -c "sh /alpinessh.sh ${passwd}"
    if [[ "${CN}" == true ]]; then
        docker exec -it ${name} sh -c "bash <(curl -sSL https://gitee.com/SuperManito/LinuxMirrors/raw/main/ChangeMirrors.sh) --source mirrors.tuna.tsinghua.edu.cn --web-protocol http --intranet false --close-firewall true --backup true --updata-software false --clean-cache false --ignore-backup-tips"
    fi
    echo "$name $sshport $passwd $cpu $memory $startport $endport $disk" >>"$name"
else
    if [ ! -f ssh.sh ]; then
        curl -L https://raw.githubusercontent.com/spiritLHLS/docker/main/scripts/ssh.sh -o ssh.sh
        chmod 777 ssh.sh
        dos2unix ssh.sh
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
            debian /bin/bash -c "tail -f /dev/null"
        docker
    else
        docker run -d \
            --cpus=${cpu} \
            --memory=${memory}m \
            --name ${name} \
            -p ${sshport}:22 \
            -p ${startport}-${endport}:${startport}-${endport} \
            --cap-add=MKNOD \
            debian /bin/bash -c "tail -f /dev/null"
    fi
    docker cp ssh.sh ${name}:/ssh.sh
    docker exec -it ${name} bash -c "bash /ssh.sh ${passwd}"
    if [[ "${CN}" == true ]]; then
        docker exec -it ${name} bash -c "bash <(curl -sSL https://gitee.com/SuperManito/LinuxMirrors/raw/main/ChangeMirrors.sh) --source mirrors.tuna.tsinghua.edu.cn --web-protocol http --intranet false --close-firewall true --backup true --updata-software false --clean-cache false --ignore-backup-tips"
    fi
    echo "$name $sshport $passwd $cpu $memory $startport $endport $disk" >>"$name"
fi
cat "$name"
