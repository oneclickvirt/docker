#!/bin/bash
#from https://github.com/spiritLHLS/docker

# ./onedocker.sh name cpu memory sshport startport endport <disk>

name="$1"
cpu="$2"
memory="$3"
ori=$(date | md5sum)
passwd=${ori: 2: 9}
sshport="$4"
startport="$5"
endport="$6"
if lsmod | grep -q xfs; then
  disk="$7"
  docker run -d --cpus=${cpu} --memory=${memory}m --storage-opt size=${disk}G --name ${name} -p ${sshport}:22 -p ${startport}-${endport}:${startport}-${endport} debian /bin/bash -c "tail -f /dev/null"
  echo "$name $sshport $passwd $cpu $memory $startport $endport" >> "$name"
else
  docker run -d --cpus=${cpu} --memory=${memory}m --name ${name} -p ${sshport}:22 -p ${startport}-${endport}:${startport}-${endport} debian /bin/bash -c "tail -f /dev/null"
  echo "$name $sshport $passwd $cpu $memory $startport $endport $disk" >> "$name"
fi
docker cp ssh.sh ${name}:/ssh.sh
docker exec -it ${name} bash -c "bash /ssh.sh ${passwd}"
cat "$name"
