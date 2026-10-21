#!/usr/bin/env bash
# 备份脚本：数据库全量 dump + 配置文件打包 + 保留最近 7 份
# 用法：./scripts/backup.sh
set -euo pipefail

BACKUP_DIR="${BACKUP_DIR:-./backup}"
KEEP="${KEEP:-7}"
STAMP=$(date +%Y%m%d_%H%M%S)
mkdir -p "$BACKUP_DIR"

echo "[1/3] 导出数据库..."
docker exec aiops-pgvector pg_dump -U "${POSTGRES_USER:-rag}" -d "${POSTGRES_DB:-ragdb}" \
  --no-owner --clean --if-exists > "$BACKUP_DIR/ragdb_${STAMP}.sql"
echo "      -> $BACKUP_DIR/ragdb_${STAMP}.sql ($(du -h "$BACKUP_DIR/ragdb_${STAMP}.sql" | cut -f1))"

echo "[2/3] 打包配置..."
tar -czf "$BACKUP_DIR/config_${STAMP}.tar.gz" \
  docker-compose.yml .env prometheus/ rag-api/ scripts/ 2>/dev/null || true
echo "      -> $BACKUP_DIR/config_${STAMP}.tar.gz"

echo "[3/3] 清理旧备份（保留最近 ${KEEP} 份）..."
ls -t "$BACKUP_DIR"/ragdb_*.sql 2>/dev/null | tail -n +$((KEEP+1)) | xargs -r rm -f
ls -t "$BACKUP_DIR"/config_*.tar.gz 2>/dev/null | tail -n +$((KEEP+1)) | xargs -r rm -f

echo "完成。当前备份："
ls -lh "$BACKUP_DIR" | tail -n +2
