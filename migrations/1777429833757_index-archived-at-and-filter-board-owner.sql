-- Up Migration

CREATE INDEX idx_documents_archived ON documents (archived_at) WHERE archived_at IS NULL;
CREATE INDEX idx_interactions_archived ON interactions (archived_at) WHERE archived_at IS NULL;
CREATE INDEX idx_partnership_integrations_archived ON partnership_integrations (archived_at) WHERE archived_at IS NULL;
CREATE INDEX idx_partnership_services_archived ON partnership_services (archived_at) WHERE archived_at IS NULL;
CREATE INDEX idx_partnerships_archived ON partnerships (archived_at) WHERE archived_at IS NULL;
CREATE INDEX idx_semantic_embeddings_archived ON semantic_embeddings (archived_at) WHERE archived_at IS NULL;
CREATE INDEX idx_task_attachments_archived ON task_attachments (archived_at) WHERE archived_at IS NULL;
CREATE INDEX idx_task_comments_archived ON task_comments (archived_at) WHERE archived_at IS NULL;
CREATE INDEX idx_task_projects_archived ON task_projects (archived_at) WHERE archived_at IS NULL;
CREATE INDEX idx_task_relations_archived ON task_relations (archived_at) WHERE archived_at IS NULL;
CREATE INDEX idx_task_statuses_archived ON task_statuses (archived_at) WHERE archived_at IS NULL;
CREATE INDEX idx_task_teams_archived ON task_teams (archived_at) WHERE archived_at IS NULL;
CREATE INDEX idx_tasks_archived ON tasks (archived_at) WHERE archived_at IS NULL;
CREATE INDEX idx_team_members_archived ON team_members (archived_at) WHERE archived_at IS NULL;

CREATE OR REPLACE VIEW partner_integration_board AS
WITH integration_cards AS (
  SELECT
    ('integration:' || pi.id::text) AS card_id,
    'integration'::text AS card_kind,
    pi.status AS lane_id,
    CASE pi.status
      WHEN 'not_started' THEN 'Not started'
      WHEN 'sandbox' THEN 'Sandbox'
      WHEN 'building' THEN 'Building'
      WHEN 'testing' THEN 'Testing'
      WHEN 'production' THEN 'Production'
      WHEN 'paused' THEN 'Paused'
      WHEN 'retired' THEN 'Retired'
      ELSE initcap(replace(pi.status, '_', ' '))
    END AS lane_name,
    CASE pi.status
      WHEN 'not_started' THEN 10
      WHEN 'sandbox' THEN 20
      WHEN 'building' THEN 30
      WHEN 'testing' THEN 40
      WHEN 'production' THEN 50
      WHEN 'paused' THEN 60
      WHEN 'retired' THEN 70
      ELSE 999
    END AS lane_order,
    concat_ws(' - ', o.name, initcap(replace(pi.integration_type, '_', ' '))) AS card_title,
    concat_ws(' / ', p.name, ps.name) AS card_subtitle,
    o.id AS organization_id,
    o.name AS organization_name,
    o.slug AS organization_slug,
    o.domain::text AS organization_domain,
    p.id AS partnership_id,
    p.name AS partnership_name,
    p.partnership_type,
    p.stage AS partnership_stage,
    CASE p.stage
      WHEN 'prospect' THEN 10
      WHEN 'intro' THEN 20
      WHEN 'discovery' THEN 30
      WHEN 'diligence' THEN 40
      WHEN 'pilot' THEN 50
      WHEN 'contracting' THEN 60
      WHEN 'live' THEN 70
      WHEN 'paused' THEN 80
      WHEN 'lost' THEN 90
      ELSE 999
    END AS partnership_stage_order,
    p.priority,
    CASE p.priority
      WHEN 'strategic' THEN 10
      WHEN 'high' THEN 20
      WHEN 'medium' THEN 30
      WHEN 'low' THEN 40
      ELSE 999
    END AS priority_order,
    p.owner_person_id,
    COALESCE(owner.display_name, owner.full_name) AS owner_name,
    ps.id AS service_id,
    ps.name AS service_name,
    ps.service_type,
    ps.status AS service_status,
    CASE ps.status
      WHEN 'proposed' THEN 10
      WHEN 'validating' THEN 20
      WHEN 'build_ready' THEN 30
      WHEN 'live' THEN 40
      WHEN 'paused' THEN 50
      WHEN 'retired' THEN 60
      ELSE 999
    END AS service_status_order,
    ps.patient_facing,
    pi.id AS integration_id,
    pi.integration_type,
    pi.status AS integration_status,
    CASE pi.status
      WHEN 'not_started' THEN 10
      WHEN 'sandbox' THEN 20
      WHEN 'building' THEN 30
      WHEN 'testing' THEN 40
      WHEN 'production' THEN 50
      WHEN 'paused' THEN 60
      WHEN 'retired' THEN 70
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
    array_remove(ARRAY[
      p.partnership_type,
      p.priority,
      pi.integration_type,
      pi.sync_direction,
      CASE WHEN pi.consent_required THEN 'consent_required' END,
      CASE WHEN pi.baa_required THEN 'baa_required' END,
      CASE WHEN ps.patient_facing THEN 'patient_facing' END
    ], NULL) AS card_labels,
    jsonb_build_object(
      'partnership_metadata', p.metadata,
      'service_metadata', COALESCE(ps.metadata, '{}'::jsonb),
      'integration_metadata', pi.metadata
    ) AS metadata,
    LEAST(p.created_at, pi.created_at, COALESCE(ps.created_at, pi.created_at)) AS created_at,
    GREATEST(p.updated_at, pi.updated_at, COALESCE(ps.updated_at, pi.updated_at)) AS updated_at
  FROM partnership_integrations pi
  JOIN partnerships p ON p.id = pi.partnership_id
  JOIN organizations o ON o.id = p.organization_id
  LEFT JOIN partnership_services ps
    ON ps.id = pi.service_id
    AND ps.archived_at IS NULL
  LEFT JOIN people owner
    ON owner.id = p.owner_person_id
    AND owner.archived_at IS NULL
  WHERE p.archived_at IS NULL
    AND o.archived_at IS NULL
    AND pi.archived_at IS NULL
),
unmapped_cards AS (
  SELECT
    CASE
      WHEN ps.id IS NULL THEN ('partnership:' || p.id::text)
      ELSE ('service:' || ps.id::text)
    END AS card_id,
    CASE WHEN ps.id IS NULL THEN 'partnership' ELSE 'service' END::text AS card_kind,
    'unmapped'::text AS lane_id,
    'Unmapped'::text AS lane_name,
    0 AS lane_order,
    concat_ws(' - ', o.name, ps.name) AS card_title,
    p.name AS card_subtitle,
    o.id AS organization_id,
    o.name AS organization_name,
    o.slug AS organization_slug,
    o.domain::text AS organization_domain,
    p.id AS partnership_id,
    p.name AS partnership_name,
    p.partnership_type,
    p.stage AS partnership_stage,
    CASE p.stage
      WHEN 'prospect' THEN 10
      WHEN 'intro' THEN 20
      WHEN 'discovery' THEN 30
      WHEN 'diligence' THEN 40
      WHEN 'pilot' THEN 50
      WHEN 'contracting' THEN 60
      WHEN 'live' THEN 70
      WHEN 'paused' THEN 80
      WHEN 'lost' THEN 90
      ELSE 999
    END AS partnership_stage_order,
    p.priority,
    CASE p.priority
      WHEN 'strategic' THEN 10
      WHEN 'high' THEN 20
      WHEN 'medium' THEN 30
      WHEN 'low' THEN 40
      ELSE 999
    END AS priority_order,
    p.owner_person_id,
    COALESCE(owner.display_name, owner.full_name) AS owner_name,
    ps.id AS service_id,
    ps.name AS service_name,
    ps.service_type,
    ps.status AS service_status,
    CASE ps.status
      WHEN 'proposed' THEN 10
      WHEN 'validating' THEN 20
      WHEN 'build_ready' THEN 30
      WHEN 'live' THEN 40
      WHEN 'paused' THEN 50
      WHEN 'retired' THEN 60
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
    NULL::timestamptz AS last_sync_at,
    p.signed_at,
    p.launched_at,
    p.status_notes,
    NULL::text AS integration_notes,
    ps.clinical_use,
    array_remove(ARRAY[
      p.partnership_type,
      p.priority,
      ps.service_type,
      CASE WHEN COALESCE(ps.patient_facing, false) THEN 'patient_facing' END
    ], NULL) AS card_labels,
    jsonb_build_object(
      'partnership_metadata', p.metadata,
      'service_metadata', COALESCE(ps.metadata, '{}'::jsonb),
      'integration_metadata', '{}'::jsonb
    ) AS metadata,
    LEAST(p.created_at, COALESCE(ps.created_at, p.created_at)) AS created_at,
    GREATEST(p.updated_at, COALESCE(ps.updated_at, p.updated_at)) AS updated_at
  FROM partnerships p
  JOIN organizations o ON o.id = p.organization_id
  LEFT JOIN partnership_services ps
    ON ps.partnership_id = p.id
    AND ps.archived_at IS NULL
  LEFT JOIN people owner
    ON owner.id = p.owner_person_id
    AND owner.archived_at IS NULL
  WHERE p.archived_at IS NULL
    AND o.archived_at IS NULL
    AND NOT EXISTS (
      SELECT 1
      FROM partnership_integrations pi
      WHERE pi.partnership_id = p.id
        AND pi.archived_at IS NULL
    )
)
SELECT *
FROM integration_cards
UNION ALL
SELECT *
FROM unmapped_cards;

COMMENT ON VIEW partner_integration_board IS 'Kanban-oriented partner integration board. One card per active integration, plus unmapped active partnerships/services without an integration row.';
COMMENT ON COLUMN partner_integration_board.card_id IS 'Stable display ID for the board card, prefixed by the source row kind.';
COMMENT ON COLUMN partner_integration_board.card_kind IS 'Card source type: integration, service, or partnership.';
COMMENT ON COLUMN partner_integration_board.lane_id IS 'Kanban lane key, usually the integration status; unmapped means no active integration row exists yet.';
COMMENT ON COLUMN partner_integration_board.lane_order IS 'Numeric lane order for board rendering.';
COMMENT ON COLUMN partner_integration_board.card_labels IS 'Small derived labels suitable for compact card badges.';
COMMENT ON COLUMN partner_integration_board.metadata IS 'Combined partnership, service, and integration metadata for drill-down views.';

-- Down Migration

CREATE OR REPLACE VIEW partner_integration_board AS
WITH integration_cards AS (
  SELECT
    ('integration:' || pi.id::text) AS card_id,
    'integration'::text AS card_kind,
    pi.status AS lane_id,
    CASE pi.status
      WHEN 'not_started' THEN 'Not started'
      WHEN 'sandbox' THEN 'Sandbox'
      WHEN 'building' THEN 'Building'
      WHEN 'testing' THEN 'Testing'
      WHEN 'production' THEN 'Production'
      WHEN 'paused' THEN 'Paused'
      WHEN 'retired' THEN 'Retired'
      ELSE initcap(replace(pi.status, '_', ' '))
    END AS lane_name,
    CASE pi.status
      WHEN 'not_started' THEN 10
      WHEN 'sandbox' THEN 20
      WHEN 'building' THEN 30
      WHEN 'testing' THEN 40
      WHEN 'production' THEN 50
      WHEN 'paused' THEN 60
      WHEN 'retired' THEN 70
      ELSE 999
    END AS lane_order,
    concat_ws(' - ', o.name, initcap(replace(pi.integration_type, '_', ' '))) AS card_title,
    concat_ws(' / ', p.name, ps.name) AS card_subtitle,
    o.id AS organization_id,
    o.name AS organization_name,
    o.slug AS organization_slug,
    o.domain::text AS organization_domain,
    p.id AS partnership_id,
    p.name AS partnership_name,
    p.partnership_type,
    p.stage AS partnership_stage,
    CASE p.stage
      WHEN 'prospect' THEN 10
      WHEN 'intro' THEN 20
      WHEN 'discovery' THEN 30
      WHEN 'diligence' THEN 40
      WHEN 'pilot' THEN 50
      WHEN 'contracting' THEN 60
      WHEN 'live' THEN 70
      WHEN 'paused' THEN 80
      WHEN 'lost' THEN 90
      ELSE 999
    END AS partnership_stage_order,
    p.priority,
    CASE p.priority
      WHEN 'strategic' THEN 10
      WHEN 'high' THEN 20
      WHEN 'medium' THEN 30
      WHEN 'low' THEN 40
      ELSE 999
    END AS priority_order,
    p.owner_person_id,
    COALESCE(owner.display_name, owner.full_name) AS owner_name,
    ps.id AS service_id,
    ps.name AS service_name,
    ps.service_type,
    ps.status AS service_status,
    CASE ps.status
      WHEN 'proposed' THEN 10
      WHEN 'validating' THEN 20
      WHEN 'build_ready' THEN 30
      WHEN 'live' THEN 40
      WHEN 'paused' THEN 50
      WHEN 'retired' THEN 60
      ELSE 999
    END AS service_status_order,
    ps.patient_facing,
    pi.id AS integration_id,
    pi.integration_type,
    pi.status AS integration_status,
    CASE pi.status
      WHEN 'not_started' THEN 10
      WHEN 'sandbox' THEN 20
      WHEN 'building' THEN 30
      WHEN 'testing' THEN 40
      WHEN 'production' THEN 50
      WHEN 'paused' THEN 60
      WHEN 'retired' THEN 70
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
    array_remove(ARRAY[
      p.partnership_type,
      p.priority,
      pi.integration_type,
      pi.sync_direction,
      CASE WHEN pi.consent_required THEN 'consent_required' END,
      CASE WHEN pi.baa_required THEN 'baa_required' END,
      CASE WHEN ps.patient_facing THEN 'patient_facing' END
    ], NULL) AS card_labels,
    jsonb_build_object(
      'partnership_metadata', p.metadata,
      'service_metadata', COALESCE(ps.metadata, '{}'::jsonb),
      'integration_metadata', pi.metadata
    ) AS metadata,
    LEAST(p.created_at, pi.created_at, COALESCE(ps.created_at, pi.created_at)) AS created_at,
    GREATEST(p.updated_at, pi.updated_at, COALESCE(ps.updated_at, pi.updated_at)) AS updated_at
  FROM partnership_integrations pi
  JOIN partnerships p ON p.id = pi.partnership_id
  JOIN organizations o ON o.id = p.organization_id
  LEFT JOIN partnership_services ps
    ON ps.id = pi.service_id
    AND ps.archived_at IS NULL
  LEFT JOIN people owner ON owner.id = p.owner_person_id
  WHERE p.archived_at IS NULL
    AND o.archived_at IS NULL
    AND pi.archived_at IS NULL
),
unmapped_cards AS (
  SELECT
    CASE
      WHEN ps.id IS NULL THEN ('partnership:' || p.id::text)
      ELSE ('service:' || ps.id::text)
    END AS card_id,
    CASE WHEN ps.id IS NULL THEN 'partnership' ELSE 'service' END::text AS card_kind,
    'unmapped'::text AS lane_id,
    'Unmapped'::text AS lane_name,
    0 AS lane_order,
    concat_ws(' - ', o.name, ps.name) AS card_title,
    p.name AS card_subtitle,
    o.id AS organization_id,
    o.name AS organization_name,
    o.slug AS organization_slug,
    o.domain::text AS organization_domain,
    p.id AS partnership_id,
    p.name AS partnership_name,
    p.partnership_type,
    p.stage AS partnership_stage,
    CASE p.stage
      WHEN 'prospect' THEN 10
      WHEN 'intro' THEN 20
      WHEN 'discovery' THEN 30
      WHEN 'diligence' THEN 40
      WHEN 'pilot' THEN 50
      WHEN 'contracting' THEN 60
      WHEN 'live' THEN 70
      WHEN 'paused' THEN 80
      WHEN 'lost' THEN 90
      ELSE 999
    END AS partnership_stage_order,
    p.priority,
    CASE p.priority
      WHEN 'strategic' THEN 10
      WHEN 'high' THEN 20
      WHEN 'medium' THEN 30
      WHEN 'low' THEN 40
      ELSE 999
    END AS priority_order,
    p.owner_person_id,
    COALESCE(owner.display_name, owner.full_name) AS owner_name,
    ps.id AS service_id,
    ps.name AS service_name,
    ps.service_type,
    ps.status AS service_status,
    CASE ps.status
      WHEN 'proposed' THEN 10
      WHEN 'validating' THEN 20
      WHEN 'build_ready' THEN 30
      WHEN 'live' THEN 40
      WHEN 'paused' THEN 50
      WHEN 'retired' THEN 60
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
    NULL::timestamptz AS last_sync_at,
    p.signed_at,
    p.launched_at,
    p.status_notes,
    NULL::text AS integration_notes,
    ps.clinical_use,
    array_remove(ARRAY[
      p.partnership_type,
      p.priority,
      ps.service_type,
      CASE WHEN COALESCE(ps.patient_facing, false) THEN 'patient_facing' END
    ], NULL) AS card_labels,
    jsonb_build_object(
      'partnership_metadata', p.metadata,
      'service_metadata', COALESCE(ps.metadata, '{}'::jsonb),
      'integration_metadata', '{}'::jsonb
    ) AS metadata,
    LEAST(p.created_at, COALESCE(ps.created_at, p.created_at)) AS created_at,
    GREATEST(p.updated_at, COALESCE(ps.updated_at, p.updated_at)) AS updated_at
  FROM partnerships p
  JOIN organizations o ON o.id = p.organization_id
  LEFT JOIN partnership_services ps
    ON ps.partnership_id = p.id
    AND ps.archived_at IS NULL
  LEFT JOIN people owner ON owner.id = p.owner_person_id
  WHERE p.archived_at IS NULL
    AND o.archived_at IS NULL
    AND NOT EXISTS (
      SELECT 1
      FROM partnership_integrations pi
      WHERE pi.partnership_id = p.id
        AND pi.archived_at IS NULL
    )
)
SELECT *
FROM integration_cards
UNION ALL
SELECT *
FROM unmapped_cards;

COMMENT ON VIEW partner_integration_board IS 'Kanban-oriented partner integration board. One card per active integration, plus unmapped active partnerships/services without an integration row.';
COMMENT ON COLUMN partner_integration_board.card_id IS 'Stable display ID for the board card, prefixed by the source row kind.';
COMMENT ON COLUMN partner_integration_board.card_kind IS 'Card source type: integration, service, or partnership.';
COMMENT ON COLUMN partner_integration_board.lane_id IS 'Kanban lane key, usually the integration status; unmapped means no active integration row exists yet.';
COMMENT ON COLUMN partner_integration_board.lane_order IS 'Numeric lane order for board rendering.';
COMMENT ON COLUMN partner_integration_board.card_labels IS 'Small derived labels suitable for compact card badges.';
COMMENT ON COLUMN partner_integration_board.metadata IS 'Combined partnership, service, and integration metadata for drill-down views.';

DROP INDEX idx_team_members_archived;
DROP INDEX idx_tasks_archived;
DROP INDEX idx_task_teams_archived;
DROP INDEX idx_task_statuses_archived;
DROP INDEX idx_task_relations_archived;
DROP INDEX idx_task_projects_archived;
DROP INDEX idx_task_comments_archived;
DROP INDEX idx_task_attachments_archived;
DROP INDEX idx_semantic_embeddings_archived;
DROP INDEX idx_partnerships_archived;
DROP INDEX idx_partnership_services_archived;
DROP INDEX idx_partnership_integrations_archived;
DROP INDEX idx_interactions_archived;
DROP INDEX idx_documents_archived;
