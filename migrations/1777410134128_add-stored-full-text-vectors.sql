-- Up Migration

ALTER TABLE organizations
  ADD COLUMN search_tsv tsvector
  GENERATED ALWAYS AS (
    to_tsvector(
      'english',
      crm_search_text(name, legal_name, domain::text, website, description, industry, hq_city, hq_region, hq_country, notes)
    )
  ) STORED;

ALTER TABLE people
  ADD COLUMN search_tsv tsvector
  GENERATED ALWAYS AS (
    to_tsvector(
      'english',
      crm_search_text(full_name, display_name, preferred_name, headline, summary, city, region, country, timezone, website, notes)
    )
  ) STORED;

ALTER TABLE interactions
  ADD COLUMN search_tsv tsvector
  GENERATED ALWAYS AS (
    to_tsvector('english', crm_search_text(subject, left(body, 250000), location))
  ) STORED;

ALTER TABLE call_transcripts
  ADD COLUMN search_tsv tsvector
  GENERATED ALWAYS AS (
    to_tsvector('english', left(raw_text, 500000))
  ) STORED;

ALTER TABLE documents
  ADD COLUMN search_tsv tsvector
  GENERATED ALWAYS AS (
    to_tsvector('english', crm_search_text(title, document_type, summary, left(body, 500000), source_path))
  ) STORED;

ALTER TABLE ai_notes
  ADD COLUMN search_tsv tsvector
  GENERATED ALWAYS AS (
    to_tsvector('english', crm_search_text(title, left(content, 250000)))
  ) STORED;

ALTER TABLE extracted_facts
  ADD COLUMN search_tsv tsvector
  GENERATED ALWAYS AS (
    to_tsvector('english', crm_search_text(key, value_text, left(source_excerpt, 50000)))
  ) STORED;

ALTER TABLE organization_research_profiles
  ADD COLUMN search_tsv tsvector
  GENERATED ALWAYS AS (
    to_tsvector(
      'english',
      crm_search_text(
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
  ) STORED;

ALTER TABLE partnerships
  ADD COLUMN search_tsv tsvector
  GENERATED ALWAYS AS (
    to_tsvector(
      'english',
      crm_search_text(name, partnership_type, stage, priority, strategic_rationale, commercial_model, status_notes)
    )
  ) STORED;

ALTER TABLE partnership_services
  ADD COLUMN search_tsv tsvector
  GENERATED ALWAYS AS (
    to_tsvector(
      'english',
      crm_search_text(name, service_type, status, clinical_use, data_modalities::text)
    )
  ) STORED;

ALTER TABLE partnership_integrations
  ADD COLUMN search_tsv tsvector
  GENERATED ALWAYS AS (
    to_tsvector(
      'english',
      crm_search_text(integration_type, status, sync_direction, data_formats::text, notes)
    )
  ) STORED;

ALTER TABLE semantic_embeddings
  ADD COLUMN search_tsv tsvector
  GENERATED ALWAYS AS (
    to_tsvector('english', content)
  ) STORED;

ALTER TABLE team_members
  ADD COLUMN search_tsv tsvector
  GENERATED ALWAYS AS (
    to_tsvector('english', crm_search_text(name, title, email::text))
  ) STORED;

ALTER TABLE task_projects
  ADD COLUMN search_tsv tsvector
  GENERATED ALWAYS AS (
    to_tsvector('english', crm_search_text(name, summary, description, status_name, priority_label))
  ) STORED;

ALTER TABLE tasks
  ADD COLUMN search_tsv tsvector
  GENERATED ALWAYS AS (
    to_tsvector('english', crm_search_text(title, left(description, 250000), source_identifier, priority_label, git_branch_name))
  ) STORED;

ALTER TABLE task_comments
  ADD COLUMN search_tsv tsvector
  GENERATED ALWAYS AS (
    to_tsvector('english', left(body, 250000))
  ) STORED;

DROP INDEX IF EXISTS idx_organizations_search_fts;
DROP INDEX IF EXISTS idx_people_search_fts;
DROP INDEX IF EXISTS idx_interactions_search_fts;
DROP INDEX IF EXISTS idx_call_transcripts_search_fts;
DROP INDEX IF EXISTS idx_documents_search_fts;
DROP INDEX IF EXISTS idx_ai_notes_search_fts;
DROP INDEX IF EXISTS idx_extracted_facts_search_fts;
DROP INDEX IF EXISTS idx_org_research_profiles_search_fts;
DROP INDEX IF EXISTS idx_partnerships_search_fts;
DROP INDEX IF EXISTS idx_partnership_services_search_fts;
DROP INDEX IF EXISTS idx_partnership_integrations_search_fts;
DROP INDEX IF EXISTS idx_semantic_embeddings_content_fts;
DROP INDEX IF EXISTS idx_team_members_search_fts;
DROP INDEX IF EXISTS idx_task_projects_search_fts;
DROP INDEX IF EXISTS idx_tasks_search_fts;
DROP INDEX IF EXISTS idx_task_comments_search_fts;

CREATE INDEX idx_organizations_search_fts
  ON organizations USING GIN (search_tsv)
  WHERE archived_at IS NULL;

CREATE INDEX idx_people_search_fts
  ON people USING GIN (search_tsv)
  WHERE archived_at IS NULL;

CREATE INDEX idx_interactions_search_fts
  ON interactions USING GIN (search_tsv)
  WHERE archived_at IS NULL;

CREATE INDEX idx_call_transcripts_search_fts
  ON call_transcripts USING GIN (search_tsv);

CREATE INDEX idx_documents_search_fts
  ON documents USING GIN (search_tsv)
  WHERE archived_at IS NULL;

CREATE INDEX idx_ai_notes_search_fts
  ON ai_notes USING GIN (search_tsv);

CREATE INDEX idx_extracted_facts_search_fts
  ON extracted_facts USING GIN (search_tsv);

CREATE INDEX idx_org_research_profiles_search_fts
  ON organization_research_profiles USING GIN (search_tsv);

CREATE INDEX idx_partnerships_search_fts
  ON partnerships USING GIN (search_tsv)
  WHERE archived_at IS NULL;

CREATE INDEX idx_partnership_services_search_fts
  ON partnership_services USING GIN (search_tsv)
  WHERE archived_at IS NULL;

CREATE INDEX idx_partnership_integrations_search_fts
  ON partnership_integrations USING GIN (search_tsv)
  WHERE archived_at IS NULL;

CREATE INDEX idx_semantic_embeddings_content_fts
  ON semantic_embeddings USING GIN (search_tsv)
  WHERE archived_at IS NULL;

CREATE INDEX idx_team_members_search_fts
  ON team_members USING GIN (search_tsv)
  WHERE archived_at IS NULL;

CREATE INDEX idx_task_projects_search_fts
  ON task_projects USING GIN (search_tsv)
  WHERE archived_at IS NULL;

CREATE INDEX idx_tasks_search_fts
  ON tasks USING GIN (search_tsv)
  WHERE archived_at IS NULL;

CREATE INDEX idx_task_comments_search_fts
  ON task_comments USING GIN (search_tsv)
  WHERE archived_at IS NULL;

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

CREATE OR REPLACE FUNCTION search_crm_full_text_base(
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

CREATE OR REPLACE FUNCTION search_crm_full_text_base(
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
          crm_search_text(o.name, o.legal_name, o.domain::text, o.website, o.description, o.industry, o.hq_city, o.hq_region, o.hq_country, o.notes)
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
        crm_search_text(o.name, o.legal_name, o.domain::text, o.website, o.description, o.industry, o.hq_city, o.hq_region, o.hq_country, o.notes)
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
          crm_search_text(p.full_name, p.display_name, p.preferred_name, p.headline, p.summary, p.city, p.region, p.country, p.timezone, p.website, p.notes)
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
        crm_search_text(p.full_name, p.display_name, p.preferred_name, p.headline, p.summary, p.city, p.region, p.country, p.timezone, p.website, p.notes)
      ) @@ query.tsq

    UNION ALL

    SELECT
      'interaction'::text AS target_type,
      i.id AS target_id,
      COALESCE(i.subject, i.type::text) AS title,
      concat_ws(' / ', i.type::text, i.direction::text, i.location) AS subtitle,
      i.occurred_at,
      ts_rank_cd(to_tsvector('english', crm_search_text(i.subject, left(i.body, 250000), i.location)), query.tsq, 32) AS rank,
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
      AND to_tsvector('english', crm_search_text(i.subject, left(i.body, 250000), i.location)) @@ query.tsq

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
        to_tsvector('english', crm_search_text(d.title, d.document_type, d.summary, left(d.body, 500000), d.source_path)),
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
      AND to_tsvector('english', crm_search_text(d.title, d.document_type, d.summary, left(d.body, 500000), d.source_path)) @@ query.tsq

    UNION ALL

    SELECT
      'ai_note'::text AS target_type,
      an.id AS target_id,
      COALESCE(an.title, an.kind::text) AS title,
      concat_ws(' / ', an.kind::text, an.model, an.model_version) AS subtitle,
      an.generated_at AS occurred_at,
      ts_rank_cd(to_tsvector('english', crm_search_text(an.title, left(an.content, 250000))), query.tsq, 32) AS rank,
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
      AND to_tsvector('english', crm_search_text(an.title, left(an.content, 250000))) @@ query.tsq

    UNION ALL

    SELECT
      'extracted_fact'::text AS target_type,
      ef.id AS target_id,
      ef.key AS title,
      ef.subject_type::text AS subtitle,
      ef.observed_at AS occurred_at,
      ts_rank_cd(to_tsvector('english', crm_search_text(ef.key, ef.value_text, left(ef.source_excerpt, 50000))), query.tsq, 32) AS rank,
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
      AND to_tsvector('english', crm_search_text(ef.key, ef.value_text, left(ef.source_excerpt, 50000))) @@ query.tsq

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
          crm_search_text(
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
        crm_search_text(
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
        to_tsvector('english', crm_search_text(p.name, p.partnership_type, p.stage, p.priority, p.strategic_rationale, p.commercial_model, p.status_notes)),
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
      AND to_tsvector('english', crm_search_text(p.name, p.partnership_type, p.stage, p.priority, p.strategic_rationale, p.commercial_model, p.status_notes)) @@ query.tsq

    UNION ALL

    SELECT
      'partnership_service'::text AS target_type,
      ps.id AS target_id,
      ps.name AS title,
      concat_ws(' / ', ps.service_type, ps.status) AS subtitle,
      ps.updated_at AS occurred_at,
      ts_rank_cd(
        to_tsvector('english', crm_search_text(ps.name, ps.service_type, ps.status, ps.clinical_use, ps.data_modalities::text)),
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
      AND to_tsvector('english', crm_search_text(ps.name, ps.service_type, ps.status, ps.clinical_use, ps.data_modalities::text)) @@ query.tsq

    UNION ALL

    SELECT
      'partnership_integration'::text AS target_type,
      pi.id AS target_id,
      pi.integration_type AS title,
      concat_ws(' / ', pi.status, pi.sync_direction) AS subtitle,
      COALESCE(pi.last_sync_at, pi.updated_at) AS occurred_at,
      ts_rank_cd(
        to_tsvector('english', crm_search_text(pi.integration_type, pi.status, pi.sync_direction, pi.data_formats::text, pi.notes)),
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
      AND to_tsvector('english', crm_search_text(pi.integration_type, pi.status, pi.sync_direction, pi.data_formats::text, pi.notes)) @@ query.tsq
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
    SELECT *
    FROM search_crm_full_text_base(search_query, 100, filter_target_types)

    UNION ALL

    SELECT
      'team_member'::text AS target_type,
      tm.id AS target_id,
      tm.name AS title,
      concat_ws(' / ', tm.title, tm.email::text) AS subtitle,
      tm.updated_at AS occurred_at,
      ts_rank_cd(
        to_tsvector('english', crm_search_text(tm.name, tm.title, tm.email::text)),
        query.tsq,
        32
      ) AS rank,
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
      AND to_tsvector('english', crm_search_text(tm.name, tm.title, tm.email::text)) @@ query.tsq

    UNION ALL

    SELECT
      'task_project'::text AS target_type,
      tp.id AS target_id,
      tp.name AS title,
      concat_ws(' / ', tp.status_name, tp.priority_label, tp.target_date::text) AS subtitle,
      COALESCE(tp.completed_at, tp.canceled_at, tp.started_at, tp.updated_at) AS occurred_at,
      ts_rank_cd(
        to_tsvector('english', crm_search_text(tp.name, tp.summary, tp.description, tp.status_name, tp.priority_label)),
        query.tsq,
        32
      ) AS rank,
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
      AND to_tsvector('english', crm_search_text(tp.name, tp.summary, tp.description, tp.status_name, tp.priority_label)) @@ query.tsq

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
        to_tsvector(
          'english',
          crm_search_text(t.title, left(t.description, 250000), t.source_identifier, t.priority_label, t.git_branch_name, tp.name, ts.name, assignee.name)
        ),
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
      AND to_tsvector(
        'english',
        crm_search_text(t.title, left(t.description, 250000), t.source_identifier, t.priority_label, t.git_branch_name, tp.name, ts.name, assignee.name)
      ) @@ query.tsq

    UNION ALL

    SELECT
      'task_comment'::text AS target_type,
      tc.id AS target_id,
      COALESCE(t.source_identifier || ' comment', 'Task comment') AS title,
      concat_ws(' / ', t.title, tm.name) AS subtitle,
      COALESCE(tc.source_created_at, tc.created_at) AS occurred_at,
      ts_rank_cd(to_tsvector('english', left(tc.body, 250000)), query.tsq, 32) AS rank,
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
      AND to_tsvector('english', left(tc.body, 250000)) @@ query.tsq
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

DROP INDEX IF EXISTS idx_organizations_search_fts;
DROP INDEX IF EXISTS idx_people_search_fts;
DROP INDEX IF EXISTS idx_interactions_search_fts;
DROP INDEX IF EXISTS idx_call_transcripts_search_fts;
DROP INDEX IF EXISTS idx_documents_search_fts;
DROP INDEX IF EXISTS idx_ai_notes_search_fts;
DROP INDEX IF EXISTS idx_extracted_facts_search_fts;
DROP INDEX IF EXISTS idx_org_research_profiles_search_fts;
DROP INDEX IF EXISTS idx_partnerships_search_fts;
DROP INDEX IF EXISTS idx_partnership_services_search_fts;
DROP INDEX IF EXISTS idx_partnership_integrations_search_fts;
DROP INDEX IF EXISTS idx_semantic_embeddings_content_fts;
DROP INDEX IF EXISTS idx_team_members_search_fts;
DROP INDEX IF EXISTS idx_task_projects_search_fts;
DROP INDEX IF EXISTS idx_tasks_search_fts;
DROP INDEX IF EXISTS idx_task_comments_search_fts;

ALTER TABLE task_comments DROP COLUMN search_tsv;
ALTER TABLE tasks DROP COLUMN search_tsv;
ALTER TABLE task_projects DROP COLUMN search_tsv;
ALTER TABLE team_members DROP COLUMN search_tsv;
ALTER TABLE semantic_embeddings DROP COLUMN search_tsv;
ALTER TABLE partnership_integrations DROP COLUMN search_tsv;
ALTER TABLE partnership_services DROP COLUMN search_tsv;
ALTER TABLE partnerships DROP COLUMN search_tsv;
ALTER TABLE organization_research_profiles DROP COLUMN search_tsv;
ALTER TABLE extracted_facts DROP COLUMN search_tsv;
ALTER TABLE ai_notes DROP COLUMN search_tsv;
ALTER TABLE documents DROP COLUMN search_tsv;
ALTER TABLE call_transcripts DROP COLUMN search_tsv;
ALTER TABLE interactions DROP COLUMN search_tsv;
ALTER TABLE people DROP COLUMN search_tsv;
ALTER TABLE organizations DROP COLUMN search_tsv;

CREATE INDEX idx_organizations_search_fts
  ON organizations
  USING GIN (
    to_tsvector(
      'english',
      crm_search_text(name, legal_name, domain::text, website, description, industry, hq_city, hq_region, hq_country, notes)
    )
  )
  WHERE archived_at IS NULL;

CREATE INDEX idx_people_search_fts
  ON people
  USING GIN (
    to_tsvector(
      'english',
      crm_search_text(full_name, display_name, preferred_name, headline, summary, city, region, country, timezone, website, notes)
    )
  )
  WHERE archived_at IS NULL;

CREATE INDEX idx_interactions_search_fts
  ON interactions
  USING GIN (
    to_tsvector('english', crm_search_text(subject, left(body, 250000), location))
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
    to_tsvector('english', crm_search_text(title, document_type, summary, left(body, 500000), source_path))
  )
  WHERE archived_at IS NULL;

CREATE INDEX idx_ai_notes_search_fts
  ON ai_notes
  USING GIN (
    to_tsvector('english', crm_search_text(title, left(content, 250000)))
  );

CREATE INDEX idx_extracted_facts_search_fts
  ON extracted_facts
  USING GIN (
    to_tsvector('english', crm_search_text(key, value_text, left(source_excerpt, 50000)))
  );

CREATE INDEX idx_org_research_profiles_search_fts
  ON organization_research_profiles
  USING GIN (
    to_tsvector(
      'english',
      crm_search_text(
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
      crm_search_text(name, partnership_type, stage, priority, strategic_rationale, commercial_model, status_notes)
    )
  )
  WHERE archived_at IS NULL;

CREATE INDEX idx_partnership_services_search_fts
  ON partnership_services
  USING GIN (
    to_tsvector(
      'english',
      crm_search_text(name, service_type, status, clinical_use, data_modalities::text)
    )
  )
  WHERE archived_at IS NULL;

CREATE INDEX idx_partnership_integrations_search_fts
  ON partnership_integrations
  USING GIN (
    to_tsvector(
      'english',
      crm_search_text(integration_type, status, sync_direction, data_formats::text, notes)
    )
  )
  WHERE archived_at IS NULL;

CREATE INDEX idx_semantic_embeddings_content_fts
  ON semantic_embeddings
  USING GIN (
    to_tsvector('english', content)
  )
  WHERE archived_at IS NULL;

CREATE INDEX idx_team_members_search_fts
  ON team_members
  USING GIN (
    to_tsvector('english', crm_search_text(name, title, email::text))
  )
  WHERE archived_at IS NULL;

CREATE INDEX idx_task_projects_search_fts
  ON task_projects
  USING GIN (
    to_tsvector('english', crm_search_text(name, summary, description, status_name, priority_label))
  )
  WHERE archived_at IS NULL;

CREATE INDEX idx_tasks_search_fts
  ON tasks
  USING GIN (
    to_tsvector('english', crm_search_text(title, left(description, 250000), source_identifier, priority_label, git_branch_name))
  )
  WHERE archived_at IS NULL;

CREATE INDEX idx_task_comments_search_fts
  ON task_comments
  USING GIN (
    to_tsvector('english', left(body, 250000))
  )
  WHERE archived_at IS NULL;
