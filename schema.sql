--
-- PostgreSQL database dump
--


-- Dumped from database version 18.2 (49f2ca4)
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
-- Name: picardo_set_updated_at(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.picardo_set_updated_at() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
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
    updated_at timestamp with time zone DEFAULT now() NOT NULL
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
    updated_at timestamp with time zone DEFAULT now() NOT NULL
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
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: organizations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.organizations (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    slug text,
    legal_name text,
    domain public.citext,
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
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


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
    CONSTRAINT partnership_integrations_data_formats_check CHECK ((jsonb_typeof(data_formats) = ANY (ARRAY['array'::text, 'object'::text]))),
    CONSTRAINT partnership_integrations_integration_type_check CHECK ((integration_type = ANY (ARRAY['api'::text, 'webhook'::text, 'sftp'::text, 'manual_upload'::text, 'pdf_import'::text, 'email'::text, 'portal'::text, 'other'::text]))),
    CONSTRAINT partnership_integrations_status_check CHECK ((status = ANY (ARRAY['not_started'::text, 'sandbox'::text, 'building'::text, 'testing'::text, 'production'::text, 'paused'::text, 'retired'::text]))),
    CONSTRAINT partnership_integrations_sync_direction_check CHECK ((sync_direction = ANY (ARRAY['inbound'::text, 'outbound'::text, 'bidirectional'::text])))
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
    primary_email public.citext,
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
    embedding_provider text DEFAULT 'ollama'::text NOT NULL,
    embedding_model text DEFAULT 'embeddinggemma'::text NOT NULL,
    embedding_model_version text DEFAULT 'latest'::text NOT NULL,
    embedding_dimension integer DEFAULT 768 NOT NULL,
    embedding public.vector(768) NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    archived_at timestamp with time zone,
    embedded_at timestamp with time zone DEFAULT now() NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT semantic_embeddings_chunk_index_check CHECK ((chunk_index >= 0)),
    CONSTRAINT semantic_embeddings_content_check CHECK ((length(TRIM(BOTH FROM content)) > 0)),
    CONSTRAINT semantic_embeddings_content_sha256_check CHECK ((content_sha256 ~ '^[a-f0-9]{64}$'::text)),
    CONSTRAINT semantic_embeddings_embedding_dimension_check CHECK ((embedding_dimension = 768)),
    CONSTRAINT semantic_embeddings_target_type_check CHECK ((target_type = ANY (ARRAY['organization'::text, 'organization_research_profile'::text, 'person'::text, 'interaction'::text, 'document'::text, 'partnership'::text, 'partnership_service'::text, 'partnership_integration'::text, 'call_transcript'::text, 'ai_note'::text, 'extracted_fact'::text])))
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
-- Name: taggings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.taggings (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tag_id uuid NOT NULL,
    target_type text NOT NULL,
    target_id uuid NOT NULL,
    source_id uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_taggings_target_type CHECK ((target_type = ANY (ARRAY['organization'::text, 'person'::text, 'interaction'::text, 'document'::text, 'partnership'::text])))
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
-- Name: idx_ai_notes_subject; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ai_notes_subject ON public.ai_notes USING btree (subject_type, subject_id);


--
-- Name: idx_call_transcripts_interaction; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_call_transcripts_interaction ON public.call_transcripts USING btree (interaction_id);


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
-- Name: idx_documents_source_path; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_documents_source_path ON public.documents USING btree (source_path);


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
-- Name: idx_interactions_occurred_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_interactions_occurred_at ON public.interactions USING btree (occurred_at DESC);


--
-- Name: idx_interactions_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_interactions_type ON public.interactions USING btree (type);


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
-- Name: idx_organizations_domain; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_organizations_domain ON public.organizations USING btree (domain);


--
-- Name: idx_organizations_name; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_organizations_name ON public.organizations USING btree (lower(name));


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
-- Name: idx_partnership_services_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_partnership_services_status ON public.partnership_services USING btree (status);


--
-- Name: idx_partnership_services_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_partnership_services_type ON public.partnership_services USING btree (service_type);


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
-- Name: idx_people_full_name; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_people_full_name ON public.people USING btree (lower(full_name));


--
-- Name: idx_people_primary_email; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_people_primary_email ON public.people USING btree (primary_email);


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
-- Name: uq_partnership_services_active_name; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_partnership_services_active_name ON public.partnership_services USING btree (partnership_id, service_type, lower(name)) WHERE (archived_at IS NULL);


--
-- Name: uq_partnerships_active_org_name; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_partnerships_active_org_name ON public.partnerships USING btree (organization_id, lower(name)) WHERE (archived_at IS NULL);


--
-- Name: uq_semantic_embeddings_active_chunk; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_semantic_embeddings_active_chunk ON public.semantic_embeddings USING btree (target_type, target_id, embedding_provider, embedding_model, embedding_model_version, chunk_index) WHERE (archived_at IS NULL);


--
-- Name: affiliations trg_affiliations_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_affiliations_updated_at BEFORE UPDATE ON public.affiliations FOR EACH ROW EXECUTE FUNCTION public.picardo_set_updated_at();


--
-- Name: ai_notes trg_ai_notes_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_ai_notes_updated_at BEFORE UPDATE ON public.ai_notes FOR EACH ROW EXECUTE FUNCTION public.picardo_set_updated_at();


--
-- Name: call_transcripts trg_call_transcripts_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_call_transcripts_updated_at BEFORE UPDATE ON public.call_transcripts FOR EACH ROW EXECUTE FUNCTION public.picardo_set_updated_at();


--
-- Name: document_interactions trg_document_interactions_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_document_interactions_updated_at BEFORE UPDATE ON public.document_interactions FOR EACH ROW EXECUTE FUNCTION public.picardo_set_updated_at();


--
-- Name: document_organizations trg_document_organizations_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_document_organizations_updated_at BEFORE UPDATE ON public.document_organizations FOR EACH ROW EXECUTE FUNCTION public.picardo_set_updated_at();


--
-- Name: document_people trg_document_people_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_document_people_updated_at BEFORE UPDATE ON public.document_people FOR EACH ROW EXECUTE FUNCTION public.picardo_set_updated_at();


--
-- Name: documents trg_documents_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_documents_updated_at BEFORE UPDATE ON public.documents FOR EACH ROW EXECUTE FUNCTION public.picardo_set_updated_at();


--
-- Name: external_identities trg_external_identities_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_external_identities_updated_at BEFORE UPDATE ON public.external_identities FOR EACH ROW EXECUTE FUNCTION public.picardo_set_updated_at();


--
-- Name: extracted_facts trg_extracted_facts_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_extracted_facts_updated_at BEFORE UPDATE ON public.extracted_facts FOR EACH ROW EXECUTE FUNCTION public.picardo_set_updated_at();


--
-- Name: interaction_participants trg_interaction_participants_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_interaction_participants_updated_at BEFORE UPDATE ON public.interaction_participants FOR EACH ROW EXECUTE FUNCTION public.picardo_set_updated_at();


--
-- Name: interactions trg_interactions_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_interactions_updated_at BEFORE UPDATE ON public.interactions FOR EACH ROW EXECUTE FUNCTION public.picardo_set_updated_at();


--
-- Name: organization_research_profiles trg_organization_research_profiles_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_organization_research_profiles_updated_at BEFORE UPDATE ON public.organization_research_profiles FOR EACH ROW EXECUTE FUNCTION public.picardo_set_updated_at();


--
-- Name: organizations trg_organizations_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_organizations_updated_at BEFORE UPDATE ON public.organizations FOR EACH ROW EXECUTE FUNCTION public.picardo_set_updated_at();


--
-- Name: partnership_documents trg_partnership_documents_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_partnership_documents_updated_at BEFORE UPDATE ON public.partnership_documents FOR EACH ROW EXECUTE FUNCTION public.picardo_set_updated_at();


--
-- Name: partnership_integrations trg_partnership_integrations_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_partnership_integrations_updated_at BEFORE UPDATE ON public.partnership_integrations FOR EACH ROW EXECUTE FUNCTION public.picardo_set_updated_at();


--
-- Name: partnership_interactions trg_partnership_interactions_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_partnership_interactions_updated_at BEFORE UPDATE ON public.partnership_interactions FOR EACH ROW EXECUTE FUNCTION public.picardo_set_updated_at();


--
-- Name: partnership_people trg_partnership_people_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_partnership_people_updated_at BEFORE UPDATE ON public.partnership_people FOR EACH ROW EXECUTE FUNCTION public.picardo_set_updated_at();


--
-- Name: partnership_services trg_partnership_services_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_partnership_services_updated_at BEFORE UPDATE ON public.partnership_services FOR EACH ROW EXECUTE FUNCTION public.picardo_set_updated_at();


--
-- Name: partnerships trg_partnerships_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_partnerships_updated_at BEFORE UPDATE ON public.partnerships FOR EACH ROW EXECUTE FUNCTION public.picardo_set_updated_at();


--
-- Name: people trg_people_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_people_updated_at BEFORE UPDATE ON public.people FOR EACH ROW EXECUTE FUNCTION public.picardo_set_updated_at();


--
-- Name: person_emails trg_person_emails_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_person_emails_updated_at BEFORE UPDATE ON public.person_emails FOR EACH ROW EXECUTE FUNCTION public.picardo_set_updated_at();


--
-- Name: person_phones trg_person_phones_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_person_phones_updated_at BEFORE UPDATE ON public.person_phones FOR EACH ROW EXECUTE FUNCTION public.picardo_set_updated_at();


--
-- Name: relationship_edges trg_relationship_edges_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_relationship_edges_updated_at BEFORE UPDATE ON public.relationship_edges FOR EACH ROW EXECUTE FUNCTION public.picardo_set_updated_at();


--
-- Name: semantic_embeddings trg_semantic_embeddings_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_semantic_embeddings_updated_at BEFORE UPDATE ON public.semantic_embeddings FOR EACH ROW EXECUTE FUNCTION public.picardo_set_updated_at();


--
-- Name: sources trg_sources_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_sources_updated_at BEFORE UPDATE ON public.sources FOR EACH ROW EXECUTE FUNCTION public.picardo_set_updated_at();


--
-- Name: tags trg_tags_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_tags_updated_at BEFORE UPDATE ON public.tags FOR EACH ROW EXECUTE FUNCTION public.picardo_set_updated_at();


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
-- PostgreSQL database dump complete
--
