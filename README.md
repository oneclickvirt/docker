# docker

[![Hits](https://hits.seeyoufarm.com/api/count/incr/badge.svg?url=https%3A%2F%2Fgithub.com%2FspiritLHLS%2Fdocker&count_bg=%2379C83D&title_bg=%23555555&icon=&icon_color=%23E7E7E7&title=hits&edge_flat=false)](https://hits.seeyoufarm.com)

## 更新

2023.10.26

- 将IPV6分配不仅限于分配出/80子网，将自动计算并分配原子网下的最大子网但不包含宿主机的IPV6地址本身的子网

[更新日志](CHANGELOG.md)

## 待解决的问题

- 模板构建自定义的模板提前初始化好部分内容，避免原始模板过于干净导致初始化时间过长
- Linux的容器暂不支持限制磁盘大小，待添加限制
- Linux的容器暂不支持开设debian和alpine之外的系统，待添加补充
- Windows的容器目前镜像很大，待缩小镜像大小做精简版

## 说明文档

国内(China)：

[virt.spiritlhl.net](https://virt.spiritlhl.net/)

国际(Global)：

[www.spiritlhl.net](https://www.spiritlhl.net/)

说明文档中 Docker 分区内容

## 致谢

感谢 [LinuxMirrors](https://github.com/SuperManito/LinuxMirrors) 提供的国内镜像安装以及国内包管理源镜像替换脚本

## Stargazers over time

[![Stargazers over time](https://starchart.cc/spiritLHLS/docker.svg)](https://starchart.cc/spiritLHLS/docker)

