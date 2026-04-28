-- Up Migration

ALTER FUNCTION search_crm_full_text(text, integer, text[])
  RENAME TO search_crm_full_text_base;

CREATE INDEX idx_internal_users_search_fts
  ON internal_users
  USING GIN (
    to_tsvector('english', crm_search_text(name, title, email::text))
  )
  WHERE archived_at IS NULL;

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
      'internal_user'::text AS target_type,
      iu.id AS target_id,
      iu.name AS title,
      concat_ws(' / ', iu.title, iu.email::text) AS subtitle,
      iu.updated_at AS occurred_at,
      ts_rank_cd(
        to_tsvector('english', crm_search_text(iu.name, iu.title, iu.email::text)),
        query.tsq,
        32
      ) AS rank,
      ts_headline(
        'english',
        concat_ws(' ', iu.name, iu.title, iu.email::text),
        query.tsq,
        'MaxWords=35, MinWords=8, MaxFragments=2'
      ) AS headline,
      iu.metadata AS metadata
    FROM internal_users iu
    CROSS JOIN query
    WHERE iu.archived_at IS NULL
      AND (filter_target_types IS NULL OR 'internal_user' = ANY(filter_target_types))
      AND to_tsvector('english', crm_search_text(iu.name, iu.title, iu.email::text)) @@ query.tsq

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
        'assignee_user_id', t.assignee_user_id
      ) AS metadata
    FROM tasks t
    LEFT JOIN task_projects tp ON tp.id = t.project_id
    LEFT JOIN task_statuses ts ON ts.id = t.status_id
    LEFT JOIN internal_users assignee ON assignee.id = t.assignee_user_id
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
      concat_ws(' / ', t.title, iu.name) AS subtitle,
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
        'author_user_id', tc.author_user_id
      ) AS metadata
    FROM task_comments tc
    JOIN tasks t ON t.id = tc.task_id
    LEFT JOIN internal_users iu ON iu.id = tc.author_user_id
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

-- Down Migration

DROP FUNCTION IF EXISTS search_crm_full_text(text, integer, text[]);
DROP INDEX IF EXISTS idx_internal_users_search_fts;
ALTER FUNCTION search_crm_full_text_base(text, integer, text[])
  RENAME TO search_crm_full_text;
