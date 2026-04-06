# docker

[![Hits](https://hits.spiritlhl.net/docker.svg?action=hit&title=Hits&title_bg=%23555555&count_bg=%230eecf8&edge_flat=false)](https://hits.spiritlhl.net)

## 更新

2026.04.06

- 支持环境变量无交互安装

[更新日志](CHANGELOG.md)

## 说明文档

国内(China)：

[https://virt.spiritlhl.net/](https://virt.spiritlhl.net/)

国际(Global)：

[https://www.spiritlhl.net/en/](https://www.spiritlhl.net/en/)

说明文档中 Docker 分区内容

## 说明

- 支持系统：Ubuntu、Debian、Alpine、AlmaLinux 9、RockyLinux 9、OpenEuler 22.03
- 支持架构：amd64、arm64
- 镜像同时发布到 GHCR（`ghcr.io/oneclickvirt/docker`）和 GitHub Releases（tar.gz 离线包）
- `onedocker.sh` 优先从 GHCR 拉取镜像，失败后自动回退至 Releases 离线包，最后回退到 Docker Hub

## 安装 Docker 环境

```bash
bash <(wget -qO- https://raw.githubusercontent.com/oneclickvirt/docker/main/scripts/dockerinstall.sh)
```

## 开设单个容器

```bash
# 用法: ./onedocker.sh <name> <cpu> <memory_mb> <password> <sshport> <startport> <endport> [independent_ipv6:y/n] [system] [disk_gb]
bash onedocker.sh dc1 1 512 mypasswd 25001 35001 35025 n debian 0
```

## 批量开设容器

```bash
bash create_docker.sh
```

## 查看与管理容器

```bash
# 查看所有容器
docker ps -a
# 查看日志文件
cat /root/dclog
# 进入容器
docker exec -it <name> bash
```

## 卸载（完整清理）

一键卸载 Docker 全套环境，包括所有容器、镜像、网络、systemd 服务、二进制文件：

```bash
bash <(wget -qO- https://raw.githubusercontent.com/oneclickvirt/docker/main/dockeruninstall.sh)
```

脚本会在执行前要求输入 `yes` 确认，操作不可逆。

> **复测流程**：先执行卸载，再执行安装，即可从零验证整个安装流程。

## 镜像说明

本仓库自编镜像通过 GitHub Actions 构建，同时发布到 GHCR 和 GitHub Releases：

| 系统 | GHCR 镜像（多架构）| amd64 tar | arm64 tar |
|------|---------------------|-----------|-----------|
| Ubuntu | `ghcr.io/oneclickvirt/docker:ubuntu` | spiritlhl_ubuntu_amd64.tar.gz | spiritlhl_ubuntu_arm64.tar.gz |
| Debian | `ghcr.io/oneclickvirt/docker:debian` | spiritlhl_debian_amd64.tar.gz | spiritlhl_debian_arm64.tar.gz |
| Alpine | `ghcr.io/oneclickvirt/docker:alpine` | spiritlhl_alpine_amd64.tar.gz | spiritlhl_alpine_arm64.tar.gz |
| AlmaLinux 9 | `ghcr.io/oneclickvirt/docker:almalinux` | spiritlhl_almalinux_amd64.tar.gz | spiritlhl_almalinux_arm64.tar.gz |
| RockyLinux 9 | `ghcr.io/oneclickvirt/docker:rockylinux` | spiritlhl_rockylinux_amd64.tar.gz | spiritlhl_rockylinux_arm64.tar.gz |
| OpenEuler 22.03 | `ghcr.io/oneclickvirt/docker:openeuler` | spiritlhl_openeuler_amd64.tar.gz | spiritlhl_openeuler_arm64.tar.gz |

手动拉取示例：

```bash
docker pull ghcr.io/oneclickvirt/docker:debian
```

## 网络说明

- 默认使用主机 NAT 网络，通过端口映射暴露 SSH 及自定义端口
- 若宿主机配置了公网 IPv6 并检测到 ndpresponder 容器，可为容器分配独立 IPv6 地址

## 致谢

感谢 [LinuxMirrors](https://github.com/SuperManito/LinuxMirrors) 提供的国内镜像安装以及国内包管理源镜像替换脚本

## Stargazers over time

[![Stargazers over time](https://starchart.cc/oneclickvirt/docker.svg)](https://starchart.cc/oneclickvirt/docker)
