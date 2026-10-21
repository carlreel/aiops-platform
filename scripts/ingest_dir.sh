#!/usr/bin/env bash
# 批量入库：把目录下所有 .md / .txt 逐个送入 /ingest
# 用法：./scripts/ingest_dir.sh ./corpus
set -uo pipefail

DIR="${1:-./corpus}"
API="${API:-http://127.0.0.1:8000}"
OK=0; FAILED=0

if [ ! -d "$DIR" ]; then
  echo "目录不存在: $DIR"; exit 1
fi

echo "开始入库: $DIR"
echo "----------------------------------------------"

while IFS= read -r -d '' f; do
  name=$(basename "$f")
  payload=$(python3 - "$f" "$name" <<'PY'
import json, sys
path, name = sys.argv[1], sys.argv[2]
text = open(path, encoding="utf-8", errors="ignore").read()
print(json.dumps({"doc_id": name, "text": text, "meta": {"source": "corpus"}}, ensure_ascii=False))
PY
)
  resp=$(curl -s -m 120 -X POST "$API/ingest" -H 'Content-Type: application/json' -d "$payload")
  if echo "$resp" | grep -q '"chunks"'; then
    n=$(echo "$resp" | grep -o '"chunks":[0-9]*' | cut -d: -f2)
    echo "  [ OK ] $name -> ${n} 片"
    OK=$((OK+1))
  else
    echo "  [FAIL] $name -> $resp"
    FAILED=$((FAILED+1))
  fi
done < <(find "$DIR" -type f \( -name '*.md' -o -name '*.txt' \) -print0)

echo "----------------------------------------------"
echo "成功 ${OK} 篇，失败 ${FAILED} 篇"
echo "当前统计:"; curl -s "$API/stats"; echo
[ "$FAILED" -eq 0 ] || exit 1
