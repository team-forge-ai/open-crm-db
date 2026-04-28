-- Up Migration
CREATE TABLE organization_research_profiles (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  source_id uuid REFERENCES sources(id) ON DELETE SET NULL,
  model text,
  model_version text,
  prompt_fingerprint text NOT NULL,
  canonical_name text,
  website text,
  domain citext,
  one_line_description text,
  category text,
  healthcare_relevance text,
  partnership_fit text,
  partnership_fit_rationale text,
  offerings jsonb NOT NULL DEFAULT '[]'::jsonb,
  likely_use_cases jsonb NOT NULL DEFAULT '[]'::jsonb,
  integration_signals jsonb NOT NULL DEFAULT '[]'::jsonb,
  compliance_signals jsonb NOT NULL DEFAULT '[]'::jsonb,
  key_public_people jsonb NOT NULL DEFAULT '[]'::jsonb,
  suggested_tags jsonb NOT NULL DEFAULT '[]'::jsonb,
  review_flags jsonb NOT NULL DEFAULT '[]'::jsonb,
  source_urls jsonb NOT NULL DEFAULT '[]'::jsonb,
  raw_enrichment jsonb NOT NULL DEFAULT '{}'::jsonb,
  researched_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (organization_id, prompt_fingerprint)
);

CREATE INDEX idx_organization_research_profiles_org
  ON organization_research_profiles (organization_id);

CREATE INDEX idx_organization_research_profiles_category
  ON organization_research_profiles (category);

CREATE INDEX idx_organization_research_profiles_researched_at
  ON organization_research_profiles (researched_at DESC);

CREATE TRIGGER trg_organization_research_profiles_updated_at
  BEFORE UPDATE ON organization_research_profiles
  FOR EACH ROW
  EXECUTE FUNCTION crm_set_updated_at();

-- Down Migration
DROP TABLE organization_research_profiles;
