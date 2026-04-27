-- Up Migration

-- -----------------------------------------------------------------------------
-- Partnership documents
-- Links contracts, memos, integration notes, pricing docs, diligence artifacts,
-- and strategy documents to a partnership.
-- -----------------------------------------------------------------------------
CREATE TABLE partnership_documents (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  partnership_id  uuid NOT NULL REFERENCES partnerships(id) ON DELETE CASCADE,
  document_id     uuid NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
  role            text NOT NULL DEFAULT 'related',
  notes           text,
  metadata        jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at      timestamptz NOT NULL DEFAULT NOW(),
  updated_at      timestamptz NOT NULL DEFAULT NOW(),
  UNIQUE (partnership_id, document_id, role)
);
CREATE INDEX idx_partnership_documents_partnership ON partnership_documents (partnership_id);
CREATE INDEX idx_partnership_documents_document    ON partnership_documents (document_id);
CREATE INDEX idx_partnership_documents_role        ON partnership_documents (role);
CREATE TRIGGER trg_partnership_documents_updated_at
  BEFORE UPDATE ON partnership_documents
  FOR EACH ROW EXECUTE PROCEDURE picardo_set_updated_at();


-- Down Migration

DROP TABLE IF EXISTS partnership_documents;
