本地文件系统支持xfs才可使用disk限制，否则将开启失败

查询

```
lsmod | grep -q xfs
```

执行上述命令有输出才可限制disk，否则勿要填写disk

不支持xfs的系统开设的容器将共享母鸡的硬盘

通过docker批量或单独开设NAT服务器(Bulk or individual NAT server provisioning via docker)

默认使用debian系统，每个容器自带1个外网ssh端口，25个内外网一致端口

默认创建的是非特权容器，且不挂载与宿主机的docker的守护进程之间的通信，所以**宿主机创建的docker虚拟化的NAT服务器内无法再嵌套虚拟化docker**

由于只是在宿主机进行了CPU和内存的限制未在容器内使用cgroup驱动，所以在容器内使用服务器测试脚本检测容器的可用资源是无效的，显示的会是宿主机的资源

由于大部分云服务器xfs文件系统不启用pquota选项，所以**默认共享宿主机硬盘，无法限制每个容器的磁盘大小**

## 配置要求

系统可安装docker即可用，网络能连接Github的raw界面就能用，硬件配置只要不拉跨就行，空闲硬盘有3G就行

推荐在开设NAT服务器前先增加部分SWAP虚拟内存，避免突发的内存占用导致母鸡卡死 [跳转](https://github.com/spiritLHLS/addswap)

PS: 如果硬件资源只是好了一点，需要限制更多东西并需要配置IPV6独立地址和限制硬盘大小，可使用LXD批量开LXC虚拟化的容器 [跳转](https://github.com/spiritLHLS/lxc)

PS: 如果硬件非常好资源很多，可使用PVE批量开KVM虚拟化的虚拟机 [跳转](https://github.com/spiritLHLS/pve)

## 环境预设

- 检测环境
- 安装docker
- 下载预制脚本

```
curl -L https://raw.githubusercontent.com/oneclickvirt/docker/main/scripts/pre_build.sh -o pre_build.sh && chmod +x pre_build.sh && bash pre_build.sh
```

## 单独开设

下载脚本

```
curl -L https://raw.githubusercontent.com/oneclickvirt/docker/main/scripts/onedocker.sh -o onedocker.sh && chmod +x onedocker.sh
```

运行

```
./onedocker.sh name cpu memory password sshport startport endport system
```

目前system仅支持选择alpine或debian，默认是debian

### 示例

将开设1核512MB内存，root的密码是123456，SSH端口映射至外网25000，批量映射的端口区间为34975到35000，此区间内外网端口一致，系统为debian

```
./onedocker.sh test 1 512 123456 25000 34975 35000 debian
```

删除示例

```
docker rm -f test
rm -rf test
ls
```

进入示例

```
docker exec -it test /bin/bash
```

### 查询信息

```
cat 容器名字
```

输出格式

```
容器名字 SSH端口 登陆的root密码 核数 内存 外网端口起 外网端口止 
```

## 批量开设

- 批量多次运行继承配置生成
- 生成多个时为避免SSH连接中断建议在screen中执行

```
curl -L https://raw.githubusercontent.com/oneclickvirt/docker/main/scripts/dockers.sh -o dockers.sh && chmod +x dockers.sh && bash dockers.sh
```

## 查询批量开设的信息

```
cat dclog
```

输出格式

```
容器名字 SSH端口 登陆的root密码 核数 内存 外网端口起 外网端口止 
```

一行一个容器对应的信息

## 卸载所有docker容器和镜像

```
docker rm -f $(docker ps -aq); docker rmi $(docker images -aq)
rm -rf dclog
ls
```

