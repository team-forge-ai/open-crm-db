-- Up Migration

-- =============================================================================
-- Picardo Internal DB — initial schema
--
-- Headless CRM for Picardo. Stores companies and people the company interacts
-- with, the relationships between them, every interaction (call, meeting,
-- email, message, note), and AI-derived artifacts (summaries, extracted facts,
-- raw transcripts).
--
-- Conventions:
--   - uuid primary keys (gen_random_uuid)
--   - created_at / updated_at on every table, with shared trigger
--   - archived_at for soft-deletable rows
--   - timestamptz everywhere; never plain timestamp
--   - explicit FK columns and ON DELETE policies; CASCADE only for
--     parent-owned children (e.g. taggings, transcripts)
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS citext;

-- -----------------------------------------------------------------------------
-- Shared: timestamp trigger
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION picardo_set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- -----------------------------------------------------------------------------
-- Enums
-- -----------------------------------------------------------------------------
CREATE TYPE entity_type AS ENUM ('organization', 'person');

CREATE TYPE interaction_type AS ENUM (
  'call',
  'meeting',
  'email',
  'message',
  'note',
  'event',
  'document',
  'other'
);

CREATE TYPE interaction_direction AS ENUM ('inbound', 'outbound', 'internal');

CREATE TYPE participant_role AS ENUM (
  'host',
  'attendee',
  'sender',
  'recipient',
  'cc',
  'bcc',
  'mentioned',
  'observer'
);

CREATE TYPE relationship_edge_type AS ENUM (
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

CREATE TYPE ai_note_kind AS ENUM (
  'summary',
  'action_items',
  'highlights',
  'sentiment',
  'coaching',
  'risk',
  'other'
);

CREATE TYPE transcript_format AS ENUM (
  'plain_text',
  'srt',
  'vtt',
  'speaker_turns_jsonl',
  'other'
);

-- -----------------------------------------------------------------------------
-- Sources of record (provenance for everything ingested)
-- -----------------------------------------------------------------------------
CREATE TABLE sources (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  -- A short stable identifier for the system the data came from. Examples:
  -- "gmail", "google_calendar", "google_meet", "zoom", "slack", "linkedin",
  -- "hubspot", "manual", "ai_extraction".
  slug         text NOT NULL UNIQUE,
  name         text NOT NULL,
  description  text,
  metadata     jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at   timestamptz NOT NULL DEFAULT NOW(),
  updated_at   timestamptz NOT NULL DEFAULT NOW()
);
CREATE TRIGGER trg_sources_updated_at
  BEFORE UPDATE ON sources
  FOR EACH ROW EXECUTE PROCEDURE picardo_set_updated_at();

-- -----------------------------------------------------------------------------
-- Organizations
-- -----------------------------------------------------------------------------
CREATE TABLE organizations (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name          text NOT NULL,
  -- Best-effort canonical slug for fuzzy matching/dedupe by an AI agent.
  slug          text UNIQUE,
  legal_name    text,
  domain        citext,
  website       text,
  description   text,
  industry      text,
  hq_city       text,
  hq_region     text,
  hq_country    text,
  notes         text,
  metadata      jsonb NOT NULL DEFAULT '{}'::jsonb,
  archived_at   timestamptz,
  created_at    timestamptz NOT NULL DEFAULT NOW(),
  updated_at    timestamptz NOT NULL DEFAULT NOW()
);
CREATE INDEX idx_organizations_name      ON organizations (lower(name));
CREATE INDEX idx_organizations_domain    ON organizations (domain);
CREATE INDEX idx_organizations_archived  ON organizations (archived_at) WHERE archived_at IS NULL;
CREATE TRIGGER trg_organizations_updated_at
  BEFORE UPDATE ON organizations
  FOR EACH ROW EXECUTE PROCEDURE picardo_set_updated_at();

-- -----------------------------------------------------------------------------
-- People
-- -----------------------------------------------------------------------------
CREATE TABLE people (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  full_name       text NOT NULL,
  given_name      text,
  family_name     text,
  display_name    text,
  preferred_name  text,
  primary_email   citext,
  primary_phone   text,
  headline        text,
  summary         text,
  city            text,
  region          text,
  country         text,
  timezone        text,
  linkedin_url    text,
  website         text,
  notes           text,
  metadata        jsonb NOT NULL DEFAULT '{}'::jsonb,
  archived_at     timestamptz,
  created_at      timestamptz NOT NULL DEFAULT NOW(),
  updated_at      timestamptz NOT NULL DEFAULT NOW()
);
CREATE INDEX idx_people_full_name      ON people (lower(full_name));
CREATE INDEX idx_people_primary_email  ON people (primary_email);
CREATE INDEX idx_people_archived       ON people (archived_at) WHERE archived_at IS NULL;
CREATE TRIGGER trg_people_updated_at
  BEFORE UPDATE ON people
  FOR EACH ROW EXECUTE PROCEDURE picardo_set_updated_at();

-- -----------------------------------------------------------------------------
-- Person contact handles (multiple emails/phones per person)
-- -----------------------------------------------------------------------------
CREATE TABLE person_emails (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  person_id    uuid NOT NULL REFERENCES people(id) ON DELETE CASCADE,
  email        citext NOT NULL,
  label        text,
  is_primary   boolean NOT NULL DEFAULT false,
  verified_at  timestamptz,
  source_id    uuid REFERENCES sources(id) ON DELETE SET NULL,
  created_at   timestamptz NOT NULL DEFAULT NOW(),
  updated_at   timestamptz NOT NULL DEFAULT NOW(),
  UNIQUE (person_id, email)
);
CREATE INDEX idx_person_emails_email ON person_emails (email);
CREATE TRIGGER trg_person_emails_updated_at
  BEFORE UPDATE ON person_emails
  FOR EACH ROW EXECUTE PROCEDURE picardo_set_updated_at();

CREATE TABLE person_phones (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  person_id    uuid NOT NULL REFERENCES people(id) ON DELETE CASCADE,
  phone        text NOT NULL,
  label        text,
  is_primary   boolean NOT NULL DEFAULT false,
  source_id    uuid REFERENCES sources(id) ON DELETE SET NULL,
  created_at   timestamptz NOT NULL DEFAULT NOW(),
  updated_at   timestamptz NOT NULL DEFAULT NOW(),
  UNIQUE (person_id, phone)
);
CREATE INDEX idx_person_phones_phone ON person_phones (phone);
CREATE TRIGGER trg_person_phones_updated_at
  BEFORE UPDATE ON person_phones
  FOR EACH ROW EXECUTE PROCEDURE picardo_set_updated_at();

-- -----------------------------------------------------------------------------
-- Affiliations: person <-> organization over time
-- -----------------------------------------------------------------------------
CREATE TABLE affiliations (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  person_id       uuid NOT NULL REFERENCES people(id) ON DELETE CASCADE,
  organization_id uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  title           text,
  department      text,
  is_current      boolean NOT NULL DEFAULT true,
  is_primary      boolean NOT NULL DEFAULT false,
  start_date      date,
  end_date        date,
  notes           text,
  source_id       uuid REFERENCES sources(id) ON DELETE SET NULL,
  metadata        jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at      timestamptz NOT NULL DEFAULT NOW(),
  updated_at      timestamptz NOT NULL DEFAULT NOW(),
  CHECK (end_date IS NULL OR start_date IS NULL OR end_date >= start_date)
);
CREATE INDEX idx_affiliations_person ON affiliations (person_id);
CREATE INDEX idx_affiliations_org    ON affiliations (organization_id);
CREATE INDEX idx_affiliations_current ON affiliations (organization_id) WHERE is_current;
CREATE UNIQUE INDEX uq_affiliations_primary_per_person
  ON affiliations (person_id) WHERE is_primary;
CREATE TRIGGER trg_affiliations_updated_at
  BEFORE UPDATE ON affiliations
  FOR EACH ROW EXECUTE PROCEDURE picardo_set_updated_at();

-- -----------------------------------------------------------------------------
-- External identities — provenance / dedupe keys for entities
-- e.g. ("hubspot", "contact", "1234") -> people row
-- -----------------------------------------------------------------------------
CREATE TABLE external_identities (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  entity_type   entity_type NOT NULL,
  entity_id     uuid NOT NULL,
  source_id     uuid NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
  -- Optional sub-namespace within the source (e.g. "contact", "company").
  kind          text,
  external_id   text NOT NULL,
  url           text,
  metadata      jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at    timestamptz NOT NULL DEFAULT NOW(),
  updated_at    timestamptz NOT NULL DEFAULT NOW(),
  UNIQUE (source_id, kind, external_id)
);
CREATE INDEX idx_external_identities_entity ON external_identities (entity_type, entity_id);
CREATE TRIGGER trg_external_identities_updated_at
  BEFORE UPDATE ON external_identities
  FOR EACH ROW EXECUTE PROCEDURE picardo_set_updated_at();

-- -----------------------------------------------------------------------------
-- Interactions
-- An interaction is the canonical record of "we talked to / met with / wrote
-- to" something or someone. Calls, meetings, emails, messages, notes.
-- -----------------------------------------------------------------------------
CREATE TABLE interactions (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  type            interaction_type NOT NULL,
  direction       interaction_direction,
  subject         text,
  body            text,
  -- When the interaction actually happened (or is scheduled to happen).
  occurred_at     timestamptz NOT NULL,
  ended_at        timestamptz,
  duration_seconds integer,
  location        text,
  -- Where the record came from (gmail, gcal, zoom, manual, ...).
  source_id       uuid REFERENCES sources(id) ON DELETE SET NULL,
  source_external_id text,
  metadata        jsonb NOT NULL DEFAULT '{}'::jsonb,
  archived_at     timestamptz,
  created_at      timestamptz NOT NULL DEFAULT NOW(),
  updated_at      timestamptz NOT NULL DEFAULT NOW(),
  CHECK (ended_at IS NULL OR ended_at >= occurred_at),
  CHECK (duration_seconds IS NULL OR duration_seconds >= 0),
  UNIQUE (source_id, source_external_id)
);
CREATE INDEX idx_interactions_occurred_at ON interactions (occurred_at DESC);
CREATE INDEX idx_interactions_type        ON interactions (type);
CREATE TRIGGER trg_interactions_updated_at
  BEFORE UPDATE ON interactions
  FOR EACH ROW EXECUTE PROCEDURE picardo_set_updated_at();

-- -----------------------------------------------------------------------------
-- Interaction participants — who was involved
-- An interaction can involve people and/or organizations. Exactly one of
-- person_id / organization_id is set per row. The unique indexes prevent
-- duplicate participant rows for the same interaction + entity.
-- -----------------------------------------------------------------------------
CREATE TABLE interaction_participants (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  interaction_id  uuid NOT NULL REFERENCES interactions(id) ON DELETE CASCADE,
  person_id       uuid REFERENCES people(id) ON DELETE SET NULL,
  organization_id uuid REFERENCES organizations(id) ON DELETE SET NULL,
  role            participant_role NOT NULL DEFAULT 'attendee',
  -- For email-style addressing: arbitrary handle used at the time.
  handle          text,
  display_name    text,
  metadata        jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at      timestamptz NOT NULL DEFAULT NOW(),
  updated_at      timestamptz NOT NULL DEFAULT NOW(),
  CHECK (
    (person_id IS NOT NULL)::int + (organization_id IS NOT NULL)::int = 1
  )
);
CREATE UNIQUE INDEX uq_interaction_participants_person
  ON interaction_participants (interaction_id, person_id, role)
  WHERE person_id IS NOT NULL;
CREATE UNIQUE INDEX uq_interaction_participants_org
  ON interaction_participants (interaction_id, organization_id, role)
  WHERE organization_id IS NOT NULL;
CREATE INDEX idx_interaction_participants_person ON interaction_participants (person_id);
CREATE INDEX idx_interaction_participants_org    ON interaction_participants (organization_id);
CREATE TRIGGER trg_interaction_participants_updated_at
  BEFORE UPDATE ON interaction_participants
  FOR EACH ROW EXECUTE PROCEDURE picardo_set_updated_at();

-- -----------------------------------------------------------------------------
-- Call transcripts — raw transcript + source metadata, 1:1 with interaction
-- -----------------------------------------------------------------------------
CREATE TABLE call_transcripts (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  interaction_id  uuid NOT NULL UNIQUE REFERENCES interactions(id) ON DELETE CASCADE,
  format          transcript_format NOT NULL DEFAULT 'plain_text',
  language        text,
  -- The full raw transcript content. For long calls this can be sizable; we
  -- keep it inline (Postgres TOASTs it) so we don't introduce a blob store.
  raw_text        text NOT NULL,
  -- Optional structured representation (speaker turns, timestamps).
  segments        jsonb,
  -- Where the audio/video originally lived.
  recording_url   text,
  recording_storage_path text,
  source_id       uuid REFERENCES sources(id) ON DELETE SET NULL,
  source_external_id text,
  -- Who/what produced the transcript itself.
  transcribed_by  text,
  transcribed_at  timestamptz,
  metadata        jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at      timestamptz NOT NULL DEFAULT NOW(),
  updated_at      timestamptz NOT NULL DEFAULT NOW(),
  UNIQUE (source_id, source_external_id)
);
CREATE INDEX idx_call_transcripts_interaction ON call_transcripts (interaction_id);
CREATE TRIGGER trg_call_transcripts_updated_at
  BEFORE UPDATE ON call_transcripts
  FOR EACH ROW EXECUTE PROCEDURE picardo_set_updated_at();

-- -----------------------------------------------------------------------------
-- AI notes — model-generated artifacts attached to an interaction OR to an
-- entity (person/org). Store the model + prompt fingerprint so older notes
-- can be re-run without losing context.
-- -----------------------------------------------------------------------------
CREATE TABLE ai_notes (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  kind              ai_note_kind NOT NULL DEFAULT 'summary',
  -- Exactly one target.
  interaction_id    uuid REFERENCES interactions(id) ON DELETE CASCADE,
  subject_type      entity_type,
  subject_id        uuid,
  title             text,
  content           text NOT NULL,
  content_format    text NOT NULL DEFAULT 'markdown',
  model             text,
  model_version     text,
  prompt_fingerprint text,
  source_id         uuid REFERENCES sources(id) ON DELETE SET NULL,
  metadata          jsonb NOT NULL DEFAULT '{}'::jsonb,
  generated_at      timestamptz NOT NULL DEFAULT NOW(),
  created_at        timestamptz NOT NULL DEFAULT NOW(),
  updated_at        timestamptz NOT NULL DEFAULT NOW(),
  CHECK (
    (interaction_id IS NOT NULL)::int +
    ((subject_type IS NOT NULL AND subject_id IS NOT NULL))::int = 1
  )
);
CREATE INDEX idx_ai_notes_interaction ON ai_notes (interaction_id);
CREATE INDEX idx_ai_notes_subject     ON ai_notes (subject_type, subject_id);
CREATE INDEX idx_ai_notes_generated   ON ai_notes (generated_at DESC);
CREATE TRIGGER trg_ai_notes_updated_at
  BEFORE UPDATE ON ai_notes
  FOR EACH ROW EXECUTE PROCEDURE picardo_set_updated_at();

-- -----------------------------------------------------------------------------
-- Extracted facts — structured key/value statements derived by AI.
-- Subject is polymorphic (person/org). Facts are immutable per (subject, key)
-- by virtue of being append-only; readers should pick the most recent record.
-- -----------------------------------------------------------------------------
CREATE TABLE extracted_facts (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  subject_type    entity_type NOT NULL,
  subject_id      uuid NOT NULL,
  key             text NOT NULL,
  value_text      text,
  value_json      jsonb,
  confidence      numeric(4, 3),
  -- Where the fact was derived from. Either an interaction or a free-text
  -- description of the source. interaction_id wins when both are present.
  interaction_id  uuid REFERENCES interactions(id) ON DELETE SET NULL,
  source_id       uuid REFERENCES sources(id) ON DELETE SET NULL,
  source_excerpt  text,
  observed_at     timestamptz NOT NULL DEFAULT NOW(),
  metadata        jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at      timestamptz NOT NULL DEFAULT NOW(),
  updated_at      timestamptz NOT NULL DEFAULT NOW(),
  CHECK (confidence IS NULL OR (confidence >= 0 AND confidence <= 1)),
  CHECK (value_text IS NOT NULL OR value_json IS NOT NULL)
);
CREATE INDEX idx_extracted_facts_subject ON extracted_facts (subject_type, subject_id, key);
CREATE INDEX idx_extracted_facts_observed ON extracted_facts (observed_at DESC);
CREATE TRIGGER trg_extracted_facts_updated_at
  BEFORE UPDATE ON extracted_facts
  FOR EACH ROW EXECUTE PROCEDURE picardo_set_updated_at();

-- -----------------------------------------------------------------------------
-- Tags + polymorphic taggings
-- -----------------------------------------------------------------------------
CREATE TABLE tags (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  slug         text NOT NULL UNIQUE,
  label        text NOT NULL,
  description  text,
  color        text,
  created_at   timestamptz NOT NULL DEFAULT NOW(),
  updated_at   timestamptz NOT NULL DEFAULT NOW()
);
CREATE TRIGGER trg_tags_updated_at
  BEFORE UPDATE ON tags
  FOR EACH ROW EXECUTE PROCEDURE picardo_set_updated_at();

CREATE TABLE taggings (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tag_id        uuid NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
  -- Polymorphic target: 'organization' | 'person' | 'interaction'
  target_type   text NOT NULL,
  target_id     uuid NOT NULL,
  source_id     uuid REFERENCES sources(id) ON DELETE SET NULL,
  created_at    timestamptz NOT NULL DEFAULT NOW(),
  UNIQUE (tag_id, target_type, target_id),
  CHECK (target_type IN ('organization', 'person', 'interaction'))
);
CREATE INDEX idx_taggings_target ON taggings (target_type, target_id);

-- -----------------------------------------------------------------------------
-- Relationship edges — typed edges between two entities
-- -----------------------------------------------------------------------------
CREATE TABLE relationship_edges (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  source_entity_type entity_type NOT NULL,
  source_entity_id   uuid NOT NULL,
  target_entity_type entity_type NOT NULL,
  target_entity_id   uuid NOT NULL,
  edge_type       relationship_edge_type NOT NULL,
  -- Free-text qualifier when edge_type doesn't fully describe the link
  -- (e.g. edge_type = 'other' with label = 'former co-founder').
  label           text,
  notes           text,
  start_date      date,
  end_date        date,
  source_id       uuid REFERENCES sources(id) ON DELETE SET NULL,
  metadata        jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at      timestamptz NOT NULL DEFAULT NOW(),
  updated_at      timestamptz NOT NULL DEFAULT NOW(),
  CHECK (
    NOT (source_entity_type = target_entity_type
         AND source_entity_id = target_entity_id)
  ),
  CHECK (end_date IS NULL OR start_date IS NULL OR end_date >= start_date),
  UNIQUE (
    source_entity_type, source_entity_id,
    target_entity_type, target_entity_id,
    edge_type
  )
);
CREATE INDEX idx_rel_edges_source ON relationship_edges (source_entity_type, source_entity_id);
CREATE INDEX idx_rel_edges_target ON relationship_edges (target_entity_type, target_entity_id);
CREATE TRIGGER trg_relationship_edges_updated_at
  BEFORE UPDATE ON relationship_edges
  FOR EACH ROW EXECUTE PROCEDURE picardo_set_updated_at();

-- -----------------------------------------------------------------------------
-- Seed: a couple of canonical sources so AI ingestion has stable slugs to
-- attach to. Safe to re-run via ON CONFLICT in future migrations.
-- -----------------------------------------------------------------------------
INSERT INTO sources (slug, name, description) VALUES
  ('manual',        'Manual entry',     'Records entered directly by a human or operator.'),
  ('ai_extraction', 'AI extraction',    'Records produced by an AI agent reading other sources.'),
  ('gmail',         'Gmail',            'Email sourced from Gmail.'),
  ('google_calendar','Google Calendar', 'Meetings sourced from Google Calendar.'),
  ('zoom',          'Zoom',             'Calls and recordings sourced from Zoom.'),
  ('google_meet',   'Google Meet',      'Calls and recordings sourced from Google Meet.')
ON CONFLICT (slug) DO NOTHING;


-- Down Migration

DROP TABLE IF EXISTS relationship_edges;
DROP TABLE IF EXISTS taggings;
DROP TABLE IF EXISTS tags;
DROP TABLE IF EXISTS extracted_facts;
DROP TABLE IF EXISTS ai_notes;
DROP TABLE IF EXISTS call_transcripts;
DROP TABLE IF EXISTS interaction_participants;
DROP TABLE IF EXISTS interactions;
DROP TABLE IF EXISTS external_identities;
DROP TABLE IF EXISTS affiliations;
DROP TABLE IF EXISTS person_phones;
DROP TABLE IF EXISTS person_emails;
DROP TABLE IF EXISTS people;
DROP TABLE IF EXISTS organizations;
DROP TABLE IF EXISTS sources;

DROP TYPE IF EXISTS transcript_format;
DROP TYPE IF EXISTS ai_note_kind;
DROP TYPE IF EXISTS relationship_edge_type;
DROP TYPE IF EXISTS participant_role;
DROP TYPE IF EXISTS interaction_direction;
DROP TYPE IF EXISTS interaction_type;
DROP TYPE IF EXISTS entity_type;

DROP FUNCTION IF EXISTS picardo_set_updated_at();
