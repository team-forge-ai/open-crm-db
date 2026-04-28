-- Up Migration

-- -----------------------------------------------------------------------------
-- Partnership services
-- Product/service surface exposed by a partnership, e.g. whole-genome
-- sequencing, lab ordering, imaging fulfillment, health-share distribution, or
-- prescription fulfillment.
-- -----------------------------------------------------------------------------
CREATE TABLE partnership_services (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  partnership_id   uuid NOT NULL REFERENCES partnerships(id) ON DELETE CASCADE,
  service_type     text NOT NULL,
  name             text NOT NULL,
  patient_facing   boolean NOT NULL DEFAULT false,
  status           text NOT NULL DEFAULT 'proposed',
  data_modalities  jsonb NOT NULL DEFAULT '[]'::jsonb,
  clinical_use     text,
  metadata         jsonb NOT NULL DEFAULT '{}'::jsonb,
  archived_at      timestamptz,
  created_at       timestamptz NOT NULL DEFAULT NOW(),
  updated_at       timestamptz NOT NULL DEFAULT NOW(),
  UNIQUE (id, partnership_id),
  CHECK (status IN ('proposed', 'validating', 'build_ready', 'live', 'paused', 'retired')),
  CHECK (jsonb_typeof(data_modalities) IN ('array', 'object'))
);
CREATE UNIQUE INDEX uq_partnership_services_active_name
  ON partnership_services (partnership_id, service_type, lower(name))
  WHERE archived_at IS NULL;
CREATE INDEX idx_partnership_services_partnership ON partnership_services (partnership_id);
CREATE INDEX idx_partnership_services_type        ON partnership_services (service_type);
CREATE INDEX idx_partnership_services_status      ON partnership_services (status);
CREATE INDEX idx_partnership_services_modalities  ON partnership_services USING GIN (data_modalities);
CREATE INDEX idx_partnership_services_metadata    ON partnership_services USING GIN (metadata);
CREATE TRIGGER trg_partnership_services_updated_at
  BEFORE UPDATE ON partnership_services
  FOR EACH ROW EXECUTE PROCEDURE crm_set_updated_at();


-- Down Migration

DROP TABLE IF EXISTS partnership_services;
