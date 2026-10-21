.PHONY: help env up down restart ps logs health backup ingest-notes query test clean

help:
	@echo "make env          复制 .env.example -> .env"
	@echo "make up           启动全部服务"
	@echo "make up-core      只启动核心（pgvector + rag-api）"
	@echo "make down         停止"
	@echo "make ps           查看状态"
	@echo "make logs         跟踪 rag-api 日志"
	@echo "make health       跑巡检脚本"
	@echo "make backup       备份数据库与配置"
	@echo "make ingest FILE=path  入库一个文本文件"
	@echo "make query Q=问题      提问"
	@echo "make test         冒烟测试"

env:
	@[ -f .env ] || cp .env.example .env
	@echo ".env 就绪"

up: env
	docker compose up -d
	@echo "等待服务就绪..."
	@sleep 8
	@docker compose ps

up-core: env
	docker compose up -d pgvector rag-api

down:
	docker compose down

restart:
	docker compose restart

ps:
	docker compose ps

logs:
	docker compose logs -f rag-api

health:
	@bash scripts/health_check.sh

backup:
	@bash scripts/backup.sh

ingest:
	@test -n "$(FILE)" || (echo "用法: make ingest FILE=docs/xxx.txt"; exit 1)
	@python3 -c "import json,sys;print(json.dumps({'doc_id':'$(notdir $(FILE))','text':open('$(FILE)',encoding='utf-8').read()}))" \
	  | curl -s -X POST http://127.0.0.1:8000/ingest -H 'Content-Type: application/json' -d @-
	@echo

query:
	@test -n "$(Q)" || (echo "用法: make query Q='你的问题'"; exit 1)
	@curl -s -X POST http://127.0.0.1:8000/query -H 'Content-Type: application/json' \
	  -d '{"question":"$(Q)"}' | python3 -m json.tool --no-ensure-ascii

test:
	@echo "1) 健康检查"; curl -s http://127.0.0.1:8000/healthz
	@echo; echo "2) 依赖详情"; curl -s http://127.0.0.1:8000/health
	@echo; echo "3) 入库统计"; curl -s http://127.0.0.1:8000/stats
	@echo; echo "4) 指标前 5 行"; curl -s http://127.0.0.1:8000/metrics | head -5

clean:
	@echo "此操作会删除所有容器与数据卷，确认请输入 yes"
	@read ans && [ "$$ans" = "yes" ] && docker compose down -v && rm -rf data/
