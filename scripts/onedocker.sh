#!/bin/bash
#from https://github.com/spiritLHLS/docker

# ./onedocker.sh name cpu memory sshport startport endport <disk>

cd /root >/dev/null 2>&1
name="$1"
cpu="$2"
memory="$3"
ori=$(date | md5sum)
passwd=${ori: 2: 9}
sshport="$4"
startport="$5"
endport="$6"
if [ ! -f ssh.sh ]; then
    curl -L https://raw.githubusercontent.com/spiritLHLS/docker/main/scripts/ssh.sh -o ssh.sh
    chmod 777 ssh.sh
    dos2unix ssh.sh
fi
if lsmod | grep -q xfs; then
  disk="$7"
  docker run -d --cpus=${cpu} --memory=${memory}m --storage-opt size=${disk}G --name ${name} -p ${sshport}:22 -p ${startport}-${endport}:${startport}-${endport} --cap-add=NET_ADMIN --cap-add=SYS_ADMIN --cap-add=MKNOD -v /var/run/docker.sock:/var/run/docker.sock debian /bin/bash -c "tail -f /dev/null"
  echo "$name $sshport $passwd $cpu $memory $startport $endport" >> "$name"
else
  docker run -d --cpus=${cpu} --memory=${memory}m --name ${name} -p ${sshport}:22 -p ${startport}-${endport}:${startport}-${endport} --cap-add=NET_ADMIN --cap-add=SYS_ADMIN --cap-add=MKNOD -v /var/run/docker.sock:/var/run/docker.sock debian /bin/bash -c "tail -f /dev/null"
  echo "$name $sshport $passwd $cpu $memory $startport $endport $disk" >> "$name"
fi
docker cp ssh.sh ${name}:/ssh.sh
docker exec -it ${name} bash -c "bash /ssh.sh ${passwd}"
cat "$name"
