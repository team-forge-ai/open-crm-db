-- Up Migration

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

-- Down Migration

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
