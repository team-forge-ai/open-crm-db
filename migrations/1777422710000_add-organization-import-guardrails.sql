-- Up Migration

CREATE OR REPLACE FUNCTION crm_normalize_import_domain(raw_domain text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT nullif(
    regexp_replace(
      regexp_replace(
        regexp_replace(
          regexp_replace(
            regexp_replace(lower(btrim(coalesce(raw_domain, ''))), '^[a-z][a-z0-9+.-]*://', ''),
            '^[^@/]+@',
            ''
          ),
          '[:/].*$',
          ''
        ),
        '^www[.]',
        ''
      ),
      '^[.]+|[.]+$',
      '',
      'g'
    ),
    ''
  );
$$;

COMMENT ON FUNCTION crm_normalize_import_domain(text)
IS 'Normalizes an imported domain or URL-like value to a lowercase bare domain for CRM import guardrails.';

CREATE OR REPLACE FUNCTION crm_registrable_import_domain(raw_domain text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  WITH normalized AS (
    SELECT crm_normalize_import_domain(raw_domain) AS domain_text
  ),
  labels AS (
    SELECT
      domain_text,
      string_to_array(domain_text, '.') AS parts
    FROM normalized
    WHERE domain_text IS NOT NULL
  ),
  suffix AS (
    SELECT
      domain_text,
      parts,
      cardinality(parts) AS part_count,
      CASE
        WHEN cardinality(parts) >= 3
          AND (parts[cardinality(parts) - 1] || '.' || parts[cardinality(parts)]) = ANY (ARRAY[
            'ac.uk',
            'ac.za',
            'co.in',
            'co.jp',
            'co.kr',
            'co.nz',
            'co.uk',
            'co.za',
            'com.ar',
            'com.au',
            'com.br',
            'com.co',
            'com.mx',
            'com.pe',
            'com.ph',
            'com.sg',
            'com.tr',
            'edu.au',
            'gov.uk',
            'gov.za',
            'net.au',
            'org.au',
            'org.uk',
            'org.za'
          ])
        THEN 3
        ELSE 2
      END AS registrable_label_count
    FROM labels
  )
  SELECT CASE
    WHEN domain_text IS NULL THEN NULL
    WHEN part_count <= registrable_label_count THEN domain_text
    ELSE array_to_string(parts[(part_count - registrable_label_count + 1):part_count], '.')
  END
  FROM suffix;
$$;

COMMENT ON FUNCTION crm_registrable_import_domain(text)
IS 'Returns a best-effort registrable/root domain for imported domains, including common multi-label public suffixes.';

CREATE OR REPLACE FUNCTION crm_assess_organization_domain_import(
  source_slug text,
  raw_name text,
  raw_domain text,
  email text DEFAULT NULL
)
RETURNS TABLE (
  normalized_name text,
  normalized_domain text,
  registrable_domain text,
  should_create_organization boolean,
  should_link_registrable_organization boolean,
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
      crm_normalize_import_domain(raw_domain) AS domain_text,
      nullif(lower(btrim(email)), '') AS email_text,
      nullif(lower(btrim(source_slug)), '') AS source_text
  ),
  domains AS (
    SELECT
      cleaned_name,
      domain_text,
      crm_registrable_import_domain(domain_text) AS root_domain,
      email_text,
      source_text
    FROM cleaned
  ),
  signals AS (
    SELECT
      cleaned_name,
      domain_text,
      root_domain,
      source_text,
      domain_text IS NULL
        OR domain_text !~ '^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?([.][a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$' AS invalid_domain,
      COALESCE(crm_is_machine_email(email_text), false) AS machine_email,
      domain_text = ANY (ARRAY[
        'aol.com',
        'gmail.com',
        'googlemail.com',
        'hotmail.com',
        'icloud.com',
        'live.com',
        'me.com',
        'msn.com',
        'outlook.com',
        'proton.me',
        'protonmail.com',
        'yahoo.com'
      ]) AS public_email_domain,
      COALESCE(domain_text <> root_domain, false) AS true_subdomain,
      COALESCE(
        domain_text ~ '(^|[.])(hubspotemail[.]net|bnc[.]salesforce[.]com|customer[.]io|zendesk[.]com|jitbit[.]com|judge[.]me|luma-mail[.]com|pandadoc[.]net)$'
        OR domain_text ~ '(^|[.])(bounce|bounces|mail-bounces|email|notification|notifications|unsubscribe|noreply|no-reply|mg|em[0-9]+|marketing|reminder|updates)[.]'
        OR domain_text ~ '^e[.]',
        false
      ) AS email_infrastructure_domain,
      COALESCE(source_text = ANY (ARRAY['gmail', 'google_calendar', 'google_meet']), false) AS untrusted_email_source
    FROM domains
  ),
  reasons AS (
    SELECT
      cleaned_name,
      domain_text,
      root_domain,
      true_subdomain,
      array_remove(ARRAY[
        CASE WHEN invalid_domain THEN 'invalid_domain' END,
        CASE WHEN machine_email THEN 'machine_email' END,
        CASE WHEN public_email_domain THEN 'public_email_domain' END,
        CASE WHEN email_infrastructure_domain THEN 'email_infrastructure_domain' END,
        CASE WHEN untrusted_email_source AND true_subdomain THEN 'untrusted_email_subdomain' END
      ], NULL) AS reason_codes
    FROM signals
  )
  SELECT
    cleaned_name AS normalized_name,
    domain_text AS normalized_domain,
    root_domain AS registrable_domain,
    cardinality(reason_codes) = 0 AS should_create_organization,
    true_subdomain AS should_link_registrable_organization,
    reason_codes
  FROM reasons;
$$;

COMMENT ON FUNCTION crm_assess_organization_domain_import(text, text, text, text)
IS 'Assesses whether an untrusted domain-derived import should create a CRM organization; email-source subdomains are routed to root-domain linking or manual review.';

CREATE OR REPLACE FUNCTION crm_import_organization_from_email(
  source_slug text,
  raw_name text,
  email text,
  external_kind text DEFAULT 'email_domain',
  external_id text DEFAULT NULL,
  metadata jsonb DEFAULT '{}'::jsonb
)
RETURNS TABLE (
  organization_id uuid,
  created boolean,
  normalized_name text,
  normalized_domain text,
  registrable_domain text,
  should_create_organization boolean,
  should_link_registrable_organization boolean,
  reason_codes text[]
)
LANGUAGE plpgsql
AS $$
DECLARE
  v_source_id uuid;
  v_email text := nullif(lower(btrim(email)), '');
  v_domain text := CASE
    WHEN v_email ~ '^[^@[:space:]]+@[^@[:space:]]+[.][^@[:space:]]+$'
    THEN split_part(v_email, '@', 2)
    ELSE NULL
  END;
  v_external_kind text := coalesce(nullif(btrim(external_kind), ''), 'email_domain');
  v_external_id text := nullif(btrim(coalesce(external_id, v_domain)), '');
  v_insert_name text;
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
    assessment.normalized_domain,
    assessment.registrable_domain,
    assessment.should_create_organization,
    assessment.should_link_registrable_organization,
    assessment.reason_codes
    INTO
      normalized_name,
      normalized_domain,
      registrable_domain,
      should_create_organization,
      should_link_registrable_organization,
      reason_codes
    FROM crm_assess_organization_domain_import(source_slug, raw_name, v_domain, v_email) AS assessment;

  IF v_external_id IS NOT NULL THEN
    SELECT ei.entity_id
      INTO organization_id
      FROM external_identities ei
     WHERE ei.source_id = v_source_id
       AND ei.kind = v_external_kind
       AND ei.external_id = v_external_id
       AND ei.entity_type = 'organization'
     LIMIT 1;
  END IF;

  IF organization_id IS NULL AND normalized_domain IS NOT NULL THEN
    SELECT o.id
      INTO organization_id
      FROM organizations o
     WHERE o.domain = normalized_domain::citext
     ORDER BY o.archived_at NULLS FIRST, o.created_at ASC
     LIMIT 1;
  END IF;

  IF organization_id IS NULL
     AND should_link_registrable_organization
     AND registrable_domain IS NOT NULL THEN
    SELECT o.id
      INTO organization_id
      FROM organizations o
     WHERE o.domain = registrable_domain::citext
       AND o.archived_at IS NULL
     ORDER BY o.created_at ASC
     LIMIT 1;
  END IF;

  IF organization_id IS NOT NULL THEN
    created := false;
    RETURN NEXT;
    RETURN;
  END IF;

  IF NOT should_create_organization THEN
    created := false;
    RETURN NEXT;
    RETURN;
  END IF;

  v_insert_name := coalesce(
    normalized_name,
    initcap(replace(split_part(normalized_domain, '.', 1), '-', ' '))
  );

  INSERT INTO organizations (name, domain, website, metadata)
  VALUES (
    v_insert_name,
    normalized_domain::citext,
    'https://' || normalized_domain,
    coalesce(metadata, '{}'::jsonb) || jsonb_build_object(
      'import_guardrail',
      jsonb_build_object(
        'source_slug', source_slug,
        'raw_name', raw_name,
        'email', v_email,
        'normalized_domain', normalized_domain,
        'registrable_domain', registrable_domain
      )
    )
  )
  RETURNING id INTO organization_id;

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
      'organization',
      organization_id,
      v_source_id,
      v_external_kind,
      v_external_id,
      jsonb_build_object('raw_name', raw_name, 'email', v_email, 'domain', normalized_domain)
    )
    ON CONFLICT ON CONSTRAINT external_identities_source_id_kind_external_id_key DO NOTHING;
  END IF;

  created := true;
  RETURN NEXT;
END;
$$;

COMMENT ON FUNCTION crm_import_organization_from_email(text, text, text, text, text, jsonb)
IS 'Safe email-domain import helper: resolves existing organizations, links subdomains to an existing root organization when possible, and refuses to create organizations for untrusted email-source subdomains or delivery infrastructure.';

CREATE OR REPLACE VIEW suspect_organization_imports AS
SELECT
  o.id,
  o.name,
  o.domain,
  assessment.registrable_domain,
  assessment.reason_codes,
  source_match.source_slug,
  o.created_at,
  o.updated_at
FROM organizations o
LEFT JOIN LATERAL (
  SELECT s.slug AS source_slug
    FROM external_identities ei
    JOIN sources s ON s.id = ei.source_id
   WHERE ei.entity_type = 'organization'
     AND ei.entity_id = o.id
   ORDER BY (s.slug = 'gmail') DESC, ei.created_at ASC
   LIMIT 1
) source_match ON true
CROSS JOIN LATERAL crm_assess_organization_domain_import(
  coalesce(source_match.source_slug, 'manual'),
  o.name,
  o.domain::text,
  NULL
) AS assessment
WHERE o.archived_at IS NULL
  AND NOT assessment.should_create_organization;

COMMENT ON VIEW suspect_organization_imports
IS 'Active organizations that would fail current email-domain import guardrails; review before cleanup, merge, or archival.';

-- Down Migration

DROP VIEW IF EXISTS suspect_organization_imports;
DROP FUNCTION IF EXISTS crm_import_organization_from_email(text, text, text, text, text, jsonb);
DROP FUNCTION IF EXISTS crm_assess_organization_domain_import(text, text, text, text);
DROP FUNCTION IF EXISTS crm_registrable_import_domain(text);
DROP FUNCTION IF EXISTS crm_normalize_import_domain(text);
