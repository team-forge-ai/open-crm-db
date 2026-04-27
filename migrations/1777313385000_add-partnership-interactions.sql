-- Up Migration

-- -----------------------------------------------------------------------------
-- Partnership interactions
-- Links CRM activity to a partnership without making the interaction itself
-- partnership-specific.
-- -----------------------------------------------------------------------------
CREATE TABLE partnership_interactions (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  partnership_id  uuid NOT NULL REFERENCES partnerships(id) ON DELETE CASCADE,
  interaction_id  uuid NOT NULL REFERENCES interactions(id) ON DELETE CASCADE,
  role            text NOT NULL DEFAULT 'related',
  notes           text,
  metadata        jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at      timestamptz NOT NULL DEFAULT NOW(),
  updated_at      timestamptz NOT NULL DEFAULT NOW(),
  UNIQUE (partnership_id, interaction_id, role)
);
CREATE INDEX idx_partnership_interactions_partnership ON partnership_interactions (partnership_id);
CREATE INDEX idx_partnership_interactions_interaction ON partnership_interactions (interaction_id);
CREATE INDEX idx_partnership_interactions_role        ON partnership_interactions (role);
CREATE TRIGGER trg_partnership_interactions_updated_at
  BEFORE UPDATE ON partnership_interactions
  FOR EACH ROW EXECUTE PROCEDURE picardo_set_updated_at();


-- Down Migration

DROP TABLE IF EXISTS partnership_interactions;
