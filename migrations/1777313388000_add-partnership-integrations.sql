-- Up Migration

-- -----------------------------------------------------------------------------
-- Partnership integrations
-- Technical integration state for a partnership/service. This captures the data
-- flow Picardo needs to import/export, without storing patient data here.
-- -----------------------------------------------------------------------------
CREATE TABLE partnership_integrations (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  partnership_id     uuid NOT NULL REFERENCES partnerships(id) ON DELETE CASCADE,
  service_id         uuid,
  source_id          uuid REFERENCES sources(id) ON DELETE SET NULL,
  integration_type   text NOT NULL,
  status             text NOT NULL DEFAULT 'not_started',
  data_formats       jsonb NOT NULL DEFAULT '[]'::jsonb,
  sync_direction     text NOT NULL DEFAULT 'inbound',
  consent_required   boolean NOT NULL DEFAULT false,
  baa_required       boolean NOT NULL DEFAULT false,
  last_sync_at       timestamptz,
  notes              text,
  metadata           jsonb NOT NULL DEFAULT '{}'::jsonb,
  archived_at        timestamptz,
  created_at         timestamptz NOT NULL DEFAULT NOW(),
  updated_at         timestamptz NOT NULL DEFAULT NOW(),
  CHECK (integration_type IN ('api', 'webhook', 'sftp', 'manual_upload', 'pdf_import', 'email', 'portal', 'other')),
  CHECK (status IN ('not_started', 'sandbox', 'building', 'testing', 'production', 'paused', 'retired')),
  CHECK (sync_direction IN ('inbound', 'outbound', 'bidirectional')),
  CHECK (jsonb_typeof(data_formats) IN ('array', 'object')),
  FOREIGN KEY (service_id, partnership_id)
    REFERENCES partnership_services(id, partnership_id)
    ON DELETE CASCADE
);
CREATE INDEX idx_partnership_integrations_partnership ON partnership_integrations (partnership_id);
CREATE INDEX idx_partnership_integrations_service     ON partnership_integrations (service_id);
CREATE INDEX idx_partnership_integrations_source      ON partnership_integrations (source_id);
CREATE INDEX idx_partnership_integrations_type        ON partnership_integrations (integration_type);
CREATE INDEX idx_partnership_integrations_status      ON partnership_integrations (status);
CREATE INDEX idx_partnership_integrations_formats     ON partnership_integrations USING GIN (data_formats);
CREATE INDEX idx_partnership_integrations_metadata    ON partnership_integrations USING GIN (metadata);
CREATE TRIGGER trg_partnership_integrations_updated_at
  BEFORE UPDATE ON partnership_integrations
  FOR EACH ROW EXECUTE PROCEDURE picardo_set_updated_at();


-- Down Migration

DROP TABLE IF EXISTS partnership_integrations;
