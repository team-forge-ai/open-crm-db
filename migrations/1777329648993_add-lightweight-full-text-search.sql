-- Up Migration

CREATE EXTENSION IF NOT EXISTS pg_trgm;

CREATE OR REPLACE FUNCTION picardo_search_text(VARIADIC parts text[])
RETURNS text
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
  SELECT COALESCE(array_to_string(parts, ' ', ''), '');
$$;

-- Full-text indexes for direct CRM record lookup.
CREATE INDEX idx_organizations_search_fts
  ON organizations
  USING GIN (
    to_tsvector(
      'english',
      picardo_search_text(name, legal_name, domain::text, website, description, industry, hq_city, hq_region, hq_country, notes)
    )
  )
  WHERE archived_at IS NULL;

CREATE INDEX idx_people_search_fts
  ON people
  USING GIN (
    to_tsvector(
      'english',
      picardo_search_text(full_name, display_name, preferred_name, headline, summary, city, region, country, timezone, website, notes)
    )
  )
  WHERE archived_at IS NULL;

CREATE INDEX idx_interactions_search_fts
  ON interactions
  USING GIN (
    to_tsvector('english', picardo_search_text(subject, left(body, 250000), location))
  )
  WHERE archived_at IS NULL;

CREATE INDEX idx_call_transcripts_search_fts
  ON call_transcripts
  USING GIN (
    to_tsvector('english', left(raw_text, 500000))
  );

CREATE INDEX idx_documents_search_fts
  ON documents
  USING GIN (
    to_tsvector('english', picardo_search_text(title, document_type, summary, left(body, 500000), source_path))
  )
  WHERE archived_at IS NULL;

CREATE INDEX idx_ai_notes_search_fts
  ON ai_notes
  USING GIN (
    to_tsvector('english', picardo_search_text(title, left(content, 250000)))
  );

CREATE INDEX idx_extracted_facts_search_fts
  ON extracted_facts
  USING GIN (
    to_tsvector('english', picardo_search_text(key, value_text, left(source_excerpt, 50000)))
  );

CREATE INDEX idx_org_research_profiles_search_fts
  ON organization_research_profiles
  USING GIN (
    to_tsvector(
      'english',
      picardo_search_text(
        canonical_name,
        website,
        domain::text,
        one_line_description,
        category,
        healthcare_relevance,
        partnership_fit,
        partnership_fit_rationale,
        offerings::text,
        likely_use_cases::text,
        integration_signals::text,
        compliance_signals::text,
        key_public_people::text,
        suggested_tags::text,
        review_flags::text
      )
    )
  );

CREATE INDEX idx_partnerships_search_fts
  ON partnerships
  USING GIN (
    to_tsvector(
      'english',
      picardo_search_text(name, partnership_type, stage, priority, strategic_rationale, commercial_model, status_notes)
    )
  )
  WHERE archived_at IS NULL;

CREATE INDEX idx_partnership_services_search_fts
  ON partnership_services
  USING GIN (
    to_tsvector(
      'english',
      picardo_search_text(name, service_type, status, clinical_use, data_modalities::text)
    )
  )
  WHERE archived_at IS NULL;

CREATE INDEX idx_partnership_integrations_search_fts
  ON partnership_integrations
  USING GIN (
    to_tsvector(
      'english',
      picardo_search_text(integration_type, status, sync_direction, data_formats::text, notes)
    )
  )
  WHERE archived_at IS NULL;

-- Lexical search over embedded chunks, shaped to pair with
-- match_semantic_embeddings for hybrid retrieval.
CREATE INDEX idx_semantic_embeddings_content_fts
  ON semantic_embeddings
  USING GIN (
    to_tsvector('english', content)
  )
  WHERE archived_at IS NULL;

-- Fuzzy lookup indexes for common human-entered names and titles.
CREATE INDEX idx_organizations_name_trgm
  ON organizations
  USING GIN (lower(name) gin_trgm_ops)
  WHERE archived_at IS NULL;

CREATE INDEX idx_people_full_name_trgm
  ON people
  USING GIN (lower(full_name) gin_trgm_ops)
  WHERE archived_at IS NULL;

CREATE INDEX idx_documents_title_trgm
  ON documents
  USING GIN (lower(title) gin_trgm_ops)
  WHERE archived_at IS NULL;

CREATE INDEX idx_interactions_subject_trgm
  ON interactions
  USING GIN (lower(subject) gin_trgm_ops)
  WHERE archived_at IS NULL
    AND subject IS NOT NULL;

CREATE OR REPLACE FUNCTION match_full_text_embeddings(
  search_query text,
  match_count integer DEFAULT 10,
  filter_target_types text[] DEFAULT NULL
)
RETURNS TABLE (
  id uuid,
  target_type text,
  target_id uuid,
  chunk_index integer,
  content text,
  embedding_provider text,
  embedding_model text,
  embedding_model_version text,
  metadata jsonb,
  rank real
)
LANGUAGE sql
STABLE
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
    ts_rank_cd(to_tsvector('english', se.content), query.tsq, 32) AS rank
  FROM semantic_embeddings se
  CROSS JOIN query
  WHERE se.archived_at IS NULL
    AND to_tsvector('english', se.content) @@ query.tsq
    AND (
      filter_target_types IS NULL
      OR se.target_type = ANY(filter_target_types)
    )
  ORDER BY rank DESC, se.embedded_at DESC
  LIMIT LEAST(GREATEST(COALESCE(match_count, 10), 1), 100);
$$;

CREATE OR REPLACE FUNCTION search_crm_full_text(
  search_query text,
  match_count integer DEFAULT 20,
  filter_target_types text[] DEFAULT NULL
)
RETURNS TABLE (
  target_type text,
  target_id uuid,
  title text,
  subtitle text,
  occurred_at timestamptz,
  rank real,
  headline text,
  metadata jsonb
)
LANGUAGE sql
STABLE
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
      ts_rank_cd(
        to_tsvector(
          'english',
          picardo_search_text(o.name, o.legal_name, o.domain::text, o.website, o.description, o.industry, o.hq_city, o.hq_region, o.hq_country, o.notes)
        ),
        query.tsq,
        32
      ) AS rank,
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
      AND to_tsvector(
        'english',
        picardo_search_text(o.name, o.legal_name, o.domain::text, o.website, o.description, o.industry, o.hq_city, o.hq_region, o.hq_country, o.notes)
      ) @@ query.tsq

    UNION ALL

    SELECT
      'person'::text AS target_type,
      p.id AS target_id,
      p.full_name AS title,
      concat_ws(' / ', p.headline, p.city, p.country) AS subtitle,
      p.updated_at AS occurred_at,
      ts_rank_cd(
        to_tsvector(
          'english',
          picardo_search_text(p.full_name, p.display_name, p.preferred_name, p.headline, p.summary, p.city, p.region, p.country, p.timezone, p.website, p.notes)
        ),
        query.tsq,
        32
      ) AS rank,
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
      AND to_tsvector(
        'english',
        picardo_search_text(p.full_name, p.display_name, p.preferred_name, p.headline, p.summary, p.city, p.region, p.country, p.timezone, p.website, p.notes)
      ) @@ query.tsq

    UNION ALL

    SELECT
      'interaction'::text AS target_type,
      i.id AS target_id,
      COALESCE(i.subject, i.type::text) AS title,
      concat_ws(' / ', i.type::text, i.direction::text, i.location) AS subtitle,
      i.occurred_at,
      ts_rank_cd(to_tsvector('english', picardo_search_text(i.subject, left(i.body, 250000), i.location)), query.tsq, 32) AS rank,
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
      AND to_tsvector('english', picardo_search_text(i.subject, left(i.body, 250000), i.location)) @@ query.tsq

    UNION ALL

    SELECT
      'call_transcript'::text AS target_type,
      ct.id AS target_id,
      COALESCE(i.subject, 'Call transcript') AS title,
      concat_ws(' / ', ct.format::text, ct.language, ct.transcribed_by) AS subtitle,
      i.occurred_at,
      ts_rank_cd(to_tsvector('english', left(ct.raw_text, 500000)), query.tsq, 32) AS rank,
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
      AND to_tsvector('english', left(ct.raw_text, 500000)) @@ query.tsq

    UNION ALL

    SELECT
      'document'::text AS target_type,
      d.id AS target_id,
      d.title,
      concat_ws(' / ', d.document_type, d.source_path) AS subtitle,
      COALESCE(d.occurred_at, d.authored_at, d.created_at) AS occurred_at,
      ts_rank_cd(
        to_tsvector('english', picardo_search_text(d.title, d.document_type, d.summary, left(d.body, 500000), d.source_path)),
        query.tsq,
        32
      ) AS rank,
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
      AND to_tsvector('english', picardo_search_text(d.title, d.document_type, d.summary, left(d.body, 500000), d.source_path)) @@ query.tsq

    UNION ALL

    SELECT
      'ai_note'::text AS target_type,
      an.id AS target_id,
      COALESCE(an.title, an.kind::text) AS title,
      concat_ws(' / ', an.kind::text, an.model, an.model_version) AS subtitle,
      an.generated_at AS occurred_at,
      ts_rank_cd(to_tsvector('english', picardo_search_text(an.title, left(an.content, 250000))), query.tsq, 32) AS rank,
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
      AND to_tsvector('english', picardo_search_text(an.title, left(an.content, 250000))) @@ query.tsq

    UNION ALL

    SELECT
      'extracted_fact'::text AS target_type,
      ef.id AS target_id,
      ef.key AS title,
      ef.subject_type::text AS subtitle,
      ef.observed_at AS occurred_at,
      ts_rank_cd(to_tsvector('english', picardo_search_text(ef.key, ef.value_text, left(ef.source_excerpt, 50000))), query.tsq, 32) AS rank,
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
      AND to_tsvector('english', picardo_search_text(ef.key, ef.value_text, left(ef.source_excerpt, 50000))) @@ query.tsq

    UNION ALL

    SELECT
      'organization_research_profile'::text AS target_type,
      orp.id AS target_id,
      COALESCE(orp.canonical_name, orp.domain::text, 'Organization research profile') AS title,
      concat_ws(' / ', orp.category, orp.partnership_fit) AS subtitle,
      orp.researched_at AS occurred_at,
      ts_rank_cd(
        to_tsvector(
          'english',
          picardo_search_text(
            orp.canonical_name,
            orp.website,
            orp.domain::text,
            orp.one_line_description,
            orp.category,
            orp.healthcare_relevance,
            orp.partnership_fit,
            orp.partnership_fit_rationale,
            orp.offerings::text,
            orp.likely_use_cases::text,
            orp.integration_signals::text,
            orp.compliance_signals::text,
            orp.key_public_people::text,
            orp.suggested_tags::text,
            orp.review_flags::text
          )
        ),
        query.tsq,
        32
      ) AS rank,
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
      AND to_tsvector(
        'english',
        picardo_search_text(
          orp.canonical_name,
          orp.website,
          orp.domain::text,
          orp.one_line_description,
          orp.category,
          orp.healthcare_relevance,
          orp.partnership_fit,
          orp.partnership_fit_rationale,
          orp.offerings::text,
          orp.likely_use_cases::text,
          orp.integration_signals::text,
          orp.compliance_signals::text,
          orp.key_public_people::text,
          orp.suggested_tags::text,
          orp.review_flags::text
        )
      ) @@ query.tsq

    UNION ALL

    SELECT
      'partnership'::text AS target_type,
      p.id AS target_id,
      p.name AS title,
      concat_ws(' / ', p.partnership_type, p.stage, p.priority) AS subtitle,
      COALESCE(p.launched_at, p.signed_at, p.updated_at) AS occurred_at,
      ts_rank_cd(
        to_tsvector('english', picardo_search_text(p.name, p.partnership_type, p.stage, p.priority, p.strategic_rationale, p.commercial_model, p.status_notes)),
        query.tsq,
        32
      ) AS rank,
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
      AND to_tsvector('english', picardo_search_text(p.name, p.partnership_type, p.stage, p.priority, p.strategic_rationale, p.commercial_model, p.status_notes)) @@ query.tsq

    UNION ALL

    SELECT
      'partnership_service'::text AS target_type,
      ps.id AS target_id,
      ps.name AS title,
      concat_ws(' / ', ps.service_type, ps.status) AS subtitle,
      ps.updated_at AS occurred_at,
      ts_rank_cd(
        to_tsvector('english', picardo_search_text(ps.name, ps.service_type, ps.status, ps.clinical_use, ps.data_modalities::text)),
        query.tsq,
        32
      ) AS rank,
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
      AND to_tsvector('english', picardo_search_text(ps.name, ps.service_type, ps.status, ps.clinical_use, ps.data_modalities::text)) @@ query.tsq

    UNION ALL

    SELECT
      'partnership_integration'::text AS target_type,
      pi.id AS target_id,
      pi.integration_type AS title,
      concat_ws(' / ', pi.status, pi.sync_direction) AS subtitle,
      COALESCE(pi.last_sync_at, pi.updated_at) AS occurred_at,
      ts_rank_cd(
        to_tsvector('english', picardo_search_text(pi.integration_type, pi.status, pi.sync_direction, pi.data_formats::text, pi.notes)),
        query.tsq,
        32
      ) AS rank,
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
      AND to_tsvector('english', picardo_search_text(pi.integration_type, pi.status, pi.sync_direction, pi.data_formats::text, pi.notes)) @@ query.tsq
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

-- Down Migration

DROP FUNCTION IF EXISTS search_crm_full_text(text, integer, text[]);
DROP FUNCTION IF EXISTS match_full_text_embeddings(text, integer, text[]);

DROP INDEX IF EXISTS idx_interactions_subject_trgm;
DROP INDEX IF EXISTS idx_documents_title_trgm;
DROP INDEX IF EXISTS idx_people_full_name_trgm;
DROP INDEX IF EXISTS idx_organizations_name_trgm;
DROP INDEX IF EXISTS idx_semantic_embeddings_content_fts;
DROP INDEX IF EXISTS idx_partnership_integrations_search_fts;
DROP INDEX IF EXISTS idx_partnership_services_search_fts;
DROP INDEX IF EXISTS idx_partnerships_search_fts;
DROP INDEX IF EXISTS idx_org_research_profiles_search_fts;
DROP INDEX IF EXISTS idx_extracted_facts_search_fts;
DROP INDEX IF EXISTS idx_ai_notes_search_fts;
DROP INDEX IF EXISTS idx_documents_search_fts;
DROP INDEX IF EXISTS idx_call_transcripts_search_fts;
DROP INDEX IF EXISTS idx_interactions_search_fts;
DROP INDEX IF EXISTS idx_people_search_fts;
DROP INDEX IF EXISTS idx_organizations_search_fts;

DROP FUNCTION IF EXISTS picardo_search_text(text[]);
