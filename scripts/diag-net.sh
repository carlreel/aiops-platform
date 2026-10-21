#!/bin/bash
# 诊断：容器 -> WSL -> Windows 的 Ollama 连通性
# 用法：wsl -d Ubuntu-24.04 -u root bash /mnt/c/WSL/diag-net.sh
set -uo pipefail

GW=$(ip route show default | awk '{print $3}')
echo "=================================================="
echo " WSL 默认网关（= Windows 主机）: $GW"
echo "=================================================="

echo ""
echo "--- [A] WSL 本机直连 $GW:11434 ---"
if curl -s -m 6 -o /dev/null -w "  HTTP %{http_code}\n" "http://$GW:11434/api/tags"; then
  echo "  ✅ WSL 到 Windows 的 Ollama 通"
else
  echo "  ❌ WSL 也连不上（说明是 Windows 防火墙/Hyper-V 防火墙拦的）"
fi

echo ""
echo "--- [B] 容器内 /etc/hosts 里 host.docker.internal 指向哪 ---"
docker exec aiops-rag-api cat /etc/hosts 2>/dev/null | grep -i "host" || echo "  (无相关条目)"

echo ""
echo "--- [C] 容器内解析 host.docker.internal ---"
docker exec aiops-rag-api python -c "import socket;print('  解析结果:', socket.gethostbyname('host.docker.internal'))" 2>&1 || echo "  解析失败"

echo ""
echo "--- [D] 容器内逐个 IP 试连 11434 ---"
docker exec aiops-rag-api python - <<PYEOF 2>&1
import socket
cands = ["host.docker.internal", "$GW", "172.17.0.1", "127.0.0.1"]
for c in cands:
    try:
        ip = socket.gethostbyname(c)
    except Exception as e:
        print("  %-24s 解析失败 %s" % (c, e)); continue
    s = socket.socket(); s.settimeout(4)
    try:
        s.connect((ip, 11434)); print("  %-24s -> %-15s ✅ 端口开放" % (c, ip))
    except Exception as e:
        print("  %-24s -> %-15s ❌ %s" % (c, ip, type(e).__name__))
    finally:
        s.close()
PYEOF

echo ""
echo "--- [E] 容器内实际请求一次 /api/tags ---"
docker exec aiops-rag-api python -c "
import urllib.request
try:
    r=urllib.request.urlopen('http://host.docker.internal:11434/api/tags',timeout=6)
    print('  HTTP', r.status); print('  ', r.read()[:200])
except Exception as e:
    print('  失败:', type(e).__name__, e)
" 2>&1

echo ""
echo "=================================================="
echo " 把 A~E 的完整输出发我"
echo "=================================================="
