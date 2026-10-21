#!/usr/bin/env bash
# 日常巡检脚本：一次性输出所有关键检查项，异常项以 [FAIL] 标出。
# 用法：./scripts/health_check.sh
set -uo pipefail

PASS=0; FAIL=0
ok()   { echo "  [ OK ] $1"; PASS=$((PASS+1)); }
bad()  { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }
info() { echo "  [ -- ] $1"; }

echo "=============================================="
echo " AI 运维平台巡检  $(date '+%Y-%m-%d %H:%M:%S')"
echo "=============================================="

echo "[1] 容器状态"
UNHEALTHY=$(docker ps --filter "health=unhealthy" --format '{{.Names}}' 2>/dev/null)
EXITED=$(docker ps -a --filter "status=exited" --format '{{.Names}}' 2>/dev/null)
[ -z "$UNHEALTHY" ] && ok "无 unhealthy 容器" || bad "unhealthy: $UNHEALTHY"
[ -z "$EXITED" ]    && ok "无已退出容器"   || bad "已退出: $EXITED"

echo "[2] 关键服务端口"
for p in 8000 9090 3000 5432; do
  if (echo > /dev/tcp/127.0.0.1/$p) >/dev/null 2>&1; then
    ok "端口 $p 可连接"
  else
    bad "端口 $p 不可连接"
  fi
done

echo "[3] 磁盘"
USED=$(df -P / | awk 'NR==2 {gsub("%","",$5); print $5}')
if [ "$USED" -lt 80 ]; then ok "根分区使用率 ${USED}%"; else bad "根分区使用率 ${USED}%（阈值 80%）"; fi
DOCKER_SIZE=$(docker system df --format '{{.Size}}' 2>/dev/null | head -1)
info "Docker 占用: ${DOCKER_SIZE:-未知}"

echo "[4] 内存"
AVAIL=$(awk '/MemAvailable/ {printf "%.0f", $2/1024/1024}' /proc/meminfo)
TOTAL=$(awk '/MemTotal/ {printf "%.0f", $2/1024/1024}' /proc/meminfo)
PCT=$(( AVAIL * 100 / TOTAL ))
if [ "$PCT" -ge 15 ]; then ok "可用内存 ${AVAIL}MB / ${TOTAL}MB (${PCT}%)"; else bad "可用内存仅 ${PCT}%"; fi

echo "[5] 业务接口"
BODY=$(curl -s -m 5 http://127.0.0.1:8000/health || echo "")
if echo "$BODY" | grep -q '"db": "up"'; then ok "RAG 服务 DB 正常"; else bad "RAG 服务 DB 异常: $BODY"; fi
if echo "$BODY" | grep -q '"ollama": "up"'; then ok "Ollama 连通"; else bad "Ollama 不通"; fi

echo "[6] 知识库规模"
STATS=$(curl -s -m 5 http://127.0.0.1:8000/stats || echo "")
info "统计: ${STATS:-获取失败}"

echo "[7] 最近错误日志"
ERR=$(docker logs --since 1h aiops-rag-api 2>&1 | grep -ciE "error|exception" || true)
if [ "${ERR:-0}" -eq 0 ]; then ok "近 1 小时无错误日志"; else bad "近 1 小时错误日志 ${ERR} 条"; fi

echo "[8] 备份"
LAST=$(ls -t ./backup/*.sql 2>/dev/null | head -1)
if [ -n "$LAST" ]; then
  AGE=$(( ( $(date +%s) - $(stat -c %Y "$LAST") ) / 3600 ))
  if [ "$AGE" -lt 48 ]; then ok "最近备份 ${AGE} 小时前: $(basename "$LAST")"; else bad "备份已 ${AGE} 小时未更新"; fi
else
  bad "未找到备份文件"
fi

echo "=============================================="
echo " 通过 ${PASS} 项，异常 ${FAIL} 项"
echo "=============================================="
[ "$FAIL" -eq 0 ] || exit 1
