#!/bin/bash
# https://github.com/oneclickvirt/docker


URL="http://xxx/vm-template/win2022.tar"
FILENAME="win2022.tar"
SPLIT_PREFIX="win2022.part"
PART_SIZE_MB=2000
TOKEN="xxxxx"
OWNER="oneclickvirt"
REPO="docker"
TAG="w2022"
echo "Downloading $FILENAME..."
# curl -O "$URL"
echo "Splitting $FILENAME into ${PART_SIZE_MB}MB parts..."
# split -b ${PART_SIZE_MB}M "$FILENAME" "$SPLIT_PREFIX"
RELEASE_API="https://api.github.com/repos/$OWNER/$REPO/releases/tags/$TAG"
RELEASE_ID=$(curl -s \
  -H "Authorization: token $TOKEN" \
  "$RELEASE_API" | jq -r '.id')
if [ "$RELEASE_ID" == "null" ]; then
  echo "Release tag '$TAG' not found. 请先在 GitHub 创建该 Tag 的 Release。"
  exit 1
fi
for FILE in ${SPLIT_PREFIX}*; do
  echo "Uploading $FILE..."
  curl -s \
    -H "Authorization: token $TOKEN" \
    -H "Content-Type: application/octet-stream" \
    -T "$FILE" \
    "https://uploads.github.com/repos/$OWNER/$REPO/releases/$RELEASE_ID/assets?name=$(basename "$FILE")"
done
echo "所有分片上传完成。"
