#!/bin/bash
# from
# https://github.com/oneclickvirt/docker
# 2024.04.17

export NODE_OPTIONS=--openssl-legacy-provider
export PATH="${PATH:-/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}"
echo "$PATH"
pkill -x adb 2>/dev/null || killall adb 2>/dev/null || true
rm -rf adb-nohup.out
nohup adb connect localhost:5555 > adb-nohup.out &
npm start
