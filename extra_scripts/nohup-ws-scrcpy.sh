#!/bin/bash
# from
# https://github.com/oneclickvirt/docker
# 2024.04.17

export NODE_OPTIONS=--openssl-legacy-provider
export PATH=
echo $PATH
killall adb
rm -rf adb-nohup.out
nohup adb connect localhost:5555 > adb-nohup.out & 
npm start
