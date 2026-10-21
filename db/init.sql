-- 初始化：向量扩展 + 关键词相似度扩展 + 业务表
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pg_trgm;

CREATE TABLE IF NOT EXISTS chunks (
    id          BIGSERIAL PRIMARY KEY,
    doc_id      TEXT        NOT NULL,
    chunk_idx   INT         NOT NULL,
    content     TEXT        NOT NULL,
    meta        JSONB       DEFAULT '{}'::jsonb,
    embedding   vector(1024) NOT NULL,
    created_at  TIMESTAMPTZ DEFAULT now()
);

-- 向量索引（余弦距离）
CREATE INDEX IF NOT EXISTS idx_chunks_embedding
    ON chunks USING hnsw (embedding vector_cosine_ops);

-- 关键词索引（中文按三元组匹配，无需分词器）
CREATE INDEX IF NOT EXISTS idx_chunks_content_trgm
    ON chunks USING gin (content gin_trgm_ops);

CREATE INDEX IF NOT EXISTS idx_chunks_doc ON chunks (doc_id);
