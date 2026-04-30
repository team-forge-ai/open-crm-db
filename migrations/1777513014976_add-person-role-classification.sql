-- Up Migration

CREATE TYPE person_role_family AS ENUM (
  'communications',
  'customer_service',
  'education',
  'engineering',
  'finance',
  'health_professional',
  'human_resources',
  'information_technology',
  'leadership',
  'legal',
  'marketing',
  'operations',
  'product',
  'public_relations',
  'real_estate',
  'recruiting',
  'research',
  'sales',
  'other',
  'unknown'
);

CREATE TYPE person_seniority AS ENUM (
  'executive',
  'director',
  'manager',
  'individual_contributor',
  'advisor',
  'contractor',
  'other',
  'unknown'
);

ALTER TABLE people
  ADD COLUMN current_title text,
  ADD COLUMN current_department text,
  ADD COLUMN current_organization_id uuid REFERENCES organizations(id) ON DELETE SET NULL,
  ADD COLUMN role_family person_role_family,
  ADD COLUMN seniority person_seniority;

ALTER TABLE affiliations
  ADD COLUMN role_family person_role_family,
  ADD COLUMN seniority person_seniority;

CREATE INDEX idx_people_current_organization
  ON people (current_organization_id)
  WHERE archived_at IS NULL AND current_organization_id IS NOT NULL;
CREATE INDEX idx_people_role_family
  ON people (role_family)
  WHERE archived_at IS NULL;
CREATE INDEX idx_people_seniority
  ON people (seniority)
  WHERE archived_at IS NULL;
CREATE INDEX idx_affiliations_role_family
  ON affiliations (role_family)
  WHERE is_current;
CREATE INDEX idx_affiliations_seniority
  ON affiliations (seniority)
  WHERE is_current;

CREATE OR REPLACE FUNCTION crm_sync_person_current_affiliation(target_person_id uuid)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
  current_affiliation record;
BEGIN
  SELECT
    a.title,
    a.department,
    a.organization_id,
    a.role_family,
    a.seniority
  INTO current_affiliation
  FROM affiliations a
  WHERE a.person_id = target_person_id
    AND a.is_current = true
    AND a.end_date IS NULL
  ORDER BY
    a.is_primary DESC,
    (a.title IS NOT NULL AND a.title <> '') DESC,
    a.updated_at DESC,
    a.created_at DESC,
    a.id DESC
  LIMIT 1;

  IF FOUND THEN
    UPDATE people
       SET current_title = current_affiliation.title,
           current_department = current_affiliation.department,
           current_organization_id = current_affiliation.organization_id,
           role_family = current_affiliation.role_family,
           seniority = current_affiliation.seniority,
           updated_at = now()
     WHERE id = target_person_id;
  ELSE
    UPDATE people
       SET current_title = NULL,
           current_department = NULL,
           current_organization_id = NULL,
           role_family = NULL,
           seniority = NULL,
           updated_at = now()
     WHERE id = target_person_id;
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION crm_affiliations_sync_person_current()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    PERFORM crm_sync_person_current_affiliation(OLD.person_id);
    RETURN OLD;
  END IF;

  PERFORM crm_sync_person_current_affiliation(NEW.person_id);

  IF TG_OP = 'UPDATE' AND OLD.person_id IS DISTINCT FROM NEW.person_id THEN
    PERFORM crm_sync_person_current_affiliation(OLD.person_id);
  END IF;

  RETURN NEW;
END;
$$;

WITH current_affiliations AS (
  SELECT DISTINCT ON (a.person_id)
    a.person_id,
    a.title,
    a.department,
    a.organization_id,
    a.role_family,
    a.seniority
  FROM affiliations a
  WHERE a.is_current = true
    AND a.end_date IS NULL
  ORDER BY
    a.person_id,
    a.is_primary DESC,
    (a.title IS NOT NULL AND a.title <> '') DESC,
    a.updated_at DESC,
    a.created_at DESC,
    a.id DESC
)
UPDATE people p
   SET current_title = ca.title,
       current_department = ca.department,
       current_organization_id = ca.organization_id,
       role_family = ca.role_family,
       seniority = ca.seniority,
       updated_at = now()
  FROM current_affiliations ca
 WHERE p.id = ca.person_id;

CREATE TRIGGER trg_affiliations_sync_person_current
  AFTER INSERT OR UPDATE OR DELETE ON affiliations
  FOR EACH ROW EXECUTE PROCEDURE crm_affiliations_sync_person_current();

-- Down Migration

DROP TRIGGER trg_affiliations_sync_person_current ON affiliations;
DROP FUNCTION crm_affiliations_sync_person_current();
DROP FUNCTION crm_sync_person_current_affiliation(uuid);

DROP INDEX idx_affiliations_seniority;
DROP INDEX idx_affiliations_role_family;
DROP INDEX idx_people_seniority;
DROP INDEX idx_people_role_family;
DROP INDEX idx_people_current_organization;

ALTER TABLE affiliations
  DROP COLUMN seniority,
  DROP COLUMN role_family;

ALTER TABLE people
  DROP COLUMN seniority,
  DROP COLUMN role_family,
  DROP COLUMN current_organization_id,
  DROP COLUMN current_department,
  DROP COLUMN current_title;

DROP TYPE person_seniority;
DROP TYPE person_role_family;
