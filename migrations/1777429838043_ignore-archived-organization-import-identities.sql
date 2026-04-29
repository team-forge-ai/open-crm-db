-- Up Migration

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
      JOIN organizations o ON o.id = ei.entity_id AND o.archived_at IS NULL
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
       AND o.archived_at IS NULL
     ORDER BY o.created_at ASC
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
IS 'Safe email-domain import helper: resolves existing active organizations, links subdomains to an existing active root organization when possible, and refuses to create organizations for untrusted email-source subdomains or delivery infrastructure.';

-- Down Migration

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
