#!/bin/bash
# https://github.com/oneclickvirt/docker

set -euo pipefail

#curl https://raw.githubusercontent.com/oneclickvirt/docker/refs/heads/main/extra_scripts/mergew.sh -o mergew.sh && chmod 777 mergew.sh
#bash mergew.sh
#docker load -i win2022.tar && docker run -d -e RAM_SIZE="4G" -e CPU_CORES="2" --name win2022 -p 8006:8006 --device=/dev/kvm --device=/dev/net/tun --cap-add NET_ADMIN --stop-timeout 120 windows:2022

OWNER="${OWNER:-oneclickvirt}"
REPO="${REPO:-docker}"
TAG="${TAG:-w2022}"
OUTPUT_FILENAME="${OUTPUT_FILENAME:-win2022.tar}"
PART_PREFIX="${PART_PREFIX:-win2022.part}"
TOKEN="${GITHUB_TOKEN:-${TOKEN:-}}"

for cmd in curl jq mktemp; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Missing required command: $cmd"
    exit 1
  fi
done

RELEASE_API="https://api.github.com/repos/$OWNER/$REPO/releases/tags/$TAG"
if [ -n "$TOKEN" ]; then
  RESPONSE=$(curl -fsSL -H "Authorization: Bearer $TOKEN" "$RELEASE_API" || true)
else
  RESPONSE=$(curl -fsSL "$RELEASE_API" || true)
fi
if [ -z "$RESPONSE" ]; then
  echo "Failed to query release tag '$TAG'. 请确认仓库、Tag、Token 权限和网络连接。"
  exit 1
fi
DOWNLOAD_URLS=$(echo "$RESPONSE" | jq -r --arg prefix "$PART_PREFIX" '.assets[]? | select(.name | startswith($prefix)) | .browser_download_url')
if [ -z "$DOWNLOAD_URLS" ]; then
  echo "未找到任何分片文件，确保 Release 中存在以 $PART_PREFIX 开头的文件。"
  exit 1
fi
TMPDIR=$(mktemp -d)
OUTPUT_DIR=$(pwd)
trap 'rm -rf "$TMPDIR"' EXIT
cd "$TMPDIR" || exit 1
for URL in $DOWNLOAD_URLS; do
  FILENAME=$(basename "$URL")
  curl -fL -O "$URL"
done
shopt -s nullglob
parts=("${PART_PREFIX}"*)
if [ "${#parts[@]}" -eq 0 ]; then
  echo "No downloaded part files found for prefix $PART_PREFIX"
  exit 1
fi
cat "${parts[@]}" > "$OUTPUT_FILENAME"
mv "$OUTPUT_FILENAME" "$OUTPUT_DIR/"
cd "$OUTPUT_DIR"
echo "下载并合并完成：$OUTPUT_FILENAME"
