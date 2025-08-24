#!/bin/bash
# from
# https://github.com/oneclickvirt/docker
# 2025.08.24
# Docker存储限制测试

echo "=== Docker存储驱动检查 ==="
docker info | grep "Storage Driver"
echo "=== 创建带存储限制的测试容器 ==="
echo "容器存储限制：500MB"
# 创建测试容器并运行测试
docker run --rm --storage-opt size=500M ubuntu:latest bash -c '
echo "=== 容器内磁盘空间检查 ==="
df -h /
echo ""
echo "=== 测试1: 创建200MB文件 (应该成功) ==="
dd if=/dev/zero of=/test_200m bs=1M count=200 2>/dev/null
if [ $? -eq 0 ]; then
    echo "✅ 200MB文件创建成功"
    ls -lh /test_200m
else
    echo "❌ 200MB文件创建失败"
fi
echo ""
echo "=== 测试2: 再创建200MB文件 (应该成功) ==="
dd if=/dev/zero of=/test_200m_2 bs=1M count=200 2>/dev/null
if [ $? -eq 0 ]; then
    echo "✅ 第二个200MB文件创建成功"
    ls -lh /test_200m_2
else
    echo "❌ 第二个200MB文件创建失败"
fi
echo ""
echo "=== 磁盘使用情况 ==="
df -h /
echo ""
echo "=== 测试3: 尝试创建200MB文件 (应该失败，因为空间不足) ==="
dd if=/dev/zero of=/test_exceed bs=1M count=200 2>/dev/null
if [ $? -eq 0 ]; then
    echo "❌ 超限文件意外创建成功 - 存储限制可能未生效"
    ls -lh /test_exceed
else
    echo "✅ 超限文件创建失败 - 存储限制正常工作"
fi
echo ""
echo "=== 最终磁盘使用情况 ==="
df -h /
'
echo ""
echo "=== 测试完成 ==="