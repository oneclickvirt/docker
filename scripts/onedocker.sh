#!/bin/bash
#from https://github.com/spiritLHLS/docker

# ./onedocker.sh name passwd sshport startport endport <disk>

name="$1"
memory="$2"
passwd="$3"
sshport="$4"
startport="$5"
endport="$6"
if lsmod | grep -q xfs; then
  disk="$7"
  docker run -d --memory=512m --storage-opt size=${disk}G --name ${name} -p ${sshport}:22 -p ${startport}-${endport}:${startport}-${endport} debian /bin/bash -c "tail -f /dev/null"
  echo "$name $memory $sshport $passwd $startport $endport" >> "$name"
else
  docker run -d --memory=512m --name ${name} -p ${sshport}:22 -p ${startport}-${endport}:${startport}-${endport} debian /bin/bash -c "tail -f /dev/null"
  echo "$name $memory $sshport $passwd $startport $endport $disk" >> "$name"
fi
docker cp ssh.sh ${name}:/ssh.sh
docker exec -it ${name} bash -c "bash /ssh.sh ${passwd}"
cat "$name"
