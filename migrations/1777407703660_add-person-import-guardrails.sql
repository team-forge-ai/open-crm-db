-- Up Migration

CREATE OR REPLACE FUNCTION crm_is_machine_email(email text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
  WITH parts AS (
    SELECT nullif(lower(btrim(email)), '') AS email_text
  ),
  split AS (
    SELECT
      email_text,
      split_part(email_text, '@', 1) AS local_part,
      split_part(email_text, '@', 2) AS domain_part
    FROM parts
  )
  SELECT COALESCE(
    email_text ~ '^[^@[:space:]]+@[^@[:space:]]+[.][^@[:space:]]+$'
    AND (
      local_part = ANY (ARRAY[
        'accounting',
        'admin',
        'announcements',
        'billing',
        'concierge',
        'contact',
        'customer.service',
        'customerservice',
        'devs',
        'do-not-reply',
        'donotreply',
        'dse',
        'education',
        'enterprise-webinars',
        'finance',
        'hello',
        'help',
        'howdy',
        'info',
        'marketing',
        'newsletter',
        'no-reply',
        'noreply',
        'notifications',
        'ops',
        'operations',
        'postmaster',
        'provider',
        'registration',
        'sales',
        'ship',
        'support',
        'team',
        'test',
        'websupport',
        'win'
      ])
      OR local_part ~ '^(bounce|bounces|mailer-daemon|notification|notifications|no[._-]?reply|do[._-]?not[._-]?reply|reply|replies)([._%+-]|$)'
      OR domain_part = ANY (ARRAY[
        'adobesign.com',
        'docusign.net',
        'email.pandadoc.net',
        'facebookmail.com',
        'info.vercel.com',
        'login.customer.io',
        'team.twilio.com'
      ])
      OR domain_part ~ '(^|[.])bnc[.]salesforce[.]com$'
      OR (
        length(regexp_replace(local_part, '[^[:alnum:]]', '', 'g')) >= 28
        AND local_part ~ '[0-9]'
      )
    ),
    false
  )
  FROM split;
$$;

COMMENT ON FUNCTION crm_is_machine_email(text)
IS 'Returns true for generic inboxes, notification senders, bounce addresses, and high-entropy generated email localparts that should not create CRM people.';

CREATE OR REPLACE FUNCTION crm_assess_person_import(raw_name text, email text)
RETURNS TABLE (
  normalized_name text,
  should_create_person boolean,
  reason_codes text[]
)
LANGUAGE sql
IMMUTABLE
AS $$
  WITH cleaned AS (
    SELECT
      nullif(
        regexp_replace(
          regexp_replace(btrim(coalesce(raw_name, '')), '^[[:space:]''"]+|[[:space:]''"]+$', '', 'g'),
          '[[:space:]]+',
          ' ',
          'g'
        ),
        ''
      ) AS cleaned_name,
      nullif(lower(btrim(email)), '') AS email_text
  ),
  route_stripped AS (
    SELECT
      cleaned_name,
      email_text,
      COALESCE(cleaned_name ~* '[[:space:]]+(via|from|at)[[:space:]]+.+$', false) AS has_route_phrase,
      nullif(
        regexp_replace(cleaned_name, '[[:space:]]+(via|from|at)[[:space:]]+.+$', '', 'i'),
        ''
      ) AS route_stripped_name
    FROM cleaned
  ),
  normalized AS (
    SELECT
      nullif(
        CASE
          WHEN route_stripped_name ~ '^[^,]+,[[:space:]]*[^,]+$'
            THEN regexp_replace(route_stripped_name, '^([^,]+),[[:space:]]*(.+)$', '\2 \1')
          ELSE route_stripped_name
        END,
        ''
      ) AS normalized_name,
      email_text,
      has_route_phrase
    FROM route_stripped
  ),
  signals AS (
    SELECT
      normalized_name,
      email_text,
      has_route_phrase,
      email_text IS NULL
        OR email_text !~ '^[^@[:space:]]+@[^@[:space:]]+[.][^@[:space:]]+$' AS invalid_email,
      crm_is_machine_email(email_text) AS machine_email,
      normalized_name IS NULL AS missing_name,
      COALESCE(
        normalized_name ~* '^[^@[:space:]]+@[^@[:space:]]+$'
        OR lower(normalized_name) = email_text,
        false
      ) AS email_as_name,
      COALESCE(normalized_name ~ '[0-9]', false)
        OR (
          length(regexp_replace(coalesce(normalized_name, ''), '[^[:alnum:]]', '', 'g')) >= 24
          AND normalized_name ~ '[0-9]'
        ) AS numeric_or_token_noise,
      COALESCE(
        normalized_name ~ '^([[:upper:]][[:alpha:]''.-]*|[[:upper:]][.]?)([[:space:]]+(de|del|der|van|von|da|di|la|le|du|[[:upper:]][[:alpha:]''.-]*|[[:upper:]][.]?)){1,5}$',
        false
      ) AS has_capitalized_first_last
    FROM normalized
  ),
  reasons AS (
    SELECT
      normalized_name,
      array_remove(ARRAY[
        CASE WHEN invalid_email THEN 'invalid_email' END,
        CASE WHEN machine_email THEN 'machine_email' END,
        CASE WHEN missing_name THEN 'missing_name' END,
        CASE WHEN email_as_name THEN 'email_as_name' END,
        CASE WHEN has_route_phrase THEN 'route_phrase' END,
        CASE WHEN numeric_or_token_noise THEN 'numeric_or_token_noise' END,
        CASE
          WHEN NOT missing_name
            AND NOT email_as_name
            AND NOT numeric_or_token_noise
            AND NOT has_capitalized_first_last
          THEN 'not_capitalized_first_last'
        END
      ], NULL) AS reason_codes
    FROM signals
  )
  SELECT
    normalized_name,
    cardinality(reason_codes) = 0 AS should_create_person,
    reason_codes
  FROM reasons;
$$;

COMMENT ON FUNCTION crm_assess_person_import(text, text)
IS 'Normalizes an email display name and returns whether an untrusted import should create a CRM person for that name/email pair.';

CREATE OR REPLACE FUNCTION crm_import_person_from_email(
  source_slug text,
  raw_name text,
  email text,
  external_kind text DEFAULT 'contact',
  external_id text DEFAULT NULL,
  metadata jsonb DEFAULT '{}'::jsonb
)
RETURNS TABLE (
  person_id uuid,
  created boolean,
  normalized_name text,
  should_create_person boolean,
  reason_codes text[]
)
LANGUAGE plpgsql
AS $$
DECLARE
  v_source_id uuid;
  v_email citext := nullif(lower(btrim(email)), '')::citext;
  v_external_kind text := coalesce(nullif(btrim(external_kind), ''), 'contact');
  v_external_id text := nullif(btrim(external_id), '');
BEGIN
  IF nullif(btrim(source_slug), '') IS NULL THEN
    RAISE EXCEPTION 'source_slug is required';
  END IF;

  SELECT id
    INTO v_source_id
    FROM sources
   WHERE slug = source_slug;

  IF v_source_id IS NULL THEN
    RAISE EXCEPTION 'unknown source_slug: %', source_slug;
  END IF;

  SELECT
    assessment.normalized_name,
    assessment.should_create_person,
    assessment.reason_codes
    INTO normalized_name, should_create_person, reason_codes
    FROM crm_assess_person_import(raw_name, v_email::text) AS assessment;

  IF v_external_id IS NOT NULL THEN
    SELECT ei.entity_id
      INTO person_id
      FROM external_identities ei
     WHERE ei.source_id = v_source_id
       AND ei.kind = v_external_kind
       AND ei.external_id = v_external_id
       AND ei.entity_type = 'person'
     LIMIT 1;
  END IF;

  IF person_id IS NULL AND v_email IS NOT NULL THEN
    SELECT p.id
      INTO person_id
      FROM people p
      LEFT JOIN person_emails pe ON pe.person_id = p.id
     WHERE p.primary_email = v_email
        OR pe.email = v_email
     ORDER BY p.created_at ASC
     LIMIT 1;
  END IF;

  IF person_id IS NOT NULL THEN
    created := false;
    RETURN NEXT;
    RETURN;
  END IF;

  IF NOT should_create_person THEN
    created := false;
    RETURN NEXT;
    RETURN;
  END IF;

  INSERT INTO people (full_name, primary_email, metadata)
  VALUES (
    normalized_name,
    v_email,
    coalesce(metadata, '{}'::jsonb) || jsonb_build_object(
      'import_guardrail', jsonb_build_object(
        'source_slug', source_slug,
        'raw_name', raw_name,
        'normalized_name', normalized_name
      )
    )
  )
  RETURNING id INTO person_id;

  INSERT INTO person_emails (person_id, email, label, is_primary, source_id)
  VALUES (person_id, v_email, 'work', true, v_source_id)
  ON CONFLICT ON CONSTRAINT person_emails_person_id_email_key DO NOTHING;

  IF v_external_id IS NOT NULL THEN
    INSERT INTO external_identities (
      entity_type,
      entity_id,
      source_id,
      kind,
      external_id,
      metadata
    )
    VALUES (
      'person',
      person_id,
      v_source_id,
      v_external_kind,
      v_external_id,
      jsonb_build_object('raw_name', raw_name, 'email', v_email::text)
    )
    ON CONFLICT ON CONSTRAINT external_identities_source_id_kind_external_id_key DO NOTHING;
  END IF;

  created := true;
  RETURN NEXT;
END;
$$;

COMMENT ON FUNCTION crm_import_person_from_email(text, text, text, text, text, jsonb)
IS 'Safe email/contact import helper: resolves existing people, normalizes trusted display names, and refuses to create people for machine senders or low-quality names.';

CREATE OR REPLACE VIEW suspect_people_imports AS
SELECT
  p.id,
  p.full_name,
  p.primary_email,
  assessment.normalized_name,
  assessment.reason_codes,
  p.created_at,
  p.updated_at
FROM people p
CROSS JOIN LATERAL crm_assess_person_import(p.full_name, p.primary_email::text) AS assessment
WHERE p.archived_at IS NULL
  AND NOT assessment.should_create_person;

COMMENT ON VIEW suspect_people_imports
IS 'Active people that would fail the current email/contact import guardrails; review before cleanup or archival.';

-- Down Migration

DROP VIEW IF EXISTS suspect_people_imports;
DROP FUNCTION IF EXISTS crm_import_person_from_email(text, text, text, text, text, jsonb);
DROP FUNCTION IF EXISTS crm_assess_person_import(text, text);
DROP FUNCTION IF EXISTS crm_is_machine_email(text);
