#!/bin/bash
# 修复 WSL2 下容器访问 Windows 侧 Ollama 的问题
# 根因：extra_hosts 的 host-gateway 在 WSL2 里解析成 172.17.0.1(docker0)，而非 Windows 主机
# 用法：wsl -d Ubuntu-24.04 -u root bash /mnt/c/WSL/fix-ollama.sh
set -uo pipefail
cd /opt/aiops-platform || { echo "❌ 找不到 /opt/aiops-platform"; exit 1; }

GW=$(ip route show default | awk '{print $3}')
echo "=================================================="
echo " 探测结果"
echo "=================================================="
echo "  WSL 默认网关（= Windows 主机）: $GW"
echo -n "  WSL 直连该地址 11434: "
curl -s -m 6 -o /dev/null -w "HTTP %{http_code}\n" "http://$GW:11434/api/tags" || echo "不通"

echo ""
echo "=================================================="
echo " [1/4] 更新 .env 的 OLLAMA_BASE_URL"
echo "=================================================="
[ -f .env.bak ] || cp .env .env.bak
sed -i "s|^OLLAMA_BASE_URL=.*|OLLAMA_BASE_URL=http://$GW:11434|" .env
grep "^OLLAMA_BASE_URL" .env

echo ""
echo "=================================================="
echo " [2/4] 同步修正 compose 的 host.docker.internal 映射"
echo "=================================================="
if grep -q "host.docker.internal:host-gateway" docker-compose.yml; then
  sed -i "s|host.docker.internal:host-gateway|host.docker.internal:$GW|" docker-compose.yml
  echo "  已改为 host.docker.internal:$GW（WSL2 下 host-gateway 解析错误）"
else
  echo "  已是指定 IP，无需修改："
  grep -A2 "extra_hosts" docker-compose.yml
fi

echo ""
echo "=================================================="
echo " [3/4] 重建 rag-api 使新配置生效"
echo "=================================================="
docker compose up -d --force-recreate rag-api

echo ""
echo "=================================================="
echo " [4/4] 等待并就绪检查"
echo "=================================================="
ok=0
for i in $(seq 1 15); do
  sleep 5
  h=$(curl -s -m 5 localhost:8000/health 2>/dev/null || echo "(无响应)")
  echo "  [$i] $h"
  if echo "$h" | grep -q '"ollama": *"up"'; then ok=1; break; fi
done

echo ""
if [ "$ok" = "1" ]; then
  echo "=================================================="
  echo " ✅ ollama 已连通，db + ollama 双 up"
  echo "=================================================="
  curl -s localhost:8000/health; echo ""
else
  echo "=================================================="
  echo " ⚠️ 仍未连通，执行下面命令看容器日志："
  echo "   docker logs --tail 30 aiops-rag-api"
  echo "=================================================="
fi
