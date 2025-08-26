#!/bin/bash
# Docker存储限制测试
# 基于 https://github.com/oneclickvirt/docker
# 2025.08.24

_red() { echo -e "\033[31m\033[01m$@\033[0m"; }
_green() { echo -e "\033[32m\033[01m$@\033[0m"; }
_yellow() { echo -e "\033[33m\033[01m$@\033[0m"; }
_blue() { echo -e "\033[36m\033[01m$@\033[0m"; }

if ! command -v docker >/dev/null 2>&1; then
    _red "Docker environment not found, please install Docker first"
    _red "Docker环境不存在，请先安装Docker"
    exit 1
fi

check_china() {
    echo "Detecting IP region... / 正在检测IP地区......"
    if [[ -z "${CN}" ]]; then
        if [[ $(curl -m 6 -s https://ipapi.co/json 2>/dev/null | grep 'China') != "" ]]; then
            _green "China IP detected, will use CDN acceleration"
            _green "检测到中国IP，将使用CDN加速"
            CN=true
        else
            _yellow "Non-China IP, using default download"
            _yellow "非中国IP，使用默认下载"
            CN=false
        fi
    fi
}

check_cdn() {
    local o_url=$1
    local shuffled_cdn_urls=($(shuf -e "${cdn_urls[@]}"))
    for cdn_url in "${shuffled_cdn_urls[@]}"; do
        if curl -4 -sL -k "$cdn_url$o_url" --max-time 6 | grep -q "success" >/dev/null 2>&1; then
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
        _green "CDN available, using CDN acceleration: $cdn_success_url"
        _green "CDN可用，使用CDN加速: $cdn_success_url"
    else
        _yellow "CDN not available, using direct connection"
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
    _blue "Current storage driver: $storage_driver / 当前存储驱动: $storage_driver"
    if [ "$storage_driver" = "btrfs" ] || [ "$storage_driver" = "zfs" ] || [ "$storage_driver" = "devicemapper" ]; then
        btrfs_support="Y"
        _green "Detected storage driver with limit support: $storage_driver"
        _green "检测到支持存储限制的驱动: $storage_driver"
        return 0
    else
        btrfs_support="N"
        _yellow "Current storage driver ($storage_driver) does not support storage limits"
        _yellow "当前存储驱动 ($storage_driver) 不支持存储限制功能"
        return 1
    fi
}

check_image_exists() {
    local system_type="debian"
    local arch=$(get_arch)
    if docker images --format '{{.Repository}}:{{.Tag}}' | grep -qx "spiritlhl:${system_type}-${arch}"; then
        _green "Image spiritlhl:${system_type}-${arch} exists / 镜像 spiritlhl:${system_type}-${arch} 已存在"
        export image_name="spiritlhl:${system_type}-${arch}"
        return 0
    fi
    if docker images --format '{{.Repository}}:{{.Tag}}' | grep -qx "spiritlhl:${system_type}"; then
        _green "Image spiritlhl:${system_type} exists / 镜像 spiritlhl:${system_type} 已存在"
        export image_name="spiritlhl:${system_type}"
        return 0
    fi
    if docker images --format '{{.Repository}}:{{.Tag}}' | grep -qx "${system_type}:latest"; then
        _green "Image ${system_type}:latest exists / 镜像 ${system_type}:latest 已存在"
        export image_name="${system_type}:latest"
        return 0
    fi
    return 1
}

download_and_load_image() {
    local system_type="debian"
    local arch=$(get_arch)
    local tar_filename="spiritlhl_${system_type}_${arch}.tar.gz"
    _yellow "Downloading ${system_type} image for ${arch} architecture..."
    _yellow "正在下载 ${system_type} 的 ${arch} 架构镜像..."
    local download_url="${cdn_success_url}https://github.com/oneclickvirt/docker/releases/download/debian/spiritlhl_debian_${arch}.tar.gz"
    curl -L "$download_url" -o "$tar_filename" --connect-timeout 10 --max-time 300
    if [ -f "$tar_filename" ] && [ -s "$tar_filename" ]; then
        _yellow "Loading image from tar file... / 正在从tar文件加载镜像..."
        docker load < "$tar_filename"
        if [ $? -eq 0 ]; then
            rm -f "$tar_filename"
            export image_name="spiritlhl:${system_type}-${arch}"
            _green "Image loaded successfully / 镜像加载成功"
            return 0
        else
            _red "Failed to load image from tar file / 从tar文件加载镜像失败"
            rm -f "$tar_filename"
        fi
    else
        _yellow "Failed to download tar file or file is empty / 下载tar文件失败或文件为空"
        rm -f "$tar_filename" 2>/dev/null
    fi
    _yellow "Attempting to pull image from Docker Hub: ${system_type}:latest"
    _yellow "尝试从Docker Hub拉取镜像: ${system_type}:latest"
    docker pull "${system_type}:latest"
    if [ $? -eq 0 ]; then
        export image_name="${system_type}:latest"
        _green "Image pulled successfully / 镜像拉取成功"
        return 0
    else
        _red "Failed to pull image from Docker Hub / 从Docker Hub拉取镜像失败"
        exit 1
    fi
}

run_storage_test() {
    local storage_limit="${1:-500}"
    local storage_opts=""
    
    local size1=$((storage_limit / 5))
    local size2=$((storage_limit / 5))
    local size3=$((storage_limit / 2))
    local size4=$((storage_limit * 4 / 5))
    
    if [ "$btrfs_support" = "Y" ]; then
        storage_opts="--storage-opt size=${storage_limit}M"
        _green "Storage limit enabled: ${storage_limit}MB / 启用存储限制: ${storage_limit}MB"
    else
        _yellow "Storage driver does not support limits, running unlimited test"
        _yellow "存储驱动不支持限制，将进行无限制测试"
    fi
    _blue "=== Starting Docker Storage Limit Test / 开始Docker存储限制测试 ==="
    _yellow "Using image: $image_name / 使用镜像: $image_name"
    _yellow "Storage limit: ${storage_limit}MB (if supported) / 存储限制: ${storage_limit}MB (如果支持)"
    docker run --rm $storage_opts $image_name bash -c "
echo '=== Container Disk Space Check / 容器内磁盘空间检查 ==='
df -h /
echo ''
echo '=== Test Environment Info / 测试环境信息 ==='
cat /etc/os-release | head -3
echo ''
echo '=== Test 1: Create ${size1}MB file (should succeed) / 测试1: 创建${size1}MB文件 (应该成功) ==='
dd if=/dev/zero of=/test_1 bs=1M count=${size1} 2>/dev/null
if [ \$? -eq 0 ]; then
    echo '✅ ${size1}MB file created successfully / ${size1}MB文件创建成功'
    ls -lh /test_1
    echo 'File size / 文件大小:' \$(du -h /test_1 | cut -f1)
else
    echo '❌ ${size1}MB file creation failed / ${size1}MB文件创建失败'
fi
echo ''
echo '=== Test 2: Create another ${size2}MB file (should succeed) / 测试2: 再创建${size2}MB文件 (应该成功) ==='
dd if=/dev/zero of=/test_2 bs=1M count=${size2} 2>/dev/null
if [ \$? -eq 0 ]; then
    echo '✅ Second ${size2}MB file created successfully / 第二个${size2}MB文件创建成功'
    ls -lh /test_2
    echo 'File size / 文件大小:' \$(du -h /test_2 | cut -f1)
else
    echo '❌ Second ${size2}MB file creation failed / 第二个${size2}MB文件创建失败'
fi
echo ''
echo '=== Mid-test Disk Usage / 中期磁盘使用情况 ==='
df -h /
echo 'Total used / 总共已使用:' \$(du -sh /test_* 2>/dev/null | awk '{sum+=\$1} END {print sum \"M\"}' 2>/dev/null || echo '$((size1+size2))M')
echo ''
echo '=== Test 3: Try to create ${size3}MB file / 测试3: 尝试创建${size3}MB文件 ==='
if [ '$btrfs_support' = 'Y' ]; then
    echo '(Under ${storage_limit}MB limit, this should fail / 在${storage_limit}MB限制下，这应该失败)'
else
    echo '(No storage limit, this should succeed / 无存储限制，这应该成功)'
fi
dd if=/dev/zero of=/test_3 bs=1M count=${size3} 2>/dev/null
if [ \$? -eq 0 ]; then
    if [ '$btrfs_support' = 'Y' ]; then
        echo '❌ Over-limit file unexpectedly created - storage limit may not be working'
        echo '❌ 超限文件意外创建成功 - 存储限制可能未生效'
    else
        echo '✅ File created successfully - expected without limits'
        echo '✅ 文件创建成功 - 符合无限制预期'
    fi
    ls -lh /test_3 2>/dev/null
    echo 'File size / 文件大小:' \$(du -h /test_3 2>/dev/null | cut -f1)
else
    if [ '$btrfs_support' = 'Y' ]; then
        echo '✅ Over-limit file creation failed - storage limit working correctly'
        echo '✅ 超限文件创建失败 - 存储限制正常工作'
    else
        echo '❌ File creation failed - may have other issues'
        echo '❌ 文件创建失败 - 可能有其他问题'
    fi
fi
echo ''
echo '=== Test 4: Try to create larger file (${size4}MB) / 测试4: 尝试创建更大文件 (${size4}MB) ==='
dd if=/dev/zero of=/test_4 bs=1M count=${size4} 2>/dev/null
if [ \$? -eq 0 ]; then
    echo 'File created successfully / 文件创建成功'
    ls -lh /test_4 2>/dev/null
else
    echo 'File creation failed (as expected) / 文件创建失败 (符合预期)'
fi
echo ''
echo '=== Final Disk Usage / 最终磁盘使用情况 ==='
df -h /
echo ''
echo '=== All Test Files List / 所有测试文件列表 ==='
ls -lh /test_* 2>/dev/null || echo 'No test files / 没有测试文件'
echo ''
echo '=== Total Size of Test Files / 测试文件总大小 ==='
du -sh /test_* 2>/dev/null | awk '{sum+=\$1} END {print \"Total / 总计: \" sum \"M\"}' || echo 'Total / 总计: 0M'
"
}

main() {
    _blue "=== Docker Storage Limit Test Tool / Docker存储限制测试工具 ==="
    echo "Test date / 测试日期: $(date)"
    echo ""
    check_china
    cdn_urls=("https://cdn0.spiritlhl.top/" "http://cdn1.spiritlhl.net/" "http://cdn2.spiritlhl.net/" "http://cdn3.spiritlhl.net/" "http://cdn4.spiritlhl.net/")
    if [ "${CN}" == true ]; then
        check_cdn_file
    fi
    _blue "=== Docker Info Check / Docker信息检查 ==="
    docker version --format '{{.Server.Version}}' | head -1 | xargs echo "Docker version / Docker版本:"
    check_storage_driver
    echo ""
    _blue "=== Image Preparation / 镜像准备 ==="
    if ! check_image_exists; then
        download_and_load_image
    fi
    echo ""
    local test_size="${1:-500}"
    run_storage_test "$test_size"
    echo ""
    _blue "=== Test Summary / 测试总结 ==="
    if [ "$btrfs_support" = "Y" ]; then
        _green "✅ Storage driver supports limit functionality / 存储驱动支持限制功能"
        _yellow "If you see over-limit file creation failed, storage limit is working correctly"
        _yellow "如果看到超限文件创建失败，说明存储限制正常工作"
    else
        _yellow "⚠️  Current storage driver does not support limit functionality"
        _yellow "⚠️  当前存储驱动不支持限制功能"
    fi
    _green "Test completed! / 测试完成！"
}

if [ "${BASH_SOURCE[0]}" == "${0}" ]; then
    main "$@"
fi
