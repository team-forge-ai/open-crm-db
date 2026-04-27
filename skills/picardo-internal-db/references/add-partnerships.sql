-- Up Migration

-- -----------------------------------------------------------------------------
-- Partnerships
-- Operating layer for strategic, commercial, clinical, and technical partner
-- work. Organizations remain the identity layer; partnerships capture the
-- pipeline/lifecycle state for a specific collaboration with that organization.
-- -----------------------------------------------------------------------------
CREATE TABLE partnerships (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id      uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  name                 text NOT NULL,
  partnership_type     text NOT NULL,
  stage                text NOT NULL DEFAULT 'prospect',
  priority             text NOT NULL DEFAULT 'medium',
  owner_person_id      uuid REFERENCES people(id) ON DELETE SET NULL,
  strategic_rationale  text,
  commercial_model     text,
  status_notes         text,
  signed_at            timestamptz,
  launched_at          timestamptz,
  source_id            uuid REFERENCES sources(id) ON DELETE SET NULL,
  metadata             jsonb NOT NULL DEFAULT '{}'::jsonb,
  archived_at          timestamptz,
  created_at           timestamptz NOT NULL DEFAULT NOW(),
  updated_at           timestamptz NOT NULL DEFAULT NOW(),
  CHECK (stage IN (
    'prospect',
    'intro',
    'discovery',
    'diligence',
    'pilot',
    'contracting',
    'live',
    'paused',
    'lost'
  )),
  CHECK (priority IN ('low', 'medium', 'high', 'strategic')),
  CHECK (launched_at IS NULL OR signed_at IS NULL OR launched_at >= signed_at)
);
CREATE UNIQUE INDEX uq_partnerships_active_org_name
  ON partnerships (organization_id, lower(name))
  WHERE archived_at IS NULL;
CREATE INDEX idx_partnerships_organization ON partnerships (organization_id);
CREATE INDEX idx_partnerships_type         ON partnerships (partnership_type);
CREATE INDEX idx_partnerships_stage        ON partnerships (stage);
CREATE INDEX idx_partnerships_priority     ON partnerships (priority);
CREATE INDEX idx_partnerships_owner        ON partnerships (owner_person_id);
CREATE INDEX idx_partnerships_source       ON partnerships (source_id);
CREATE INDEX idx_partnerships_metadata     ON partnerships USING GIN (metadata);
CREATE TRIGGER trg_partnerships_updated_at
  BEFORE UPDATE ON partnerships
  FOR EACH ROW EXECUTE PROCEDURE picardo_set_updated_at();

-- Partnerships are taggable operating artifacts.
ALTER TABLE taggings
  DROP CONSTRAINT IF EXISTS ck_taggings_target_type;
ALTER TABLE taggings
  DROP CONSTRAINT IF EXISTS taggings_target_type_check;
ALTER TABLE taggings
  ADD CONSTRAINT ck_taggings_target_type CHECK (
    target_type IN ('organization', 'person', 'interaction', 'document', 'partnership')
  );


-- Down Migration

ALTER TABLE taggings
  DROP CONSTRAINT IF EXISTS ck_taggings_target_type;
DELETE FROM taggings WHERE target_type = 'partnership';
ALTER TABLE taggings
  ADD CONSTRAINT ck_taggings_target_type CHECK (
    target_type IN ('organization', 'person', 'interaction', 'document')
  );

DROP TABLE IF EXISTS partnerships;
