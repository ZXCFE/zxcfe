#!/bin/bash
set -e

# 日志函数
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# 错误处理函数
cleanup_locks() {
    log "清理 apt 锁文件..."
    sudo killall apt apt-get dpkg 2>/dev/null || true
    sudo rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/cache/apt/archives/lock
    sudo dpkg --configure -a 2>/dev/null || true
}

# 带重试的 apt 安装
install_packages() {
    local max_attempts=3
    local attempt=1

    while [ $attempt -le $max_attempts ]; do
        log "尝试安装软件包 (第 $attempt 次)..."

        if apt update && apt-get install curl xfsprogs lxcfs uuid-runtime -y; then
            log "软件包安装成功"
            return 0
        else
            log "安装失败，清理锁文件..."
            cleanup_locks

            if [ $attempt -eq $max_attempts ]; then
                log "经过 $max_attempts 次尝试后依然失败"
                exit 1
            fi

            attempt=$((attempt + 1))
            sleep 5
        fi
    done
}

# 检查并启动服务
start_service() {
    local service=$1
    if ! systemctl is-active --quiet $service; then
        log "启动 $service 服务..."
        systemctl start $service
    else
        log "$service 服务已在运行"
    fi

    if ! systemctl is-enabled --quiet $service; then
        log "启用 $service 服务..."
        systemctl enable $service
    else
        log "$service 服务已启用"
    fi
}

# 创建 XFS 磁盘
create_xfs_disk() {
    local disk_file=$1
    local size=$2
    local mount_point=$3
    local mount_opts=$4

    if [ ! -f "$disk_file" ]; then
        log "创建 $disk_file (大小: $size)..."
        fallocate -l $size $disk_file
        mkfs.xfs $disk_file
    else
        log "$disk_file 已存在，跳过创建"
    fi

    if [ ! -d "$mount_point" ]; then
        log "创建挂载点 $mount_point..."
        mkdir -p $mount_point
    fi

    if ! mountpoint -q $mount_point; then
        log "挂载 $disk_file 到 $mount_point..."
        mount -o $mount_opts $disk_file $mount_point
    else
        log "$mount_point 已挂载"
    fi

    # 检查 fstab 条目
    if ! grep -q "$disk_file" /etc/fstab; then
        log "添加 fstab 条目..."
        echo "$disk_file $mount_point xfs $mount_opts 0 0" >> /etc/fstab
    else
        log "fstab 条目已存在"
    fi
}

# 带重试的下载函数
download_with_retry() {
    local url=$1
    local output=$2
    local max_attempts=3
    local attempt=1

    while [ $attempt -le $max_attempts ]; do
        log "下载 $url (第 $attempt 次)..."
        if curl -L -o "$output" "$url"; then
            return 0
        else
            log "下载失败"
            if [ $attempt -eq $max_attempts ]; then
                log "下载失败，已达最大重试次数"
                return 1
            fi
            attempt=$((attempt + 1))
            sleep 5
        fi
    done
}

# 主脚本开始
log "开始安装脚本..."

# 安装软件包
install_packages

# 启动和启用 lxcfs
start_service lxcfs

# 检测架构
ARCH=$(uname -m)
case $ARCH in
    x86_64)
        ARCH_SUFFIX="amd64"
        ;;
    aarch64|arm64)
        ARCH_SUFFIX="arm64"
        ;;
    *)
        log "❌ 不支持的架构: $ARCH (仅支持 amd64 和 arm64)"
        exit 1
        ;;
esac
log "检测到架构: $ARCH ($ARCH_SUFFIX)"

# 安装 Docker
if ! command -v docker &> /dev/null; then
    log "安装 Docker..."
    if ! curl -fsSL https://get.docker.com | bash -s docker; then
        log "Docker 安装失败"
        exit 1
    fi
else
    log "Docker 已安装"
fi

# 获取磁盘大小（如果是重复执行，使用默认值）
if [ -f "/xfs_disk.img" ]; then
    xfs_size="existing"
    log "检测到现有 XFS 磁盘，跳过大小输入"
else
    read -p "请输入 Docker 磁盘大小 (例如: 20G): " xfs_size
    xfs_size=${xfs_size:-20G}
fi

# 创建数据磁盘
if [ "$xfs_size" != "existing" ]; then
    create_xfs_disk "/xfs_disk.img" "$xfs_size" "/data" "defaults,pquota,loop"
else
    log "数据磁盘已存在"
    # 确保挂载
    if [ ! -d "/data" ]; then
        mkdir -p /data
    fi
    if ! mountpoint -q /data; then
        mount -o defaults,pquota,loop /xfs_disk.img /data
    fi
fi

# 创建配置磁盘
create_xfs_disk "/config_disk.img" "300M" "/config" "defaults,pquota,loop"

# 创建配置文件
log "创建配置文件..."
echo -e "nameserver 1.1.1.1\nnameserver 8.8.8.8" > /config/resolv.conf
echo -e "127.0.0.1 localhost\n::1 ipv6-localhost" > /config/hosts

# 下载 systemctl
if [ ! -f "/config/systemctl" ]; then
    log "下载 systemctl..."
    if ! curl -L https://github.com/narwhal-cloud/systemctl/releases/latest/download/systemctl_Linux_$ARCH_SUFFIX.tar.gz | tar -xzf - -C /config systemctl; then
        log "systemctl 下载失败"
        exit 1
    fi
    chmod +x /config/systemctl
else
    log "systemctl 已存在"
fi

# 配置 Docker
if [ ! -f "/etc/docker/daemon.json" ]; then
    log "配置 Docker..."
    mkdir -p /etc/docker
    echo '{"data-root": "/data/docker"}' > /etc/docker/daemon.json
    systemctl restart docker
else
    log "Docker 已配置"
    # 确保 Docker 运行
    if ! systemctl is-active --quiet docker; then
        systemctl restart docker
    fi
fi

# 创建 OpenGFW 目录和文件
log "设置 OpenGFW..."
mkdir -p /root/OpenGFW

# 下载 OpenGFW
if [ ! -f "/root/OpenGFW/OpenGFW" ]; then
    if ! download_with_retry "https://github.com/narwhal-cloud/OpenGFW/releases/latest/download/OpenGFW-linux-$ARCH_SUFFIX" "/root/OpenGFW/OpenGFW"; then
        log "OpenGFW 下载失败"
        exit 1
    fi
    chmod +x /root/OpenGFW/OpenGFW
else
    log "OpenGFW 已存在"
fi

# 创建配置文件
log "创建 OpenGFW 配置文件..."
cat > /root/OpenGFW/config.yaml <<EOF
io:
  queueSize: 1024
  queueNum: 100
  table: opengfw
  connMarkAccept: 1001
  connMarkDrop: 1002
  rcvBuf: 4194304
  sndBuf: 4194304
  local: false
  rst: false
  input: true
  output: true
  forward: true
  docker: true

workers:
  count: 4
  queueSize: 64
  tcpMaxBufferedPagesTotal: 65536
  tcpMaxBufferedPagesPerConn: 16
  tcpTimeout: 5m
  udpMaxStreams: 4096

replay:
  realtime: false

EOF

cat > /root/OpenGFW/rules.yaml <<EOF
- name: block email
  action: block
  log: false
  expr: port.dst == 25 || port.dst == 587 || port.dst == 465 || port.dst == 143 || port.dst == 993

- name: Block SOCKS
  action: block
  log: false
  expr: geoip(string(ip.src), "cn") && socks != nil

- name: Block shadowsocks and vmess
  action: block
  log: false
  expr: geoip(string(ip.src), "cn") && fet != nil && fet.yes

- name: Block trojan
  action: block
  log: false
  expr: geoip(string(ip.src), "cn") && trojan != nil && trojan.yes
EOF

# 创建系统服务
if [ ! -f "/etc/systemd/system/opengfw.service" ]; then
    log "创建 OpenGFW 系统服务..."
    cat > /etc/systemd/system/opengfw.service <<EOF
[Unit]
Description=OpenGFW
After=network.target docker.service
Wants=network-online.target docker.service

[Service]
Type=simple
User=root
Group=root
MemoryHigh=768M
MemoryMax=1G
WorkingDirectory=/root/OpenGFW
ExecStart=/root/OpenGFW/OpenGFW -c config.yaml rules.yaml
Restart=always

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
else
    log "OpenGFW 服务已存在"
fi

# 启动 OpenGFW 服务
start_service opengfw

# 拉取 Docker 镜像
log "拉取 Docker 镜像..."
for image in "narwhalcloud/agent:latest" "narwhalcloud/debian:latest" "narwhalcloud/alpine:latest"; do
    if ! docker images --format "table {{.Repository}}:{{.Tag}}" | grep -q "$image"; then
        log "拉取镜像: $image"
        if ! docker pull $image; then
            log "警告: 镜像 $image 拉取失败，稍后可能需要重试"
        fi
    else
        log "镜像 $image 已存在"
    fi
done

# 运行 agent 容器
if docker ps -a --format "table {{.Names}}" | grep -q "fuckip-agent"; then
    log "fuckip-agent 容器已存在"
    if ! docker ps --format "table {{.Names}}" | grep -q "fuckip-agent"; then
        log "启动现有的 fuckip-agent 容器..."
        docker start fuckip-agent
    else
        log "fuckip-agent 容器已在运行"
    fi
    # 获取现有容器的 UUID
    UUID=$(docker logs fuckip-agent 2>&1 | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1 || echo "")
    if [ -z "$UUID" ]; then
        log "无法从现有容器获取 UUID，生成新的..."
        UUID=$(uuidgen)
    fi
else
    log "创建新的 fuckip-agent 容器..."
    UUID=$(uuidgen)
    if ! docker run -d \
      --network host \
      --restart=always \
      -v /var/run/docker.sock:/var/run/docker.sock \
      --name fuckip-agent \
      narwhalcloud/agent:latest /app/agent -p $UUID; then
        log "容器启动失败"
        exit 1
    fi
fi

# 获取 IP 地址
log "获取服务器信息..."
if command -v curl &> /dev/null; then
    IP=$(curl -4 -s --max-time 10 ip.sb || echo "获取失败")
else
    IP="curl未安装"
fi

log "========================================"
log "🎉 安装完成！"
log "Your IP: $IP"
log "Your Key: $UUID"
log "========================================"