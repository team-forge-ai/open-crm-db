-- Up Migration

ALTER TABLE organizations
  ALTER COLUMN domain SET NOT NULL;

DROP INDEX IF EXISTS idx_people_primary_email;
DROP INDEX IF EXISTS idx_organizations_domain;

CREATE UNIQUE INDEX uq_people_primary_email
  ON people (primary_email);

CREATE UNIQUE INDEX uq_organizations_domain
  ON organizations (domain);

-- Down Migration

DROP INDEX IF EXISTS uq_organizations_domain;
DROP INDEX IF EXISTS uq_people_primary_email;

CREATE INDEX idx_organizations_domain
  ON organizations (domain);

CREATE INDEX idx_people_primary_email
  ON people (primary_email);

ALTER TABLE organizations
  ALTER COLUMN domain DROP NOT NULL;
