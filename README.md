# docker

通过docker批量或单独开设NAT服务器(Bulk or individual NAT server provisioning via docker)

## 环境预设

```
curl -L https://raw.githubusercontent.com/spiritLHLS/docker/main/scripts/pre_build.sh -o pre_build.sh && chmod +x pre_build.sh && bash pre_build.sh
```

## 单独开设

```
curl -L https://raw.githubusercontent.com/spiritLHLS/docker/main/scripts/onedocker.sh -o onedocker.sh && chmod +x onedocker.sh
```

本地文件系统支持xfs才可使用disk限制，否则将开启失败

查询

```
lsmod | grep -q xfs
```

执行上述命令有输出才可限制disk，否则勿要填写disk

```
./onedocker.sh name cpu memory sshport startport endport <disk>
```

### 示例

将开设1核512MB内存10G硬盘，SSH端口映射至外网2022，批量映射的端口区间为2023到2033，此区间内外网端口一致

```
./onedocker.sh test 1 512 2022 2023 2033 10
```

### 查询信息

```
cat 容器名字
```

## 批量开设

```
curl -L https://raw.githubusercontent.com/spiritLHLS/docker/main/scripts/dockers.sh -o dockers.sh && chmod +x dockers.sh && bash dockers.sh
```
