#!/bin/bash
# https://github.com/oneclickvirt/docker

set -euo pipefail

URL="${URL:-}"
FILENAME="${FILENAME:-win2022.tar}"
SPLIT_PREFIX="${SPLIT_PREFIX:-win2022.part}"
PART_SIZE_MB="${PART_SIZE_MB:-2000}"
TOKEN="${GITHUB_TOKEN:-${TOKEN:-}}"
OWNER="${OWNER:-oneclickvirt}"
REPO="${REPO:-docker}"
TAG="${TAG:-w2022}"

for cmd in curl jq split; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Missing required command: $cmd"
    exit 1
  fi
done

if [ -z "$TOKEN" ]; then
  echo "Please set GITHUB_TOKEN or TOKEN before uploading release assets."
  exit 1
fi
if [[ ! "$PART_SIZE_MB" =~ ^[1-9][0-9]*$ ]]; then
  echo "Invalid PART_SIZE_MB: $PART_SIZE_MB"
  exit 1
fi

if [ ! -f "$FILENAME" ]; then
  if [ -z "$URL" ]; then
    echo "File $FILENAME not found. Set URL to download it or place the file in the current directory."
    exit 1
  fi
  echo "Downloading $FILENAME from $URL..."
  curl -fL --connect-timeout 15 --max-time 0 -o "$FILENAME" "$URL"
fi

shopt -s nullglob
parts=("${SPLIT_PREFIX}"*)
if [ "${#parts[@]}" -eq 0 ]; then
  echo "Splitting $FILENAME into ${PART_SIZE_MB}MB parts..."
  split -b "${PART_SIZE_MB}M" "$FILENAME" "$SPLIT_PREFIX"
  parts=("${SPLIT_PREFIX}"*)
fi
if [ "${#parts[@]}" -eq 0 ]; then
  echo "No split files found for prefix $SPLIT_PREFIX"
  exit 1
fi

RELEASE_API="https://api.github.com/repos/$OWNER/$REPO/releases/tags/$TAG"
release_response=$(curl -fsSL \
  -H "Authorization: Bearer $TOKEN" \
  "$RELEASE_API" || true)
if [ -z "$release_response" ]; then
  echo "Failed to query release tag '$TAG'. 请确认仓库、Tag、Token 权限和网络连接。"
  exit 1
fi
RELEASE_ID=$(echo "$release_response" | jq -r '.id // empty')
if [ -z "$RELEASE_ID" ] || [ "$RELEASE_ID" == "null" ]; then
  echo "Release tag '$TAG' not found. 请先在 GitHub 创建该 Tag 的 Release。"
  exit 1
fi
for FILE in "${parts[@]}"; do
  echo "Uploading $FILE..."
  curl -fsSL \
    -X POST \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/octet-stream" \
    --data-binary @"$FILE" \
    "https://uploads.github.com/repos/$OWNER/$REPO/releases/$RELEASE_ID/assets?name=$(basename "$FILE")" >/dev/null
done
echo "所有分片上传完成。"
