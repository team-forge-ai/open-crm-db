-- Up Migration

UPDATE people AS p
SET primary_email = candidate.email
FROM (
  SELECT DISTINCT ON (person_id)
    person_id,
    email
  FROM person_emails
  ORDER BY person_id, is_primary DESC, created_at ASC, id ASC
) AS candidate
WHERE p.id = candidate.person_id
  AND p.primary_email IS NULL;

ALTER TABLE people
  ALTER COLUMN primary_email SET NOT NULL;

-- Down Migration

ALTER TABLE people
  ALTER COLUMN primary_email DROP NOT NULL;
