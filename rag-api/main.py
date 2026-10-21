"""RAG 检索服务：向量 + 关键词混合召回 → RRF 融合 → Ollama 生成。

对外接口：
  POST /ingest   文本切片入库
  POST /query    检索问答（带引用）
  GET  /healthz  存活探针（给 Docker healthcheck 用）
  GET  /health   依赖健康详情
  GET  /stats    库内统计
  GET  /metrics  Prometheus 指标
"""
import os
import re
import logging
from contextlib import asynccontextmanager

import httpx
import psycopg2
from psycopg2.pool import SimpleConnectionPool
from fastapi import FastAPI, HTTPException
from fastapi.responses import Response
from pydantic import BaseModel, Field
from prometheus_client import Counter, Histogram, CONTENT_TYPE_LATEST, generate_latest

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("rag-api")

OLLAMA = os.getenv("OLLAMA_BASE_URL", "http://host.docker.internal:11434").rstrip("/")
LLM_MODEL = os.getenv("LLM_MODEL", "qwen2.5:3b")  # 勿用 qwen3:4b，模板硬编码 <think> 会吞掉全部 token
EMB_MODEL = os.getenv("EMB_MODEL", "bge-m3")
DATABASE_URL = os.getenv("DATABASE_URL", "postgresql://rag:rag_pass@pgvector:5432/ragdb")
CHUNK_SIZE = int(os.getenv("CHUNK_SIZE", "512"))
CHUNK_OVERLAP = int(os.getenv("CHUNK_OVERLAP", "64"))
TOP_K = int(os.getenv("TOP_K", "5"))
CANDIDATES = int(os.getenv("CANDIDATES", "20"))

# ---------- 指标 ----------
QUERY_TOTAL = Counter("rag_query_total", "查询总次数", ["status"])
QUERY_LATENCY = Histogram("rag_query_latency_seconds", "端到端查询耗时",
                          buckets=(0.1, 0.5, 1, 2, 3, 5, 8, 13, 21))
CHUNKS_TOTAL = Counter("rag_chunks_ingested_total", "累计入库切片数")
RETRIEVED_HIST = Histogram("rag_retrieved_chunks", "单次查询召回切片数",
                           buckets=(1, 2, 3, 5, 8, 10, 20))
EMBED_LATENCY = Histogram("rag_embed_latency_seconds", "向量化耗时",
                          buckets=(0.05, 0.1, 0.3, 0.6, 1, 2, 5))
LLM_LATENCY = Histogram("rag_llm_latency_seconds", "大模型生成耗时",
                        buckets=(0.5, 1, 2, 4, 8, 15, 25))

_pool: SimpleConnectionPool | None = None


def _init_pool(retries: int = 30, delay: float = 2.0):
    global _pool
    for i in range(retries):
        conn = None
        try:
            _pool = SimpleConnectionPool(1, 8, dsn=DATABASE_URL)
            conn = _pool.getconn()
            with conn.cursor() as cur:
                cur.execute("SELECT 1")
            _pool.putconn(conn)
            log.info("数据库连接池就绪")
            return
        except Exception as exc:  # noqa: BLE001
            if conn is not None and _pool is not None:
                try:
                    _pool.putconn(conn, close=True)
                except Exception:  # noqa: BLE001
                    pass
            log.warning("等待数据库 (%s/%s): %s", i + 1, retries, exc)
            import time
            time.sleep(delay)
    raise RuntimeError("数据库始终不可用，服务退出")


@asynccontextmanager
async def lifespan(app: FastAPI):
    _init_pool()
    yield


app = FastAPI(title="AI 知识库检索服务", version="1.0.0", lifespan=lifespan)


@app.middleware("http")
async def force_utf8_charset(request, call_next):
    """统一给 JSON 响应补上 charset=utf-8。

    否则部分客户端（PowerShell 的 Invoke-RestMethod、某些 Postman 版本）
    会按 ISO-8859-1 解码，中文全变乱码——响应体本身是对的，只是缺声明。
    """
    response = await call_next(request)
    ctype = response.headers.get("content-type", "")
    if ctype.startswith("application/json") and "charset" not in ctype:
        response.headers["content-type"] = ctype + "; charset=utf-8"
    return response


def get_conn():
    if _pool is None:
        raise HTTPException(503, "连接池未就绪")
    return _pool.getconn()


# ---------- 上游调用 ----------
def embed(texts: list[str]) -> list[list[float]]:
    """调 Ollama 向量化。优先新接口 /api/embed，失败回退旧接口。"""
    with EMBED_LATENCY.time():
        with httpx.Client(timeout=120.0) as client:
            resp = client.post(f"{OLLAMA}/api/embed", json={"model": EMB_MODEL, "input": texts})
            if resp.status_code == 200:
                return resp.json()["embeddings"]
            log.warning("/api/embed 不可用(%s)，回退 /api/embeddings", resp.status_code)
            out = []
            for t in texts:
                r = client.post(f"{OLLAMA}/api/embeddings", json={"model": EMB_MODEL, "prompt": t})
                r.raise_for_status()
                out.append(r.json()["embedding"])
            return out


def llm(prompt: str) -> str:
    with LLM_LATENCY.time():
        with httpx.Client(timeout=180.0) as client:
            r = client.post(f"{OLLAMA}/api/generate", json={
                "model": LLM_MODEL,
                "prompt": prompt,
                "stream": False,
                "options": {"temperature": 0.2, "num_predict": 512},
            })
            r.raise_for_status()
            return r.json()["response"].strip()


# ---------- 工具 ----------
def split_text(text: str, size: int, overlap: int) -> list[str]:
    text = re.sub(r"\r\n", "\n", text)
    text = re.sub(r"[ \t]+", " ", text)
    text = re.sub(r"\n{3,}", "\n\n", text).strip()
    if not text:
        return []
    if len(text) <= size:
        return [text]
    step = max(1, size - overlap)
    return [text[i:i + size] for i in range(0, len(text), step) if text[i:i + size].strip()]


def to_vec(v: list[float]) -> str:
    return "[" + ",".join(f"{x:.6f}" for x in v) + "]"


def rrf_fuse(vec_rows, kw_rows, k: int = 60):
    """Reciprocal Rank Fusion：两路召回按名次融合，避免分数尺度不一致。"""
    fused: dict[int, dict] = {}
    for rows in (vec_rows, kw_rows):
        for rank, row in enumerate(rows, start=1):
            item = fused.setdefault(row[0], {"row": row, "score": 0.0})
            item["score"] += 1.0 / (k + rank)
    return sorted(fused.values(), key=lambda x: -x["score"])


# ---------- 模型 ----------
class IngestReq(BaseModel):
    doc_id: str
    text: str
    meta: dict = Field(default_factory=dict)


class QueryReq(BaseModel):
    question: str
    top_k: int | None = None


PROMPT_TMPL = """你是企业知识库助手。请严格依据【参考资料】回答用户问题。

规则：
1. 只使用参考资料中的信息，不要编造；资料中没有依据时，直接回答「根据现有资料无法回答」。
2. 回答末尾用 [序号] 标注引用来源。
3. 用中文回答，简洁分点，不超过 200 字。

【参考资料】
{context}

【问题】
{question}"""


# ---------- 接口 ----------
@app.post("/ingest")
def ingest(req: IngestReq):
    pieces = split_text(req.text, CHUNK_SIZE, CHUNK_OVERLAP)
    if not pieces:
        raise HTTPException(400, "文本为空")

    vectors = embed(pieces)
    if len(vectors) != len(pieces):
        raise HTTPException(502, f"向量数量不匹配：{len(vectors)} != {len(pieces)}")

    conn = get_conn()
    try:
        conn.autocommit = False
        with conn.cursor() as cur:
            cur.execute("DELETE FROM chunks WHERE doc_id = %s", (req.doc_id,))  # 幂等重入
            import json as _json
            for idx, (piece, vec) in enumerate(zip(pieces, vectors)):
                cur.execute(
                    "INSERT INTO chunks (doc_id, chunk_idx, content, meta, embedding) "
                    "VALUES (%s, %s, %s, %s::jsonb, %s::vector)",
                    (req.doc_id, idx, piece, _json.dumps(req.meta, ensure_ascii=False), to_vec(vec)),
                )
        conn.commit()
        CHUNKS_TOTAL.inc(len(pieces))
        return {"doc_id": req.doc_id, "chunks": len(pieces)}
    except Exception as exc:  # noqa: BLE001
        conn.rollback()
        log.exception("入库失败")
        raise HTTPException(500, f"入库失败: {exc}") from exc
    finally:
        _pool.putconn(conn)


@app.post("/query")
def query(req: QueryReq):
    if not req.question.strip():
        raise HTTPException(400, "问题不能为空")
    k = req.top_k or TOP_K

    try:
        with QUERY_LATENCY.time():
            qvec = embed([req.question])[0]
            vs = to_vec(qvec)

            conn = get_conn()
            try:
                with conn.cursor() as cur:
                    cur.execute(
                        "SELECT id, doc_id, content, 1 - (embedding <=> %s::vector) AS score "
                        "FROM chunks ORDER BY embedding <=> %s::vector LIMIT %s",
                        (vs, vs, CANDIDATES),
                    )
                    vec_rows = cur.fetchall()

                    cur.execute(
                        "SELECT id, doc_id, content, similarity(content, %s) AS score "
                        "FROM chunks WHERE similarity(content, %s) > 0.02 "
                        "ORDER BY score DESC LIMIT %s",
                        (req.question, req.question, CANDIDATES),
                    )
                    kw_rows = cur.fetchall()
            finally:
                _pool.putconn(conn)

            ranked = rrf_fuse(vec_rows, kw_rows)[:k]
            if not ranked:
                QUERY_TOTAL.labels(status="no_hit").inc()
                return {"answer": "根据现有资料无法回答。", "sources": []}

            RETRIEVED_HIST.observe(len(ranked))
            context = "\n\n".join(
                f"[{i}] ({it['row'][1]}) {it['row'][2]}" for i, it in enumerate(ranked, start=1)
            )
            answer = llm(PROMPT_TMPL.format(context=context, question=req.question))

        QUERY_TOTAL.labels(status="ok").inc()
        return {
            "answer": answer,
            "sources": [
                {
                    "rank": i,
                    "doc_id": it["row"][1],
                    "score": round(it["score"], 6),
                    "snippet": it["row"][2][:160],
                }
                for i, it in enumerate(ranked, start=1)
            ],
        }
    except HTTPException:
        QUERY_TOTAL.labels(status="error").inc()
        raise
    except Exception as exc:  # noqa: BLE001
        QUERY_TOTAL.labels(status="error").inc()
        log.exception("查询失败")
        raise HTTPException(500, f"查询失败: {exc}") from exc


@app.get("/healthz")
def healthz():
    return {"status": "ok"}


@app.get("/health")
def health():
    detail = {"db": "down", "ollama": "down", "model": LLM_MODEL, "emb_model": EMB_MODEL}
    try:
        conn = get_conn()
        try:
            with conn.cursor() as cur:
                cur.execute("SELECT count(*) FROM chunks")
                detail["db"] = "up"
                detail["chunks"] = cur.fetchone()[0]
        finally:
            _pool.putconn(conn)
    except Exception as exc:  # noqa: BLE001
        detail["db_error"] = str(exc)

    try:
        with httpx.Client(timeout=5.0) as client:
            if client.get(f"{OLLAMA}/api/tags").status_code == 200:
                detail["ollama"] = "up"
    except Exception as exc:  # noqa: BLE001
        detail["ollama_error"] = str(exc)

    code = 200 if detail["db"] == "up" else 503
    return Response(
        content=__import__("json").dumps(detail, ensure_ascii=False),
        media_type="application/json",
        status_code=code,
    )


@app.get("/stats")
def stats():
    conn = get_conn()
    try:
        with conn.cursor() as cur:
            cur.execute("SELECT count(*), count(DISTINCT doc_id) FROM chunks")
            chunks, docs = cur.fetchone()
        return {"chunks": chunks, "docs": docs,
                "chunk_size": CHUNK_SIZE, "overlap": CHUNK_OVERLAP, "top_k": TOP_K}
    finally:
        _pool.putconn(conn)


@app.get("/metrics")
def metrics():
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)
