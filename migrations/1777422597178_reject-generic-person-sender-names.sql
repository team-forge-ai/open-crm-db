-- Up Migration

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
          WHEN route_stripped_name ~* '^[^,]+,[[:space:]]*(jr[.]?|sr[.]?|ii|iii|iv|m[.]?d[.]?|d[.]?o[.]?|ph[.]?d[.]?)$'
            THEN route_stripped_name
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
        normalized_name ~* '^(the[[:space:]]+)?[[:alnum:]&.'' -]+[[:space:]]+(accounting|admin|billing|concierge|customer[[:space:]]+service|customer[[:space:]]+success|finance|help|marketing|notifications?|office|operations|ops|reminders?|sales|success|support|team)$'
        OR normalized_name ~* '^(accounting|admin|billing|concierge|customer[[:space:]]+service|customer[[:space:]]+success|finance|help|info|marketing|notifications?|office|operations|ops|reminders?|sales|success|support|team)([[:space:]]+team)?$',
        false
      ) AS generic_sender_name,
      COALESCE(
        regexp_replace(
          normalized_name,
          '[,]?[[:space:]]+(Jr[.]?|Sr[.]?|II|III|IV|M[.]?D[.]?|D[.]?O[.]?|Ph[.]?D[.]?)$',
          '',
          'i'
        ) ~ '^([[:upper:]][[:alpha:]''.-]*|[[:upper:]][.]?)([[:space:]]+(de|del|der|van|von|da|di|la|le|du|[[:upper:]][[:alpha:]''.-]*|[[:upper:]][.]?)){1,5}$',
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
        CASE WHEN generic_sender_name THEN 'generic_sender_name' END,
        CASE
          WHEN NOT missing_name
            AND NOT email_as_name
            AND NOT numeric_or_token_noise
            AND NOT generic_sender_name
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

-- Down Migration

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
          WHEN route_stripped_name ~* '^[^,]+,[[:space:]]*(jr[.]?|sr[.]?|ii|iii|iv|m[.]?d[.]?|d[.]?o[.]?|ph[.]?d[.]?)$'
            THEN route_stripped_name
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
        regexp_replace(
          normalized_name,
          '[,]?[[:space:]]+(Jr[.]?|Sr[.]?|II|III|IV|M[.]?D[.]?|D[.]?O[.]?|Ph[.]?D[.]?)$',
          '',
          'i'
        ) ~ '^([[:upper:]][[:alpha:]''.-]*|[[:upper:]][.]?)([[:space:]]+(de|del|der|van|von|da|di|la|le|du|[[:upper:]][[:alpha:]''.-]*|[[:upper:]][.]?)){1,5}$',
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
