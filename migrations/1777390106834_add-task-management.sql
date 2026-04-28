-- Up Migration

INSERT INTO sources (slug, name, description)
VALUES ('linear', 'Linear', 'Tasks, projects, comments, labels, and workflow states sourced from Linear.')
ON CONFLICT (slug) DO NOTHING;

-- -----------------------------------------------------------------------------
-- Internal users
-- Picardo operators and system actors. Keep these separate from CRM people,
-- which are external contacts and counterparties.
-- -----------------------------------------------------------------------------
CREATE TABLE internal_users (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name               text NOT NULL,
  title              text,
  email              citext NOT NULL,
  avatar_url         text,
  is_active          boolean NOT NULL DEFAULT true,
  is_bot             boolean NOT NULL DEFAULT false,
  source_id          uuid REFERENCES sources(id) ON DELETE SET NULL,
  source_external_id text,
  metadata           jsonb NOT NULL DEFAULT '{}'::jsonb,
  archived_at        timestamptz,
  created_at         timestamptz NOT NULL DEFAULT NOW(),
  updated_at         timestamptz NOT NULL DEFAULT NOW(),
  CHECK (length(trim(name)) > 0),
  CHECK (length(trim(email::text)) > 0)
);
CREATE UNIQUE INDEX uq_internal_users_email
  ON internal_users (email);
CREATE UNIQUE INDEX uq_internal_users_source_external_id
  ON internal_users (source_id, source_external_id)
  WHERE source_external_id IS NOT NULL;
CREATE INDEX idx_internal_users_source   ON internal_users (source_id);
CREATE INDEX idx_internal_users_active   ON internal_users (is_active) WHERE archived_at IS NULL;
CREATE INDEX idx_internal_users_metadata ON internal_users USING GIN (metadata);
CREATE INDEX idx_internal_users_name_trgm
  ON internal_users
  USING GIN (lower(name) gin_trgm_ops)
  WHERE archived_at IS NULL;
CREATE TRIGGER trg_internal_users_updated_at
  BEFORE UPDATE ON internal_users
  FOR EACH ROW EXECUTE PROCEDURE picardo_set_updated_at();

-- -----------------------------------------------------------------------------
-- Task teams and workflow states
-- Linear workflow states are team-scoped data, not enums.
-- -----------------------------------------------------------------------------
CREATE TABLE task_teams (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name               text NOT NULL,
  key                text,
  description        text,
  icon               text,
  color              text,
  source_id          uuid REFERENCES sources(id) ON DELETE SET NULL,
  source_external_id text,
  metadata           jsonb NOT NULL DEFAULT '{}'::jsonb,
  archived_at        timestamptz,
  created_at         timestamptz NOT NULL DEFAULT NOW(),
  updated_at         timestamptz NOT NULL DEFAULT NOW(),
  CHECK (length(trim(name)) > 0),
  CHECK (key IS NULL OR length(trim(key)) > 0)
);
CREATE UNIQUE INDEX uq_task_teams_source_external_id
  ON task_teams (source_id, source_external_id)
  WHERE source_external_id IS NOT NULL;
CREATE UNIQUE INDEX uq_task_teams_active_key
  ON task_teams (lower(key))
  WHERE archived_at IS NULL AND key IS NOT NULL;
CREATE UNIQUE INDEX uq_task_teams_active_name
  ON task_teams (lower(name))
  WHERE archived_at IS NULL;
CREATE INDEX idx_task_teams_source   ON task_teams (source_id);
CREATE INDEX idx_task_teams_metadata ON task_teams USING GIN (metadata);
CREATE TRIGGER trg_task_teams_updated_at
  BEFORE UPDATE ON task_teams
  FOR EACH ROW EXECUTE PROCEDURE picardo_set_updated_at();

CREATE TABLE task_statuses (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  team_id            uuid NOT NULL REFERENCES task_teams(id) ON DELETE CASCADE,
  name               text NOT NULL,
  status_type        text NOT NULL,
  position           numeric,
  color              text,
  description        text,
  source_id          uuid REFERENCES sources(id) ON DELETE SET NULL,
  source_external_id text,
  metadata           jsonb NOT NULL DEFAULT '{}'::jsonb,
  archived_at        timestamptz,
  created_at         timestamptz NOT NULL DEFAULT NOW(),
  updated_at         timestamptz NOT NULL DEFAULT NOW(),
  CHECK (status_type IN ('backlog', 'unstarted', 'started', 'completed', 'canceled')),
  CHECK (length(trim(name)) > 0)
);
CREATE UNIQUE INDEX uq_task_statuses_source_external_id
  ON task_statuses (source_id, source_external_id)
  WHERE source_external_id IS NOT NULL;
CREATE UNIQUE INDEX uq_task_statuses_active_team_name
  ON task_statuses (team_id, lower(name))
  WHERE archived_at IS NULL;
CREATE INDEX idx_task_statuses_team      ON task_statuses (team_id);
CREATE INDEX idx_task_statuses_type      ON task_statuses (status_type);
CREATE INDEX idx_task_statuses_source    ON task_statuses (source_id);
CREATE INDEX idx_task_statuses_metadata  ON task_statuses USING GIN (metadata);
CREATE TRIGGER trg_task_statuses_updated_at
  BEFORE UPDATE ON task_statuses
  FOR EACH ROW EXECUTE PROCEDURE picardo_set_updated_at();

-- -----------------------------------------------------------------------------
-- Task projects
-- Linear projects are operating containers for tasks. Milestones and cycles are
-- intentionally deferred until Picardo actually uses them.
-- -----------------------------------------------------------------------------
CREATE TABLE task_projects (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name               text NOT NULL,
  summary            text,
  description        text,
  icon               text,
  color              text,
  status_name        text,
  status_type        text,
  priority_value     integer NOT NULL DEFAULT 0,
  priority_label     text,
  lead_user_id       uuid REFERENCES internal_users(id) ON DELETE SET NULL,
  start_date         date,
  target_date        date,
  started_at         timestamptz,
  completed_at       timestamptz,
  canceled_at        timestamptz,
  source_id          uuid REFERENCES sources(id) ON DELETE SET NULL,
  source_external_id text,
  source_url         text,
  metadata           jsonb NOT NULL DEFAULT '{}'::jsonb,
  archived_at        timestamptz,
  created_at         timestamptz NOT NULL DEFAULT NOW(),
  updated_at         timestamptz NOT NULL DEFAULT NOW(),
  CHECK (length(trim(name)) > 0),
  CHECK (status_type IS NULL OR status_type IN ('backlog', 'planned', 'started', 'paused', 'completed', 'canceled')),
  CHECK (priority_value BETWEEN 0 AND 4),
  CHECK (target_date IS NULL OR start_date IS NULL OR target_date >= start_date)
);
CREATE UNIQUE INDEX uq_task_projects_source_external_id
  ON task_projects (source_id, source_external_id)
  WHERE source_external_id IS NOT NULL;
CREATE UNIQUE INDEX uq_task_projects_active_name
  ON task_projects (lower(name))
  WHERE archived_at IS NULL;
CREATE INDEX idx_task_projects_status   ON task_projects (status_type);
CREATE INDEX idx_task_projects_priority ON task_projects (priority_value);
CREATE INDEX idx_task_projects_lead     ON task_projects (lead_user_id);
CREATE INDEX idx_task_projects_source   ON task_projects (source_id);
CREATE INDEX idx_task_projects_metadata ON task_projects USING GIN (metadata);
CREATE INDEX idx_task_projects_search_fts
  ON task_projects
  USING GIN (
    to_tsvector('english', picardo_search_text(name, summary, description, status_name, priority_label))
  )
  WHERE archived_at IS NULL;
CREATE INDEX idx_task_projects_name_trgm
  ON task_projects
  USING GIN (lower(name) gin_trgm_ops)
  WHERE archived_at IS NULL;
CREATE TRIGGER trg_task_projects_updated_at
  BEFORE UPDATE ON task_projects
  FOR EACH ROW EXECUTE PROCEDURE picardo_set_updated_at();

CREATE TABLE task_project_teams (
  project_id uuid NOT NULL REFERENCES task_projects(id) ON DELETE CASCADE,
  team_id    uuid NOT NULL REFERENCES task_teams(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT NOW(),
  PRIMARY KEY (project_id, team_id)
);
CREATE INDEX idx_task_project_teams_team ON task_project_teams (team_id);

-- -----------------------------------------------------------------------------
-- Tasks
-- Imported Linear issues and future Picardo-owned operational work.
-- -----------------------------------------------------------------------------
CREATE TABLE tasks (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  team_id               uuid NOT NULL REFERENCES task_teams(id) ON DELETE RESTRICT,
  status_id             uuid REFERENCES task_statuses(id) ON DELETE SET NULL,
  project_id            uuid REFERENCES task_projects(id) ON DELETE SET NULL,
  parent_task_id        uuid REFERENCES tasks(id) ON DELETE SET NULL,
  creator_user_id       uuid REFERENCES internal_users(id) ON DELETE SET NULL,
  assignee_user_id      uuid REFERENCES internal_users(id) ON DELETE SET NULL,
  delegate_user_id      uuid REFERENCES internal_users(id) ON DELETE SET NULL,
  title                 text NOT NULL,
  description           text,
  priority_value        integer NOT NULL DEFAULT 0,
  priority_label        text,
  estimate              numeric,
  sort_order            numeric,
  priority_sort_order   numeric,
  due_date              date,
  started_at            timestamptz,
  completed_at          timestamptz,
  canceled_at           timestamptz,
  auto_closed_at        timestamptz,
  auto_archived_at      timestamptz,
  snoozed_until_at      timestamptz,
  added_to_project_at   timestamptz,
  added_to_team_at      timestamptz,
  source_created_at     timestamptz,
  source_updated_at     timestamptz,
  source_id             uuid REFERENCES sources(id) ON DELETE SET NULL,
  source_external_id    text,
  source_identifier     text,
  source_number         integer,
  source_url            text,
  git_branch_name       text,
  sla_started_at        timestamptz,
  sla_medium_risk_at    timestamptz,
  sla_high_risk_at      timestamptz,
  sla_breaches_at       timestamptz,
  sla_type              text,
  metadata              jsonb NOT NULL DEFAULT '{}'::jsonb,
  archived_at           timestamptz,
  created_at            timestamptz NOT NULL DEFAULT NOW(),
  updated_at            timestamptz NOT NULL DEFAULT NOW(),
  CHECK (length(trim(title)) > 0),
  CHECK (priority_value BETWEEN 0 AND 4),
  CHECK (estimate IS NULL OR estimate >= 0),
  CHECK (source_number IS NULL OR source_number > 0),
  CHECK (completed_at IS NULL OR canceled_at IS NULL),
  CHECK (parent_task_id IS NULL OR parent_task_id <> id)
);
CREATE UNIQUE INDEX uq_tasks_source_external_id
  ON tasks (source_id, source_external_id)
  WHERE source_external_id IS NOT NULL;
CREATE UNIQUE INDEX uq_tasks_source_identifier
  ON tasks (source_id, source_identifier)
  WHERE source_identifier IS NOT NULL;
CREATE INDEX idx_tasks_team_status       ON tasks (team_id, status_id);
CREATE INDEX idx_tasks_status            ON tasks (status_id);
CREATE INDEX idx_tasks_project_status    ON tasks (project_id, status_id);
CREATE INDEX idx_tasks_assignee          ON tasks (assignee_user_id);
CREATE INDEX idx_tasks_creator           ON tasks (creator_user_id);
CREATE INDEX idx_tasks_parent            ON tasks (parent_task_id);
CREATE INDEX idx_tasks_priority          ON tasks (priority_value);
CREATE INDEX idx_tasks_due_date          ON tasks (due_date) WHERE due_date IS NOT NULL;
CREATE INDEX idx_tasks_source_updated_at ON tasks (source_updated_at DESC);
CREATE INDEX idx_tasks_active_updated_at ON tasks (updated_at DESC) WHERE archived_at IS NULL;
CREATE INDEX idx_tasks_metadata          ON tasks USING GIN (metadata);
CREATE INDEX idx_tasks_search_fts
  ON tasks
  USING GIN (
    to_tsvector('english', picardo_search_text(title, left(description, 250000), source_identifier, priority_label, git_branch_name))
  )
  WHERE archived_at IS NULL;
CREATE INDEX idx_tasks_title_trgm
  ON tasks
  USING GIN (lower(title) gin_trgm_ops)
  WHERE archived_at IS NULL;
CREATE TRIGGER trg_tasks_updated_at
  BEFORE UPDATE ON tasks
  FOR EACH ROW EXECUTE PROCEDURE picardo_set_updated_at();

CREATE TABLE task_comments (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  task_id            uuid NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
  parent_comment_id  uuid REFERENCES task_comments(id) ON DELETE SET NULL,
  author_user_id     uuid REFERENCES internal_users(id) ON DELETE SET NULL,
  body               text NOT NULL,
  body_format        text NOT NULL DEFAULT 'markdown',
  source_id          uuid REFERENCES sources(id) ON DELETE SET NULL,
  source_external_id text,
  source_url         text,
  source_created_at  timestamptz,
  source_updated_at  timestamptz,
  edited_at          timestamptz,
  resolved_at        timestamptz,
  metadata           jsonb NOT NULL DEFAULT '{}'::jsonb,
  archived_at        timestamptz,
  created_at         timestamptz NOT NULL DEFAULT NOW(),
  updated_at         timestamptz NOT NULL DEFAULT NOW(),
  CHECK (length(trim(body)) > 0),
  CHECK (body_format IN ('markdown', 'plain_text', 'other')),
  CHECK (parent_comment_id IS NULL OR parent_comment_id <> id)
);
CREATE UNIQUE INDEX uq_task_comments_source_external_id
  ON task_comments (source_id, source_external_id)
  WHERE source_external_id IS NOT NULL;
CREATE INDEX idx_task_comments_task              ON task_comments (task_id, source_created_at);
CREATE INDEX idx_task_comments_author            ON task_comments (author_user_id);
CREATE INDEX idx_task_comments_parent            ON task_comments (parent_comment_id);
CREATE INDEX idx_task_comments_source_updated_at ON task_comments (source_updated_at DESC);
CREATE INDEX idx_task_comments_metadata          ON task_comments USING GIN (metadata);
CREATE INDEX idx_task_comments_search_fts
  ON task_comments
  USING GIN (to_tsvector('english', left(body, 250000)))
  WHERE archived_at IS NULL;
CREATE TRIGGER trg_task_comments_updated_at
  BEFORE UPDATE ON task_comments
  FOR EACH ROW EXECUTE PROCEDURE picardo_set_updated_at();

CREATE TABLE task_attachments (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  task_id            uuid NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
  title              text,
  subtitle           text,
  url                text,
  content_type       text,
  source_id          uuid REFERENCES sources(id) ON DELETE SET NULL,
  source_external_id text,
  source_url         text,
  metadata           jsonb NOT NULL DEFAULT '{}'::jsonb,
  archived_at        timestamptz,
  created_at         timestamptz NOT NULL DEFAULT NOW(),
  updated_at         timestamptz NOT NULL DEFAULT NOW()
);
CREATE UNIQUE INDEX uq_task_attachments_source_external_id
  ON task_attachments (source_id, source_external_id)
  WHERE source_external_id IS NOT NULL;
CREATE INDEX idx_task_attachments_task     ON task_attachments (task_id);
CREATE INDEX idx_task_attachments_metadata ON task_attachments USING GIN (metadata);
CREATE TRIGGER trg_task_attachments_updated_at
  BEFORE UPDATE ON task_attachments
  FOR EACH ROW EXECUTE PROCEDURE picardo_set_updated_at();

CREATE TABLE task_relations (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  task_id         uuid NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
  related_task_id uuid NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
  relation_type   text NOT NULL,
  source_id       uuid REFERENCES sources(id) ON DELETE SET NULL,
  metadata        jsonb NOT NULL DEFAULT '{}'::jsonb,
  archived_at     timestamptz,
  created_at      timestamptz NOT NULL DEFAULT NOW(),
  updated_at      timestamptz NOT NULL DEFAULT NOW(),
  CHECK (relation_type IN ('blocks', 'blocked_by', 'related', 'duplicate')),
  CHECK (task_id <> related_task_id)
);
CREATE UNIQUE INDEX uq_task_relations_active
  ON task_relations (task_id, related_task_id, relation_type)
  WHERE archived_at IS NULL;
CREATE INDEX idx_task_relations_related  ON task_relations (related_task_id);
CREATE INDEX idx_task_relations_type     ON task_relations (relation_type);
CREATE INDEX idx_task_relations_metadata ON task_relations USING GIN (metadata);
CREATE TRIGGER trg_task_relations_updated_at
  BEFORE UPDATE ON task_relations
  FOR EACH ROW EXECUTE PROCEDURE picardo_set_updated_at();

-- Linear issue labels attach to tasks through the existing tag system.
ALTER TABLE taggings
  DROP CONSTRAINT IF EXISTS ck_taggings_target_type;
ALTER TABLE taggings
  ADD CONSTRAINT ck_taggings_target_type CHECK (
    target_type IN ('organization', 'person', 'interaction', 'document', 'partnership', 'task')
  );

-- Task content can participate in the existing chunk-level embedding index.
ALTER TABLE semantic_embeddings
  DROP CONSTRAINT IF EXISTS semantic_embeddings_target_type_check;
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

-- Down Migration

ALTER TABLE semantic_embeddings
  DROP CONSTRAINT IF EXISTS semantic_embeddings_target_type_check;
DELETE FROM semantic_embeddings
WHERE target_type IN ('internal_user', 'task', 'task_project', 'task_comment');
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
      'extracted_fact'
    )
  );

ALTER TABLE taggings
  DROP CONSTRAINT IF EXISTS ck_taggings_target_type;
DELETE FROM taggings WHERE target_type = 'task';
ALTER TABLE taggings
  ADD CONSTRAINT ck_taggings_target_type CHECK (
    target_type IN ('organization', 'person', 'interaction', 'document', 'partnership')
  );

DROP TABLE IF EXISTS task_relations;
DROP TABLE IF EXISTS task_attachments;
DROP TABLE IF EXISTS task_comments;
DROP TABLE IF EXISTS tasks;
DROP TABLE IF EXISTS task_project_teams;
DROP TABLE IF EXISTS task_projects;
DROP TABLE IF EXISTS task_statuses;
DROP TABLE IF EXISTS task_teams;
DROP TABLE IF EXISTS internal_users;

DELETE FROM sources WHERE slug = 'linear';
