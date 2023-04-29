#!/bin/bash
#from https://github.com/spiritLHLS/docker

# ./onedocker.sh name cpu memory password sshport startport endport <disk>

cd /root >/dev/null 2>&1
name="$1"
cpu="$2"
memory="$3"
passwd="$4"
sshport="$5"
startport="$6"
endport="$7"
if [ ! -f ssh.sh ]; then
    curl -L https://raw.githubusercontent.com/spiritLHLS/docker/main/scripts/ssh.sh -o ssh.sh
    chmod 777 ssh.sh
    dos2unix ssh.sh
fi
# -v /var/run/docker.sock:/var/run/docker.sock
# --cap-add=NET_ADMIN --cap-add=SYS_ADMIN
if lsmod | grep -q xfs; then
  disk="$8"
  docker run -d --cpus=${cpu} --memory=${memory}m --storage-opt size=${disk}G --name ${name} -p ${sshport}:22 -p ${startport}-${endport}:${startport}-${endport} --cap-add=MKNOD debian /bin/bash -c "tail -f /dev/null"
  echo "$name $sshport $passwd $cpu $memory $startport $endport" >> "$name"
else
  docker run -d --cpus=${cpu} --memory=${memory}m --name ${name} -p ${sshport}:22 -p ${startport}-${endport}:${startport}-${endport} --cap-add=MKNOD debian /bin/bash -c "tail -f /dev/null"
  echo "$name $sshport $passwd $cpu $memory $startport $endport $disk" >> "$name"
fi
docker cp ssh.sh ${name}:/ssh.sh
docker exec -it ${name} bash -c "bash /ssh.sh ${passwd}"
cat "$name"
