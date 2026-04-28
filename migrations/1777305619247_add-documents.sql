-- Up Migration

-- -----------------------------------------------------------------------------
-- Documents
-- Durable company knowledge artifacts that are not necessarily interactions:
-- internal notes, memos, research docs, strategy docs, meeting-note documents,
-- contract summaries, external briefs, and similar source-backed material.
-- -----------------------------------------------------------------------------
CREATE TABLE documents (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  title              text NOT NULL,
  document_type      text NOT NULL,
  body               text,
  body_format        text NOT NULL DEFAULT 'markdown',
  summary            text,
  authored_at        timestamptz,
  occurred_at        timestamptz,
  source_id          uuid REFERENCES sources(id) ON DELETE SET NULL,
  source_external_id text,
  source_path        text,
  metadata           jsonb NOT NULL DEFAULT '{}'::jsonb,
  archived_at        timestamptz,
  created_at         timestamptz NOT NULL DEFAULT NOW(),
  updated_at         timestamptz NOT NULL DEFAULT NOW()
);
CREATE UNIQUE INDEX uq_documents_source_external_id
  ON documents (source_id, source_external_id)
  WHERE source_external_id IS NOT NULL;
CREATE INDEX idx_documents_document_type ON documents (document_type);
CREATE INDEX idx_documents_authored_at   ON documents (authored_at DESC);
CREATE INDEX idx_documents_occurred_at   ON documents (occurred_at DESC);
CREATE INDEX idx_documents_source_path   ON documents (source_path);
CREATE INDEX idx_documents_metadata      ON documents USING GIN (metadata);
CREATE TRIGGER trg_documents_updated_at
  BEFORE UPDATE ON documents
  FOR EACH ROW EXECUTE PROCEDURE crm_set_updated_at();

-- -----------------------------------------------------------------------------
-- Document links
-- Documents can mention, be authored by, or otherwise concern people,
-- organizations, and interactions without pretending those entities were
-- meeting participants.
-- -----------------------------------------------------------------------------
CREATE TABLE document_people (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  document_id  uuid NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
  person_id    uuid NOT NULL REFERENCES people(id) ON DELETE CASCADE,
  role         text NOT NULL DEFAULT 'mentioned',
  notes        text,
  metadata     jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at   timestamptz NOT NULL DEFAULT NOW(),
  updated_at   timestamptz NOT NULL DEFAULT NOW(),
  UNIQUE (document_id, person_id, role)
);
CREATE INDEX idx_document_people_document ON document_people (document_id);
CREATE INDEX idx_document_people_person   ON document_people (person_id);
CREATE INDEX idx_document_people_role     ON document_people (role);
CREATE TRIGGER trg_document_people_updated_at
  BEFORE UPDATE ON document_people
  FOR EACH ROW EXECUTE PROCEDURE crm_set_updated_at();

CREATE TABLE document_organizations (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  document_id     uuid NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
  organization_id uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  role            text NOT NULL DEFAULT 'mentioned',
  notes           text,
  metadata        jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at      timestamptz NOT NULL DEFAULT NOW(),
  updated_at      timestamptz NOT NULL DEFAULT NOW(),
  UNIQUE (document_id, organization_id, role)
);
CREATE INDEX idx_document_organizations_document ON document_organizations (document_id);
CREATE INDEX idx_document_organizations_org      ON document_organizations (organization_id);
CREATE INDEX idx_document_organizations_role     ON document_organizations (role);
CREATE TRIGGER trg_document_organizations_updated_at
  BEFORE UPDATE ON document_organizations
  FOR EACH ROW EXECUTE PROCEDURE crm_set_updated_at();

CREATE TABLE document_interactions (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  document_id    uuid NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
  interaction_id uuid NOT NULL REFERENCES interactions(id) ON DELETE CASCADE,
  role           text NOT NULL DEFAULT 'related',
  notes          text,
  metadata       jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at     timestamptz NOT NULL DEFAULT NOW(),
  updated_at     timestamptz NOT NULL DEFAULT NOW(),
  UNIQUE (document_id, interaction_id, role)
);
CREATE INDEX idx_document_interactions_document    ON document_interactions (document_id);
CREATE INDEX idx_document_interactions_interaction ON document_interactions (interaction_id);
CREATE INDEX idx_document_interactions_role        ON document_interactions (role);
CREATE TRIGGER trg_document_interactions_updated_at
  BEFORE UPDATE ON document_interactions
  FOR EACH ROW EXECUTE PROCEDURE crm_set_updated_at();

-- Let AI notes and extracted facts cite documents directly as provenance.
ALTER TABLE ai_notes
  DROP CONSTRAINT ai_notes_check;
ALTER TABLE ai_notes
  ADD COLUMN document_id uuid REFERENCES documents(id) ON DELETE CASCADE;
CREATE INDEX idx_ai_notes_document ON ai_notes (document_id);
ALTER TABLE ai_notes
  ADD CONSTRAINT ck_ai_notes_exactly_one_anchor CHECK (
    (interaction_id IS NOT NULL)::int +
    (document_id IS NOT NULL)::int +
    ((subject_type IS NOT NULL AND subject_id IS NOT NULL))::int = 1
  );

ALTER TABLE extracted_facts
  ADD COLUMN document_id uuid REFERENCES documents(id) ON DELETE SET NULL;
CREATE INDEX idx_extracted_facts_document ON extracted_facts (document_id);

-- Documents are taggable CRM knowledge artifacts.
ALTER TABLE taggings
  DROP CONSTRAINT taggings_target_type_check;
ALTER TABLE taggings
  ADD CONSTRAINT ck_taggings_target_type CHECK (
    target_type IN ('organization', 'person', 'interaction', 'document')
  );


-- Down Migration

ALTER TABLE taggings
  DROP CONSTRAINT IF EXISTS ck_taggings_target_type;
ALTER TABLE taggings
  ADD CONSTRAINT taggings_target_type_check CHECK (
    target_type IN ('organization', 'person', 'interaction')
  );

DROP INDEX IF EXISTS idx_extracted_facts_document;
ALTER TABLE extracted_facts
  DROP COLUMN IF EXISTS document_id;

ALTER TABLE ai_notes
  DROP CONSTRAINT IF EXISTS ck_ai_notes_exactly_one_anchor;
DROP INDEX IF EXISTS idx_ai_notes_document;
ALTER TABLE ai_notes
  DROP COLUMN IF EXISTS document_id;
ALTER TABLE ai_notes
  ADD CONSTRAINT ai_notes_check CHECK (
    (interaction_id IS NOT NULL)::int +
    ((subject_type IS NOT NULL AND subject_id IS NOT NULL))::int = 1
  );

DROP TABLE IF EXISTS document_interactions;
DROP TABLE IF EXISTS document_organizations;
DROP TABLE IF EXISTS document_people;
DROP TABLE IF EXISTS documents;
