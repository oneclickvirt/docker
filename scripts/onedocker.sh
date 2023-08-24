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
if ! command -v docker >/dev/null 2>&1; then
    echo "There is no Docker environment on this machine, please execute the main installation first."
    echo "没有Docker环境，请先执行主体安装"
    exit 1
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
    docker run -d \
        --cpus=${cpu} \
        --memory=${memory}m \
        --name ${name} \
        -p ${sshport}:22 \
        -p ${startport}-${endport}:${startport}-${endport} \
        --cap-add=MKNOD \
        debian /bin/bash -c "tail -f /dev/null"
    docker cp ssh.sh ${name}:/ssh.sh
    docker exec -it ${name} bash -c "bash /ssh.sh ${passwd}"
    echo "$name $sshport $passwd $cpu $memory $startport $endport $disk" >>"$name"
fi
cat "$name"
