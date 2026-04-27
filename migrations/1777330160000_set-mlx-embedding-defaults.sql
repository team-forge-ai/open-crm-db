-- Up Migration
ALTER TABLE semantic_embeddings
  ALTER COLUMN embedding_provider SET DEFAULT 'mlx',
  ALTER COLUMN embedding_model SET DEFAULT 'mlx-community/embeddinggemma-300m-4bit',
  ALTER COLUMN embedding_model_version SET DEFAULT '4bit';

-- Down Migration
ALTER TABLE semantic_embeddings
  ALTER COLUMN embedding_provider DROP DEFAULT,
  ALTER COLUMN embedding_model DROP DEFAULT,
  ALTER COLUMN embedding_model_version DROP DEFAULT;
