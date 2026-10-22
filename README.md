# docker

[![Hits](https://hits.spiritlhl.net/docker.svg?action=hit&title=Hits&title_bg=%23555555&count_bg=%230eecf8&edge_flat=false)](https://hits.spiritlhl.net)

## 更新

[更新日志](CHANGELOG.md)

## 说明文档

国内(China)：

[https://virt.spiritlhl.net/](https://virt.spiritlhl.net/)

国际(Global)：

[https://www.spiritlhl.net/en/](https://www.spiritlhl.net/en/)

说明文档中 Docker 分区内容

## 说明

- 支持系统：Ubuntu、Debian、Alpine、AlmaLinux 9、RockyLinux 9、OpenEuler 22.03
- 系统输入支持带版本号写法，例如 `debian11`、`debian/11`、`ubuntu20`、`almalinux9`、`rockylinux9`、`openeuler22.03`；脚本会归一到当前维护的镜像族
- 支持架构：amd64、arm64
- 镜像同时发布到 GHCR（`ghcr.io/oneclickvirt/docker`）和 GitHub Releases（tar.gz 离线包）
- `onedocker.sh` 优先从 GHCR 拉取镜像，失败后自动回退至 Releases 离线包，最后回退到 Docker Hub

## 致谢

感谢 [LinuxMirrors](https://github.com/SuperManito/LinuxMirrors) 提供的国内镜像安装以及国内包管理源镜像替换脚本

## Stargazers over time

[![Stargazers over time](https://starchart.cc/oneclickvirt/docker.svg)](https://starchart.cc/oneclickvirt/docker)
