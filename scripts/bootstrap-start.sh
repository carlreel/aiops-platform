#!/bin/bash
# 第二阶段：配置镜像加速 + 启动 pgvector 与 rag-api + 验证
# 用法（Windows PowerShell）：
#   wsl -d Ubuntu-24.04 -u root bash /mnt/c/WSL/setup-run.sh
set -uo pipefail
cd /opt/aiops-platform || { echo "❌ 找不到 /opt/aiops-platform"; exit 1; }

echo "=================================================="
echo " [1/6] 配置 Docker 镜像加速"
echo "=================================================="
mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<'EOF'
{
  "registry-mirrors": [
    "https://docker.m.daocloud.io",
    "https://docker.1ms.run",
    "https://docker.xuanyuan.me"
  ],
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
EOF
systemctl restart docker
sleep 3
docker info 2>/dev/null | grep -A4 "Registry Mirrors" || echo "（未读到 mirror 列表，继续）"

echo ""
echo "=================================================="
echo " [2/6] 生成 .env 并确认关键配置"
echo "=================================================="
[ -f .env ] || cp .env.example .env
grep -E "^(LLM_MODEL|EMB_MODEL|OLLAMA_BASE_URL)" .env

echo ""
echo "=================================================="
echo " [3/6] 测试 WSL 能否访问 Windows 侧 Ollama"
echo "=================================================="
GW=$(ip route show default | awk '{print $3}')
echo "WSL 默认网关（即 Windows 主机）: $GW"
if curl -s -m 8 "http://$GW:11434/api/tags" >/tmp/tags.json 2>/dev/null; then
  echo "✅ Ollama 可达，已装模型："
  grep -o '"name":"[^"]*"' /tmp/tags.json | head -5
else
  echo "⚠️ 从 WSL 访问不到 $GW:11434"
  echo "   → 多半是 Windows 防火墙拦了。先继续，若 /health 显示 ollama down 再处理。"
fi

echo ""
echo "=================================================="
echo " [4/6] 拉取 pgvector 镜像（走加速器）"
echo "=================================================="
if docker pull pgvector/pgvector:pg16; then
  echo "✅ pgvector 镜像就绪"
else
  echo "❌ 拉取失败。把报错发我，我换下一个加速器。"
  exit 1
fi

echo ""
echo "=================================================="
echo " [5/6] 启动 pgvector + rag-api（rag-api 要 build，较慢）"
echo "=================================================="
docker compose up -d pgvector rag-api

echo ""
echo "=================================================="
echo " [6/6] 等健康检查（最多 4 分钟）"
echo "=================================================="
for i in $(seq 1 24); do
  sleep 10
  pg=$(docker inspect --format '{{.State.Health.Status}}' aiops-pgvector 2>/dev/null || echo "none")
  api=$(docker inspect --format '{{.State.Health.Status}}' aiops-rag-api 2>/dev/null || echo "none")
  echo "  [${i}] pgvector=$pg  rag-api=$api"
  if [ "$pg" = "healthy" ] && [ "$api" = "healthy" ]; then
    echo "✅ 两个容器都健康"
    break
  fi
done

echo ""
echo "--- docker compose ps ---"
docker compose ps
echo ""
echo "--- /health ---"
curl -s -m 15 localhost:8000/health
echo ""
echo ""
echo "=================================================="
echo " 完成。若上面 ollama 显示 up，今天目标达成。"
echo "=================================================="
