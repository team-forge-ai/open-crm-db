# Picardo Internal DB — Schema Reference

Entity-level reference for the headless-CRM schema. Mirrors the initial
migration `migrations/<ts>_initial-schema.sql`. When the migration changes,
update this file in the same PR.

## Conventions

- All primary keys are `uuid` with `DEFAULT gen_random_uuid()`.
- All tables have `created_at` and `updated_at` (`timestamptz`, `DEFAULT NOW()`).
  A shared trigger function `picardo_set_updated_at()` keeps `updated_at` fresh.
- Soft delete is expressed via `archived_at timestamptz NULL`. Hard deletes are
  reserved for genuinely junk data.
- All timestamps are `timestamptz`. Never use plain `timestamp`.
- Free-form structured data lives in `metadata jsonb NOT NULL DEFAULT '{}'`.
- Email columns use the `citext` extension so equality is case-insensitive.

## Enums

| Enum                     | Values                                                                                                                                          |
| ------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| `entity_type`            | `organization`, `person`                                                                                                                        |
| `interaction_type`       | `call`, `meeting`, `email`, `message`, `note`, `event`, `document`, `other`                                                                     |
| `interaction_direction`  | `inbound`, `outbound`, `internal`                                                                                                               |
| `participant_role`       | `host`, `attendee`, `sender`, `recipient`, `cc`, `bcc`, `mentioned`, `observer`                                                                 |
| `relationship_edge_type` | `introduced_by`, `reports_to`, `works_with`, `mentor_of`, `investor_of`, `customer_of`, `partner_of`, `parent_org_of`, `subsidiary_of`, `other` |
| `ai_note_kind`           | `summary`, `action_items`, `highlights`, `sentiment`, `coaching`, `risk`, `other`                                                               |
| `transcript_format`      | `plain_text`, `srt`, `vtt`, `speaker_turns_jsonl`, `other`                                                                                      |

## Core entities

### `organizations`

Companies, institutions, counterparties. Identified by `name` plus optional
`domain` (citext) and `slug`. Use `external_identities` to record IDs from
HubSpot, Google Contacts, etc.

### `people`

Individual humans. `primary_email` is convenience; the canonical list lives in
`person_emails`. `primary_phone` likewise relates to `person_phones`.

### `person_emails` / `person_phones`

One row per handle per person. `(person_id, email)` and `(person_id, phone)`
are unique. Pre-existing handles should be respected — emails/phones are how
inbound interactions are matched to people.

### `affiliations`

Many-to-many between `people` and `organizations`, with `title`, `department`,
`start_date`, `end_date`, `is_current`, `is_primary`. The unique partial index
`uq_affiliations_primary_per_person` enforces at most one primary affiliation
per person.

When a person changes job, set `is_current = false` and `end_date` on the old
affiliation, then insert a new row for the new role.

### `external_identities`

Provenance / dedupe keys. `(source_id, kind, external_id)` is unique. `kind`
namespaces external IDs within a source (e.g. HubSpot has both contacts and
companies). `(entity_type, entity_id)` points at either a row in
`organizations` or `people`.

This is the table to consult before inserting a new person/org from an
external source: look up by `(source_id, kind, external_id)` and reuse the
existing entity if found.

## Documents

### `documents`

Durable company knowledge artifacts that are not necessarily interactions:
internal notes, memos, research notes, strategy documents, meeting-note
documents, contract summaries, external briefs, and similar material.

Use `document_type` for a stable category such as `memo`, `research_note`,
`meeting_notes`, `strategy_doc`, `contract_summary`, `internal_note`,
`external_brief`, or `other`. `body` holds the source content, with
`body_format` defaulting to `markdown`; `summary` is for a durable human or AI
summary. `authored_at` captures when the document was written, while
`occurred_at` can capture the date of the event the document describes.

`(source_id, source_external_id)` is a partial unique idempotency key when
`source_external_id` is present. `source_path` stores repo paths, Drive paths,
or other durable file locations.

### `document_people` / `document_organizations`

Join documents to people and organizations without pretending those entities
were meeting participants. `role` is free text so ingestion can distinguish
`author`, `mentioned`, `subject`, `reviewer`, `owner`, `signatory`, or other
document-specific relationships. `(document_id, entity_id, role)` is unique.

### `document_interactions`

Join documents to interactions when a memo summarizes a call, meeting notes
belong to a calendar event, or a strategy document references prior CRM
activity. `role` defaults to `related` and can be specialized by ingestion.

## Partnerships

### `partnerships`

Operating layer for strategic, commercial, clinical, and technical partner
work. `organizations` remain the identity layer; `partnerships` capture the
pipeline/lifecycle state for a specific collaboration with an organization.

Use `partnership_type` for stable categories such as `genomics`, `labs`,
`imaging`, `health_share`, `prescriptions`, `supplements`,
`provider_network`, `data_provider`, or `other`. `stage` tracks the operating
pipeline: `prospect`, `intro`, `discovery`, `diligence`, `pilot`,
`contracting`, `live`, `paused`, or `lost`. `priority` is `low`, `medium`,
`high`, or `strategic`.

`owner_person_id` points at the internal owner when known. `signed_at` and
`launched_at` distinguish contracting from a live integration. Use
`strategic_rationale`, `commercial_model`, and `status_notes` for durable
human-readable context; keep structured details in `metadata`.

### `partnership_people`

Joins partnerships to people with partnership-specific roles such as
`champion`, `decision_maker`, `technical_contact`, `legal`, `clinical`,
`commercial`, or `internal_owner`. This table is for relationship management,
not employment history; use `affiliations` for person-to-organization roles.

### `partnership_interactions`

Joins interactions to partnerships. Use `role` to classify the interaction's
purpose, such as `intro`, `discovery`, `diligence`, `negotiation`,
`implementation`, `support`, or `related`.

### `partnership_documents`

Joins contracts, memos, pricing docs, integration notes, diligence artifacts,
and strategy documents to partnerships. Use `role` values such as `contract`,
`memo`, `integration_notes`, `pricing`, `security_review`, `clinical_review`,
or `related`.

### `partnership_services`

Product/service surface exposed by a partnership, for example whole-genome
sequencing, lab ordering, imaging fulfillment, health-share distribution, or
prescription fulfillment.

`service_type` names the category, `status` tracks `proposed`, `validating`,
`build_ready`, `live`, `paused`, or `retired`, and `patient_facing` indicates
whether members will directly experience the service. `data_modalities` is
JSON for modalities such as genome files, variants, polygenic risk reports,
lab results, imaging findings, prescriptions, claims, or eligibility data.

### `partnership_integrations`

Technical integration state for a partnership and optionally a specific
partnership service. This table records integration shape and readiness, not
patient data.

`integration_type` is one of `api`, `webhook`, `sftp`, `manual_upload`,
`pdf_import`, `email`, `portal`, or `other`. `status` tracks `not_started`,
`sandbox`, `building`, `testing`, `production`, `paused`, or `retired`.
`sync_direction` is `inbound`, `outbound`, or `bidirectional`.
`data_formats` stores expected formats such as `FHIR`, `VCF`, `PDF`, `CSV`,
or a proprietary API schema. `consent_required` and `baa_required` record
high-level compliance gating without replacing legal review.

## Interactions

### `interactions`

Canonical record of "we contacted / met with X". One row per call, meeting,
email, message, note, etc. `occurred_at` is required and indexed descending.

`(source_id, source_external_id)` is unique to give AI agents a stable
idempotency key for ingestion (e.g. Gmail message ID).

### `interaction_participants`

Joins `interactions` to `people` and/or `organizations`. Exactly one of
`person_id` or `organization_id` must be set per row (CHECK enforced). Unique
indexes prevent duplicate participant rows for the same `(interaction, entity,
role)`.

### `call_transcripts`

1:1 with `interactions` via `UNIQUE (interaction_id)`. Stores the raw
transcript inline as `raw_text` (Postgres TOAST handles size). Optional
`segments jsonb` holds structured speaker turns. `(source_id,
source_external_id)` is unique so the same Zoom transcript ID can't be
ingested twice.

## AI artifacts

### `ai_notes`

Model-generated artifacts attached either to one `interaction` or to one
`document` or to one entity via `(subject_type, subject_id)` — exactly one of
those anchoring modes per row (CHECK enforced).

Always write `model`, `model_version`, and `prompt_fingerprint` so older notes
can be regenerated when prompts evolve. `kind` lets readers filter for e.g.
`action_items` only.

### `extracted_facts`

Append-only structured statements. `(subject_type, subject_id, key)` is the
read key — clients should pick the most recent record by `observed_at`.
`confidence` is `[0, 1]`. At least one of `value_text` or `value_json` must
be set (CHECK enforced).

`interaction_id` and `source_id` are both optional pointers to where the fact
came from. `document_id` can point at the source document that produced the
fact. Use provenance generously: facts without provenance are noise.

## Flexible structures

### `tags` / `taggings`

`tags` are global (unique by `slug`). `taggings` is polymorphic over
`{organization, person, interaction, document, partnership}` with a CHECK
constraint, and `(tag_id, target_type, target_id)` is unique.

### `relationship_edges`

Typed graph edges between any two entities. Source and target each carry both
their own `entity_type` and `entity_id`. A self-edge is rejected by CHECK.
`(source, target, edge_type)` is unique so the same "X reports_to Y" edge
isn't recorded twice.

## Provenance

### `sources`

Lookup table of named systems data was sourced from (`gmail`,
`google_calendar`, `zoom`, `hubspot`, `manual`, `ai_extraction`, ...). The
initial migration seeds the common ones with `ON CONFLICT DO NOTHING` so it is
safe to re-run.

Most other tables carry a nullable `source_id` so we can always trace where a
row came from.
