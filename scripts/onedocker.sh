#!/bin/bash
# from
# https://github.com/spiritLHLS/docker
# 2023.08.24

# ./onedocker.sh name cpu memory password sshport startport endport <system> <disk> <independent_ipv6>

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

_red() { echo -e "\033[31m\033[01m$@\033[0m"; }
_green() { echo -e "\033[32m\033[01m$@\033[0m"; }
_yellow() { echo -e "\033[33m\033[01m$@\033[0m"; }
_blue() { echo -e "\033[36m\033[01m$@\033[0m"; }
if ! command -v docker >/dev/null 2>&1; then
    _yellow "There is no Docker environment on this machine, please execute the main installation first."
    _yellow "没有Docker环境，请先执行主体安装"
    exit 1
fi
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
if [ -n "$8" ] && [ "$8" = "alpine" ]; then
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
    echo "$name $sshport $passwd $cpu $memory $startport $endport $disk" >>"$name"
else
    if [ ! -f ssh.sh ]; then
        curl -L https://raw.githubusercontent.com/spiritLHLS/docker/main/scripts/ssh.sh -o ssh.sh
        chmod 777 ssh.sh
        dos2unix ssh.sh
    fi
    if [ "$ndpresponder_status" = "Y" ] && [ "$ipv6_net_status" = "Y" ] && [ ! -z "$ipv6_address" ] && [ ! -z "$ipv6_address_without_last_segment" ]; then
        docker run -d \
            --cpus=${cpu} \
            --memory=${memory}m \
            --name ${name} \
            --network=ipv6_net \
            --ip6="${ipv6_address_without_last_segment}11" \
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
    echo "$name $sshport $passwd $cpu $memory $startport $endport $disk" >>"$name"
fi
cat "$name"
