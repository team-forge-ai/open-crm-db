---
name: open-crm-db
description: Operate an open-crm-db Postgres database. Use when an AI agent needs to inspect, search, or edit the headless CRM database; sync conversations, calls, transcripts, meetings, emails, documents, tasks, AI notes, extracted facts, people, organizations, partnerships, tags, or relationship edges; or run CRM SQL against the live database.
---

# open-crm-db

## Overview

Use this skill to work with a live `open-crm-db` Postgres database. It is
self-contained so it can be copied or aliased into `~/.agents/skills` without
repo-relative references. Live credentials are intentionally local-only: set
`DATABASE_URL` in the environment or create `references/credentials.env` from
`references/credentials.env.example`.

Treat the database as live production-like data. Make reads freely when useful;
make writes only when the user asks for data changes or sync work.

## Resources

- `references/credentials.env.example`: template for local-only `DATABASE_URL`.
- `references/credentials.env`: optional ignored local credential file. Do not print it.
- `references/schema.sql`: exact schema snapshot for the migrated database.
- `references/schema.md`: human-readable entity model.
- `references/ai-ingestion.md`: identity, dedupe, idempotency, privacy rules.
- `references/sync-workflows.md`: SQL patterns for syncing interactions and transcripts.
- `scripts/psql.sh`: loads credentials and runs `psql` against the configured database.

Read `references/schema.md` and `references/ai-ingestion.md` before writing
data. Use `references/schema.sql` when you need exact columns, constraints,
indexes, views, or SQL helper functions. Read `references/sync-workflows.md`
before syncing documents, conversations, transcripts, notes, or facts.

## Database Access

Run SQL through the helper so credentials stay out of shell history and command
output. The helper uses `DATABASE_URL` from the environment when present, or
loads `references/credentials.env` when present:

```bash
scripts/psql.sh -c "select now();"
```

For multi-statement writes, create a temporary SQL file outside the skill and
run:

```bash
scripts/psql.sh -v ON_ERROR_STOP=1 -f /path/to/work.sql
```

Use `BEGIN; ... COMMIT;` for write batches. Use `ROLLBACK;` while rehearsing.

## Operating Rules

Do not echo `DATABASE_URL`, passwords, transcript bodies, or full AI notes in
responses. Summarize row counts and IDs instead.

Prefer idempotent writes:

- For people/orgs: resolve by `external_identities`, then email/domain, then
  cautious fuzzy matching. Use `crm_import_person_from_email(...)` and
  `crm_import_organization_from_email(...)` for untrusted email/calendar
  imports.
- For interactions: use `(source_id, source_external_id)`.
- For transcripts: use `(source_id, source_external_id)` when available, else
  `interaction_id`.
- For facts: append new `extracted_facts`; do not overwrite history.

Use parameterized SQL or `psql` variables for user-provided values. If ad hoc
literal SQL is unavoidable, escape carefully.

Never run destructive operations (`DROP`, `TRUNCATE`, broad `DELETE`, mass
`UPDATE`, migration rollback) unless the user explicitly requests that exact
operation. For corrections, prefer targeted updates or soft deletion via
`archived_at` where available.

Before and after substantial writes, run:

```sql
select name, run_on from public.pgmigrations order by id;
select count(*) from interactions;
select count(*) from call_transcripts;
```

## CRM Enrichment Workflow

When the user asks to enrich CRM records, assume you are responsible for
enriching the CRM fields at runtime: gather evidence, decide the best
structured values, write them to the CRM, and preserve provenance. Do not wait
for a separate enrichment service unless the user explicitly asks for one.

For organizations:

1. Resolve the organization by `external_identities`, domain, or cautious name
   matching.
2. Fill stable public identity fields on `organizations` when supported by
   evidence: `name`, `legal_name`, `domain`, `website`, `description`,
   `industry`, `hq_city`, `hq_region`, and `hq_country`.
3. Use `organization_research_profiles` for richer AI/public research:
   one-line description, category, partnership fit, offerings, likely use
   cases, integration/compliance signals, key public people, suggested tags,
   review flags, source URLs, and raw enrichment.
4. Keep provider-specific or run-specific details in `metadata`, but do not
   hide important first-class fields there.

For people:

1. Resolve people by `external_identities`, email, or cautious matching.
2. Store durable display/profile fields on `people`: `headline`, `summary`,
   location fields, `linkedin_url`, `website`, and `notes` when appropriate.
3. Store employment evidence on `affiliations`: `organization_id`, `title`,
   `department`, `is_current`, `is_primary`, `role_family`, and `seniority`.
   The `people.current_*`, `people.role_family`, and `people.seniority` fields
   are synced from the best current affiliation by trigger.
4. Treat `NULL` role/seniority as "not attempted"; write `unknown` only when a
   classification attempt was made and no confident value could be resolved.

For all enrichment:

- Prefer source-backed facts from email signatures, calendar context, public
  profiles, company websites, or trusted documents.
- Append durable claims to `extracted_facts` with `source_id`,
  `source_excerpt`, confidence, and source metadata when useful.
- Do not overwrite richer human-entered values with lower-confidence AI
  guesses. If evidence conflicts, add a review flag or fact rather than
  silently replacing data.

## Search

Use read-only SQL through `scripts/psql.sh` for CRM search. Prefer
`search_crm_full_text` for names, emails, product terms, and quoted phrases.
Use `match_full_text_embeddings` or `match_semantic_embeddings` for chunk-level
retrieval after embeddings have been backfilled. Return IDs, target types,
titles, scores, and short excerpts; summarize sensitive matches instead of
dumping transcripts or full AI notes.

Supported search target types are documented in `references/schema.md` and
defined exactly in `references/schema.sql`.

## Sync Workflow

For a document, transcript, or conversation sync:

1. Identify the source slug (`zoom`, `google_meet`, `gmail`, `manual`, etc.)
   and stable external ID.
2. Resolve or create participating people and organizations.
3. Upsert the `interactions` row.
4. Upsert `interaction_participants`.
5. For durable memos/research/strategy/meeting-note files, upsert `documents`
   and link through `document_people`, `document_organizations`, or
   `document_interactions`.
6. Upsert `call_transcripts` when raw transcript text or segments exist.
7. Insert `ai_notes` for summaries/action items/coaching outputs.
8. Insert `extracted_facts` for structured person/org facts.
9. Verify counts and return a concise summary.

Use `references/sync-workflows.md` for CTE patterns.
