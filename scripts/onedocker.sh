#!/bin/bash
#from https://github.com/spiritLHLS/docker

name="$1"
docker run -d --memory=512m -e USERNAME=test -e PASSWORD=123456 --name test --tmpfs /tmp:rw,size=5096000  -p 2022:22 debian /bin/bash -c "tail -f /dev/null && apt update && apt install wget sudo curl -y"
docker cp ssh.sh ${name}:/ssh.sh
docker exec -it ${name} bash -c "bash /ssh.sh"
