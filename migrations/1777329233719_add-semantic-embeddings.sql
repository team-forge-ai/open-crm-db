-- Up Migration
CREATE EXTENSION IF NOT EXISTS vector;

CREATE TABLE semantic_embeddings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  target_type text NOT NULL CHECK (
    target_type IN (
      'organization',
      'organization_research_profile',
      'person',
      'interaction',
      'document',
      'partnership',
      'partnership_service',
      'partnership_integration',
      'call_transcript',
      'ai_note',
      'extracted_fact'
    )
  ),
  target_id uuid NOT NULL,
  chunk_index integer NOT NULL DEFAULT 0 CHECK (chunk_index >= 0),
  content text NOT NULL CHECK (length(trim(content)) > 0),
  content_sha256 text NOT NULL CHECK (content_sha256 ~ '^[a-f0-9]{64}$'),
  embedding_provider text NOT NULL DEFAULT 'ollama',
  embedding_model text NOT NULL DEFAULT 'embeddinggemma',
  embedding_model_version text NOT NULL DEFAULT 'latest',
  embedding_dimension integer NOT NULL DEFAULT 768 CHECK (embedding_dimension = 768),
  embedding vector(768) NOT NULL,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  archived_at timestamptz,
  embedded_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_semantic_embeddings_target
  ON semantic_embeddings (target_type, target_id)
  WHERE archived_at IS NULL;

CREATE INDEX idx_semantic_embeddings_model
  ON semantic_embeddings (
    embedding_provider,
    embedding_model,
    embedding_model_version
  )
  WHERE archived_at IS NULL;

CREATE UNIQUE INDEX uq_semantic_embeddings_active_chunk
  ON semantic_embeddings (
    target_type,
    target_id,
    embedding_provider,
    embedding_model,
    embedding_model_version,
    chunk_index
  )
  WHERE archived_at IS NULL;

CREATE INDEX idx_semantic_embeddings_embedding_hnsw
  ON semantic_embeddings
  USING hnsw (embedding vector_cosine_ops)
  WHERE archived_at IS NULL;

CREATE TRIGGER trg_semantic_embeddings_updated_at
  BEFORE UPDATE ON semantic_embeddings
  FOR EACH ROW
  EXECUTE FUNCTION picardo_set_updated_at();

CREATE OR REPLACE FUNCTION match_semantic_embeddings(
  query_embedding vector(768),
  match_count integer DEFAULT 10,
  filter_target_types text[] DEFAULT NULL
)
RETURNS TABLE (
  id uuid,
  target_type text,
  target_id uuid,
  chunk_index integer,
  content text,
  embedding_provider text,
  embedding_model text,
  embedding_model_version text,
  metadata jsonb,
  similarity double precision
)
LANGUAGE sql
STABLE
AS $$
  SELECT
    se.id,
    se.target_type,
    se.target_id,
    se.chunk_index,
    se.content,
    se.embedding_provider,
    se.embedding_model,
    se.embedding_model_version,
    se.metadata,
    1 - (se.embedding <=> query_embedding) AS similarity
  FROM semantic_embeddings se
  WHERE se.archived_at IS NULL
    AND (
      filter_target_types IS NULL
      OR se.target_type = ANY(filter_target_types)
    )
  ORDER BY se.embedding <=> query_embedding
  LIMIT LEAST(GREATEST(COALESCE(match_count, 10), 1), 100);
$$;

-- Down Migration
DROP FUNCTION IF EXISTS match_semantic_embeddings(vector, integer, text[]);
DROP TABLE semantic_embeddings;
