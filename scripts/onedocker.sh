#!/bin/bash
#from https://github.com/spiritLHLS/docker

name="$1"
passwd="$2"
docker run -d --memory=512m --name ${name} --tmpfs /tmp:rw,size=5096000  -p 2022:22 debian /bin/bash -c "tail -f /dev/null"
docker cp ssh.sh ${name}:/ssh.sh
docker exec -it ${name} bash -c "bash /ssh.sh ${passwd}"
