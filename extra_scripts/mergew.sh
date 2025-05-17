#!/bin/bash
# https://github.com/oneclickvirt/docker

#curl https://raw.githubusercontent.com/oneclickvirt/docker/refs/heads/main/extra_scripts/mergew.sh -o mergew.sh && chmod 777 mergew.sh
#bash mergew.sh
#docker load -i win2022.tar && docker run -it -d -e RAM_SIZE="4G" -e CPU_CORES="2" --name win2022 -p 8006:8006 --device=/dev/kvm --device=/dev/net/tun --cap-add NET_ADMIN --stop-timeout 120 windows:2022

OWNER="oneclickvirt"
REPO="docker"
TAG="w2022"
OUTPUT_FILENAME="win2022.tar"
PART_PREFIX="win2022.part"
TOKEN=""
RELEASE_API="https://api.github.com/repos/$OWNER/$REPO/releases/tags/$TAG"
if [ -n "$TOKEN" ]; then
  RESPONSE=$(curl -s -H "Authorization: token $TOKEN" "$RELEASE_API")
else
  RESPONSE=$(curl -s "$RELEASE_API")
fi
DOWNLOAD_URLS=$(echo "$RESPONSE" | jq -r '.assets[] | select(.name | startswith("'$PART_PREFIX'")) | .browser_download_url')
if [ -z "$DOWNLOAD_URLS" ]; then
  echo "未找到任何分片文件，确保 Release 中存在以 $PART_PREFIX 开头的文件。"
  exit 1
fi
TMPDIR=$(mktemp -d)
cd "$TMPDIR" || exit 1
for URL in $DOWNLOAD_URLS; do
  FILENAME=$(basename "$URL")
  curl -L -O "$URL"
done
cat ${PART_PREFIX}* > "$OUTPUT_FILENAME"
mv "$OUTPUT_FILENAME" "$OLDPWD/"
cd "$OLDPWD"
rm -rf "$TMPDIR"
echo "下载并合并完成：$OUTPUT_FILENAME"
