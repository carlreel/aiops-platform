#!/bin/bash
# aiops-platform 环境初始化：Ubuntu 24.04 (WSL2) + Docker + 项目代码
# 用法（在 Windows PowerShell 里）：
#   wsl -d Ubuntu-24.04 -u root bash /mnt/c/WSL/setup-docker.sh
set -uo pipefail

PROJ_SRC="/mnt/c/Users/crush/WorkBuddy/2026-10-19-17-41-14/aiops-platform"
PROJ_DST="/opt/aiops-platform"

echo "=================================================="
echo " [1/7] 环境检查"
echo "=================================================="
head -2 /etc/os-release
echo "init: $(ps -p 1 -o comm=)"
echo "CPU : $(nproc) cores"
free -h | head -2
df -h / | tail -1

echo ""
echo "=================================================="
echo " [2/7] 网络诊断（关键：apt 卡住多半是 IPv6）"
echo "=================================================="
echo "--- DNS 解析 mirrors.aliyun.com ---"
if getent hosts mirrors.aliyun.com >/dev/null 2>&1; then
  echo "  OK: $(getent hosts mirrors.aliyun.com | head -1)"
else
  echo "  ❌ DNS 解析失败"
fi
echo "--- IPv4 连通性 ---"
if curl -4 -sI -m 10 https://mirrors.aliyun.com/ >/dev/null 2>&1; then
  echo "  OK: IPv4 可达"
else
  echo "  ❌ IPv4 不可达"
fi
echo "--- IPv6 连通性（不通属正常，但会导致 apt 干等）---"
if curl -6 -sI -m 6 https://mirrors.aliyun.com/ >/dev/null 2>&1; then
  echo "  IPv6 也通"
else
  echo "  IPv6 不通 → 下面强制 apt 只用 IPv4"
fi

echo ""
echo "=================================================="
echo " [3/7] 强制 apt 走 IPv4 + 设置超时重试"
echo "=================================================="
cat > /etc/apt/apt.conf.d/99force-ipv4 <<'EOF'
Acquire::ForceIPv4 "true";
Acquire::http::Timeout "20";
Acquire::https::Timeout "20";
Acquire::Retries "2";
EOF
echo "已写入 /etc/apt/apt.conf.d/99force-ipv4"
cat /etc/apt/apt.conf.d/99force-ipv4

echo ""
echo "=================================================="
echo " [4/7] 切换阿里云 APT 源"
echo "=================================================="
if [ -f /etc/apt/sources.list.d/ubuntu.sources ]; then
  sed -i 's|http://archive.ubuntu.com/ubuntu|https://mirrors.aliyun.com/ubuntu|g' /etc/apt/sources.list.d/ubuntu.sources
  sed -i 's|http://security.ubuntu.com/ubuntu|https://mirrors.aliyun.com/ubuntu|g' /etc/apt/sources.list.d/ubuntu.sources
  sed -i 's|http://ports.ubuntu.com/ubuntu-ports|https://mirrors.aliyun.com/ubuntu-ports|g' /etc/apt/sources.list.d/ubuntu.sources
  echo "已处理 ubuntu.sources，当前 URIs:"
  grep -i "^URIs:" /etc/apt/sources.list.d/ubuntu.sources
fi
if [ -f /etc/apt/sources.list ]; then
  sed -i 's|http://archive.ubuntu.com/ubuntu|https://mirrors.aliyun.com/ubuntu|g' /etc/apt/sources.list
  sed -i 's|http://security.ubuntu.com/ubuntu|https://mirrors.aliyun.com/ubuntu|g' /etc/apt/sources.list
fi

echo ""
echo "=================================================="
echo " [5/7] apt update（带超时保护，最多 4 分钟）"
echo "=================================================="
if timeout 240 apt-get update; then
  echo "✅ apt update 完成"
else
  echo "⚠️ apt update 超时或失败，退出码 $?"
  echo "   → 请检查 Windows 上是否开着全局代理/TUN，或换成手机热点重试"
  exit 1
fi

echo ""
echo "=================================================="
echo " [6/7] 安装 Docker（阿里云源）"
echo "=================================================="
export DEBIAN_FRONTEND=noninteractive
apt-get install -y ca-certificates curl gnupg
install -m 0755 -d /etc/apt/keyrings
curl -fsSL --ipv4 https://mirrors.aliyun.com/docker-ce/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
CODENAME=$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://mirrors.aliyun.com/docker-ce/linux/ubuntu ${CODENAME} stable" > /etc/apt/sources.list.d/docker.list
echo "Docker 源: $(cat /etc/apt/sources.list.d/docker.list)"
timeout 180 apt-get update || true
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

echo ""
echo "=================================================="
echo " [7/7] 启动 Docker + 复制项目代码"
echo "=================================================="
if [ "$(ps -p 1 -o comm=)" = "systemd" ]; then
  systemctl enable --now docker
  echo "通过 systemd 启动"
else
  service docker start || true
  sleep 4
  echo "通过 service 启动（systemd 未启用）"
fi
sleep 2
docker --version
docker compose version || true
docker info --format '服务端: {{.ServerVersion}} / 存储驱动: {{.Driver}}' || true

# 项目代码必须放进 WSL 内部 ext4，不能留在 /mnt/c（9p 协议慢 5~10 倍）
mkdir -p /opt
rm -rf "$PROJ_DST"
cp -r "$PROJ_SRC" "$PROJ_DST"
chmod +x "$PROJ_DST"/scripts/*.sh 2>/dev/null || true
echo "项目已复制到: $PROJ_DST"
ls "$PROJ_DST"

echo ""
echo "=================================================="
echo " ✅ 完成"
echo "=================================================="
echo "下一步：cd /opt/aiops-platform && cp .env.example .env && docker compose up -d pgvector rag-api"
