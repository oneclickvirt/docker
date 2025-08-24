#!/bin/bash
# Docker存储限制测试
# 基于 https://github.com/oneclickvirt/docker
# 2025.08.24

_red() { echo -e "\033[31m\033[01m$@\033[0m"; }
_green() { echo -e "\033[32m\033[01m$@\033[0m"; }
_yellow() { echo -e "\033[33m\033[01m$@\033[0m"; }
_blue() { echo -e "\033[36m\033[01m$@\033[0m"; }

if ! command -v docker >/dev/null 2>&1; then
    _red "Docker环境不存在，请先安装Docker"
    exit 1
fi

check_china() {
    echo "正在检测IP地区......"
    if [[ -z "${CN}" ]]; then
        if [[ $(curl -m 6 -s https://ipapi.co/json 2>/dev/null | grep 'China') != "" ]]; then
            _green "检测到中国IP，将使用CDN加速"
            CN=true
        else
            _yellow "非中国IP，使用默认下载"
            CN=false
        fi
    fi
}

check_cdn() {
    local o_url=$1
    local shuffled_cdn_urls=($(shuf -e "${cdn_urls[@]}"))
    for cdn_url in "${shuffled_cdn_urls[@]}"; do
        if curl -sL -k "$cdn_url$o_url" --max-time 6 | grep -q "success" >/dev/null 2>&1; then
            export cdn_success_url="$cdn_url"
            return
        fi
        sleep 0.5
    done
    export cdn_success_url=""
}

check_cdn_file() {
    check_cdn "https://raw.githubusercontent.com/spiritLHLS/ecs/main/back/test"
    if [ -n "$cdn_success_url" ]; then
        _green "CDN可用，使用CDN加速: $cdn_success_url"
    else
        _yellow "CDN不可用，使用直连"
    fi
}

get_arch() {
    local arch=$(uname -m)
    case $arch in
        x86_64)
            echo "amd64"
            ;;
        aarch64|arm64)
            echo "arm64"
            ;;
        *)
            echo "amd64"
            ;;
    esac
}

check_storage_driver() {
    storage_driver=$(docker info --format '{{.Driver}}' 2>/dev/null || echo "overlay2")
    if [ -f /usr/local/bin/docker_storage_driver ]; then
        storage_driver=$(cat /usr/local/bin/docker_storage_driver)
    fi
    _blue "当前存储驱动: $storage_driver"
    if [ "$storage_driver" = "btrfs" ] || [ "$storage_driver" = "zfs" ] || [ "$storage_driver" = "devicemapper" ]; then
        btrfs_support="Y"
        _green "检测到支持存储限制的驱动: $storage_driver"
        return 0
    else
        btrfs_support="N"
        _yellow "当前存储驱动 ($storage_driver) 不支持存储限制功能"
        return 1
    fi
}

check_image_exists() {
    local system_type="debian"
    local arch=$(get_arch)
    # 优先查找 spiritlhl:debian-arch 格式
    if docker images --format '{{.Repository}}:{{.Tag}}' | grep -qx "spiritlhl:${system_type}-${arch}"; then
        _green "镜像 spiritlhl:${system_type}-${arch} 已存在"
        export image_name="spiritlhl:${system_type}-${arch}"
        return 0
    fi
    # 查找 spiritlhl:debian 格式
    if docker images --format '{{.Repository}}:{{.Tag}}' | grep -qx "spiritlhl:${system_type}"; then
        _green "镜像 spiritlhl:${system_type} 已存在"
        export image_name="spiritlhl:${system_type}"
        return 0
    fi
    # 查找 debian:latest 格式
    if docker images --format '{{.Repository}}:{{.Tag}}' | grep -qx "${system_type}:latest"; then
        _green "镜像 ${system_type}:latest 已存在"
        export image_name="${system_type}:latest"
        return 0
    fi
    return 1
}

download_and_load_image() {
    local system_type="debian"
    local arch=$(get_arch)
    local tar_filename="spiritlhl_${system_type}_${arch}.tar.gz"
    _yellow "正在下载 ${system_type} 的 ${arch} 架构镜像..."
    local download_url="${cdn_success_url}https://github.com/oneclickvirt/docker/releases/download/debian/spiritlhl_debian_${arch}.tar.gz"
    curl -L "$download_url" -o "$tar_filename" --connect-timeout 10 --max-time 300
    if [ -f "$tar_filename" ] && [ -s "$tar_filename" ]; then
        _yellow "正在从tar文件加载镜像..."
        docker load < "$tar_filename"
        if [ $? -eq 0 ]; then
            rm -f "$tar_filename"
            export image_name="spiritlhl:${system_type}-${arch}"
            _green "镜像加载成功"
            return 0
        else
            _red "从tar文件加载镜像失败"
            rm -f "$tar_filename"
        fi
    else
        _yellow "下载tar文件失败或文件为空"
        rm -f "$tar_filename" 2>/dev/null
    fi
    _yellow "尝试从Docker Hub拉取镜像: ${system_type}:latest"
    docker pull "${system_type}:latest"
    if [ $? -eq 0 ]; then
        export image_name="${system_type}:latest"
        _green "镜像拉取成功"
        return 0
    else
        _red "从Docker Hub拉取镜像失败"
        exit 1
    fi
}

run_storage_test() {
    local storage_limit="${1:-500}"  # 默认500MB限制
    local storage_opts=""
    if [ "$btrfs_support" = "Y" ]; then
        storage_opts="--storage-opt size=${storage_limit}M"
        _green "启用存储限制: ${storage_limit}MB"
    else
        _yellow "存储驱动不支持限制，将进行无限制测试"
    fi
    _blue "=== 开始Docker存储限制测试 ==="
    _yellow "使用镜像: $image_name"
    _yellow "存储限制: ${storage_limit}MB (如果支持)"
    docker run --rm $storage_opts $image_name bash -c "
echo '=== 容器内磁盘空间检查 ==='
df -h /
echo ''
echo '=== 测试环境信息 ==='
cat /etc/os-release | head -3
echo ''
echo '=== 测试1: 创建100MB文件 (应该成功) ==='
dd if=/dev/zero of=/test_100m bs=1M count=100 2>/dev/null
if [ \$? -eq 0 ]; then
    echo '✅ 100MB文件创建成功'
    ls -lh /test_100m
    echo '文件大小:' \$(du -h /test_100m | cut -f1)
else
    echo '❌ 100MB文件创建失败'
fi
echo ''
echo '=== 测试2: 再创建100MB文件 (应该成功) ==='
dd if=/dev/zero of=/test_100m_2 bs=1M count=100 2>/dev/null
if [ \$? -eq 0 ]; then
    echo '✅ 第二个100MB文件创建成功'
    ls -lh /test_100m_2
    echo '文件大小:' \$(du -h /test_100m_2 | cut -f1)
else
    echo '❌ 第二个100MB文件创建失败'
fi
echo ''
echo '=== 中期磁盘使用情况 ==='
df -h /
echo '总共已使用:' \$(du -sh /test_* 2>/dev/null | awk '{sum+=\$1} END {print sum \"M\"}' 2>/dev/null || echo '200M')
echo ''
echo '=== 测试3: 尝试创建250MB文件 ==='
if [ '$btrfs_support' = 'Y' ]; then
    echo '(在${storage_limit}MB限制下，这应该失败)'
else
    echo '(无存储限制，这应该成功)'
fi
dd if=/dev/zero of=/test_250m bs=1M count=250 2>/dev/null
if [ \$? -eq 0 ]; then
    if [ '$btrfs_support' = 'Y' ]; then
        echo '❌ 超限文件意外创建成功 - 存储限制可能未生效'
    else
        echo '✅ 文件创建成功 - 符合无限制预期'
    fi
    ls -lh /test_250m 2>/dev/null
    echo '文件大小:' \$(du -h /test_250m 2>/dev/null | cut -f1)
else
    if [ '$btrfs_support' = 'Y' ]; then
        echo '✅ 超限文件创建失败 - 存储限制正常工作'
    else
        echo '❌ 文件创建失败 - 可能有其他问题'
    fi
fi
echo ''
echo '=== 测试4: 尝试创建更大文件 (400MB) ==='
dd if=/dev/zero of=/test_400m bs=1M count=400 2>/dev/null
if [ \$? -eq 0 ]; then
    echo '文件创建成功'
    ls -lh /test_400m 2>/dev/null
else
    echo '文件创建失败 (符合预期)'
fi
echo ''
echo '=== 最终磁盘使用情况 ==='
df -h /
echo ''
echo '=== 所有测试文件列表 ==='
ls -lh /test_* 2>/dev/null || echo '没有测试文件'
echo ''
echo '=== 测试文件总大小 ==='
du -sh /test_* 2>/dev/null | awk '{sum+=\$1} END {print \"总计: \" sum \"M\"}' || echo '总计: 0M'
"
}

main() {
    _blue "=== Docker存储限制测试工具 ==="
    echo "测试日期: $(date)"
    echo ""
    check_china
    cdn_urls=("https://cdn0.spiritlhl.top/" "http://cdn1.spiritlhl.net/" "http://cdn2.spiritlhl.net/" "http://cdn3.spiritlhl.net/" "http://cdn4.spiritlhl.net/")
    if [ "${CN}" == true ]; then
        check_cdn_file
    fi
    _blue "=== Docker信息检查 ==="
    docker version --format '{{.Server.Version}}' | head -1 | xargs echo "Docker版本:"
    check_storage_driver
    echo ""
    _blue "=== 镜像准备 ==="
    if ! check_image_exists; then
        download_and_load_image
    fi
    echo ""
    local test_size="${1:-500}"
    run_storage_test "$test_size"
    echo ""
    _blue "=== 测试总结 ==="
    if [ "$btrfs_support" = "Y" ]; then
        _green "✅ 存储驱动支持限制功能"
        _yellow "如果看到超限文件创建失败，说明存储限制正常工作"
    else
        _yellow "⚠️  当前存储驱动不支持限制功能"
        _yellow "建议切换到btrfs、zfs或devicemapper驱动来使用存储限制"
    fi
    _green "测试完成！"
}

if [ "${BASH_SOURCE[0]}" == "${0}" ]; then
    main "$@"
fi
