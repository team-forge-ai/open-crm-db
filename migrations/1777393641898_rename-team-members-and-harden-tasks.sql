-- Up Migration

-- Internal operators are Picardo team members, not CRM people.
ALTER TABLE internal_users RENAME TO team_members;
ALTER TABLE team_members RENAME CONSTRAINT internal_users_pkey TO team_members_pkey;
ALTER TABLE team_members RENAME CONSTRAINT internal_users_email_check TO team_members_email_check;
ALTER TABLE team_members RENAME CONSTRAINT internal_users_name_check TO team_members_name_check;
ALTER TABLE team_members RENAME CONSTRAINT internal_users_source_id_fkey TO team_members_source_id_fkey;
ALTER INDEX uq_internal_users_email RENAME TO uq_team_members_email;
ALTER INDEX uq_internal_users_source_external_id RENAME TO uq_team_members_source_external_id;
ALTER INDEX idx_internal_users_source RENAME TO idx_team_members_source;
ALTER INDEX idx_internal_users_active RENAME TO idx_team_members_active;
ALTER INDEX idx_internal_users_metadata RENAME TO idx_team_members_metadata;
ALTER INDEX idx_internal_users_name_trgm RENAME TO idx_team_members_name_trgm;
ALTER INDEX idx_internal_users_search_fts RENAME TO idx_team_members_search_fts;
ALTER TRIGGER trg_internal_users_updated_at ON team_members
  RENAME TO trg_team_members_updated_at;

ALTER TABLE task_projects RENAME COLUMN lead_user_id TO lead_member_id;
ALTER TABLE task_projects
  RENAME CONSTRAINT task_projects_lead_user_id_fkey TO task_projects_lead_member_id_fkey;
ALTER INDEX idx_task_projects_lead RENAME TO idx_task_projects_lead_member;

ALTER TABLE tasks RENAME COLUMN creator_user_id TO creator_member_id;
ALTER TABLE tasks RENAME COLUMN assignee_user_id TO assignee_member_id;
ALTER TABLE tasks RENAME COLUMN delegate_user_id TO delegate_member_id;
ALTER TABLE tasks
  RENAME CONSTRAINT tasks_creator_user_id_fkey TO tasks_creator_member_id_fkey;
ALTER TABLE tasks
  RENAME CONSTRAINT tasks_assignee_user_id_fkey TO tasks_assignee_member_id_fkey;
ALTER TABLE tasks
  RENAME CONSTRAINT tasks_delegate_user_id_fkey TO tasks_delegate_member_id_fkey;
ALTER INDEX idx_tasks_creator RENAME TO idx_tasks_creator_member;
ALTER INDEX idx_tasks_assignee RENAME TO idx_tasks_assignee_member;

ALTER TABLE task_comments RENAME COLUMN author_user_id TO author_member_id;
ALTER TABLE task_comments
  RENAME CONSTRAINT task_comments_author_user_id_fkey TO task_comments_author_member_id_fkey;
ALTER INDEX idx_task_comments_author RENAME TO idx_task_comments_author_member;

-- A task status belongs to a team; enforce that tasks cannot point at a
-- workflow state from another team.
ALTER TABLE tasks DROP CONSTRAINT tasks_status_id_fkey;
ALTER TABLE task_statuses
  ADD CONSTRAINT task_statuses_team_id_id_key UNIQUE (team_id, id);
ALTER TABLE tasks
  ADD CONSTRAINT tasks_team_status_id_fkey
  FOREIGN KEY (team_id, status_id)
  REFERENCES task_statuses(team_id, id)
  ON DELETE SET NULL (status_id);

-- A task project may belong to multiple teams via task_project_teams. Enforce
-- that an assigned task project is linked to the task's team.
CREATE OR REPLACE FUNCTION picardo_check_task_project_team()
RETURNS trigger
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

CREATE TRIGGER trg_tasks_project_team_guard
  BEFORE INSERT OR UPDATE OF project_id, team_id ON tasks
  FOR EACH ROW EXECUTE FUNCTION picardo_check_task_project_team();

CREATE OR REPLACE FUNCTION picardo_prevent_task_project_team_orphan()
RETURNS trigger
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

CREATE TRIGGER trg_task_project_teams_no_orphan
  BEFORE DELETE OR UPDATE OF project_id, team_id ON task_project_teams
  FOR EACH ROW EXECUTE FUNCTION picardo_prevent_task_project_team_orphan();

-- Keep target type names aligned with the renamed table.
ALTER TABLE semantic_embeddings
  DROP CONSTRAINT IF EXISTS semantic_embeddings_target_type_check;
UPDATE semantic_embeddings
   SET target_type = 'team_member'
 WHERE target_type = 'internal_user';
ALTER TABLE semantic_embeddings
  ADD CONSTRAINT semantic_embeddings_target_type_check CHECK (
    target_type IN (
      'organization',
      'organization_research_profile',
      'person',
      'interaction',
      'document',
      'partnership',
      'partnership_service',
      'partnership_integration',
      'call_transcript',
      'ai_note',
      'extracted_fact',
      'team_member',
      'task',
      'task_project',
      'task_comment'
    )
  );

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
        to_tsvector('english', picardo_search_text(tm.name, tm.title, tm.email::text)),
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
      AND to_tsvector('english', picardo_search_text(tm.name, tm.title, tm.email::text)) @@ query.tsq

    UNION ALL

    SELECT
      'task_project'::text AS target_type,
      tp.id AS target_id,
      tp.name AS title,
      concat_ws(' / ', tp.status_name, tp.priority_label, tp.target_date::text) AS subtitle,
      COALESCE(tp.completed_at, tp.canceled_at, tp.started_at, tp.updated_at) AS occurred_at,
      ts_rank_cd(
        to_tsvector('english', picardo_search_text(tp.name, tp.summary, tp.description, tp.status_name, tp.priority_label)),
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
      AND to_tsvector('english', picardo_search_text(tp.name, tp.summary, tp.description, tp.status_name, tp.priority_label)) @@ query.tsq

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
          picardo_search_text(t.title, left(t.description, 250000), t.source_identifier, t.priority_label, t.git_branch_name, tp.name, ts.name, assignee.name)
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
        picardo_search_text(t.title, left(t.description, 250000), t.source_identifier, t.priority_label, t.git_branch_name, tp.name, ts.name, assignee.name)
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

COMMENT ON TABLE team_members IS 'Picardo team members and system actors who own, create, or comment on internal operational work. Not external CRM contacts.';
COMMENT ON COLUMN team_members.title IS 'Internal role/title for the team member, when known.';
COMMENT ON COLUMN team_members.is_bot IS 'True for imported system or bot actors such as the Linear app user.';
COMMENT ON COLUMN team_members.source_external_id IS 'Stable upstream member/user ID from the source system.';
COMMENT ON COLUMN team_members.metadata IS 'Provider-specific member fields that are useful for provenance but not worth first-class columns.';
COMMENT ON COLUMN team_members.archived_at IS 'Soft-delete timestamp; active team members have NULL archived_at.';

COMMENT ON TABLE task_teams IS 'Task workflow containers imported from Linear teams or created for Picardo internal work.';
COMMENT ON COLUMN task_teams.key IS 'Short issue prefix or team key, for example PIC.';
COMMENT ON COLUMN task_teams.source_external_id IS 'Stable upstream team ID from the source system.';

COMMENT ON TABLE task_statuses IS 'Team-scoped workflow states. Names are data, not PostgreSQL enum values.';
COMMENT ON COLUMN task_statuses.status_type IS 'Normalized workflow category: backlog, unstarted, started, completed, or canceled.';
COMMENT ON COLUMN task_statuses.position IS 'Source-system ordering for rendering workflow states.';

COMMENT ON TABLE task_projects IS 'Internal operating project containers for tasks.';
COMMENT ON COLUMN task_projects.status_name IS 'Display name of the project status from the source system.';
COMMENT ON COLUMN task_projects.status_type IS 'Normalized project status category, kept flexible with a CHECK constraint.';
COMMENT ON COLUMN task_projects.priority_value IS 'Numeric priority imported from Linear: 0 none, 1 urgent, 2 high, 3 medium/normal, 4 low.';
COMMENT ON COLUMN task_projects.lead_member_id IS 'Picardo team member who leads the project, when known.';
COMMENT ON COLUMN task_projects.source_url IS 'Canonical URL for the upstream project.';

COMMENT ON TABLE task_project_teams IS 'Many-to-many membership between task projects and task teams.';

COMMENT ON TABLE tasks IS 'Internal operating tasks, including imported Linear issues.';
COMMENT ON COLUMN tasks.status_id IS 'Workflow state for the task; constrained to belong to the same team as tasks.team_id.';
COMMENT ON COLUMN tasks.project_id IS 'Optional operating project; constrained by trigger to be linked to the task team.';
COMMENT ON COLUMN tasks.creator_member_id IS 'Team member who created the task in the source system.';
COMMENT ON COLUMN tasks.assignee_member_id IS 'Team member currently responsible for the task.';
COMMENT ON COLUMN tasks.delegate_member_id IS 'Delegated team member or agent, when a source system provides one.';
COMMENT ON COLUMN tasks.priority_value IS 'Numeric priority imported from Linear: 0 none, 1 urgent, 2 high, 3 medium/normal, 4 low.';
COMMENT ON COLUMN tasks.source_external_id IS 'Stable upstream task ID. For Linear MCP imports this may be the issue identifier when UUID is not exposed.';
COMMENT ON COLUMN tasks.source_identifier IS 'Human-readable task identifier such as PIC-226.';
COMMENT ON COLUMN tasks.source_number IS 'Numeric portion of the human-readable task identifier.';
COMMENT ON COLUMN tasks.git_branch_name IS 'Suggested or generated git branch name from the task source.';
COMMENT ON COLUMN tasks.metadata IS 'Provider-specific task fields that are useful for provenance but not worth first-class columns.';

COMMENT ON TABLE task_comments IS 'Threaded comments attached to internal operating tasks.';
COMMENT ON COLUMN task_comments.author_member_id IS 'Team member or bot actor who authored the comment.';
COMMENT ON COLUMN task_comments.body IS 'Comment body, usually Markdown for Linear imports.';
COMMENT ON COLUMN task_comments.source_external_id IS 'Stable upstream comment ID from the source system.';
COMMENT ON COLUMN task_comments.source_created_at IS 'Original upstream comment creation timestamp.';
COMMENT ON COLUMN task_comments.source_updated_at IS 'Original upstream comment update timestamp.';

COMMENT ON TABLE task_attachments IS 'Task attachment and external-link metadata. Binary payloads are not stored here by default.';
COMMENT ON COLUMN task_attachments.url IS 'Attachment or external-link URL visible from Picardo.';
COMMENT ON COLUMN task_attachments.source_url IS 'Canonical upstream URL for the attachment when different from url.';
COMMENT ON COLUMN task_attachments.metadata IS 'Provider-specific attachment fields.';

COMMENT ON TABLE task_relations IS 'Directed relationships between tasks such as blocks, blocked_by, related, or duplicate.';
COMMENT ON COLUMN task_relations.relation_type IS 'Directed relation kind: blocks, blocked_by, related, or duplicate.';
COMMENT ON COLUMN task_relations.related_task_id IS 'The other task participating in the directed relation.';

-- Down Migration

DROP TRIGGER IF EXISTS trg_task_project_teams_no_orphan ON task_project_teams;
DROP TRIGGER IF EXISTS trg_tasks_project_team_guard ON tasks;
DROP FUNCTION IF EXISTS picardo_prevent_task_project_team_orphan();
DROP FUNCTION IF EXISTS picardo_check_task_project_team();

ALTER TABLE tasks DROP CONSTRAINT tasks_team_status_id_fkey;
ALTER TABLE task_statuses DROP CONSTRAINT task_statuses_team_id_id_key;
ALTER TABLE tasks
  ADD CONSTRAINT tasks_status_id_fkey
  FOREIGN KEY (status_id) REFERENCES task_statuses(id) ON DELETE SET NULL;

ALTER TABLE semantic_embeddings
  DROP CONSTRAINT IF EXISTS semantic_embeddings_target_type_check;
UPDATE semantic_embeddings
   SET target_type = 'internal_user'
 WHERE target_type = 'team_member';
ALTER TABLE semantic_embeddings
  ADD CONSTRAINT semantic_embeddings_target_type_check CHECK (
    target_type IN (
      'organization',
      'organization_research_profile',
      'person',
      'interaction',
      'document',
      'partnership',
      'partnership_service',
      'partnership_integration',
      'call_transcript',
      'ai_note',
      'extracted_fact',
      'internal_user',
      'task',
      'task_project',
      'task_comment'
    )
  );

ALTER TABLE task_comments RENAME COLUMN author_member_id TO author_user_id;
ALTER TABLE task_comments
  RENAME CONSTRAINT task_comments_author_member_id_fkey TO task_comments_author_user_id_fkey;
ALTER INDEX idx_task_comments_author_member RENAME TO idx_task_comments_author;

ALTER TABLE tasks RENAME COLUMN creator_member_id TO creator_user_id;
ALTER TABLE tasks RENAME COLUMN assignee_member_id TO assignee_user_id;
ALTER TABLE tasks RENAME COLUMN delegate_member_id TO delegate_user_id;
ALTER TABLE tasks
  RENAME CONSTRAINT tasks_creator_member_id_fkey TO tasks_creator_user_id_fkey;
ALTER TABLE tasks
  RENAME CONSTRAINT tasks_assignee_member_id_fkey TO tasks_assignee_user_id_fkey;
ALTER TABLE tasks
  RENAME CONSTRAINT tasks_delegate_member_id_fkey TO tasks_delegate_user_id_fkey;
ALTER INDEX idx_tasks_creator_member RENAME TO idx_tasks_creator;
ALTER INDEX idx_tasks_assignee_member RENAME TO idx_tasks_assignee;

ALTER TABLE task_projects RENAME COLUMN lead_member_id TO lead_user_id;
ALTER TABLE task_projects
  RENAME CONSTRAINT task_projects_lead_member_id_fkey TO task_projects_lead_user_id_fkey;
ALTER INDEX idx_task_projects_lead_member RENAME TO idx_task_projects_lead;

ALTER TRIGGER trg_team_members_updated_at ON team_members
  RENAME TO trg_internal_users_updated_at;
ALTER INDEX idx_team_members_search_fts RENAME TO idx_internal_users_search_fts;
ALTER INDEX idx_team_members_name_trgm RENAME TO idx_internal_users_name_trgm;
ALTER INDEX idx_team_members_metadata RENAME TO idx_internal_users_metadata;
ALTER INDEX idx_team_members_active RENAME TO idx_internal_users_active;
ALTER INDEX idx_team_members_source RENAME TO idx_internal_users_source;
ALTER INDEX uq_team_members_source_external_id RENAME TO uq_internal_users_source_external_id;
ALTER INDEX uq_team_members_email RENAME TO uq_internal_users_email;
ALTER TABLE team_members RENAME CONSTRAINT team_members_source_id_fkey TO internal_users_source_id_fkey;
ALTER TABLE team_members RENAME CONSTRAINT team_members_name_check TO internal_users_name_check;
ALTER TABLE team_members RENAME CONSTRAINT team_members_email_check TO internal_users_email_check;
ALTER TABLE team_members RENAME CONSTRAINT team_members_pkey TO internal_users_pkey;
ALTER TABLE team_members RENAME TO internal_users;
