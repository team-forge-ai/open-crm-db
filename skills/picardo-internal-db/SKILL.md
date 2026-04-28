---
name: picardo-internal-db
description: Operate Picardo's remote Neon Postgres headless CRM. Use when Codex needs to inspect, search, or edit the Picardo internal database; sync conversations, calls, transcripts, meetings, emails, documents, tasks, AI notes, extracted facts, people, organizations, partnerships, tags, or relationship edges; or run CRM SQL against the live remote database.
---

# Picardo Internal DB

## Overview

Use this skill to work with Picardo's live remote Postgres CRM. It is
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
- `scripts/psql.sh`: loads credentials and runs `psql` against Neon.

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
  cautious fuzzy matching.
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
