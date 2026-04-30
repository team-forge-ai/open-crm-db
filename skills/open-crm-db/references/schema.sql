--
-- PostgreSQL database dump
--


-- Dumped from database version 18.3 (Homebrew)
-- Dumped by pg_dump version 18.3 (Homebrew)


--
-- Name: citext; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS citext WITH SCHEMA public;


--
-- Name: EXTENSION citext; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION citext IS 'data type for case-insensitive character strings';


--
-- Name: pg_trgm; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pg_trgm WITH SCHEMA public;


--
-- Name: EXTENSION pg_trgm; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION pg_trgm IS 'text similarity measurement and index searching based on trigrams';


--
-- Name: pgcrypto; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA public;


--
-- Name: EXTENSION pgcrypto; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION pgcrypto IS 'cryptographic functions';


--
-- Name: vector; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS vector WITH SCHEMA public;


--
-- Name: EXTENSION vector; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION vector IS 'vector data type and ivfflat and hnsw access methods';


--
-- Name: ai_note_kind; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.ai_note_kind AS ENUM (
    'summary',
    'action_items',
    'highlights',
    'sentiment',
    'coaching',
    'risk',
    'other'
);


--
-- Name: entity_type; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.entity_type AS ENUM (
    'organization',
    'person'
);


--
-- Name: interaction_direction; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.interaction_direction AS ENUM (
    'inbound',
    'outbound',
    'internal'
);


--
-- Name: interaction_type; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.interaction_type AS ENUM (
    'call',
    'meeting',
    'email',
    'message',
    'note',
    'event',
    'document',
    'other'
);


--
-- Name: participant_role; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.participant_role AS ENUM (
    'host',
    'attendee',
    'sender',
    'recipient',
    'cc',
    'bcc',
    'mentioned',
    'observer'
);


--
-- Name: person_role_family; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.person_role_family AS ENUM (
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


--
-- Name: person_seniority; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.person_seniority AS ENUM (
    'executive',
    'director',
    'manager',
    'individual_contributor',
    'advisor',
    'contractor',
    'other',
    'unknown'
);


--
-- Name: relationship_edge_type; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.relationship_edge_type AS ENUM (
    'introduced_by',
    'reports_to',
    'works_with',
    'mentor_of',
    'investor_of',
    'customer_of',
    'partner_of',
    'parent_org_of',
    'subsidiary_of',
    'other'
);


--
-- Name: transcript_format; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.transcript_format AS ENUM (
    'plain_text',
    'srt',
    'vtt',
    'speaker_turns_jsonl',
    'other'
);


--
-- Name: crm_affiliations_sync_person_current(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.crm_affiliations_sync_person_current() RETURNS trigger
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


--
-- Name: crm_assess_organization_domain_import(text, text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.crm_assess_organization_domain_import(source_slug text, raw_name text, raw_domain text, email text DEFAULT NULL::text) RETURNS TABLE(normalized_name text, normalized_domain text, registrable_domain text, should_create_organization boolean, should_link_registrable_organization boolean, reason_codes text[])
    LANGUAGE sql IMMUTABLE
    AS $_$
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
$_$;


--
-- Name: FUNCTION crm_assess_organization_domain_import(source_slug text, raw_name text, raw_domain text, email text); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.crm_assess_organization_domain_import(source_slug text, raw_name text, raw_domain text, email text) IS 'Assesses whether an untrusted domain-derived import should create a CRM organization; email-source subdomains are routed to root-domain linking or manual review.';


--
-- Name: crm_assess_person_import(text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.crm_assess_person_import(raw_name text, email text) RETURNS TABLE(normalized_name text, should_create_person boolean, reason_codes text[])
    LANGUAGE sql IMMUTABLE
    AS $_$
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
$_$;


--
-- Name: FUNCTION crm_assess_person_import(raw_name text, email text); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.crm_assess_person_import(raw_name text, email text) IS 'Normalizes an email display name and returns whether an untrusted import should create a CRM person for that name/email pair.';


--
-- Name: crm_check_task_project_team(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.crm_check_task_project_team() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF NEW.project_id IS NULL THEN
    RETURN NEW;
  END IF;

  IF NOT EXISTS (
    SELECT 1
      FROM task_project_teams tpt
     WHERE tpt.project_id = NEW.project_id
       AND tpt.team_id = NEW.team_id
  ) THEN
    RAISE EXCEPTION 'task project % is not linked to task team %', NEW.project_id, NEW.team_id
      USING ERRCODE = '23514';
  END IF;

  RETURN NEW;
END;
$$;


--
-- Name: crm_import_organization_from_email(text, text, text, text, text, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.crm_import_organization_from_email(source_slug text, raw_name text, email text, external_kind text DEFAULT 'email_domain'::text, external_id text DEFAULT NULL::text, metadata jsonb DEFAULT '{}'::jsonb) RETURNS TABLE(organization_id uuid, created boolean, normalized_name text, normalized_domain text, registrable_domain text, should_create_organization boolean, should_link_registrable_organization boolean, reason_codes text[])
    LANGUAGE plpgsql
    AS $_$
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
$_$;


--
-- Name: FUNCTION crm_import_organization_from_email(source_slug text, raw_name text, email text, external_kind text, external_id text, metadata jsonb); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.crm_import_organization_from_email(source_slug text, raw_name text, email text, external_kind text, external_id text, metadata jsonb) IS 'Safe email-domain import helper: resolves existing active organizations, links subdomains to an existing active root organization when possible, and refuses to create organizations for untrusted email-source subdomains or delivery infrastructure.';


--
-- Name: crm_import_person_from_email(text, text, text, text, text, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.crm_import_person_from_email(source_slug text, raw_name text, email text, external_kind text DEFAULT 'contact'::text, external_id text DEFAULT NULL::text, metadata jsonb DEFAULT '{}'::jsonb) RETURNS TABLE(person_id uuid, created boolean, normalized_name text, should_create_person boolean, reason_codes text[])
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


--
-- Name: FUNCTION crm_import_person_from_email(source_slug text, raw_name text, email text, external_kind text, external_id text, metadata jsonb); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.crm_import_person_from_email(source_slug text, raw_name text, email text, external_kind text, external_id text, metadata jsonb) IS 'Safe email/contact import helper: resolves existing people, normalizes trusted display names, and refuses to create people for machine senders or low-quality names.';


--
-- Name: crm_is_machine_email(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.crm_is_machine_email(email text) RETURNS boolean
    LANGUAGE sql IMMUTABLE
    AS $_$
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
$_$;


--
-- Name: FUNCTION crm_is_machine_email(email text); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.crm_is_machine_email(email text) IS 'Returns true for generic inboxes, notification senders, bounce addresses, and high-entropy generated email localparts that should not create CRM people.';


--
-- Name: crm_normalize_import_domain(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.crm_normalize_import_domain(raw_domain text) RETURNS text
    LANGUAGE sql IMMUTABLE
    AS $_$
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
$_$;


--
-- Name: FUNCTION crm_normalize_import_domain(raw_domain text); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.crm_normalize_import_domain(raw_domain text) IS 'Normalizes an imported domain or URL-like value to a lowercase bare domain for CRM import guardrails.';


--
-- Name: crm_prevent_task_project_team_orphan(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.crm_prevent_task_project_team_orphan() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF EXISTS (
    SELECT 1
      FROM tasks t
     WHERE t.project_id = OLD.project_id
       AND t.team_id = OLD.team_id
       AND t.archived_at IS NULL
  ) THEN
    RAISE EXCEPTION 'task project/team link is still used by active tasks'
      USING ERRCODE = '23503';
  END IF;

  RETURN OLD;
END;
$$;


--
-- Name: crm_registrable_import_domain(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.crm_registrable_import_domain(raw_domain text) RETURNS text
    LANGUAGE sql IMMUTABLE
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


--
-- Name: FUNCTION crm_registrable_import_domain(raw_domain text); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.crm_registrable_import_domain(raw_domain text) IS 'Returns a best-effort registrable/root domain for imported domains, including common multi-label public suffixes.';


--
-- Name: crm_search_text(text[]); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.crm_search_text(VARIADIC parts text[]) RETURNS text
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    AS $$
  SELECT COALESCE(array_to_string(parts, ' ', ''), '');
$$;


--
-- Name: crm_set_updated_at(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.crm_set_updated_at() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;


--
-- Name: crm_sync_person_current_affiliation(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.crm_sync_person_current_affiliation(target_person_id uuid) RETURNS void
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


--
-- Name: match_full_text_embeddings(text, integer, text[]); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.match_full_text_embeddings(search_query text, match_count integer DEFAULT 10, filter_target_types text[] DEFAULT NULL::text[]) RETURNS TABLE(id uuid, target_type text, target_id uuid, chunk_index integer, content text, embedding_provider text, embedding_model text, embedding_model_version text, metadata jsonb, rank real)
    LANGUAGE sql STABLE
    AS $$
  WITH query AS (
    SELECT websearch_to_tsquery('english', COALESCE(search_query, '')) AS tsq
  )
  SELECT
    se.id,
    se.target_type,
    se.target_id,
    se.chunk_index,
    se.content,
    se.embedding_provider,
    se.embedding_model,
    se.embedding_model_version,
    se.metadata,
    ts_rank_cd(se.search_tsv, query.tsq, 32) AS rank
  FROM semantic_embeddings se
  CROSS JOIN query
  WHERE se.archived_at IS NULL
    AND se.search_tsv @@ query.tsq
    AND (
      filter_target_types IS NULL
      OR se.target_type = ANY(filter_target_types)
    )
  ORDER BY rank DESC, se.embedded_at DESC
  LIMIT LEAST(GREATEST(COALESCE(match_count, 10), 1), 100);
$$;


--
-- Name: match_semantic_embeddings(public.vector, integer, text[]); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.match_semantic_embeddings(query_embedding public.vector, match_count integer DEFAULT 10, filter_target_types text[] DEFAULT NULL::text[]) RETURNS TABLE(id uuid, target_type text, target_id uuid, chunk_index integer, content text, embedding_provider text, embedding_model text, embedding_model_version text, metadata jsonb, similarity double precision)
    LANGUAGE sql STABLE
    AS $$
  SELECT
    se.id,
    se.target_type,
    se.target_id,
    se.chunk_index,
    se.content,
    se.embedding_provider,
    se.embedding_model,
    se.embedding_model_version,
    se.metadata,
    1 - (se.embedding <=> query_embedding) AS similarity
  FROM semantic_embeddings se
  WHERE se.archived_at IS NULL
    AND (
      filter_target_types IS NULL
      OR se.target_type = ANY(filter_target_types)
    )
  ORDER BY se.embedding <=> query_embedding
  LIMIT LEAST(GREATEST(COALESCE(match_count, 10), 1), 100);
$$;


--
-- Name: search_crm_full_text(text, integer, text[]); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.search_crm_full_text(search_query text, match_count integer DEFAULT 20, filter_target_types text[] DEFAULT NULL::text[]) RETURNS TABLE(target_type text, target_id uuid, title text, subtitle text, occurred_at timestamp with time zone, rank real, headline text, metadata jsonb)
    LANGUAGE sql STABLE
    AS $$
  WITH query AS (
    SELECT
      websearch_to_tsquery('english', COALESCE(search_query, '')) AS tsq,
      NULLIF(lower(btrim(COALESCE(search_query, ''))), '') AS normalized
  ),
  direct AS (
    SELECT
      'organization'::text AS target_type,
      o.id AS target_id,
      o.name AS title,
      concat_ws(' / ', o.domain::text, o.industry, o.hq_country) AS subtitle,
      o.updated_at AS occurred_at,
      (
        CASE
          WHEN lower(o.name) = query.normalized THEN 20
          WHEN lower(o.legal_name) = query.normalized THEN 18
          WHEN lower(o.domain::text) = query.normalized THEN 16
          WHEN starts_with(lower(o.name), query.normalized) THEN 12
          WHEN starts_with(lower(o.legal_name), query.normalized) THEN 10
          WHEN starts_with(lower(o.domain::text), query.normalized) THEN 9
          ELSE 5
        END
      )::real AS rank,
      ts_headline(
        'english',
        concat_ws(' ', o.name, o.legal_name, o.domain::text, o.website),
        query.tsq,
        'MaxWords=20, MinWords=4, MaxFragments=1'
      ) AS headline,
      o.metadata AS metadata
    FROM organizations o
    CROSS JOIN query
    WHERE query.normalized IS NOT NULL
      AND o.archived_at IS NULL
      AND (filter_target_types IS NULL OR 'organization' = ANY(filter_target_types))
      AND (
        lower(o.name) = query.normalized
        OR lower(o.legal_name) = query.normalized
        OR lower(o.domain::text) = query.normalized
        OR starts_with(lower(o.name), query.normalized)
        OR starts_with(lower(o.legal_name), query.normalized)
        OR starts_with(lower(o.domain::text), query.normalized)
        OR position(query.normalized in lower(COALESCE(o.website, ''))) > 0
      )

    UNION ALL

    SELECT
      'person'::text AS target_type,
      p.id AS target_id,
      p.full_name AS title,
      concat_ws(' / ', p.headline, p.city, p.country) AS subtitle,
      p.updated_at AS occurred_at,
      (
        CASE
          WHEN lower(p.full_name) = query.normalized THEN 18
          WHEN lower(p.display_name) = query.normalized THEN 17
          WHEN lower(p.preferred_name) = query.normalized THEN 16
          WHEN lower(p.primary_email::text) = query.normalized THEN 15
          WHEN starts_with(lower(p.full_name), query.normalized) THEN 10
          WHEN starts_with(lower(p.display_name), query.normalized) THEN 9
          WHEN starts_with(lower(p.primary_email::text), query.normalized) THEN 8
          ELSE 4
        END
      )::real AS rank,
      ts_headline(
        'english',
        concat_ws(' ', p.full_name, p.display_name, p.preferred_name, p.primary_email::text, p.website),
        query.tsq,
        'MaxWords=20, MinWords=4, MaxFragments=1'
      ) AS headline,
      p.metadata AS metadata
    FROM people p
    CROSS JOIN query
    WHERE query.normalized IS NOT NULL
      AND p.archived_at IS NULL
      AND (filter_target_types IS NULL OR 'person' = ANY(filter_target_types))
      AND (
        lower(p.full_name) = query.normalized
        OR lower(p.display_name) = query.normalized
        OR lower(p.preferred_name) = query.normalized
        OR lower(p.primary_email::text) = query.normalized
        OR starts_with(lower(p.full_name), query.normalized)
        OR starts_with(lower(p.display_name), query.normalized)
        OR starts_with(lower(p.preferred_name), query.normalized)
        OR starts_with(lower(p.primary_email::text), query.normalized)
        OR position(query.normalized in lower(COALESCE(p.website, ''))) > 0
      )

    UNION ALL

    SELECT
      'interaction'::text AS target_type,
      i.id AS target_id,
      COALESCE(i.subject, i.type::text) AS title,
      concat_ws(' / ', i.type::text, i.direction::text, i.location) AS subtitle,
      i.occurred_at,
      (
        CASE
          WHEN lower(i.subject) = query.normalized THEN 8
          WHEN starts_with(lower(i.subject), query.normalized) THEN 5
          ELSE 3
        END
      )::real AS rank,
      ts_headline(
        'english',
        COALESCE(i.subject, ''),
        query.tsq,
        'MaxWords=20, MinWords=4, MaxFragments=1'
      ) AS headline,
      i.metadata AS metadata
    FROM interactions i
    CROSS JOIN query
    WHERE query.normalized IS NOT NULL
      AND i.archived_at IS NULL
      AND (filter_target_types IS NULL OR 'interaction' = ANY(filter_target_types))
      AND (
        lower(i.subject) = query.normalized
        OR starts_with(lower(i.subject), query.normalized)
      )

    UNION ALL

    SELECT
      'document'::text AS target_type,
      d.id AS target_id,
      d.title,
      concat_ws(' / ', d.document_type, d.source_path) AS subtitle,
      COALESCE(d.occurred_at, d.authored_at, d.created_at) AS occurred_at,
      (
        CASE
          WHEN lower(d.title) = query.normalized THEN 8
          WHEN starts_with(lower(d.title), query.normalized) THEN 5
          ELSE 3
        END
      )::real AS rank,
      ts_headline(
        'english',
        concat_ws(' ', d.title, d.source_path),
        query.tsq,
        'MaxWords=20, MinWords=4, MaxFragments=1'
      ) AS headline,
      d.metadata AS metadata
    FROM documents d
    CROSS JOIN query
    WHERE query.normalized IS NOT NULL
      AND d.archived_at IS NULL
      AND (filter_target_types IS NULL OR 'document' = ANY(filter_target_types))
      AND (
        lower(d.title) = query.normalized
        OR starts_with(lower(d.title), query.normalized)
      )

    UNION ALL

    SELECT
      'organization_research_profile'::text AS target_type,
      orp.id AS target_id,
      COALESCE(orp.canonical_name, orp.domain::text, 'Organization research profile') AS title,
      concat_ws(' / ', orp.category, orp.partnership_fit) AS subtitle,
      orp.researched_at AS occurred_at,
      (
        CASE
          WHEN lower(orp.canonical_name) = query.normalized THEN 14
          WHEN lower(orp.domain::text) = query.normalized THEN 13
          WHEN starts_with(lower(orp.canonical_name), query.normalized) THEN 8
          WHEN starts_with(lower(orp.domain::text), query.normalized) THEN 7
          ELSE 4
        END
      )::real AS rank,
      ts_headline(
        'english',
        concat_ws(' ', orp.canonical_name, orp.domain::text, orp.website),
        query.tsq,
        'MaxWords=20, MinWords=4, MaxFragments=1'
      ) AS headline,
      jsonb_build_object(
        'organization_id', orp.organization_id,
        'source_urls', orp.source_urls
      ) AS metadata
    FROM organization_research_profiles orp
    CROSS JOIN query
    WHERE query.normalized IS NOT NULL
      AND (filter_target_types IS NULL OR 'organization_research_profile' = ANY(filter_target_types))
      AND (
        lower(orp.canonical_name) = query.normalized
        OR lower(orp.domain::text) = query.normalized
        OR starts_with(lower(orp.canonical_name), query.normalized)
        OR starts_with(lower(orp.domain::text), query.normalized)
        OR position(query.normalized in lower(COALESCE(orp.website, ''))) > 0
      )

    UNION ALL

    SELECT
      'partnership'::text AS target_type,
      p.id AS target_id,
      p.name AS title,
      concat_ws(' / ', p.partnership_type, p.stage, p.priority) AS subtitle,
      COALESCE(p.launched_at, p.signed_at, p.updated_at) AS occurred_at,
      (
        CASE
          WHEN lower(p.name) = query.normalized THEN 12
          WHEN starts_with(lower(p.name), query.normalized) THEN 7
          ELSE 4
        END
      )::real AS rank,
      ts_headline(
        'english',
        p.name,
        query.tsq,
        'MaxWords=20, MinWords=4, MaxFragments=1'
      ) AS headline,
      p.metadata AS metadata
    FROM partnerships p
    CROSS JOIN query
    WHERE query.normalized IS NOT NULL
      AND p.archived_at IS NULL
      AND (filter_target_types IS NULL OR 'partnership' = ANY(filter_target_types))
      AND (
        lower(p.name) = query.normalized
        OR starts_with(lower(p.name), query.normalized)
      )

    UNION ALL

    SELECT
      'partnership_service'::text AS target_type,
      ps.id AS target_id,
      ps.name AS title,
      concat_ws(' / ', ps.service_type, ps.status) AS subtitle,
      ps.updated_at AS occurred_at,
      (
        CASE
          WHEN lower(ps.name) = query.normalized THEN 10
          WHEN starts_with(lower(ps.name), query.normalized) THEN 6
          ELSE 3
        END
      )::real AS rank,
      ts_headline(
        'english',
        ps.name,
        query.tsq,
        'MaxWords=20, MinWords=4, MaxFragments=1'
      ) AS headline,
      ps.metadata AS metadata
    FROM partnership_services ps
    CROSS JOIN query
    WHERE query.normalized IS NOT NULL
      AND ps.archived_at IS NULL
      AND (filter_target_types IS NULL OR 'partnership_service' = ANY(filter_target_types))
      AND (
        lower(ps.name) = query.normalized
        OR starts_with(lower(ps.name), query.normalized)
      )

    UNION ALL

    SELECT
      'partnership_integration'::text AS target_type,
      pi.id AS target_id,
      pi.integration_type AS title,
      concat_ws(' / ', pi.status, pi.sync_direction) AS subtitle,
      COALESCE(pi.last_sync_at, pi.updated_at) AS occurred_at,
      (
        CASE
          WHEN lower(pi.integration_type) = query.normalized THEN 10
          WHEN starts_with(lower(pi.integration_type), query.normalized) THEN 6
          ELSE 3
        END
      )::real AS rank,
      ts_headline(
        'english',
        pi.integration_type,
        query.tsq,
        'MaxWords=20, MinWords=4, MaxFragments=1'
      ) AS headline,
      pi.metadata AS metadata
    FROM partnership_integrations pi
    CROSS JOIN query
    WHERE query.normalized IS NOT NULL
      AND pi.archived_at IS NULL
      AND (filter_target_types IS NULL OR 'partnership_integration' = ANY(filter_target_types))
      AND (
        lower(pi.integration_type) = query.normalized
        OR starts_with(lower(pi.integration_type), query.normalized)
      )

    UNION ALL

    SELECT
      'team_member'::text AS target_type,
      tm.id AS target_id,
      tm.name AS title,
      concat_ws(' / ', tm.title, tm.email::text) AS subtitle,
      tm.updated_at AS occurred_at,
      (
        CASE
          WHEN lower(tm.name) = query.normalized THEN 18
          WHEN lower(tm.email::text) = query.normalized THEN 15
          WHEN starts_with(lower(tm.name), query.normalized) THEN 10
          WHEN starts_with(lower(tm.email::text), query.normalized) THEN 8
          ELSE 4
        END
      )::real AS rank,
      ts_headline(
        'english',
        concat_ws(' ', tm.name, tm.title, tm.email::text),
        query.tsq,
        'MaxWords=20, MinWords=4, MaxFragments=1'
      ) AS headline,
      tm.metadata AS metadata
    FROM team_members tm
    CROSS JOIN query
    WHERE query.normalized IS NOT NULL
      AND tm.archived_at IS NULL
      AND (filter_target_types IS NULL OR 'team_member' = ANY(filter_target_types))
      AND (
        lower(tm.name) = query.normalized
        OR lower(tm.email::text) = query.normalized
        OR starts_with(lower(tm.name), query.normalized)
        OR starts_with(lower(tm.email::text), query.normalized)
      )

    UNION ALL

    SELECT
      'task_project'::text AS target_type,
      tp.id AS target_id,
      tp.name AS title,
      concat_ws(' / ', tp.status_name, tp.priority_label, tp.target_date::text) AS subtitle,
      COALESCE(tp.completed_at, tp.canceled_at, tp.started_at, tp.updated_at) AS occurred_at,
      (
        CASE
          WHEN lower(tp.name) = query.normalized THEN 10
          WHEN starts_with(lower(tp.name), query.normalized) THEN 6
          ELSE 3
        END
      )::real AS rank,
      ts_headline(
        'english',
        tp.name,
        query.tsq,
        'MaxWords=20, MinWords=4, MaxFragments=1'
      ) AS headline,
      tp.metadata AS metadata
    FROM task_projects tp
    CROSS JOIN query
    WHERE query.normalized IS NOT NULL
      AND tp.archived_at IS NULL
      AND (filter_target_types IS NULL OR 'task_project' = ANY(filter_target_types))
      AND (
        lower(tp.name) = query.normalized
        OR starts_with(lower(tp.name), query.normalized)
      )

    UNION ALL

    SELECT
      'task'::text AS target_type,
      t.id AS target_id,
      COALESCE(t.source_identifier || ': ' || t.title, t.title) AS title,
      concat_ws(
        ' / ',
        tp.name,
        ts.name,
        assignee.name,
        t.priority_label,
        t.due_date::text
      ) AS subtitle,
      COALESCE(t.completed_at, t.canceled_at, t.started_at, t.source_updated_at, t.updated_at) AS occurred_at,
      (
        CASE
          WHEN lower(t.title) = query.normalized THEN 8
          WHEN lower(t.source_identifier) = query.normalized THEN 8
          WHEN starts_with(lower(t.title), query.normalized) THEN 5
          WHEN starts_with(lower(t.source_identifier), query.normalized) THEN 5
          ELSE 3
        END
      )::real AS rank,
      ts_headline(
        'english',
        concat_ws(' ', t.source_identifier, t.title),
        query.tsq,
        'MaxWords=20, MinWords=4, MaxFragments=1'
      ) AS headline,
      t.metadata || jsonb_build_object(
        'source_identifier', t.source_identifier,
        'source_url', t.source_url,
        'project_id', t.project_id,
        'status_id', t.status_id,
        'assignee_member_id', t.assignee_member_id
      ) AS metadata
    FROM tasks t
    LEFT JOIN task_projects tp ON tp.id = t.project_id
    LEFT JOIN task_statuses ts ON ts.id = t.status_id
    LEFT JOIN team_members assignee ON assignee.id = t.assignee_member_id
    CROSS JOIN query
    WHERE query.normalized IS NOT NULL
      AND t.archived_at IS NULL
      AND (filter_target_types IS NULL OR 'task' = ANY(filter_target_types))
      AND (
        lower(t.title) = query.normalized
        OR lower(t.source_identifier) = query.normalized
        OR starts_with(lower(t.title), query.normalized)
        OR starts_with(lower(t.source_identifier), query.normalized)
      )
  ),
  ranked_direct AS (
    SELECT target_type, target_id, title, subtitle, occurred_at, rank, headline, metadata
    FROM (
      SELECT
        direct.*,
        row_number() OVER (
          PARTITION BY target_type
          ORDER BY rank DESC, occurred_at DESC NULLS LAST
        ) AS direct_rank
      FROM direct
    ) rows
    WHERE direct_rank <= 3
  ),
  lexical AS (
    SELECT *
    FROM search_crm_full_text_base(search_query, 100, filter_target_types)

    UNION ALL

    SELECT
      'team_member'::text AS target_type,
      tm.id AS target_id,
      tm.name AS title,
      concat_ws(' / ', tm.title, tm.email::text) AS subtitle,
      tm.updated_at AS occurred_at,
      ts_rank_cd(tm.search_tsv, query.tsq, 32) AS rank,
      ts_headline(
        'english',
        concat_ws(' ', tm.name, tm.title, tm.email::text),
        query.tsq,
        'MaxWords=35, MinWords=8, MaxFragments=2'
      ) AS headline,
      tm.metadata AS metadata
    FROM team_members tm
    CROSS JOIN query
    WHERE tm.archived_at IS NULL
      AND (filter_target_types IS NULL OR 'team_member' = ANY(filter_target_types))
      AND tm.search_tsv @@ query.tsq

    UNION ALL

    SELECT
      'task_project'::text AS target_type,
      tp.id AS target_id,
      tp.name AS title,
      concat_ws(' / ', tp.status_name, tp.priority_label, tp.target_date::text) AS subtitle,
      COALESCE(tp.completed_at, tp.canceled_at, tp.started_at, tp.updated_at) AS occurred_at,
      ts_rank_cd(tp.search_tsv, query.tsq, 32) AS rank,
      ts_headline(
        'english',
        concat_ws(' ', tp.name, tp.summary, tp.description, tp.status_name, tp.priority_label),
        query.tsq,
        'MaxWords=35, MinWords=8, MaxFragments=2'
      ) AS headline,
      tp.metadata AS metadata
    FROM task_projects tp
    CROSS JOIN query
    WHERE tp.archived_at IS NULL
      AND (filter_target_types IS NULL OR 'task_project' = ANY(filter_target_types))
      AND tp.search_tsv @@ query.tsq

    UNION ALL

    SELECT
      'task'::text AS target_type,
      t.id AS target_id,
      COALESCE(t.source_identifier || ': ' || t.title, t.title) AS title,
      concat_ws(
        ' / ',
        tp.name,
        ts.name,
        assignee.name,
        t.priority_label,
        t.due_date::text
      ) AS subtitle,
      COALESCE(t.completed_at, t.canceled_at, t.started_at, t.source_updated_at, t.updated_at) AS occurred_at,
      ts_rank_cd(
        t.search_tsv || to_tsvector('english', crm_search_text(tp.name, ts.name, assignee.name)),
        query.tsq,
        32
      ) AS rank,
      ts_headline(
        'english',
        concat_ws(' ', t.source_identifier, t.title, left(t.description, 250000), tp.name, ts.name, assignee.name),
        query.tsq,
        'MaxWords=35, MinWords=8, MaxFragments=2'
      ) AS headline,
      t.metadata || jsonb_build_object(
        'source_identifier', t.source_identifier,
        'source_url', t.source_url,
        'project_id', t.project_id,
        'status_id', t.status_id,
        'assignee_member_id', t.assignee_member_id
      ) AS metadata
    FROM tasks t
    LEFT JOIN task_projects tp ON tp.id = t.project_id
    LEFT JOIN task_statuses ts ON ts.id = t.status_id
    LEFT JOIN team_members assignee ON assignee.id = t.assignee_member_id
    CROSS JOIN query
    WHERE t.archived_at IS NULL
      AND (filter_target_types IS NULL OR 'task' = ANY(filter_target_types))
      AND (t.search_tsv || to_tsvector('english', crm_search_text(tp.name, ts.name, assignee.name))) @@ query.tsq

    UNION ALL

    SELECT
      'task_comment'::text AS target_type,
      tc.id AS target_id,
      COALESCE(t.source_identifier || ' comment', 'Task comment') AS title,
      concat_ws(' / ', t.title, tm.name) AS subtitle,
      COALESCE(tc.source_created_at, tc.created_at) AS occurred_at,
      ts_rank_cd(tc.search_tsv, query.tsq, 32) AS rank,
      ts_headline(
        'english',
        left(tc.body, 250000),
        query.tsq,
        'MaxWords=35, MinWords=8, MaxFragments=2'
      ) AS headline,
      tc.metadata || jsonb_build_object(
        'task_id', tc.task_id,
        'author_member_id', tc.author_member_id
      ) AS metadata
    FROM task_comments tc
    JOIN tasks t ON t.id = tc.task_id
    LEFT JOIN team_members tm ON tm.id = tc.author_member_id
    CROSS JOIN query
    WHERE tc.archived_at IS NULL
      AND (filter_target_types IS NULL OR 'task_comment' = ANY(filter_target_types))
      AND tc.search_tsv @@ query.tsq
  ),
  combined AS (
    SELECT * FROM ranked_direct
    UNION ALL
    SELECT * FROM lexical
  ),
  deduped AS (
    SELECT DISTINCT ON (combined.target_type, combined.target_id)
      combined.target_type,
      combined.target_id,
      combined.title,
      combined.subtitle,
      combined.occurred_at,
      combined.rank,
      combined.headline,
      combined.metadata
    FROM combined
    ORDER BY combined.target_type, combined.target_id, combined.rank DESC, combined.occurred_at DESC NULLS LAST
  )
  SELECT
    deduped.target_type,
    deduped.target_id,
    deduped.title,
    deduped.subtitle,
    deduped.occurred_at,
    deduped.rank,
    deduped.headline,
    deduped.metadata
  FROM deduped
  ORDER BY deduped.rank DESC, deduped.occurred_at DESC NULLS LAST
  LIMIT LEAST(GREATEST(COALESCE(match_count, 20), 1), 100);
$$;


--
-- Name: search_crm_full_text_base(text, integer, text[]); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.search_crm_full_text_base(search_query text, match_count integer DEFAULT 20, filter_target_types text[] DEFAULT NULL::text[]) RETURNS TABLE(target_type text, target_id uuid, title text, subtitle text, occurred_at timestamp with time zone, rank real, headline text, metadata jsonb)
    LANGUAGE sql STABLE
    AS $$
  WITH query AS (
    SELECT websearch_to_tsquery('english', COALESCE(search_query, '')) AS tsq
  ),
  ranked AS (
    SELECT
      'organization'::text AS target_type,
      o.id AS target_id,
      o.name AS title,
      concat_ws(' / ', o.domain::text, o.industry, o.hq_country) AS subtitle,
      o.updated_at AS occurred_at,
      ts_rank_cd(o.search_tsv, query.tsq, 32) AS rank,
      ts_headline(
        'english',
        concat_ws(' ', o.name, o.legal_name, o.description, o.industry, o.notes),
        query.tsq,
        'MaxWords=35, MinWords=8, MaxFragments=2'
      ) AS headline,
      o.metadata AS metadata
    FROM organizations o
    CROSS JOIN query
    WHERE o.archived_at IS NULL
      AND (filter_target_types IS NULL OR 'organization' = ANY(filter_target_types))
      AND o.search_tsv @@ query.tsq

    UNION ALL

    SELECT
      'person'::text AS target_type,
      p.id AS target_id,
      p.full_name AS title,
      concat_ws(' / ', p.headline, p.city, p.country) AS subtitle,
      p.updated_at AS occurred_at,
      ts_rank_cd(p.search_tsv, query.tsq, 32) AS rank,
      ts_headline(
        'english',
        concat_ws(' ', p.full_name, p.headline, p.summary, p.notes),
        query.tsq,
        'MaxWords=35, MinWords=8, MaxFragments=2'
      ) AS headline,
      p.metadata AS metadata
    FROM people p
    CROSS JOIN query
    WHERE p.archived_at IS NULL
      AND (filter_target_types IS NULL OR 'person' = ANY(filter_target_types))
      AND p.search_tsv @@ query.tsq

    UNION ALL

    SELECT
      'interaction'::text AS target_type,
      i.id AS target_id,
      COALESCE(i.subject, i.type::text) AS title,
      concat_ws(' / ', i.type::text, i.direction::text, i.location) AS subtitle,
      i.occurred_at,
      ts_rank_cd(i.search_tsv, query.tsq, 32) AS rank,
      ts_headline(
        'english',
        concat_ws(' ', i.subject, left(i.body, 250000), i.location),
        query.tsq,
        'MaxWords=35, MinWords=8, MaxFragments=2'
      ) AS headline,
      i.metadata AS metadata
    FROM interactions i
    CROSS JOIN query
    WHERE i.archived_at IS NULL
      AND (filter_target_types IS NULL OR 'interaction' = ANY(filter_target_types))
      AND i.search_tsv @@ query.tsq

    UNION ALL

    SELECT
      'call_transcript'::text AS target_type,
      ct.id AS target_id,
      COALESCE(i.subject, 'Call transcript') AS title,
      concat_ws(' / ', ct.format::text, ct.language, ct.transcribed_by) AS subtitle,
      i.occurred_at,
      ts_rank_cd(ct.search_tsv, query.tsq, 32) AS rank,
      ts_headline(
        'english',
        left(ct.raw_text, 500000),
        query.tsq,
        'MaxWords=35, MinWords=8, MaxFragments=2'
      ) AS headline,
      ct.metadata AS metadata
    FROM call_transcripts ct
    JOIN interactions i ON i.id = ct.interaction_id
    CROSS JOIN query
    WHERE (filter_target_types IS NULL OR 'call_transcript' = ANY(filter_target_types))
      AND ct.search_tsv @@ query.tsq

    UNION ALL

    SELECT
      'document'::text AS target_type,
      d.id AS target_id,
      d.title,
      concat_ws(' / ', d.document_type, d.source_path) AS subtitle,
      COALESCE(d.occurred_at, d.authored_at, d.created_at) AS occurred_at,
      ts_rank_cd(d.search_tsv, query.tsq, 32) AS rank,
      ts_headline(
        'english',
        concat_ws(' ', d.title, d.summary, left(d.body, 500000)),
        query.tsq,
        'MaxWords=35, MinWords=8, MaxFragments=2'
      ) AS headline,
      d.metadata AS metadata
    FROM documents d
    CROSS JOIN query
    WHERE d.archived_at IS NULL
      AND (filter_target_types IS NULL OR 'document' = ANY(filter_target_types))
      AND d.search_tsv @@ query.tsq

    UNION ALL

    SELECT
      'ai_note'::text AS target_type,
      an.id AS target_id,
      COALESCE(an.title, an.kind::text) AS title,
      concat_ws(' / ', an.kind::text, an.model, an.model_version) AS subtitle,
      an.generated_at AS occurred_at,
      ts_rank_cd(an.search_tsv, query.tsq, 32) AS rank,
      ts_headline(
        'english',
        concat_ws(' ', an.title, left(an.content, 250000)),
        query.tsq,
        'MaxWords=35, MinWords=8, MaxFragments=2'
      ) AS headline,
      an.metadata AS metadata
    FROM ai_notes an
    CROSS JOIN query
    WHERE (filter_target_types IS NULL OR 'ai_note' = ANY(filter_target_types))
      AND an.search_tsv @@ query.tsq

    UNION ALL

    SELECT
      'extracted_fact'::text AS target_type,
      ef.id AS target_id,
      ef.key AS title,
      ef.subject_type::text AS subtitle,
      ef.observed_at AS occurred_at,
      ts_rank_cd(ef.search_tsv, query.tsq, 32) AS rank,
      ts_headline(
        'english',
        concat_ws(' ', ef.key, ef.value_text, left(ef.source_excerpt, 50000)),
        query.tsq,
        'MaxWords=35, MinWords=8, MaxFragments=2'
      ) AS headline,
      ef.metadata AS metadata
    FROM extracted_facts ef
    CROSS JOIN query
    WHERE (filter_target_types IS NULL OR 'extracted_fact' = ANY(filter_target_types))
      AND ef.search_tsv @@ query.tsq

    UNION ALL

    SELECT
      'organization_research_profile'::text AS target_type,
      orp.id AS target_id,
      COALESCE(orp.canonical_name, orp.domain::text, 'Organization research profile') AS title,
      concat_ws(' / ', orp.category, orp.partnership_fit) AS subtitle,
      orp.researched_at AS occurred_at,
      ts_rank_cd(orp.search_tsv, query.tsq, 32) AS rank,
      ts_headline(
        'english',
        concat_ws(' ', orp.canonical_name, orp.one_line_description, orp.healthcare_relevance, orp.partnership_fit, orp.partnership_fit_rationale),
        query.tsq,
        'MaxWords=35, MinWords=8, MaxFragments=2'
      ) AS headline,
      jsonb_build_object(
        'organization_id', orp.organization_id,
        'source_urls', orp.source_urls
      ) AS metadata
    FROM organization_research_profiles orp
    CROSS JOIN query
    WHERE (filter_target_types IS NULL OR 'organization_research_profile' = ANY(filter_target_types))
      AND orp.search_tsv @@ query.tsq

    UNION ALL

    SELECT
      'partnership'::text AS target_type,
      p.id AS target_id,
      p.name AS title,
      concat_ws(' / ', p.partnership_type, p.stage, p.priority) AS subtitle,
      COALESCE(p.launched_at, p.signed_at, p.updated_at) AS occurred_at,
      ts_rank_cd(p.search_tsv, query.tsq, 32) AS rank,
      ts_headline(
        'english',
        concat_ws(' ', p.name, p.strategic_rationale, p.commercial_model, p.status_notes),
        query.tsq,
        'MaxWords=35, MinWords=8, MaxFragments=2'
      ) AS headline,
      p.metadata AS metadata
    FROM partnerships p
    CROSS JOIN query
    WHERE p.archived_at IS NULL
      AND (filter_target_types IS NULL OR 'partnership' = ANY(filter_target_types))
      AND p.search_tsv @@ query.tsq

    UNION ALL

    SELECT
      'partnership_service'::text AS target_type,
      ps.id AS target_id,
      ps.name AS title,
      concat_ws(' / ', ps.service_type, ps.status) AS subtitle,
      ps.updated_at AS occurred_at,
      ts_rank_cd(ps.search_tsv, query.tsq, 32) AS rank,
      ts_headline(
        'english',
        concat_ws(' ', ps.name, ps.service_type, ps.status, ps.clinical_use, ps.data_modalities::text),
        query.tsq,
        'MaxWords=35, MinWords=8, MaxFragments=2'
      ) AS headline,
      ps.metadata AS metadata
    FROM partnership_services ps
    CROSS JOIN query
    WHERE ps.archived_at IS NULL
      AND (filter_target_types IS NULL OR 'partnership_service' = ANY(filter_target_types))
      AND ps.search_tsv @@ query.tsq

    UNION ALL

    SELECT
      'partnership_integration'::text AS target_type,
      pi.id AS target_id,
      pi.integration_type AS title,
      concat_ws(' / ', pi.status, pi.sync_direction) AS subtitle,
      COALESCE(pi.last_sync_at, pi.updated_at) AS occurred_at,
      ts_rank_cd(pi.search_tsv, query.tsq, 32) AS rank,
      ts_headline(
        'english',
        concat_ws(' ', pi.integration_type, pi.status, pi.sync_direction, pi.data_formats::text, pi.notes),
        query.tsq,
        'MaxWords=35, MinWords=8, MaxFragments=2'
      ) AS headline,
      pi.metadata AS metadata
    FROM partnership_integrations pi
    CROSS JOIN query
    WHERE pi.archived_at IS NULL
      AND (filter_target_types IS NULL OR 'partnership_integration' = ANY(filter_target_types))
      AND pi.search_tsv @@ query.tsq
  )
  SELECT
    ranked.target_type,
    ranked.target_id,
    ranked.title,
    ranked.subtitle,
    ranked.occurred_at,
    ranked.rank,
    ranked.headline,
    ranked.metadata
  FROM ranked
  ORDER BY ranked.rank DESC, ranked.occurred_at DESC NULLS LAST
  LIMIT LEAST(GREATEST(COALESCE(match_count, 20), 1), 100);
$$;




--
-- Name: affiliations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.affiliations (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    person_id uuid NOT NULL,
    organization_id uuid NOT NULL,
    title text,
    department text,
    is_current boolean DEFAULT true NOT NULL,
    is_primary boolean DEFAULT false NOT NULL,
    start_date date,
    end_date date,
    notes text,
    source_id uuid,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    role_family public.person_role_family,
    seniority public.person_seniority,
    CONSTRAINT affiliations_check CHECK (((end_date IS NULL) OR (start_date IS NULL) OR (end_date >= start_date)))
);


--
-- Name: ai_notes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ai_notes (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    kind public.ai_note_kind DEFAULT 'summary'::public.ai_note_kind NOT NULL,
    interaction_id uuid,
    subject_type public.entity_type,
    subject_id uuid,
    title text,
    content text NOT NULL,
    content_format text DEFAULT 'markdown'::text NOT NULL,
    model text,
    model_version text,
    prompt_fingerprint text,
    source_id uuid,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    generated_at timestamp with time zone DEFAULT now() NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    document_id uuid,
    search_tsv tsvector GENERATED ALWAYS AS (to_tsvector('english'::regconfig, public.crm_search_text(VARIADIC ARRAY[title, "left"(content, 250000)]))) STORED,
    CONSTRAINT ck_ai_notes_exactly_one_anchor CHECK ((((((interaction_id IS NOT NULL))::integer + ((document_id IS NOT NULL))::integer) + (((subject_type IS NOT NULL) AND (subject_id IS NOT NULL)))::integer) = 1))
);


--
-- Name: call_transcripts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.call_transcripts (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    interaction_id uuid NOT NULL,
    format public.transcript_format DEFAULT 'plain_text'::public.transcript_format NOT NULL,
    language text,
    raw_text text NOT NULL,
    segments jsonb,
    recording_url text,
    recording_storage_path text,
    source_id uuid,
    source_external_id text,
    transcribed_by text,
    transcribed_at timestamp with time zone,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    search_tsv tsvector GENERATED ALWAYS AS (to_tsvector('english'::regconfig, "left"(raw_text, 500000))) STORED
);


--
-- Name: document_interactions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.document_interactions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    document_id uuid NOT NULL,
    interaction_id uuid NOT NULL,
    role text DEFAULT 'related'::text NOT NULL,
    notes text,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: document_organizations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.document_organizations (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    document_id uuid NOT NULL,
    organization_id uuid NOT NULL,
    role text DEFAULT 'mentioned'::text NOT NULL,
    notes text,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: document_people; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.document_people (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    document_id uuid NOT NULL,
    person_id uuid NOT NULL,
    role text DEFAULT 'mentioned'::text NOT NULL,
    notes text,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: documents; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.documents (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    title text NOT NULL,
    document_type text NOT NULL,
    body text,
    body_format text DEFAULT 'markdown'::text NOT NULL,
    summary text,
    authored_at timestamp with time zone,
    occurred_at timestamp with time zone,
    source_id uuid,
    source_external_id text,
    source_path text,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    archived_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    search_tsv tsvector GENERATED ALWAYS AS (to_tsvector('english'::regconfig, public.crm_search_text(VARIADIC ARRAY[title, document_type, summary, "left"(body, 500000), source_path]))) STORED
);


--
-- Name: external_identities; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.external_identities (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    entity_type public.entity_type NOT NULL,
    entity_id uuid NOT NULL,
    source_id uuid NOT NULL,
    kind text,
    external_id text NOT NULL,
    url text,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: extracted_facts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.extracted_facts (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    subject_type public.entity_type NOT NULL,
    subject_id uuid NOT NULL,
    key text NOT NULL,
    value_text text,
    value_json jsonb,
    confidence numeric(4,3),
    interaction_id uuid,
    source_id uuid,
    source_excerpt text,
    observed_at timestamp with time zone DEFAULT now() NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    document_id uuid,
    search_tsv tsvector GENERATED ALWAYS AS (to_tsvector('english'::regconfig, public.crm_search_text(VARIADIC ARRAY[key, value_text, "left"(source_excerpt, 50000)]))) STORED,
    CONSTRAINT extracted_facts_check CHECK (((value_text IS NOT NULL) OR (value_json IS NOT NULL))),
    CONSTRAINT extracted_facts_confidence_check CHECK (((confidence IS NULL) OR ((confidence >= (0)::numeric) AND (confidence <= (1)::numeric))))
);


--
-- Name: interaction_participants; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.interaction_participants (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    interaction_id uuid NOT NULL,
    person_id uuid,
    organization_id uuid,
    role public.participant_role DEFAULT 'attendee'::public.participant_role NOT NULL,
    handle text,
    display_name text,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT interaction_participants_check CHECK (((((person_id IS NOT NULL))::integer + ((organization_id IS NOT NULL))::integer) = 1))
);


--
-- Name: interactions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.interactions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    type public.interaction_type NOT NULL,
    direction public.interaction_direction,
    subject text,
    body text,
    occurred_at timestamp with time zone NOT NULL,
    ended_at timestamp with time zone,
    duration_seconds integer,
    location text,
    source_id uuid,
    source_external_id text,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    archived_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    search_tsv tsvector GENERATED ALWAYS AS (to_tsvector('english'::regconfig, public.crm_search_text(VARIADIC ARRAY[subject, "left"(body, 250000), location]))) STORED,
    CONSTRAINT interactions_check CHECK (((ended_at IS NULL) OR (ended_at >= occurred_at))),
    CONSTRAINT interactions_duration_seconds_check CHECK (((duration_seconds IS NULL) OR (duration_seconds >= 0)))
);


--
-- Name: organization_research_profiles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.organization_research_profiles (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organization_id uuid NOT NULL,
    source_id uuid,
    model text,
    model_version text,
    prompt_fingerprint text NOT NULL,
    canonical_name text,
    website text,
    domain public.citext,
    one_line_description text,
    category text,
    healthcare_relevance text,
    partnership_fit text,
    partnership_fit_rationale text,
    offerings jsonb DEFAULT '[]'::jsonb NOT NULL,
    likely_use_cases jsonb DEFAULT '[]'::jsonb NOT NULL,
    integration_signals jsonb DEFAULT '[]'::jsonb NOT NULL,
    compliance_signals jsonb DEFAULT '[]'::jsonb NOT NULL,
    key_public_people jsonb DEFAULT '[]'::jsonb NOT NULL,
    suggested_tags jsonb DEFAULT '[]'::jsonb NOT NULL,
    review_flags jsonb DEFAULT '[]'::jsonb NOT NULL,
    source_urls jsonb DEFAULT '[]'::jsonb NOT NULL,
    raw_enrichment jsonb DEFAULT '{}'::jsonb NOT NULL,
    researched_at timestamp with time zone DEFAULT now() NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    search_tsv tsvector GENERATED ALWAYS AS (to_tsvector('english'::regconfig, public.crm_search_text(VARIADIC ARRAY[canonical_name, website, (domain)::text, one_line_description, category, healthcare_relevance, partnership_fit, partnership_fit_rationale, (offerings)::text, (likely_use_cases)::text, (integration_signals)::text, (compliance_signals)::text, (key_public_people)::text, (suggested_tags)::text, (review_flags)::text]))) STORED
);


--
-- Name: organizations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.organizations (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    slug text,
    legal_name text,
    domain public.citext NOT NULL,
    website text,
    description text,
    industry text,
    hq_city text,
    hq_region text,
    hq_country text,
    notes text,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    archived_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    search_tsv tsvector GENERATED ALWAYS AS (to_tsvector('english'::regconfig, public.crm_search_text(VARIADIC ARRAY[name, legal_name, (domain)::text, website, description, industry, hq_city, hq_region, hq_country, notes]))) STORED
);


--
-- Name: partnership_integrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.partnership_integrations (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    partnership_id uuid NOT NULL,
    service_id uuid,
    source_id uuid,
    integration_type text NOT NULL,
    status text DEFAULT 'not_started'::text NOT NULL,
    data_formats jsonb DEFAULT '[]'::jsonb NOT NULL,
    sync_direction text DEFAULT 'inbound'::text NOT NULL,
    consent_required boolean DEFAULT false NOT NULL,
    baa_required boolean DEFAULT false NOT NULL,
    last_sync_at timestamp with time zone,
    notes text,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    archived_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    search_tsv tsvector GENERATED ALWAYS AS (to_tsvector('english'::regconfig, public.crm_search_text(VARIADIC ARRAY[integration_type, status, sync_direction, (data_formats)::text, notes]))) STORED,
    CONSTRAINT partnership_integrations_data_formats_check CHECK ((jsonb_typeof(data_formats) = ANY (ARRAY['array'::text, 'object'::text]))),
    CONSTRAINT partnership_integrations_integration_type_check CHECK ((integration_type = ANY (ARRAY['api'::text, 'webhook'::text, 'sftp'::text, 'manual_upload'::text, 'pdf_import'::text, 'email'::text, 'portal'::text, 'other'::text]))),
    CONSTRAINT partnership_integrations_status_check CHECK ((status = ANY (ARRAY['not_started'::text, 'sandbox'::text, 'building'::text, 'testing'::text, 'production'::text, 'paused'::text, 'retired'::text]))),
    CONSTRAINT partnership_integrations_sync_direction_check CHECK ((sync_direction = ANY (ARRAY['inbound'::text, 'outbound'::text, 'bidirectional'::text])))
);


--
-- Name: partnership_services; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.partnership_services (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    partnership_id uuid NOT NULL,
    service_type text NOT NULL,
    name text NOT NULL,
    patient_facing boolean DEFAULT false NOT NULL,
    status text DEFAULT 'proposed'::text NOT NULL,
    data_modalities jsonb DEFAULT '[]'::jsonb NOT NULL,
    clinical_use text,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    archived_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    search_tsv tsvector GENERATED ALWAYS AS (to_tsvector('english'::regconfig, public.crm_search_text(VARIADIC ARRAY[name, service_type, status, clinical_use, (data_modalities)::text]))) STORED,
    CONSTRAINT partnership_services_data_modalities_check CHECK ((jsonb_typeof(data_modalities) = ANY (ARRAY['array'::text, 'object'::text]))),
    CONSTRAINT partnership_services_status_check CHECK ((status = ANY (ARRAY['proposed'::text, 'validating'::text, 'build_ready'::text, 'live'::text, 'paused'::text, 'retired'::text])))
);


--
-- Name: partnerships; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.partnerships (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organization_id uuid NOT NULL,
    name text NOT NULL,
    partnership_type text NOT NULL,
    stage text DEFAULT 'prospect'::text NOT NULL,
    priority text DEFAULT 'medium'::text NOT NULL,
    owner_person_id uuid,
    strategic_rationale text,
    commercial_model text,
    status_notes text,
    signed_at timestamp with time zone,
    launched_at timestamp with time zone,
    source_id uuid,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    archived_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    search_tsv tsvector GENERATED ALWAYS AS (to_tsvector('english'::regconfig, public.crm_search_text(VARIADIC ARRAY[name, partnership_type, stage, priority, strategic_rationale, commercial_model, status_notes]))) STORED,
    CONSTRAINT partnerships_check CHECK (((launched_at IS NULL) OR (signed_at IS NULL) OR (launched_at >= signed_at))),
    CONSTRAINT partnerships_priority_check CHECK ((priority = ANY (ARRAY['low'::text, 'medium'::text, 'high'::text, 'strategic'::text]))),
    CONSTRAINT partnerships_stage_check CHECK ((stage = ANY (ARRAY['prospect'::text, 'intro'::text, 'discovery'::text, 'diligence'::text, 'pilot'::text, 'contracting'::text, 'live'::text, 'paused'::text, 'lost'::text])))
);


--
-- Name: people; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.people (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    full_name text NOT NULL,
    given_name text,
    family_name text,
    display_name text,
    preferred_name text,
    primary_email public.citext NOT NULL,
    primary_phone text,
    headline text,
    summary text,
    city text,
    region text,
    country text,
    timezone text,
    linkedin_url text,
    website text,
    notes text,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    archived_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    search_tsv tsvector GENERATED ALWAYS AS (to_tsvector('english'::regconfig, public.crm_search_text(VARIADIC ARRAY[full_name, display_name, preferred_name, headline, summary, city, region, country, timezone, website, notes]))) STORED,
    current_title text,
    current_department text,
    current_organization_id uuid,
    role_family public.person_role_family,
    seniority public.person_seniority
);


--
-- Name: partner_integration_board; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.partner_integration_board AS
 WITH integration_cards AS (
         SELECT ('integration:'::text || (pi.id)::text) AS card_id,
            'integration'::text AS card_kind,
            pi.status AS lane_id,
                CASE pi.status
                    WHEN 'not_started'::text THEN 'Not started'::text
                    WHEN 'sandbox'::text THEN 'Sandbox'::text
                    WHEN 'building'::text THEN 'Building'::text
                    WHEN 'testing'::text THEN 'Testing'::text
                    WHEN 'production'::text THEN 'Production'::text
                    WHEN 'paused'::text THEN 'Paused'::text
                    WHEN 'retired'::text THEN 'Retired'::text
                    ELSE initcap(replace(pi.status, '_'::text, ' '::text))
                END AS lane_name,
                CASE pi.status
                    WHEN 'not_started'::text THEN 10
                    WHEN 'sandbox'::text THEN 20
                    WHEN 'building'::text THEN 30
                    WHEN 'testing'::text THEN 40
                    WHEN 'production'::text THEN 50
                    WHEN 'paused'::text THEN 60
                    WHEN 'retired'::text THEN 70
                    ELSE 999
                END AS lane_order,
            concat_ws(' - '::text, o.name, initcap(replace(pi.integration_type, '_'::text, ' '::text))) AS card_title,
            concat_ws(' / '::text, p.name, ps.name) AS card_subtitle,
            o.id AS organization_id,
            o.name AS organization_name,
            o.slug AS organization_slug,
            (o.domain)::text AS organization_domain,
            p.id AS partnership_id,
            p.name AS partnership_name,
            p.partnership_type,
            p.stage AS partnership_stage,
                CASE p.stage
                    WHEN 'prospect'::text THEN 10
                    WHEN 'intro'::text THEN 20
                    WHEN 'discovery'::text THEN 30
                    WHEN 'diligence'::text THEN 40
                    WHEN 'pilot'::text THEN 50
                    WHEN 'contracting'::text THEN 60
                    WHEN 'live'::text THEN 70
                    WHEN 'paused'::text THEN 80
                    WHEN 'lost'::text THEN 90
                    ELSE 999
                END AS partnership_stage_order,
            p.priority,
                CASE p.priority
                    WHEN 'strategic'::text THEN 10
                    WHEN 'high'::text THEN 20
                    WHEN 'medium'::text THEN 30
                    WHEN 'low'::text THEN 40
                    ELSE 999
                END AS priority_order,
            p.owner_person_id,
            COALESCE(owner.display_name, owner.full_name) AS owner_name,
            ps.id AS service_id,
            ps.name AS service_name,
            ps.service_type,
            ps.status AS service_status,
                CASE ps.status
                    WHEN 'proposed'::text THEN 10
                    WHEN 'validating'::text THEN 20
                    WHEN 'build_ready'::text THEN 30
                    WHEN 'live'::text THEN 40
                    WHEN 'paused'::text THEN 50
                    WHEN 'retired'::text THEN 60
                    ELSE 999
                END AS service_status_order,
            ps.patient_facing,
            pi.id AS integration_id,
            pi.integration_type,
            pi.status AS integration_status,
                CASE pi.status
                    WHEN 'not_started'::text THEN 10
                    WHEN 'sandbox'::text THEN 20
                    WHEN 'building'::text THEN 30
                    WHEN 'testing'::text THEN 40
                    WHEN 'production'::text THEN 50
                    WHEN 'paused'::text THEN 60
                    WHEN 'retired'::text THEN 70
                    ELSE 999
                END AS integration_status_order,
            pi.sync_direction,
            pi.data_formats,
            pi.consent_required,
            pi.baa_required,
            pi.last_sync_at,
            p.signed_at,
            p.launched_at,
            p.status_notes,
            pi.notes AS integration_notes,
            ps.clinical_use,
            array_remove(ARRAY[p.partnership_type, p.priority, pi.integration_type, pi.sync_direction,
                CASE
                    WHEN pi.consent_required THEN 'consent_required'::text
                    ELSE NULL::text
                END,
                CASE
                    WHEN pi.baa_required THEN 'baa_required'::text
                    ELSE NULL::text
                END,
                CASE
                    WHEN ps.patient_facing THEN 'patient_facing'::text
                    ELSE NULL::text
                END], NULL::text) AS card_labels,
            jsonb_build_object('partnership_metadata', p.metadata, 'service_metadata', COALESCE(ps.metadata, '{}'::jsonb), 'integration_metadata', pi.metadata) AS metadata,
            LEAST(p.created_at, pi.created_at, COALESCE(ps.created_at, pi.created_at)) AS created_at,
            GREATEST(p.updated_at, pi.updated_at, COALESCE(ps.updated_at, pi.updated_at)) AS updated_at
           FROM ((((public.partnership_integrations pi
             JOIN public.partnerships p ON ((p.id = pi.partnership_id)))
             JOIN public.organizations o ON ((o.id = p.organization_id)))
             LEFT JOIN public.partnership_services ps ON (((ps.id = pi.service_id) AND (ps.archived_at IS NULL))))
             LEFT JOIN public.people owner ON (((owner.id = p.owner_person_id) AND (owner.archived_at IS NULL))))
          WHERE ((p.archived_at IS NULL) AND (o.archived_at IS NULL) AND (pi.archived_at IS NULL))
        ), unmapped_cards AS (
         SELECT
                CASE
                    WHEN (ps.id IS NULL) THEN ('partnership:'::text || (p.id)::text)
                    ELSE ('service:'::text || (ps.id)::text)
                END AS card_id,
                CASE
                    WHEN (ps.id IS NULL) THEN 'partnership'::text
                    ELSE 'service'::text
                END AS card_kind,
            'unmapped'::text AS lane_id,
            'Unmapped'::text AS lane_name,
            0 AS lane_order,
            concat_ws(' - '::text, o.name, ps.name) AS card_title,
            p.name AS card_subtitle,
            o.id AS organization_id,
            o.name AS organization_name,
            o.slug AS organization_slug,
            (o.domain)::text AS organization_domain,
            p.id AS partnership_id,
            p.name AS partnership_name,
            p.partnership_type,
            p.stage AS partnership_stage,
                CASE p.stage
                    WHEN 'prospect'::text THEN 10
                    WHEN 'intro'::text THEN 20
                    WHEN 'discovery'::text THEN 30
                    WHEN 'diligence'::text THEN 40
                    WHEN 'pilot'::text THEN 50
                    WHEN 'contracting'::text THEN 60
                    WHEN 'live'::text THEN 70
                    WHEN 'paused'::text THEN 80
                    WHEN 'lost'::text THEN 90
                    ELSE 999
                END AS partnership_stage_order,
            p.priority,
                CASE p.priority
                    WHEN 'strategic'::text THEN 10
                    WHEN 'high'::text THEN 20
                    WHEN 'medium'::text THEN 30
                    WHEN 'low'::text THEN 40
                    ELSE 999
                END AS priority_order,
            p.owner_person_id,
            COALESCE(owner.display_name, owner.full_name) AS owner_name,
            ps.id AS service_id,
            ps.name AS service_name,
            ps.service_type,
            ps.status AS service_status,
                CASE ps.status
                    WHEN 'proposed'::text THEN 10
                    WHEN 'validating'::text THEN 20
                    WHEN 'build_ready'::text THEN 30
                    WHEN 'live'::text THEN 40
                    WHEN 'paused'::text THEN 50
                    WHEN 'retired'::text THEN 60
                    ELSE 999
                END AS service_status_order,
            COALESCE(ps.patient_facing, false) AS patient_facing,
            NULL::uuid AS integration_id,
            NULL::text AS integration_type,
            'unmapped'::text AS integration_status,
            0 AS integration_status_order,
            NULL::text AS sync_direction,
            '[]'::jsonb AS data_formats,
            false AS consent_required,
            false AS baa_required,
            NULL::timestamp with time zone AS last_sync_at,
            p.signed_at,
            p.launched_at,
            p.status_notes,
            NULL::text AS integration_notes,
            ps.clinical_use,
            array_remove(ARRAY[p.partnership_type, p.priority, ps.service_type,
                CASE
                    WHEN COALESCE(ps.patient_facing, false) THEN 'patient_facing'::text
                    ELSE NULL::text
                END], NULL::text) AS card_labels,
            jsonb_build_object('partnership_metadata', p.metadata, 'service_metadata', COALESCE(ps.metadata, '{}'::jsonb), 'integration_metadata', '{}'::jsonb) AS metadata,
            LEAST(p.created_at, COALESCE(ps.created_at, p.created_at)) AS created_at,
            GREATEST(p.updated_at, COALESCE(ps.updated_at, p.updated_at)) AS updated_at
           FROM (((public.partnerships p
             JOIN public.organizations o ON ((o.id = p.organization_id)))
             LEFT JOIN public.partnership_services ps ON (((ps.partnership_id = p.id) AND (ps.archived_at IS NULL))))
             LEFT JOIN public.people owner ON (((owner.id = p.owner_person_id) AND (owner.archived_at IS NULL))))
          WHERE ((p.archived_at IS NULL) AND (o.archived_at IS NULL) AND (NOT (EXISTS ( SELECT 1
                   FROM public.partnership_integrations pi
                  WHERE ((pi.partnership_id = p.id) AND (pi.archived_at IS NULL))))))
        )
 SELECT integration_cards.card_id,
    integration_cards.card_kind,
    integration_cards.lane_id,
    integration_cards.lane_name,
    integration_cards.lane_order,
    integration_cards.card_title,
    integration_cards.card_subtitle,
    integration_cards.organization_id,
    integration_cards.organization_name,
    integration_cards.organization_slug,
    integration_cards.organization_domain,
    integration_cards.partnership_id,
    integration_cards.partnership_name,
    integration_cards.partnership_type,
    integration_cards.partnership_stage,
    integration_cards.partnership_stage_order,
    integration_cards.priority,
    integration_cards.priority_order,
    integration_cards.owner_person_id,
    integration_cards.owner_name,
    integration_cards.service_id,
    integration_cards.service_name,
    integration_cards.service_type,
    integration_cards.service_status,
    integration_cards.service_status_order,
    integration_cards.patient_facing,
    integration_cards.integration_id,
    integration_cards.integration_type,
    integration_cards.integration_status,
    integration_cards.integration_status_order,
    integration_cards.sync_direction,
    integration_cards.data_formats,
    integration_cards.consent_required,
    integration_cards.baa_required,
    integration_cards.last_sync_at,
    integration_cards.signed_at,
    integration_cards.launched_at,
    integration_cards.status_notes,
    integration_cards.integration_notes,
    integration_cards.clinical_use,
    integration_cards.card_labels,
    integration_cards.metadata,
    integration_cards.created_at,
    integration_cards.updated_at
   FROM integration_cards
UNION ALL
 SELECT unmapped_cards.card_id,
    unmapped_cards.card_kind,
    unmapped_cards.lane_id,
    unmapped_cards.lane_name,
    unmapped_cards.lane_order,
    unmapped_cards.card_title,
    unmapped_cards.card_subtitle,
    unmapped_cards.organization_id,
    unmapped_cards.organization_name,
    unmapped_cards.organization_slug,
    unmapped_cards.organization_domain,
    unmapped_cards.partnership_id,
    unmapped_cards.partnership_name,
    unmapped_cards.partnership_type,
    unmapped_cards.partnership_stage,
    unmapped_cards.partnership_stage_order,
    unmapped_cards.priority,
    unmapped_cards.priority_order,
    unmapped_cards.owner_person_id,
    unmapped_cards.owner_name,
    unmapped_cards.service_id,
    unmapped_cards.service_name,
    unmapped_cards.service_type,
    unmapped_cards.service_status,
    unmapped_cards.service_status_order,
    unmapped_cards.patient_facing,
    unmapped_cards.integration_id,
    unmapped_cards.integration_type,
    unmapped_cards.integration_status,
    unmapped_cards.integration_status_order,
    unmapped_cards.sync_direction,
    unmapped_cards.data_formats,
    unmapped_cards.consent_required,
    unmapped_cards.baa_required,
    unmapped_cards.last_sync_at,
    unmapped_cards.signed_at,
    unmapped_cards.launched_at,
    unmapped_cards.status_notes,
    unmapped_cards.integration_notes,
    unmapped_cards.clinical_use,
    unmapped_cards.card_labels,
    unmapped_cards.metadata,
    unmapped_cards.created_at,
    unmapped_cards.updated_at
   FROM unmapped_cards;


--
-- Name: VIEW partner_integration_board; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON VIEW public.partner_integration_board IS 'Kanban-oriented partner integration board. One card per active integration, plus unmapped active partnerships/services without an integration row.';


--
-- Name: COLUMN partner_integration_board.card_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.partner_integration_board.card_id IS 'Stable display ID for the board card, prefixed by the source row kind.';


--
-- Name: COLUMN partner_integration_board.card_kind; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.partner_integration_board.card_kind IS 'Card source type: integration, service, or partnership.';


--
-- Name: COLUMN partner_integration_board.lane_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.partner_integration_board.lane_id IS 'Kanban lane key, usually the integration status; unmapped means no active integration row exists yet.';


--
-- Name: COLUMN partner_integration_board.lane_order; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.partner_integration_board.lane_order IS 'Numeric lane order for board rendering.';


--
-- Name: COLUMN partner_integration_board.card_labels; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.partner_integration_board.card_labels IS 'Small derived labels suitable for compact card badges.';


--
-- Name: COLUMN partner_integration_board.metadata; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.partner_integration_board.metadata IS 'Combined partnership, service, and integration metadata for drill-down views.';


--
-- Name: partnership_documents; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.partnership_documents (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    partnership_id uuid NOT NULL,
    document_id uuid NOT NULL,
    role text DEFAULT 'related'::text NOT NULL,
    notes text,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: partnership_interactions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.partnership_interactions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    partnership_id uuid NOT NULL,
    interaction_id uuid NOT NULL,
    role text DEFAULT 'related'::text NOT NULL,
    notes text,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: partnership_people; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.partnership_people (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    partnership_id uuid NOT NULL,
    person_id uuid NOT NULL,
    role text NOT NULL,
    notes text,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: person_emails; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.person_emails (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    person_id uuid NOT NULL,
    email public.citext NOT NULL,
    label text,
    is_primary boolean DEFAULT false NOT NULL,
    verified_at timestamp with time zone,
    source_id uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: person_phones; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.person_phones (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    person_id uuid NOT NULL,
    phone text NOT NULL,
    label text,
    is_primary boolean DEFAULT false NOT NULL,
    source_id uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: pgmigrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.pgmigrations (
    id integer NOT NULL,
    name character varying(255) NOT NULL,
    run_on timestamp without time zone NOT NULL
);


--
-- Name: pgmigrations_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.pgmigrations_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: pgmigrations_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.pgmigrations_id_seq OWNED BY public.pgmigrations.id;


--
-- Name: relationship_edges; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.relationship_edges (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    source_entity_type public.entity_type NOT NULL,
    source_entity_id uuid NOT NULL,
    target_entity_type public.entity_type NOT NULL,
    target_entity_id uuid NOT NULL,
    edge_type public.relationship_edge_type NOT NULL,
    label text,
    notes text,
    start_date date,
    end_date date,
    source_id uuid,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT relationship_edges_check CHECK ((NOT ((source_entity_type = target_entity_type) AND (source_entity_id = target_entity_id)))),
    CONSTRAINT relationship_edges_check1 CHECK (((end_date IS NULL) OR (start_date IS NULL) OR (end_date >= start_date)))
);


--
-- Name: semantic_embeddings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.semantic_embeddings (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    target_type text NOT NULL,
    target_id uuid NOT NULL,
    chunk_index integer DEFAULT 0 NOT NULL,
    content text NOT NULL,
    content_sha256 text NOT NULL,
    embedding_provider text DEFAULT 'mlx'::text NOT NULL,
    embedding_model text DEFAULT 'mlx-community/embeddinggemma-300m-4bit'::text NOT NULL,
    embedding_model_version text DEFAULT '4bit'::text NOT NULL,
    embedding_dimension integer DEFAULT 768 NOT NULL,
    embedding public.vector(768) NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    archived_at timestamp with time zone,
    embedded_at timestamp with time zone DEFAULT now() NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    search_tsv tsvector GENERATED ALWAYS AS (to_tsvector('english'::regconfig, content)) STORED,
    CONSTRAINT semantic_embeddings_chunk_index_check CHECK ((chunk_index >= 0)),
    CONSTRAINT semantic_embeddings_content_check CHECK ((length(TRIM(BOTH FROM content)) > 0)),
    CONSTRAINT semantic_embeddings_content_sha256_check CHECK ((content_sha256 ~ '^[a-f0-9]{64}$'::text)),
    CONSTRAINT semantic_embeddings_embedding_dimension_check CHECK ((embedding_dimension = 768)),
    CONSTRAINT semantic_embeddings_target_type_check CHECK ((target_type = ANY (ARRAY['organization'::text, 'organization_research_profile'::text, 'person'::text, 'interaction'::text, 'document'::text, 'partnership'::text, 'partnership_service'::text, 'partnership_integration'::text, 'call_transcript'::text, 'ai_note'::text, 'extracted_fact'::text, 'team_member'::text, 'task'::text, 'task_project'::text, 'task_comment'::text])))
);


--
-- Name: sources; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sources (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    slug text NOT NULL,
    name text NOT NULL,
    description text,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: suspect_organization_imports; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.suspect_organization_imports AS
 SELECT o.id,
    o.name,
    o.domain,
    assessment.registrable_domain,
    assessment.reason_codes,
    source_match.source_slug,
    o.created_at,
    o.updated_at
   FROM ((public.organizations o
     LEFT JOIN LATERAL ( SELECT s.slug AS source_slug
           FROM (public.external_identities ei
             JOIN public.sources s ON ((s.id = ei.source_id)))
          WHERE ((ei.entity_type = 'organization'::public.entity_type) AND (ei.entity_id = o.id))
          ORDER BY (s.slug = 'gmail'::text) DESC, ei.created_at
         LIMIT 1) source_match ON (true))
     CROSS JOIN LATERAL public.crm_assess_organization_domain_import(COALESCE(source_match.source_slug, 'manual'::text), o.name, (o.domain)::text, NULL::text) assessment(normalized_name, normalized_domain, registrable_domain, should_create_organization, should_link_registrable_organization, reason_codes))
  WHERE ((o.archived_at IS NULL) AND (NOT assessment.should_create_organization));


--
-- Name: VIEW suspect_organization_imports; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON VIEW public.suspect_organization_imports IS 'Active organizations that would fail current email-domain import guardrails; review before cleanup, merge, or archival.';


--
-- Name: suspect_people_imports; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.suspect_people_imports AS
 SELECT p.id,
    p.full_name,
    p.primary_email,
    assessment.normalized_name,
    assessment.reason_codes,
    p.created_at,
    p.updated_at
   FROM (public.people p
     CROSS JOIN LATERAL public.crm_assess_person_import(p.full_name, (p.primary_email)::text) assessment(normalized_name, should_create_person, reason_codes))
  WHERE ((p.archived_at IS NULL) AND (NOT assessment.should_create_person));


--
-- Name: VIEW suspect_people_imports; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON VIEW public.suspect_people_imports IS 'Active people that would fail the current email/contact import guardrails; review before cleanup or archival.';


--
-- Name: taggings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.taggings (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tag_id uuid NOT NULL,
    target_type text NOT NULL,
    target_id uuid NOT NULL,
    source_id uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_taggings_target_type CHECK ((target_type = ANY (ARRAY['organization'::text, 'person'::text, 'interaction'::text, 'document'::text, 'partnership'::text, 'task'::text])))
);


--
-- Name: tags; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tags (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    slug text NOT NULL,
    label text NOT NULL,
    description text,
    color text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: task_attachments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.task_attachments (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    task_id uuid NOT NULL,
    title text,
    subtitle text,
    url text,
    content_type text,
    source_id uuid,
    source_external_id text,
    source_url text,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    archived_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: TABLE task_attachments; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.task_attachments IS 'Task attachment and external-link metadata. Binary payloads are not stored here by default.';


--
-- Name: COLUMN task_attachments.url; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.task_attachments.url IS 'Attachment or external-link URL visible from the operating organization.';


--
-- Name: COLUMN task_attachments.source_url; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.task_attachments.source_url IS 'Canonical upstream URL for the attachment when different from url.';


--
-- Name: COLUMN task_attachments.metadata; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.task_attachments.metadata IS 'Provider-specific attachment fields.';


--
-- Name: task_comments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.task_comments (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    task_id uuid NOT NULL,
    parent_comment_id uuid,
    author_member_id uuid,
    body text NOT NULL,
    body_format text DEFAULT 'markdown'::text NOT NULL,
    source_id uuid,
    source_external_id text,
    source_url text,
    source_created_at timestamp with time zone,
    source_updated_at timestamp with time zone,
    edited_at timestamp with time zone,
    resolved_at timestamp with time zone,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    archived_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    search_tsv tsvector GENERATED ALWAYS AS (to_tsvector('english'::regconfig, "left"(body, 250000))) STORED,
    CONSTRAINT task_comments_body_check CHECK ((length(TRIM(BOTH FROM body)) > 0)),
    CONSTRAINT task_comments_body_format_check CHECK ((body_format = ANY (ARRAY['markdown'::text, 'plain_text'::text, 'other'::text]))),
    CONSTRAINT task_comments_check CHECK (((parent_comment_id IS NULL) OR (parent_comment_id <> id)))
);


--
-- Name: TABLE task_comments; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.task_comments IS 'Threaded comments attached to internal operating tasks.';


--
-- Name: COLUMN task_comments.author_member_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.task_comments.author_member_id IS 'Team member or bot actor who authored the comment.';


--
-- Name: COLUMN task_comments.body; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.task_comments.body IS 'Comment body, usually Markdown for imported comments.';


--
-- Name: COLUMN task_comments.source_external_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.task_comments.source_external_id IS 'Stable upstream comment ID from the source system.';


--
-- Name: COLUMN task_comments.source_created_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.task_comments.source_created_at IS 'Original upstream comment creation timestamp.';


--
-- Name: COLUMN task_comments.source_updated_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.task_comments.source_updated_at IS 'Original upstream comment update timestamp.';


--
-- Name: task_project_teams; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.task_project_teams (
    project_id uuid NOT NULL,
    team_id uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: TABLE task_project_teams; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.task_project_teams IS 'Many-to-many membership between task projects and task teams.';


--
-- Name: task_projects; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.task_projects (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    summary text,
    description text,
    icon text,
    color text,
    status_name text,
    status_type text,
    priority_value integer DEFAULT 0 NOT NULL,
    priority_label text,
    lead_member_id uuid,
    start_date date,
    target_date date,
    started_at timestamp with time zone,
    completed_at timestamp with time zone,
    canceled_at timestamp with time zone,
    source_id uuid,
    source_external_id text,
    source_url text,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    archived_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    search_tsv tsvector GENERATED ALWAYS AS (to_tsvector('english'::regconfig, public.crm_search_text(VARIADIC ARRAY[name, summary, description, status_name, priority_label]))) STORED,
    CONSTRAINT task_projects_check CHECK (((target_date IS NULL) OR (start_date IS NULL) OR (target_date >= start_date))),
    CONSTRAINT task_projects_name_check CHECK ((length(TRIM(BOTH FROM name)) > 0)),
    CONSTRAINT task_projects_priority_value_check CHECK (((priority_value >= 0) AND (priority_value <= 4))),
    CONSTRAINT task_projects_status_type_check CHECK (((status_type IS NULL) OR (status_type = ANY (ARRAY['backlog'::text, 'planned'::text, 'started'::text, 'paused'::text, 'completed'::text, 'canceled'::text]))))
);


--
-- Name: TABLE task_projects; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.task_projects IS 'Internal operating project containers for tasks.';


--
-- Name: COLUMN task_projects.status_name; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.task_projects.status_name IS 'Display name of the project status from the source system.';


--
-- Name: COLUMN task_projects.status_type; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.task_projects.status_type IS 'Normalized project status category, kept flexible with a CHECK constraint.';


--
-- Name: COLUMN task_projects.priority_value; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.task_projects.priority_value IS 'Numeric priority: 0 none, 1 urgent, 2 high, 3 medium/normal, 4 low.';


--
-- Name: COLUMN task_projects.lead_member_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.task_projects.lead_member_id IS 'Team member who leads the project, when known.';


--
-- Name: COLUMN task_projects.source_url; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.task_projects.source_url IS 'Canonical URL for the upstream project.';


--
-- Name: task_relations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.task_relations (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    task_id uuid NOT NULL,
    related_task_id uuid NOT NULL,
    relation_type text NOT NULL,
    source_id uuid,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    archived_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT task_relations_check CHECK ((task_id <> related_task_id)),
    CONSTRAINT task_relations_relation_type_check CHECK ((relation_type = ANY (ARRAY['blocks'::text, 'blocked_by'::text, 'related'::text, 'duplicate'::text])))
);


--
-- Name: TABLE task_relations; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.task_relations IS 'Directed relationships between tasks such as blocks, blocked_by, related, or duplicate.';


--
-- Name: COLUMN task_relations.related_task_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.task_relations.related_task_id IS 'The other task participating in the directed relation.';


--
-- Name: COLUMN task_relations.relation_type; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.task_relations.relation_type IS 'Directed relation kind: blocks, blocked_by, related, or duplicate.';


--
-- Name: task_statuses; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.task_statuses (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    team_id uuid NOT NULL,
    name text NOT NULL,
    status_type text NOT NULL,
    "position" numeric,
    color text,
    description text,
    source_id uuid,
    source_external_id text,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    archived_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT task_statuses_name_check CHECK ((length(TRIM(BOTH FROM name)) > 0)),
    CONSTRAINT task_statuses_status_type_check CHECK ((status_type = ANY (ARRAY['backlog'::text, 'unstarted'::text, 'started'::text, 'completed'::text, 'canceled'::text])))
);


--
-- Name: TABLE task_statuses; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.task_statuses IS 'Team-scoped workflow states. Names are data, not PostgreSQL enum values.';


--
-- Name: COLUMN task_statuses.status_type; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.task_statuses.status_type IS 'Normalized workflow category: backlog, unstarted, started, completed, or canceled.';


--
-- Name: COLUMN task_statuses."position"; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.task_statuses."position" IS 'Source-system ordering for rendering workflow states.';


--
-- Name: task_teams; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.task_teams (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    key text,
    description text,
    icon text,
    color text,
    source_id uuid,
    source_external_id text,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    archived_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT task_teams_key_check CHECK (((key IS NULL) OR (length(TRIM(BOTH FROM key)) > 0))),
    CONSTRAINT task_teams_name_check CHECK ((length(TRIM(BOTH FROM name)) > 0))
);


--
-- Name: TABLE task_teams; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.task_teams IS 'Task workflow containers, optionally imported from an external task tracker.';


--
-- Name: COLUMN task_teams.key; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.task_teams.key IS 'Short issue prefix or team key, for example ENG.';


--
-- Name: COLUMN task_teams.source_external_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.task_teams.source_external_id IS 'Stable upstream team ID from the source system.';


--
-- Name: tasks; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tasks (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    team_id uuid NOT NULL,
    status_id uuid,
    project_id uuid,
    parent_task_id uuid,
    creator_member_id uuid,
    assignee_member_id uuid,
    delegate_member_id uuid,
    title text NOT NULL,
    description text,
    priority_value integer DEFAULT 0 NOT NULL,
    priority_label text,
    estimate numeric,
    sort_order numeric,
    priority_sort_order numeric,
    due_date date,
    started_at timestamp with time zone,
    completed_at timestamp with time zone,
    canceled_at timestamp with time zone,
    auto_closed_at timestamp with time zone,
    auto_archived_at timestamp with time zone,
    snoozed_until_at timestamp with time zone,
    added_to_project_at timestamp with time zone,
    added_to_team_at timestamp with time zone,
    source_created_at timestamp with time zone,
    source_updated_at timestamp with time zone,
    source_id uuid,
    source_external_id text,
    source_identifier text,
    source_number integer,
    source_url text,
    git_branch_name text,
    sla_started_at timestamp with time zone,
    sla_medium_risk_at timestamp with time zone,
    sla_high_risk_at timestamp with time zone,
    sla_breaches_at timestamp with time zone,
    sla_type text,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    archived_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    search_tsv tsvector GENERATED ALWAYS AS (to_tsvector('english'::regconfig, public.crm_search_text(VARIADIC ARRAY[title, "left"(description, 250000), source_identifier, priority_label, git_branch_name]))) STORED,
    CONSTRAINT tasks_check CHECK (((completed_at IS NULL) OR (canceled_at IS NULL))),
    CONSTRAINT tasks_check1 CHECK (((parent_task_id IS NULL) OR (parent_task_id <> id))),
    CONSTRAINT tasks_estimate_check CHECK (((estimate IS NULL) OR (estimate >= (0)::numeric))),
    CONSTRAINT tasks_priority_value_check CHECK (((priority_value >= 0) AND (priority_value <= 4))),
    CONSTRAINT tasks_source_number_check CHECK (((source_number IS NULL) OR (source_number > 0))),
    CONSTRAINT tasks_title_check CHECK ((length(TRIM(BOTH FROM title)) > 0))
);


--
-- Name: TABLE tasks; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.tasks IS 'Internal operating tasks. Generic work-item model.';


--
-- Name: COLUMN tasks.status_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.tasks.status_id IS 'Workflow state for the task; constrained to belong to the same team as tasks.team_id.';


--
-- Name: COLUMN tasks.project_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.tasks.project_id IS 'Optional operating project; constrained by trigger to be linked to the task team.';


--
-- Name: COLUMN tasks.creator_member_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.tasks.creator_member_id IS 'Team member who created the task in the source system.';


--
-- Name: COLUMN tasks.assignee_member_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.tasks.assignee_member_id IS 'Team member currently responsible for the task.';


--
-- Name: COLUMN tasks.delegate_member_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.tasks.delegate_member_id IS 'Delegated team member or agent, when a source system provides one.';


--
-- Name: COLUMN tasks.priority_value; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.tasks.priority_value IS 'Numeric priority: 0 none, 1 urgent, 2 high, 3 medium/normal, 4 low.';


--
-- Name: COLUMN tasks.source_external_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.tasks.source_external_id IS 'Stable upstream task ID from the source system, when imported.';


--
-- Name: COLUMN tasks.source_identifier; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.tasks.source_identifier IS 'Human-readable task identifier such as ENG-226.';


--
-- Name: COLUMN tasks.source_number; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.tasks.source_number IS 'Numeric portion of the human-readable task identifier.';


--
-- Name: COLUMN tasks.git_branch_name; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.tasks.git_branch_name IS 'Suggested or generated git branch name from the task source.';


--
-- Name: COLUMN tasks.metadata; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.tasks.metadata IS 'Provider-specific task fields that are useful for provenance but not worth first-class columns.';


--
-- Name: team_members; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.team_members (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    title text,
    email public.citext NOT NULL,
    avatar_url text,
    is_active boolean DEFAULT true NOT NULL,
    is_bot boolean DEFAULT false NOT NULL,
    source_id uuid,
    source_external_id text,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    archived_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    search_tsv tsvector GENERATED ALWAYS AS (to_tsvector('english'::regconfig, public.crm_search_text(VARIADIC ARRAY[name, title, (email)::text]))) STORED,
    CONSTRAINT team_members_email_check CHECK ((length(TRIM(BOTH FROM (email)::text)) > 0)),
    CONSTRAINT team_members_name_check CHECK ((length(TRIM(BOTH FROM name)) > 0))
);


--
-- Name: TABLE team_members; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.team_members IS 'Internal team members and system actors who own, create, or comment on internal operational work. Not external CRM contacts.';


--
-- Name: COLUMN team_members.title; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.team_members.title IS 'Internal role/title for the team member, when known.';


--
-- Name: COLUMN team_members.is_bot; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.team_members.is_bot IS 'True for imported system or bot actors.';


--
-- Name: COLUMN team_members.source_external_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.team_members.source_external_id IS 'Stable upstream member/user ID from the source system.';


--
-- Name: COLUMN team_members.metadata; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.team_members.metadata IS 'Provider-specific member fields that are useful for provenance but not worth first-class columns.';


--
-- Name: COLUMN team_members.archived_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.team_members.archived_at IS 'Soft-delete timestamp; active team members have NULL archived_at.';


--
-- Name: pgmigrations id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pgmigrations ALTER COLUMN id SET DEFAULT nextval('public.pgmigrations_id_seq'::regclass);


--
-- Name: affiliations affiliations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.affiliations
    ADD CONSTRAINT affiliations_pkey PRIMARY KEY (id);


--
-- Name: ai_notes ai_notes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_notes
    ADD CONSTRAINT ai_notes_pkey PRIMARY KEY (id);


--
-- Name: call_transcripts call_transcripts_interaction_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.call_transcripts
    ADD CONSTRAINT call_transcripts_interaction_id_key UNIQUE (interaction_id);


--
-- Name: call_transcripts call_transcripts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.call_transcripts
    ADD CONSTRAINT call_transcripts_pkey PRIMARY KEY (id);


--
-- Name: call_transcripts call_transcripts_source_id_source_external_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.call_transcripts
    ADD CONSTRAINT call_transcripts_source_id_source_external_id_key UNIQUE (source_id, source_external_id);


--
-- Name: document_interactions document_interactions_document_id_interaction_id_role_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.document_interactions
    ADD CONSTRAINT document_interactions_document_id_interaction_id_role_key UNIQUE (document_id, interaction_id, role);


--
-- Name: document_interactions document_interactions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.document_interactions
    ADD CONSTRAINT document_interactions_pkey PRIMARY KEY (id);


--
-- Name: document_organizations document_organizations_document_id_organization_id_role_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.document_organizations
    ADD CONSTRAINT document_organizations_document_id_organization_id_role_key UNIQUE (document_id, organization_id, role);


--
-- Name: document_organizations document_organizations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.document_organizations
    ADD CONSTRAINT document_organizations_pkey PRIMARY KEY (id);


--
-- Name: document_people document_people_document_id_person_id_role_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.document_people
    ADD CONSTRAINT document_people_document_id_person_id_role_key UNIQUE (document_id, person_id, role);


--
-- Name: document_people document_people_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.document_people
    ADD CONSTRAINT document_people_pkey PRIMARY KEY (id);


--
-- Name: documents documents_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.documents
    ADD CONSTRAINT documents_pkey PRIMARY KEY (id);


--
-- Name: external_identities external_identities_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.external_identities
    ADD CONSTRAINT external_identities_pkey PRIMARY KEY (id);


--
-- Name: external_identities external_identities_source_id_kind_external_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.external_identities
    ADD CONSTRAINT external_identities_source_id_kind_external_id_key UNIQUE (source_id, kind, external_id);


--
-- Name: extracted_facts extracted_facts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.extracted_facts
    ADD CONSTRAINT extracted_facts_pkey PRIMARY KEY (id);


--
-- Name: interaction_participants interaction_participants_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.interaction_participants
    ADD CONSTRAINT interaction_participants_pkey PRIMARY KEY (id);


--
-- Name: interactions interactions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.interactions
    ADD CONSTRAINT interactions_pkey PRIMARY KEY (id);


--
-- Name: interactions interactions_source_id_source_external_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.interactions
    ADD CONSTRAINT interactions_source_id_source_external_id_key UNIQUE (source_id, source_external_id);


--
-- Name: organization_research_profiles organization_research_profile_organization_id_prompt_finger_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_research_profiles
    ADD CONSTRAINT organization_research_profile_organization_id_prompt_finger_key UNIQUE (organization_id, prompt_fingerprint);


--
-- Name: organization_research_profiles organization_research_profiles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_research_profiles
    ADD CONSTRAINT organization_research_profiles_pkey PRIMARY KEY (id);


--
-- Name: organizations organizations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organizations
    ADD CONSTRAINT organizations_pkey PRIMARY KEY (id);


--
-- Name: organizations organizations_slug_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organizations
    ADD CONSTRAINT organizations_slug_key UNIQUE (slug);


--
-- Name: partnership_documents partnership_documents_partnership_id_document_id_role_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.partnership_documents
    ADD CONSTRAINT partnership_documents_partnership_id_document_id_role_key UNIQUE (partnership_id, document_id, role);


--
-- Name: partnership_documents partnership_documents_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.partnership_documents
    ADD CONSTRAINT partnership_documents_pkey PRIMARY KEY (id);


--
-- Name: partnership_integrations partnership_integrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.partnership_integrations
    ADD CONSTRAINT partnership_integrations_pkey PRIMARY KEY (id);


--
-- Name: partnership_interactions partnership_interactions_partnership_id_interaction_id_role_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.partnership_interactions
    ADD CONSTRAINT partnership_interactions_partnership_id_interaction_id_role_key UNIQUE (partnership_id, interaction_id, role);


--
-- Name: partnership_interactions partnership_interactions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.partnership_interactions
    ADD CONSTRAINT partnership_interactions_pkey PRIMARY KEY (id);


--
-- Name: partnership_people partnership_people_partnership_id_person_id_role_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.partnership_people
    ADD CONSTRAINT partnership_people_partnership_id_person_id_role_key UNIQUE (partnership_id, person_id, role);


--
-- Name: partnership_people partnership_people_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.partnership_people
    ADD CONSTRAINT partnership_people_pkey PRIMARY KEY (id);


--
-- Name: partnership_services partnership_services_id_partnership_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.partnership_services
    ADD CONSTRAINT partnership_services_id_partnership_id_key UNIQUE (id, partnership_id);


--
-- Name: partnership_services partnership_services_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.partnership_services
    ADD CONSTRAINT partnership_services_pkey PRIMARY KEY (id);


--
-- Name: partnerships partnerships_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.partnerships
    ADD CONSTRAINT partnerships_pkey PRIMARY KEY (id);


--
-- Name: people people_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.people
    ADD CONSTRAINT people_pkey PRIMARY KEY (id);


--
-- Name: person_emails person_emails_person_id_email_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.person_emails
    ADD CONSTRAINT person_emails_person_id_email_key UNIQUE (person_id, email);


--
-- Name: person_emails person_emails_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.person_emails
    ADD CONSTRAINT person_emails_pkey PRIMARY KEY (id);


--
-- Name: person_phones person_phones_person_id_phone_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.person_phones
    ADD CONSTRAINT person_phones_person_id_phone_key UNIQUE (person_id, phone);


--
-- Name: person_phones person_phones_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.person_phones
    ADD CONSTRAINT person_phones_pkey PRIMARY KEY (id);


--
-- Name: pgmigrations pgmigrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pgmigrations
    ADD CONSTRAINT pgmigrations_pkey PRIMARY KEY (id);


--
-- Name: relationship_edges relationship_edges_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.relationship_edges
    ADD CONSTRAINT relationship_edges_pkey PRIMARY KEY (id);


--
-- Name: relationship_edges relationship_edges_source_entity_type_source_entity_id_targ_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.relationship_edges
    ADD CONSTRAINT relationship_edges_source_entity_type_source_entity_id_targ_key UNIQUE (source_entity_type, source_entity_id, target_entity_type, target_entity_id, edge_type);


--
-- Name: semantic_embeddings semantic_embeddings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.semantic_embeddings
    ADD CONSTRAINT semantic_embeddings_pkey PRIMARY KEY (id);


--
-- Name: sources sources_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sources
    ADD CONSTRAINT sources_pkey PRIMARY KEY (id);


--
-- Name: sources sources_slug_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sources
    ADD CONSTRAINT sources_slug_key UNIQUE (slug);


--
-- Name: taggings taggings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.taggings
    ADD CONSTRAINT taggings_pkey PRIMARY KEY (id);


--
-- Name: taggings taggings_tag_id_target_type_target_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.taggings
    ADD CONSTRAINT taggings_tag_id_target_type_target_id_key UNIQUE (tag_id, target_type, target_id);


--
-- Name: tags tags_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tags
    ADD CONSTRAINT tags_pkey PRIMARY KEY (id);


--
-- Name: tags tags_slug_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tags
    ADD CONSTRAINT tags_slug_key UNIQUE (slug);


--
-- Name: task_attachments task_attachments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.task_attachments
    ADD CONSTRAINT task_attachments_pkey PRIMARY KEY (id);


--
-- Name: task_comments task_comments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.task_comments
    ADD CONSTRAINT task_comments_pkey PRIMARY KEY (id);


--
-- Name: task_project_teams task_project_teams_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.task_project_teams
    ADD CONSTRAINT task_project_teams_pkey PRIMARY KEY (project_id, team_id);


--
-- Name: task_projects task_projects_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.task_projects
    ADD CONSTRAINT task_projects_pkey PRIMARY KEY (id);


--
-- Name: task_relations task_relations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.task_relations
    ADD CONSTRAINT task_relations_pkey PRIMARY KEY (id);


--
-- Name: task_statuses task_statuses_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.task_statuses
    ADD CONSTRAINT task_statuses_pkey PRIMARY KEY (id);


--
-- Name: task_statuses task_statuses_team_id_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.task_statuses
    ADD CONSTRAINT task_statuses_team_id_id_key UNIQUE (team_id, id);


--
-- Name: task_teams task_teams_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.task_teams
    ADD CONSTRAINT task_teams_pkey PRIMARY KEY (id);


--
-- Name: tasks tasks_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tasks
    ADD CONSTRAINT tasks_pkey PRIMARY KEY (id);


--
-- Name: team_members team_members_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.team_members
    ADD CONSTRAINT team_members_pkey PRIMARY KEY (id);


--
-- Name: idx_affiliations_current; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_affiliations_current ON public.affiliations USING btree (organization_id) WHERE is_current;


--
-- Name: idx_affiliations_org; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_affiliations_org ON public.affiliations USING btree (organization_id);


--
-- Name: idx_affiliations_person; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_affiliations_person ON public.affiliations USING btree (person_id);


--
-- Name: idx_affiliations_role_family; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_affiliations_role_family ON public.affiliations USING btree (role_family) WHERE is_current;


--
-- Name: idx_affiliations_seniority; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_affiliations_seniority ON public.affiliations USING btree (seniority) WHERE is_current;


--
-- Name: idx_ai_notes_document; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ai_notes_document ON public.ai_notes USING btree (document_id);


--
-- Name: idx_ai_notes_generated; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ai_notes_generated ON public.ai_notes USING btree (generated_at DESC);


--
-- Name: idx_ai_notes_interaction; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ai_notes_interaction ON public.ai_notes USING btree (interaction_id);


--
-- Name: idx_ai_notes_search_fts; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ai_notes_search_fts ON public.ai_notes USING gin (search_tsv);


--
-- Name: idx_ai_notes_subject; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ai_notes_subject ON public.ai_notes USING btree (subject_type, subject_id);


--
-- Name: idx_call_transcripts_interaction; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_call_transcripts_interaction ON public.call_transcripts USING btree (interaction_id);


--
-- Name: idx_call_transcripts_search_fts; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_call_transcripts_search_fts ON public.call_transcripts USING gin (search_tsv);


--
-- Name: idx_document_interactions_document; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_document_interactions_document ON public.document_interactions USING btree (document_id);


--
-- Name: idx_document_interactions_interaction; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_document_interactions_interaction ON public.document_interactions USING btree (interaction_id);


--
-- Name: idx_document_interactions_role; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_document_interactions_role ON public.document_interactions USING btree (role);


--
-- Name: idx_document_organizations_document; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_document_organizations_document ON public.document_organizations USING btree (document_id);


--
-- Name: idx_document_organizations_org; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_document_organizations_org ON public.document_organizations USING btree (organization_id);


--
-- Name: idx_document_organizations_role; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_document_organizations_role ON public.document_organizations USING btree (role);


--
-- Name: idx_document_people_document; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_document_people_document ON public.document_people USING btree (document_id);


--
-- Name: idx_document_people_person; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_document_people_person ON public.document_people USING btree (person_id);


--
-- Name: idx_document_people_role; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_document_people_role ON public.document_people USING btree (role);


--
-- Name: idx_documents_archived; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_documents_archived ON public.documents USING btree (archived_at) WHERE (archived_at IS NULL);


--
-- Name: idx_documents_authored_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_documents_authored_at ON public.documents USING btree (authored_at DESC);


--
-- Name: idx_documents_document_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_documents_document_type ON public.documents USING btree (document_type);


--
-- Name: idx_documents_metadata; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_documents_metadata ON public.documents USING gin (metadata);


--
-- Name: idx_documents_occurred_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_documents_occurred_at ON public.documents USING btree (occurred_at DESC);


--
-- Name: idx_documents_search_fts; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_documents_search_fts ON public.documents USING gin (search_tsv) WHERE (archived_at IS NULL);


--
-- Name: idx_documents_source_path; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_documents_source_path ON public.documents USING btree (source_path);


--
-- Name: idx_documents_title_trgm; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_documents_title_trgm ON public.documents USING gin (lower(title) public.gin_trgm_ops) WHERE (archived_at IS NULL);


--
-- Name: idx_external_identities_entity; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_external_identities_entity ON public.external_identities USING btree (entity_type, entity_id);


--
-- Name: idx_extracted_facts_document; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_extracted_facts_document ON public.extracted_facts USING btree (document_id);


--
-- Name: idx_extracted_facts_observed; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_extracted_facts_observed ON public.extracted_facts USING btree (observed_at DESC);


--
-- Name: idx_extracted_facts_search_fts; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_extracted_facts_search_fts ON public.extracted_facts USING gin (search_tsv);


--
-- Name: idx_extracted_facts_subject; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_extracted_facts_subject ON public.extracted_facts USING btree (subject_type, subject_id, key);


--
-- Name: idx_interaction_participants_org; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_interaction_participants_org ON public.interaction_participants USING btree (organization_id);


--
-- Name: idx_interaction_participants_person; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_interaction_participants_person ON public.interaction_participants USING btree (person_id);


--
-- Name: idx_interactions_archived; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_interactions_archived ON public.interactions USING btree (archived_at) WHERE (archived_at IS NULL);


--
-- Name: idx_interactions_occurred_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_interactions_occurred_at ON public.interactions USING btree (occurred_at DESC);


--
-- Name: idx_interactions_search_fts; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_interactions_search_fts ON public.interactions USING gin (search_tsv) WHERE (archived_at IS NULL);


--
-- Name: idx_interactions_subject_trgm; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_interactions_subject_trgm ON public.interactions USING gin (lower(subject) public.gin_trgm_ops) WHERE ((archived_at IS NULL) AND (subject IS NOT NULL));


--
-- Name: idx_interactions_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_interactions_type ON public.interactions USING btree (type);


--
-- Name: idx_org_research_profiles_search_fts; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_org_research_profiles_search_fts ON public.organization_research_profiles USING gin (search_tsv);


--
-- Name: idx_organization_research_profiles_category; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_organization_research_profiles_category ON public.organization_research_profiles USING btree (category);


--
-- Name: idx_organization_research_profiles_org; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_organization_research_profiles_org ON public.organization_research_profiles USING btree (organization_id);


--
-- Name: idx_organization_research_profiles_researched_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_organization_research_profiles_researched_at ON public.organization_research_profiles USING btree (researched_at DESC);


--
-- Name: idx_organizations_archived; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_organizations_archived ON public.organizations USING btree (archived_at) WHERE (archived_at IS NULL);


--
-- Name: idx_organizations_name; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_organizations_name ON public.organizations USING btree (lower(name));


--
-- Name: idx_organizations_name_trgm; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_organizations_name_trgm ON public.organizations USING gin (lower(name) public.gin_trgm_ops) WHERE (archived_at IS NULL);


--
-- Name: idx_organizations_search_fts; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_organizations_search_fts ON public.organizations USING gin (search_tsv) WHERE (archived_at IS NULL);


--
-- Name: idx_partnership_documents_document; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_partnership_documents_document ON public.partnership_documents USING btree (document_id);


--
-- Name: idx_partnership_documents_partnership; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_partnership_documents_partnership ON public.partnership_documents USING btree (partnership_id);


--
-- Name: idx_partnership_documents_role; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_partnership_documents_role ON public.partnership_documents USING btree (role);


--
-- Name: idx_partnership_integrations_archived; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_partnership_integrations_archived ON public.partnership_integrations USING btree (archived_at) WHERE (archived_at IS NULL);


--
-- Name: idx_partnership_integrations_formats; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_partnership_integrations_formats ON public.partnership_integrations USING gin (data_formats);


--
-- Name: idx_partnership_integrations_metadata; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_partnership_integrations_metadata ON public.partnership_integrations USING gin (metadata);


--
-- Name: idx_partnership_integrations_partnership; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_partnership_integrations_partnership ON public.partnership_integrations USING btree (partnership_id);


--
-- Name: idx_partnership_integrations_search_fts; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_partnership_integrations_search_fts ON public.partnership_integrations USING gin (search_tsv) WHERE (archived_at IS NULL);


--
-- Name: idx_partnership_integrations_service; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_partnership_integrations_service ON public.partnership_integrations USING btree (service_id);


--
-- Name: idx_partnership_integrations_source; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_partnership_integrations_source ON public.partnership_integrations USING btree (source_id);


--
-- Name: idx_partnership_integrations_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_partnership_integrations_status ON public.partnership_integrations USING btree (status);


--
-- Name: idx_partnership_integrations_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_partnership_integrations_type ON public.partnership_integrations USING btree (integration_type);


--
-- Name: idx_partnership_interactions_interaction; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_partnership_interactions_interaction ON public.partnership_interactions USING btree (interaction_id);


--
-- Name: idx_partnership_interactions_partnership; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_partnership_interactions_partnership ON public.partnership_interactions USING btree (partnership_id);


--
-- Name: idx_partnership_interactions_role; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_partnership_interactions_role ON public.partnership_interactions USING btree (role);


--
-- Name: idx_partnership_people_partnership; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_partnership_people_partnership ON public.partnership_people USING btree (partnership_id);


--
-- Name: idx_partnership_people_person; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_partnership_people_person ON public.partnership_people USING btree (person_id);


--
-- Name: idx_partnership_people_role; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_partnership_people_role ON public.partnership_people USING btree (role);


--
-- Name: idx_partnership_services_archived; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_partnership_services_archived ON public.partnership_services USING btree (archived_at) WHERE (archived_at IS NULL);


--
-- Name: idx_partnership_services_metadata; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_partnership_services_metadata ON public.partnership_services USING gin (metadata);


--
-- Name: idx_partnership_services_modalities; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_partnership_services_modalities ON public.partnership_services USING gin (data_modalities);


--
-- Name: idx_partnership_services_partnership; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_partnership_services_partnership ON public.partnership_services USING btree (partnership_id);


--
-- Name: idx_partnership_services_search_fts; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_partnership_services_search_fts ON public.partnership_services USING gin (search_tsv) WHERE (archived_at IS NULL);


--
-- Name: idx_partnership_services_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_partnership_services_status ON public.partnership_services USING btree (status);


--
-- Name: idx_partnership_services_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_partnership_services_type ON public.partnership_services USING btree (service_type);


--
-- Name: idx_partnerships_archived; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_partnerships_archived ON public.partnerships USING btree (archived_at) WHERE (archived_at IS NULL);


--
-- Name: idx_partnerships_metadata; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_partnerships_metadata ON public.partnerships USING gin (metadata);


--
-- Name: idx_partnerships_organization; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_partnerships_organization ON public.partnerships USING btree (organization_id);


--
-- Name: idx_partnerships_owner; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_partnerships_owner ON public.partnerships USING btree (owner_person_id);


--
-- Name: idx_partnerships_priority; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_partnerships_priority ON public.partnerships USING btree (priority);


--
-- Name: idx_partnerships_search_fts; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_partnerships_search_fts ON public.partnerships USING gin (search_tsv) WHERE (archived_at IS NULL);


--
-- Name: idx_partnerships_source; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_partnerships_source ON public.partnerships USING btree (source_id);


--
-- Name: idx_partnerships_stage; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_partnerships_stage ON public.partnerships USING btree (stage);


--
-- Name: idx_partnerships_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_partnerships_type ON public.partnerships USING btree (partnership_type);


--
-- Name: idx_people_archived; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_people_archived ON public.people USING btree (archived_at) WHERE (archived_at IS NULL);


--
-- Name: idx_people_current_organization; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_people_current_organization ON public.people USING btree (current_organization_id) WHERE ((archived_at IS NULL) AND (current_organization_id IS NOT NULL));


--
-- Name: idx_people_full_name; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_people_full_name ON public.people USING btree (lower(full_name));


--
-- Name: idx_people_full_name_trgm; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_people_full_name_trgm ON public.people USING gin (lower(full_name) public.gin_trgm_ops) WHERE (archived_at IS NULL);


--
-- Name: idx_people_role_family; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_people_role_family ON public.people USING btree (role_family) WHERE (archived_at IS NULL);


--
-- Name: idx_people_search_fts; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_people_search_fts ON public.people USING gin (search_tsv) WHERE (archived_at IS NULL);


--
-- Name: idx_people_seniority; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_people_seniority ON public.people USING btree (seniority) WHERE (archived_at IS NULL);


--
-- Name: idx_person_emails_email; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_person_emails_email ON public.person_emails USING btree (email);


--
-- Name: idx_person_phones_phone; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_person_phones_phone ON public.person_phones USING btree (phone);


--
-- Name: idx_rel_edges_source; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rel_edges_source ON public.relationship_edges USING btree (source_entity_type, source_entity_id);


--
-- Name: idx_rel_edges_target; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rel_edges_target ON public.relationship_edges USING btree (target_entity_type, target_entity_id);


--
-- Name: idx_semantic_embeddings_archived; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_semantic_embeddings_archived ON public.semantic_embeddings USING btree (archived_at) WHERE (archived_at IS NULL);


--
-- Name: idx_semantic_embeddings_content_fts; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_semantic_embeddings_content_fts ON public.semantic_embeddings USING gin (search_tsv) WHERE (archived_at IS NULL);


--
-- Name: idx_semantic_embeddings_embedding_hnsw; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_semantic_embeddings_embedding_hnsw ON public.semantic_embeddings USING hnsw (embedding public.vector_cosine_ops) WHERE (archived_at IS NULL);


--
-- Name: idx_semantic_embeddings_model; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_semantic_embeddings_model ON public.semantic_embeddings USING btree (embedding_provider, embedding_model, embedding_model_version) WHERE (archived_at IS NULL);


--
-- Name: idx_semantic_embeddings_target; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_semantic_embeddings_target ON public.semantic_embeddings USING btree (target_type, target_id) WHERE (archived_at IS NULL);


--
-- Name: idx_taggings_target; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_taggings_target ON public.taggings USING btree (target_type, target_id);


--
-- Name: idx_task_attachments_archived; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_task_attachments_archived ON public.task_attachments USING btree (archived_at) WHERE (archived_at IS NULL);


--
-- Name: idx_task_attachments_metadata; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_task_attachments_metadata ON public.task_attachments USING gin (metadata);


--
-- Name: idx_task_attachments_task; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_task_attachments_task ON public.task_attachments USING btree (task_id);


--
-- Name: idx_task_comments_archived; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_task_comments_archived ON public.task_comments USING btree (archived_at) WHERE (archived_at IS NULL);


--
-- Name: idx_task_comments_author_member; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_task_comments_author_member ON public.task_comments USING btree (author_member_id);


--
-- Name: idx_task_comments_metadata; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_task_comments_metadata ON public.task_comments USING gin (metadata);


--
-- Name: idx_task_comments_parent; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_task_comments_parent ON public.task_comments USING btree (parent_comment_id);


--
-- Name: idx_task_comments_search_fts; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_task_comments_search_fts ON public.task_comments USING gin (search_tsv) WHERE (archived_at IS NULL);


--
-- Name: idx_task_comments_source_updated_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_task_comments_source_updated_at ON public.task_comments USING btree (source_updated_at DESC);


--
-- Name: idx_task_comments_task; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_task_comments_task ON public.task_comments USING btree (task_id, source_created_at);


--
-- Name: idx_task_project_teams_team; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_task_project_teams_team ON public.task_project_teams USING btree (team_id);


--
-- Name: idx_task_projects_archived; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_task_projects_archived ON public.task_projects USING btree (archived_at) WHERE (archived_at IS NULL);


--
-- Name: idx_task_projects_lead_member; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_task_projects_lead_member ON public.task_projects USING btree (lead_member_id);


--
-- Name: idx_task_projects_metadata; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_task_projects_metadata ON public.task_projects USING gin (metadata);


--
-- Name: idx_task_projects_name_trgm; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_task_projects_name_trgm ON public.task_projects USING gin (lower(name) public.gin_trgm_ops) WHERE (archived_at IS NULL);


--
-- Name: idx_task_projects_priority; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_task_projects_priority ON public.task_projects USING btree (priority_value);


--
-- Name: idx_task_projects_search_fts; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_task_projects_search_fts ON public.task_projects USING gin (search_tsv) WHERE (archived_at IS NULL);


--
-- Name: idx_task_projects_source; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_task_projects_source ON public.task_projects USING btree (source_id);


--
-- Name: idx_task_projects_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_task_projects_status ON public.task_projects USING btree (status_type);


--
-- Name: idx_task_relations_archived; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_task_relations_archived ON public.task_relations USING btree (archived_at) WHERE (archived_at IS NULL);


--
-- Name: idx_task_relations_metadata; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_task_relations_metadata ON public.task_relations USING gin (metadata);


--
-- Name: idx_task_relations_related; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_task_relations_related ON public.task_relations USING btree (related_task_id);


--
-- Name: idx_task_relations_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_task_relations_type ON public.task_relations USING btree (relation_type);


--
-- Name: idx_task_statuses_archived; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_task_statuses_archived ON public.task_statuses USING btree (archived_at) WHERE (archived_at IS NULL);


--
-- Name: idx_task_statuses_metadata; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_task_statuses_metadata ON public.task_statuses USING gin (metadata);


--
-- Name: idx_task_statuses_source; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_task_statuses_source ON public.task_statuses USING btree (source_id);


--
-- Name: idx_task_statuses_team; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_task_statuses_team ON public.task_statuses USING btree (team_id);


--
-- Name: idx_task_statuses_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_task_statuses_type ON public.task_statuses USING btree (status_type);


--
-- Name: idx_task_teams_archived; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_task_teams_archived ON public.task_teams USING btree (archived_at) WHERE (archived_at IS NULL);


--
-- Name: idx_task_teams_metadata; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_task_teams_metadata ON public.task_teams USING gin (metadata);


--
-- Name: idx_task_teams_source; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_task_teams_source ON public.task_teams USING btree (source_id);


--
-- Name: idx_tasks_active_updated_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_tasks_active_updated_at ON public.tasks USING btree (updated_at DESC) WHERE (archived_at IS NULL);


--
-- Name: idx_tasks_archived; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_tasks_archived ON public.tasks USING btree (archived_at) WHERE (archived_at IS NULL);


--
-- Name: idx_tasks_assignee_member; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_tasks_assignee_member ON public.tasks USING btree (assignee_member_id);


--
-- Name: idx_tasks_creator_member; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_tasks_creator_member ON public.tasks USING btree (creator_member_id);


--
-- Name: idx_tasks_due_date; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_tasks_due_date ON public.tasks USING btree (due_date) WHERE (due_date IS NOT NULL);


--
-- Name: idx_tasks_metadata; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_tasks_metadata ON public.tasks USING gin (metadata);


--
-- Name: idx_tasks_parent; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_tasks_parent ON public.tasks USING btree (parent_task_id);


--
-- Name: idx_tasks_priority; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_tasks_priority ON public.tasks USING btree (priority_value);


--
-- Name: idx_tasks_project_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_tasks_project_status ON public.tasks USING btree (project_id, status_id);


--
-- Name: idx_tasks_search_fts; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_tasks_search_fts ON public.tasks USING gin (search_tsv) WHERE (archived_at IS NULL);


--
-- Name: idx_tasks_source_updated_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_tasks_source_updated_at ON public.tasks USING btree (source_updated_at DESC);


--
-- Name: idx_tasks_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_tasks_status ON public.tasks USING btree (status_id);


--
-- Name: idx_tasks_team_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_tasks_team_status ON public.tasks USING btree (team_id, status_id);


--
-- Name: idx_tasks_title_trgm; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_tasks_title_trgm ON public.tasks USING gin (lower(title) public.gin_trgm_ops) WHERE (archived_at IS NULL);


--
-- Name: idx_team_members_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_team_members_active ON public.team_members USING btree (is_active) WHERE (archived_at IS NULL);


--
-- Name: idx_team_members_archived; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_team_members_archived ON public.team_members USING btree (archived_at) WHERE (archived_at IS NULL);


--
-- Name: idx_team_members_metadata; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_team_members_metadata ON public.team_members USING gin (metadata);


--
-- Name: idx_team_members_name_trgm; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_team_members_name_trgm ON public.team_members USING gin (lower(name) public.gin_trgm_ops) WHERE (archived_at IS NULL);


--
-- Name: idx_team_members_search_fts; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_team_members_search_fts ON public.team_members USING gin (search_tsv) WHERE (archived_at IS NULL);


--
-- Name: idx_team_members_source; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_team_members_source ON public.team_members USING btree (source_id);


--
-- Name: uq_affiliations_primary_per_person; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_affiliations_primary_per_person ON public.affiliations USING btree (person_id) WHERE is_primary;


--
-- Name: uq_documents_source_external_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_documents_source_external_id ON public.documents USING btree (source_id, source_external_id) WHERE (source_external_id IS NOT NULL);


--
-- Name: uq_interaction_participants_org; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_interaction_participants_org ON public.interaction_participants USING btree (interaction_id, organization_id, role) WHERE (organization_id IS NOT NULL);


--
-- Name: uq_interaction_participants_person; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_interaction_participants_person ON public.interaction_participants USING btree (interaction_id, person_id, role) WHERE (person_id IS NOT NULL);


--
-- Name: uq_organizations_domain; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_organizations_domain ON public.organizations USING btree (domain);


--
-- Name: uq_partnership_services_active_name; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_partnership_services_active_name ON public.partnership_services USING btree (partnership_id, service_type, lower(name)) WHERE (archived_at IS NULL);


--
-- Name: uq_partnerships_active_org_name; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_partnerships_active_org_name ON public.partnerships USING btree (organization_id, lower(name)) WHERE (archived_at IS NULL);


--
-- Name: uq_people_primary_email; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_people_primary_email ON public.people USING btree (primary_email);


--
-- Name: uq_semantic_embeddings_active_chunk; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_semantic_embeddings_active_chunk ON public.semantic_embeddings USING btree (target_type, target_id, embedding_provider, embedding_model, embedding_model_version, chunk_index) WHERE (archived_at IS NULL);


--
-- Name: uq_task_attachments_source_external_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_task_attachments_source_external_id ON public.task_attachments USING btree (source_id, source_external_id) WHERE (source_external_id IS NOT NULL);


--
-- Name: uq_task_comments_source_external_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_task_comments_source_external_id ON public.task_comments USING btree (source_id, source_external_id) WHERE (source_external_id IS NOT NULL);


--
-- Name: uq_task_projects_active_name; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_task_projects_active_name ON public.task_projects USING btree (lower(name)) WHERE (archived_at IS NULL);


--
-- Name: uq_task_projects_source_external_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_task_projects_source_external_id ON public.task_projects USING btree (source_id, source_external_id) WHERE (source_external_id IS NOT NULL);


--
-- Name: uq_task_relations_active; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_task_relations_active ON public.task_relations USING btree (task_id, related_task_id, relation_type) WHERE (archived_at IS NULL);


--
-- Name: uq_task_statuses_active_team_name; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_task_statuses_active_team_name ON public.task_statuses USING btree (team_id, lower(name)) WHERE (archived_at IS NULL);


--
-- Name: uq_task_statuses_source_external_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_task_statuses_source_external_id ON public.task_statuses USING btree (source_id, source_external_id) WHERE (source_external_id IS NOT NULL);


--
-- Name: uq_task_teams_active_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_task_teams_active_key ON public.task_teams USING btree (lower(key)) WHERE ((archived_at IS NULL) AND (key IS NOT NULL));


--
-- Name: uq_task_teams_active_name; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_task_teams_active_name ON public.task_teams USING btree (lower(name)) WHERE (archived_at IS NULL);


--
-- Name: uq_task_teams_source_external_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_task_teams_source_external_id ON public.task_teams USING btree (source_id, source_external_id) WHERE (source_external_id IS NOT NULL);


--
-- Name: uq_tasks_source_external_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_tasks_source_external_id ON public.tasks USING btree (source_id, source_external_id) WHERE (source_external_id IS NOT NULL);


--
-- Name: uq_tasks_source_identifier; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_tasks_source_identifier ON public.tasks USING btree (source_id, source_identifier) WHERE (source_identifier IS NOT NULL);


--
-- Name: uq_team_members_email; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_team_members_email ON public.team_members USING btree (email);


--
-- Name: uq_team_members_source_external_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_team_members_source_external_id ON public.team_members USING btree (source_id, source_external_id) WHERE (source_external_id IS NOT NULL);


--
-- Name: affiliations trg_affiliations_sync_person_current; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_affiliations_sync_person_current AFTER INSERT OR DELETE OR UPDATE ON public.affiliations FOR EACH ROW EXECUTE FUNCTION public.crm_affiliations_sync_person_current();


--
-- Name: affiliations trg_affiliations_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_affiliations_updated_at BEFORE UPDATE ON public.affiliations FOR EACH ROW EXECUTE FUNCTION public.crm_set_updated_at();


--
-- Name: ai_notes trg_ai_notes_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_ai_notes_updated_at BEFORE UPDATE ON public.ai_notes FOR EACH ROW EXECUTE FUNCTION public.crm_set_updated_at();


--
-- Name: call_transcripts trg_call_transcripts_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_call_transcripts_updated_at BEFORE UPDATE ON public.call_transcripts FOR EACH ROW EXECUTE FUNCTION public.crm_set_updated_at();


--
-- Name: document_interactions trg_document_interactions_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_document_interactions_updated_at BEFORE UPDATE ON public.document_interactions FOR EACH ROW EXECUTE FUNCTION public.crm_set_updated_at();


--
-- Name: document_organizations trg_document_organizations_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_document_organizations_updated_at BEFORE UPDATE ON public.document_organizations FOR EACH ROW EXECUTE FUNCTION public.crm_set_updated_at();


--
-- Name: document_people trg_document_people_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_document_people_updated_at BEFORE UPDATE ON public.document_people FOR EACH ROW EXECUTE FUNCTION public.crm_set_updated_at();


--
-- Name: documents trg_documents_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_documents_updated_at BEFORE UPDATE ON public.documents FOR EACH ROW EXECUTE FUNCTION public.crm_set_updated_at();


--
-- Name: external_identities trg_external_identities_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_external_identities_updated_at BEFORE UPDATE ON public.external_identities FOR EACH ROW EXECUTE FUNCTION public.crm_set_updated_at();


--
-- Name: extracted_facts trg_extracted_facts_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_extracted_facts_updated_at BEFORE UPDATE ON public.extracted_facts FOR EACH ROW EXECUTE FUNCTION public.crm_set_updated_at();


--
-- Name: interaction_participants trg_interaction_participants_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_interaction_participants_updated_at BEFORE UPDATE ON public.interaction_participants FOR EACH ROW EXECUTE FUNCTION public.crm_set_updated_at();


--
-- Name: interactions trg_interactions_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_interactions_updated_at BEFORE UPDATE ON public.interactions FOR EACH ROW EXECUTE FUNCTION public.crm_set_updated_at();


--
-- Name: organization_research_profiles trg_organization_research_profiles_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_organization_research_profiles_updated_at BEFORE UPDATE ON public.organization_research_profiles FOR EACH ROW EXECUTE FUNCTION public.crm_set_updated_at();


--
-- Name: organizations trg_organizations_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_organizations_updated_at BEFORE UPDATE ON public.organizations FOR EACH ROW EXECUTE FUNCTION public.crm_set_updated_at();


--
-- Name: partnership_documents trg_partnership_documents_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_partnership_documents_updated_at BEFORE UPDATE ON public.partnership_documents FOR EACH ROW EXECUTE FUNCTION public.crm_set_updated_at();


--
-- Name: partnership_integrations trg_partnership_integrations_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_partnership_integrations_updated_at BEFORE UPDATE ON public.partnership_integrations FOR EACH ROW EXECUTE FUNCTION public.crm_set_updated_at();


--
-- Name: partnership_interactions trg_partnership_interactions_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_partnership_interactions_updated_at BEFORE UPDATE ON public.partnership_interactions FOR EACH ROW EXECUTE FUNCTION public.crm_set_updated_at();


--
-- Name: partnership_people trg_partnership_people_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_partnership_people_updated_at BEFORE UPDATE ON public.partnership_people FOR EACH ROW EXECUTE FUNCTION public.crm_set_updated_at();


--
-- Name: partnership_services trg_partnership_services_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_partnership_services_updated_at BEFORE UPDATE ON public.partnership_services FOR EACH ROW EXECUTE FUNCTION public.crm_set_updated_at();


--
-- Name: partnerships trg_partnerships_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_partnerships_updated_at BEFORE UPDATE ON public.partnerships FOR EACH ROW EXECUTE FUNCTION public.crm_set_updated_at();


--
-- Name: people trg_people_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_people_updated_at BEFORE UPDATE ON public.people FOR EACH ROW EXECUTE FUNCTION public.crm_set_updated_at();


--
-- Name: person_emails trg_person_emails_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_person_emails_updated_at BEFORE UPDATE ON public.person_emails FOR EACH ROW EXECUTE FUNCTION public.crm_set_updated_at();


--
-- Name: person_phones trg_person_phones_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_person_phones_updated_at BEFORE UPDATE ON public.person_phones FOR EACH ROW EXECUTE FUNCTION public.crm_set_updated_at();


--
-- Name: relationship_edges trg_relationship_edges_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_relationship_edges_updated_at BEFORE UPDATE ON public.relationship_edges FOR EACH ROW EXECUTE FUNCTION public.crm_set_updated_at();


--
-- Name: semantic_embeddings trg_semantic_embeddings_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_semantic_embeddings_updated_at BEFORE UPDATE ON public.semantic_embeddings FOR EACH ROW EXECUTE FUNCTION public.crm_set_updated_at();


--
-- Name: sources trg_sources_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_sources_updated_at BEFORE UPDATE ON public.sources FOR EACH ROW EXECUTE FUNCTION public.crm_set_updated_at();


--
-- Name: tags trg_tags_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_tags_updated_at BEFORE UPDATE ON public.tags FOR EACH ROW EXECUTE FUNCTION public.crm_set_updated_at();


--
-- Name: task_attachments trg_task_attachments_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_task_attachments_updated_at BEFORE UPDATE ON public.task_attachments FOR EACH ROW EXECUTE FUNCTION public.crm_set_updated_at();


--
-- Name: task_comments trg_task_comments_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_task_comments_updated_at BEFORE UPDATE ON public.task_comments FOR EACH ROW EXECUTE FUNCTION public.crm_set_updated_at();


--
-- Name: task_project_teams trg_task_project_teams_no_orphan; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_task_project_teams_no_orphan BEFORE DELETE OR UPDATE OF project_id, team_id ON public.task_project_teams FOR EACH ROW EXECUTE FUNCTION public.crm_prevent_task_project_team_orphan();


--
-- Name: task_projects trg_task_projects_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_task_projects_updated_at BEFORE UPDATE ON public.task_projects FOR EACH ROW EXECUTE FUNCTION public.crm_set_updated_at();


--
-- Name: task_relations trg_task_relations_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_task_relations_updated_at BEFORE UPDATE ON public.task_relations FOR EACH ROW EXECUTE FUNCTION public.crm_set_updated_at();


--
-- Name: task_statuses trg_task_statuses_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_task_statuses_updated_at BEFORE UPDATE ON public.task_statuses FOR EACH ROW EXECUTE FUNCTION public.crm_set_updated_at();


--
-- Name: task_teams trg_task_teams_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_task_teams_updated_at BEFORE UPDATE ON public.task_teams FOR EACH ROW EXECUTE FUNCTION public.crm_set_updated_at();


--
-- Name: tasks trg_tasks_project_team_guard; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_tasks_project_team_guard BEFORE INSERT OR UPDATE OF project_id, team_id ON public.tasks FOR EACH ROW EXECUTE FUNCTION public.crm_check_task_project_team();


--
-- Name: tasks trg_tasks_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_tasks_updated_at BEFORE UPDATE ON public.tasks FOR EACH ROW EXECUTE FUNCTION public.crm_set_updated_at();


--
-- Name: team_members trg_team_members_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_team_members_updated_at BEFORE UPDATE ON public.team_members FOR EACH ROW EXECUTE FUNCTION public.crm_set_updated_at();


--
-- Name: affiliations affiliations_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.affiliations
    ADD CONSTRAINT affiliations_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: affiliations affiliations_person_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.affiliations
    ADD CONSTRAINT affiliations_person_id_fkey FOREIGN KEY (person_id) REFERENCES public.people(id) ON DELETE CASCADE;


--
-- Name: affiliations affiliations_source_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.affiliations
    ADD CONSTRAINT affiliations_source_id_fkey FOREIGN KEY (source_id) REFERENCES public.sources(id) ON DELETE SET NULL;


--
-- Name: ai_notes ai_notes_document_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_notes
    ADD CONSTRAINT ai_notes_document_id_fkey FOREIGN KEY (document_id) REFERENCES public.documents(id) ON DELETE CASCADE;


--
-- Name: ai_notes ai_notes_interaction_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_notes
    ADD CONSTRAINT ai_notes_interaction_id_fkey FOREIGN KEY (interaction_id) REFERENCES public.interactions(id) ON DELETE CASCADE;


--
-- Name: ai_notes ai_notes_source_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_notes
    ADD CONSTRAINT ai_notes_source_id_fkey FOREIGN KEY (source_id) REFERENCES public.sources(id) ON DELETE SET NULL;


--
-- Name: call_transcripts call_transcripts_interaction_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.call_transcripts
    ADD CONSTRAINT call_transcripts_interaction_id_fkey FOREIGN KEY (interaction_id) REFERENCES public.interactions(id) ON DELETE CASCADE;


--
-- Name: call_transcripts call_transcripts_source_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.call_transcripts
    ADD CONSTRAINT call_transcripts_source_id_fkey FOREIGN KEY (source_id) REFERENCES public.sources(id) ON DELETE SET NULL;


--
-- Name: document_interactions document_interactions_document_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.document_interactions
    ADD CONSTRAINT document_interactions_document_id_fkey FOREIGN KEY (document_id) REFERENCES public.documents(id) ON DELETE CASCADE;


--
-- Name: document_interactions document_interactions_interaction_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.document_interactions
    ADD CONSTRAINT document_interactions_interaction_id_fkey FOREIGN KEY (interaction_id) REFERENCES public.interactions(id) ON DELETE CASCADE;


--
-- Name: document_organizations document_organizations_document_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.document_organizations
    ADD CONSTRAINT document_organizations_document_id_fkey FOREIGN KEY (document_id) REFERENCES public.documents(id) ON DELETE CASCADE;


--
-- Name: document_organizations document_organizations_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.document_organizations
    ADD CONSTRAINT document_organizations_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: document_people document_people_document_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.document_people
    ADD CONSTRAINT document_people_document_id_fkey FOREIGN KEY (document_id) REFERENCES public.documents(id) ON DELETE CASCADE;


--
-- Name: document_people document_people_person_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.document_people
    ADD CONSTRAINT document_people_person_id_fkey FOREIGN KEY (person_id) REFERENCES public.people(id) ON DELETE CASCADE;


--
-- Name: documents documents_source_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.documents
    ADD CONSTRAINT documents_source_id_fkey FOREIGN KEY (source_id) REFERENCES public.sources(id) ON DELETE SET NULL;


--
-- Name: external_identities external_identities_source_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.external_identities
    ADD CONSTRAINT external_identities_source_id_fkey FOREIGN KEY (source_id) REFERENCES public.sources(id) ON DELETE CASCADE;


--
-- Name: extracted_facts extracted_facts_document_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.extracted_facts
    ADD CONSTRAINT extracted_facts_document_id_fkey FOREIGN KEY (document_id) REFERENCES public.documents(id) ON DELETE SET NULL;


--
-- Name: extracted_facts extracted_facts_interaction_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.extracted_facts
    ADD CONSTRAINT extracted_facts_interaction_id_fkey FOREIGN KEY (interaction_id) REFERENCES public.interactions(id) ON DELETE SET NULL;


--
-- Name: extracted_facts extracted_facts_source_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.extracted_facts
    ADD CONSTRAINT extracted_facts_source_id_fkey FOREIGN KEY (source_id) REFERENCES public.sources(id) ON DELETE SET NULL;


--
-- Name: interaction_participants interaction_participants_interaction_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.interaction_participants
    ADD CONSTRAINT interaction_participants_interaction_id_fkey FOREIGN KEY (interaction_id) REFERENCES public.interactions(id) ON DELETE CASCADE;


--
-- Name: interaction_participants interaction_participants_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.interaction_participants
    ADD CONSTRAINT interaction_participants_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE SET NULL;


--
-- Name: interaction_participants interaction_participants_person_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.interaction_participants
    ADD CONSTRAINT interaction_participants_person_id_fkey FOREIGN KEY (person_id) REFERENCES public.people(id) ON DELETE SET NULL;


--
-- Name: interactions interactions_source_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.interactions
    ADD CONSTRAINT interactions_source_id_fkey FOREIGN KEY (source_id) REFERENCES public.sources(id) ON DELETE SET NULL;


--
-- Name: organization_research_profiles organization_research_profiles_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_research_profiles
    ADD CONSTRAINT organization_research_profiles_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: organization_research_profiles organization_research_profiles_source_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_research_profiles
    ADD CONSTRAINT organization_research_profiles_source_id_fkey FOREIGN KEY (source_id) REFERENCES public.sources(id) ON DELETE SET NULL;


--
-- Name: partnership_documents partnership_documents_document_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.partnership_documents
    ADD CONSTRAINT partnership_documents_document_id_fkey FOREIGN KEY (document_id) REFERENCES public.documents(id) ON DELETE CASCADE;


--
-- Name: partnership_documents partnership_documents_partnership_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.partnership_documents
    ADD CONSTRAINT partnership_documents_partnership_id_fkey FOREIGN KEY (partnership_id) REFERENCES public.partnerships(id) ON DELETE CASCADE;


--
-- Name: partnership_integrations partnership_integrations_partnership_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.partnership_integrations
    ADD CONSTRAINT partnership_integrations_partnership_id_fkey FOREIGN KEY (partnership_id) REFERENCES public.partnerships(id) ON DELETE CASCADE;


--
-- Name: partnership_integrations partnership_integrations_service_id_partnership_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.partnership_integrations
    ADD CONSTRAINT partnership_integrations_service_id_partnership_id_fkey FOREIGN KEY (service_id, partnership_id) REFERENCES public.partnership_services(id, partnership_id) ON DELETE CASCADE;


--
-- Name: partnership_integrations partnership_integrations_source_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.partnership_integrations
    ADD CONSTRAINT partnership_integrations_source_id_fkey FOREIGN KEY (source_id) REFERENCES public.sources(id) ON DELETE SET NULL;


--
-- Name: partnership_interactions partnership_interactions_interaction_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.partnership_interactions
    ADD CONSTRAINT partnership_interactions_interaction_id_fkey FOREIGN KEY (interaction_id) REFERENCES public.interactions(id) ON DELETE CASCADE;


--
-- Name: partnership_interactions partnership_interactions_partnership_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.partnership_interactions
    ADD CONSTRAINT partnership_interactions_partnership_id_fkey FOREIGN KEY (partnership_id) REFERENCES public.partnerships(id) ON DELETE CASCADE;


--
-- Name: partnership_people partnership_people_partnership_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.partnership_people
    ADD CONSTRAINT partnership_people_partnership_id_fkey FOREIGN KEY (partnership_id) REFERENCES public.partnerships(id) ON DELETE CASCADE;


--
-- Name: partnership_people partnership_people_person_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.partnership_people
    ADD CONSTRAINT partnership_people_person_id_fkey FOREIGN KEY (person_id) REFERENCES public.people(id) ON DELETE CASCADE;


--
-- Name: partnership_services partnership_services_partnership_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.partnership_services
    ADD CONSTRAINT partnership_services_partnership_id_fkey FOREIGN KEY (partnership_id) REFERENCES public.partnerships(id) ON DELETE CASCADE;


--
-- Name: partnerships partnerships_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.partnerships
    ADD CONSTRAINT partnerships_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: partnerships partnerships_owner_person_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.partnerships
    ADD CONSTRAINT partnerships_owner_person_id_fkey FOREIGN KEY (owner_person_id) REFERENCES public.people(id) ON DELETE SET NULL;


--
-- Name: partnerships partnerships_source_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.partnerships
    ADD CONSTRAINT partnerships_source_id_fkey FOREIGN KEY (source_id) REFERENCES public.sources(id) ON DELETE SET NULL;


--
-- Name: people people_current_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.people
    ADD CONSTRAINT people_current_organization_id_fkey FOREIGN KEY (current_organization_id) REFERENCES public.organizations(id) ON DELETE SET NULL;


--
-- Name: person_emails person_emails_person_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.person_emails
    ADD CONSTRAINT person_emails_person_id_fkey FOREIGN KEY (person_id) REFERENCES public.people(id) ON DELETE CASCADE;


--
-- Name: person_emails person_emails_source_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.person_emails
    ADD CONSTRAINT person_emails_source_id_fkey FOREIGN KEY (source_id) REFERENCES public.sources(id) ON DELETE SET NULL;


--
-- Name: person_phones person_phones_person_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.person_phones
    ADD CONSTRAINT person_phones_person_id_fkey FOREIGN KEY (person_id) REFERENCES public.people(id) ON DELETE CASCADE;


--
-- Name: person_phones person_phones_source_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.person_phones
    ADD CONSTRAINT person_phones_source_id_fkey FOREIGN KEY (source_id) REFERENCES public.sources(id) ON DELETE SET NULL;


--
-- Name: relationship_edges relationship_edges_source_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.relationship_edges
    ADD CONSTRAINT relationship_edges_source_id_fkey FOREIGN KEY (source_id) REFERENCES public.sources(id) ON DELETE SET NULL;


--
-- Name: taggings taggings_source_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.taggings
    ADD CONSTRAINT taggings_source_id_fkey FOREIGN KEY (source_id) REFERENCES public.sources(id) ON DELETE SET NULL;


--
-- Name: taggings taggings_tag_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.taggings
    ADD CONSTRAINT taggings_tag_id_fkey FOREIGN KEY (tag_id) REFERENCES public.tags(id) ON DELETE CASCADE;


--
-- Name: task_attachments task_attachments_source_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.task_attachments
    ADD CONSTRAINT task_attachments_source_id_fkey FOREIGN KEY (source_id) REFERENCES public.sources(id) ON DELETE SET NULL;


--
-- Name: task_attachments task_attachments_task_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.task_attachments
    ADD CONSTRAINT task_attachments_task_id_fkey FOREIGN KEY (task_id) REFERENCES public.tasks(id) ON DELETE CASCADE;


--
-- Name: task_comments task_comments_author_member_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.task_comments
    ADD CONSTRAINT task_comments_author_member_id_fkey FOREIGN KEY (author_member_id) REFERENCES public.team_members(id) ON DELETE SET NULL;


--
-- Name: task_comments task_comments_parent_comment_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.task_comments
    ADD CONSTRAINT task_comments_parent_comment_id_fkey FOREIGN KEY (parent_comment_id) REFERENCES public.task_comments(id) ON DELETE SET NULL;


--
-- Name: task_comments task_comments_source_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.task_comments
    ADD CONSTRAINT task_comments_source_id_fkey FOREIGN KEY (source_id) REFERENCES public.sources(id) ON DELETE SET NULL;


--
-- Name: task_comments task_comments_task_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.task_comments
    ADD CONSTRAINT task_comments_task_id_fkey FOREIGN KEY (task_id) REFERENCES public.tasks(id) ON DELETE CASCADE;


--
-- Name: task_project_teams task_project_teams_project_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.task_project_teams
    ADD CONSTRAINT task_project_teams_project_id_fkey FOREIGN KEY (project_id) REFERENCES public.task_projects(id) ON DELETE CASCADE;


--
-- Name: task_project_teams task_project_teams_team_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.task_project_teams
    ADD CONSTRAINT task_project_teams_team_id_fkey FOREIGN KEY (team_id) REFERENCES public.task_teams(id) ON DELETE CASCADE;


--
-- Name: task_projects task_projects_lead_member_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.task_projects
    ADD CONSTRAINT task_projects_lead_member_id_fkey FOREIGN KEY (lead_member_id) REFERENCES public.team_members(id) ON DELETE SET NULL;


--
-- Name: task_projects task_projects_source_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.task_projects
    ADD CONSTRAINT task_projects_source_id_fkey FOREIGN KEY (source_id) REFERENCES public.sources(id) ON DELETE SET NULL;


--
-- Name: task_relations task_relations_related_task_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.task_relations
    ADD CONSTRAINT task_relations_related_task_id_fkey FOREIGN KEY (related_task_id) REFERENCES public.tasks(id) ON DELETE CASCADE;


--
-- Name: task_relations task_relations_source_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.task_relations
    ADD CONSTRAINT task_relations_source_id_fkey FOREIGN KEY (source_id) REFERENCES public.sources(id) ON DELETE SET NULL;


--
-- Name: task_relations task_relations_task_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.task_relations
    ADD CONSTRAINT task_relations_task_id_fkey FOREIGN KEY (task_id) REFERENCES public.tasks(id) ON DELETE CASCADE;


--
-- Name: task_statuses task_statuses_source_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.task_statuses
    ADD CONSTRAINT task_statuses_source_id_fkey FOREIGN KEY (source_id) REFERENCES public.sources(id) ON DELETE SET NULL;


--
-- Name: task_statuses task_statuses_team_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.task_statuses
    ADD CONSTRAINT task_statuses_team_id_fkey FOREIGN KEY (team_id) REFERENCES public.task_teams(id) ON DELETE CASCADE;


--
-- Name: task_teams task_teams_source_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.task_teams
    ADD CONSTRAINT task_teams_source_id_fkey FOREIGN KEY (source_id) REFERENCES public.sources(id) ON DELETE SET NULL;


--
-- Name: tasks tasks_assignee_member_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tasks
    ADD CONSTRAINT tasks_assignee_member_id_fkey FOREIGN KEY (assignee_member_id) REFERENCES public.team_members(id) ON DELETE SET NULL;


--
-- Name: tasks tasks_creator_member_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tasks
    ADD CONSTRAINT tasks_creator_member_id_fkey FOREIGN KEY (creator_member_id) REFERENCES public.team_members(id) ON DELETE SET NULL;


--
-- Name: tasks tasks_delegate_member_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tasks
    ADD CONSTRAINT tasks_delegate_member_id_fkey FOREIGN KEY (delegate_member_id) REFERENCES public.team_members(id) ON DELETE SET NULL;


--
-- Name: tasks tasks_parent_task_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tasks
    ADD CONSTRAINT tasks_parent_task_id_fkey FOREIGN KEY (parent_task_id) REFERENCES public.tasks(id) ON DELETE SET NULL;


--
-- Name: tasks tasks_project_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tasks
    ADD CONSTRAINT tasks_project_id_fkey FOREIGN KEY (project_id) REFERENCES public.task_projects(id) ON DELETE SET NULL;


--
-- Name: tasks tasks_source_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tasks
    ADD CONSTRAINT tasks_source_id_fkey FOREIGN KEY (source_id) REFERENCES public.sources(id) ON DELETE SET NULL;


--
-- Name: tasks tasks_team_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tasks
    ADD CONSTRAINT tasks_team_id_fkey FOREIGN KEY (team_id) REFERENCES public.task_teams(id) ON DELETE RESTRICT;


--
-- Name: tasks tasks_team_status_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tasks
    ADD CONSTRAINT tasks_team_status_id_fkey FOREIGN KEY (team_id, status_id) REFERENCES public.task_statuses(team_id, id) ON DELETE SET NULL (status_id);


--
-- Name: team_members team_members_source_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.team_members
    ADD CONSTRAINT team_members_source_id_fkey FOREIGN KEY (source_id) REFERENCES public.sources(id) ON DELETE SET NULL;


--
-- PostgreSQL database dump complete
--
