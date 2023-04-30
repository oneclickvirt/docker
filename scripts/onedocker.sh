#!/bin/bash
#from https://github.com/spiritLHLS/docker

# ./onedocker.sh name cpu memory password sshport startport endport <system> <disk>

cd /root >/dev/null 2>&1
name="${1:-test}"
cpu="${2:-1}"
memory="${3:-512}"
passwd="${4:-123456}"
sshport="${5:-25000}"
startport="${6:-34975}"
endport="${7:-35000}"
if [ ! -f ssh.sh ]; then
    curl -L https://raw.githubusercontent.com/spiritLHLS/docker/main/scripts/ssh.sh -o ssh.sh
    chmod 777 ssh.sh
    dos2unix ssh.sh
fi
# -v /var/run/docker.sock:/var/run/docker.sock
# --cap-add=NET_ADMIN --cap-add=SYS_ADMIN
# if lsmod | grep -q xfs; then
#   disk="${8:-5}"
#   docker run -d --cpus=${cpu} --memory=${memory}m --storage-opt size=${disk}G --name ${name} -p ${sshport}:22 -p ${startport}-${endport}:${startport}-${endport} --cap-add=MKNOD debian /bin/bash -c "tail -f /dev/null"
#   echo "$name $sshport $passwd $cpu $memory $startport $endport" >> "$name"
# else
# fi
if [ -n "$8" ] && [ "$8" = "alpine" ]
then
    docker run -d --cpus=${cpu} --memory=${memory}m --name ${name} -p ${sshport}:22 -p ${startport}-${endport}:${startport}-${endport} --cap-add=MKNOD alpine /bin/sh -c "tail -f /dev/null"
    echo "$name $sshport $passwd $cpu $memory $startport $endport $disk" >> "$name"
    docker cp ssh.sh ${name}:/ssh.sh
    docker exec -it ${name} sh -c "sh /ssh.sh ${passwd}"
else
    docker run -d --cpus=${cpu} --memory=${memory}m --name ${name} -p ${sshport}:22 -p ${startport}-${endport}:${startport}-${endport} --cap-add=MKNOD debian /bin/bash -c "tail -f /dev/null"
    echo "$name $sshport $passwd $cpu $memory $startport $endport $disk" >> "$name"
    docker cp ssh.sh ${name}:/ssh.sh
    docker exec -it ${name} bash -c "bash /ssh.sh ${passwd}"
fi
cat "$name"
