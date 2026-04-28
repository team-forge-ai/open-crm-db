-- Up Migration

-- -----------------------------------------------------------------------------
-- Partnership people
-- The people who matter to a partnership: champions, decision makers, technical
-- contacts, legal/commercial contacts, clinical reviewers, and internal owners.
-- -----------------------------------------------------------------------------
CREATE TABLE partnership_people (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  partnership_id  uuid NOT NULL REFERENCES partnerships(id) ON DELETE CASCADE,
  person_id       uuid NOT NULL REFERENCES people(id) ON DELETE CASCADE,
  role            text NOT NULL,
  notes           text,
  metadata        jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at      timestamptz NOT NULL DEFAULT NOW(),
  updated_at      timestamptz NOT NULL DEFAULT NOW(),
  UNIQUE (partnership_id, person_id, role)
);
CREATE INDEX idx_partnership_people_partnership ON partnership_people (partnership_id);
CREATE INDEX idx_partnership_people_person      ON partnership_people (person_id);
CREATE INDEX idx_partnership_people_role        ON partnership_people (role);
CREATE TRIGGER trg_partnership_people_updated_at
  BEFORE UPDATE ON partnership_people
  FOR EACH ROW EXECUTE PROCEDURE crm_set_updated_at();


-- Down Migration

DROP TABLE IF EXISTS partnership_people;
