# open-crm-db

> A small, generic, MIT-licensed Postgres schema and CLI for an open headless
> internal CRM / knowledge database.

`open-crm-db` is the schema layer for an internal AI-friendly knowledge base
that records every interaction your organization has with another organization
or person, the people and orgs themselves, the relationships between them, the
documents and notes you accumulate, and the tasks/projects your team operates
on top of all that.

This repo is intentionally narrow:

- the database schema (SQL migrations only)
- a small CLI to apply / inspect / scaffold migrations and to backfill local
  semantic-search embeddings
- documentation an AI agent can read to populate the database safely

There is no web UI, no API server, and no application code beyond the CLI.

## Who this is for

- Teams who want a Postgres-native, headless CRM-style schema they can shape
  to their own product instead of a closed SaaS.
- Teams who want a single store for organizations, people, interactions,
  documents, notes, facts, tasks, partnerships, and semantic embeddings that
  AI agents can write to and search over.
- Anyone who prefers SQL migrations + provenance metadata over an opinionated
  ORM and a hosted control plane.

## Requirements

- Node 20+
- pnpm 10+
- PostgreSQL 14+ with the `pgcrypto`, `citext`, `pg_trgm`, and (for semantic
  search) `vector` extensions

## Install

```sh
pnpm install
cp .env.example .env
# edit .env, set DATABASE_URL
```

## Commands

```sh
pnpm open-crm-db --help                    # full help
pnpm open-crm-db info                      # connection + schema guidance
pnpm open-crm-db migrate up                # apply all pending migrations
pnpm open-crm-db migrate up -n 1           # apply at most one
pnpm open-crm-db migrate down              # revert the most recent migration
pnpm open-crm-db migrate down -n 2         # revert the last two
pnpm open-crm-db migrate status            # applied vs pending
pnpm open-crm-db migrate create "add foo"  # scaffold a new SQL migration
pnpm open-crm-db embeddings backfill         # dry-run local semantic embedding backfill
pnpm open-crm-db embeddings backfill --apply # write local MLX embeddings
```

After `pnpm build`, the same CLI is available as `open-crm-db` (via the `bin`
entry in `package.json`).

## Project layout

```
src/                TypeScript source for the CLI
  cli.ts            Commander entrypoint + buildProgram() for tests
  config.ts         Env / path resolution
  migrations.ts     File-system + DB helpers (slugify, list, diff, create)
  runner.ts         Thin wrapper around node-pg-migrate
  schema-dump.ts    pg_dump wrapper that refreshes schema.sql after migrations
  commands/         One file per CLI command
  __tests__/        Vitest unit tests
migrations/         SQL migrations applied in timestamp order
templates/          Migration template (`-- Up Migration` / `-- Down Migration`)
docs/               schema reference + AI ingestion contract
skills/             optional self-contained local AI skill for safe operations
```

## Migrations

- All migrations are SQL (`*.sql`), never JS/TS.
- Filename: `<unix_ms>_<kebab-name>.sql`.
- Each file has two sections, split by header comments:

  ```sql
  -- Up Migration
  CREATE TABLE ...;

  -- Down Migration
  DROP TABLE ...;
  ```

- Tracking table: `public.pgmigrations` (override with
  `OPEN_CRM_DB_MIGRATIONS_TABLE` / `OPEN_CRM_DB_MIGRATIONS_SCHEMA`).
- After a successful `migrate up` or `migrate down`, the CLI refreshes
  `schema.sql` with `pg_dump --schema-only --no-owner --no-privileges`.
  Override the output path with `OPEN_CRM_DB_SCHEMA_DUMP_PATH`.
- Recent migrations make `people.primary_email` and `organizations.domain`
  required and unique. Existing databases must resolve rows missing those
  values before applying the migrations.

## Schema

See [`docs/schema.md`](docs/schema.md) for the full entity model and
[`docs/ai-ingestion.md`](docs/ai-ingestion.md) for the contract an AI agent
should follow when populating the database.

`schema.sql` is a generated convenience snapshot of the current database
schema. Schema changes should still be authored as timestamped SQL migrations.

Top-level entities:

- `organizations`, `organization_research_profiles`, `people`, `affiliations`
- `interactions`, `interaction_participants`
- `documents`, `document_people`, `document_organizations`, `document_interactions`
- `partnerships`, `partnership_people`, `partnership_interactions`, `partnership_documents`
- `partnership_services`, `partnership_integrations`
- `team_members`, `task_teams`, `task_statuses`, `task_projects`, `tasks`
- `task_comments`, `task_attachments`, `task_relations`
- `call_transcripts`, `ai_notes`, `extracted_facts`
- `semantic_embeddings`
- `tags` / `taggings`, `relationship_edges`
- `sources`, `external_identities`

Convenience views:

- `partner_integration_board` — kanban-oriented partner integration status

Identity constraints:

- `people.primary_email` is required and unique.
- `organizations.domain` is required and unique.
- For untrusted email/calendar imports, use the SQL guardrail helpers
  `crm_import_person_from_email(...)` and
  `crm_import_organization_from_email(...)` instead of inserting directly.

The task schema (`tasks`, `task_teams`, `task_statuses`, `task_projects`,
`task_comments`, `task_attachments`, `task_relations`) is a generic
work-item model. It is not derived from any specific external task tracker,
and you can populate it from whatever upstream system you choose by setting
`source_id` and `source_external_id`.

## Search

The database supports two lightweight search paths:

- lexical search through Postgres full-text search and `pg_trgm`
- semantic search through Postgres `pgvector`

For keyword search across CRM records:

```sql
select *
from search_crm_full_text('genomics lab ordering', 20);
```

For keyword search over embedded content chunks, useful for hybrid retrieval:

```sql
select *
from match_full_text_embeddings('genomics lab ordering', 10, array['document', 'ai_note']);
```

Embeddings live in the chunk-level `semantic_embeddings` table and are
searched with the SQL helper function:

```sql
select *
from match_semantic_embeddings('[...]'::vector, 10, array['document', 'ai_note']);
```

The current schema fixes vectors at 768 dimensions. For local development on
Apple Silicon, use MLX EmbeddingGemma:

```sh
uv run --with mlx-embeddings --with mlx python -c "from mlx_embeddings import load; load('mlx-community/embeddinggemma-300m-4bit')"
```

Use the same embedding model for indexing and querying. If you switch to a
model with a different vector length, add a SQL migration for the new
dimension instead of mixing dimensions in the same index.

Backfill active records into chunk-level embeddings with local MLX:

```sh
pnpm open-crm-db embeddings backfill
pnpm open-crm-db embeddings backfill --apply
pnpm open-crm-db embeddings backfill --apply --target-type document,call_transcript
```

The command is dry-run by default, skips unchanged chunks by SHA-256 hash, and
archives stale extra chunks when source content gets shorter. It loads
`DATABASE_URL` from `.env` or the local skill credentials file, and sends
source text only through the local MLX embedding runtime.

Direct source-record full-text indexes intentionally cap very long text inputs
to stay under Postgres' per-row `tsvector` limit. Full long-form coverage
should come from chunking content into `semantic_embeddings`, then using
semantic search, chunk-level full-text search, or both.

## Local AI skill

This repo includes one optional, self-contained local skill under
[`skills/`](skills/):

- [`skills/open-crm-db`](skills/open-crm-db) bundles the current schema
  snapshot, human-readable schema reference, ingestion contract, sync
  workflows, and a `psql` helper for safely searching and syncing
  transcripts, conversations, documents, notes, tasks, and extracted facts.

Live database credentials are not committed. To enable the helper, copy
`skills/open-crm-db/references/credentials.env.example` to
`skills/open-crm-db/references/credentials.env`, fill in your Postgres
connection string, and keep that file local.

## Privacy & safety

- Treat `call_transcripts.raw_text`, `ai_notes.content`, and any extracted
  PII as **highly sensitive**. Do not echo them verbatim into other systems.
- The schema is designed for first-party use. Do not store regulated data
  (PHI, payment data, etc.) here unless your deployment satisfies the
  applicable regulatory requirements.
- Never commit a populated `.env`, `credentials.env`, or any file containing
  real connection strings or secrets.

## Development

```sh
pnpm typecheck
pnpm lint
pnpm test
pnpm build
```

End-to-end against a disposable local DB:

```sh
createdb open_crm_db_dev
DATABASE_URL=postgres://localhost/open_crm_db_dev pnpm open-crm-db migrate up
DATABASE_URL=postgres://localhost/open_crm_db_dev pnpm open-crm-db migrate status
DATABASE_URL=postgres://localhost/open_crm_db_dev pnpm open-crm-db migrate down
dropdb open_crm_db_dev
```

## License

[MIT](LICENSE).
