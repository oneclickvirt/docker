本地文件系统支持xfs才可使用disk限制，否则将开启失败

查询

```
lsmod | grep -q xfs
```

执行上述命令有输出才可限制disk，否则勿要填写disk

不支持xfs的系统开设的容器将共享母鸡的硬盘
