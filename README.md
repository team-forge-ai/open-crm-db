# Picardo Internal DB

Headless TypeScript CLI that owns the schema and migrations for **Picardo's
internal Postgres database** — a headless CRM that records every interaction
the company has with another company or person, including raw call transcripts
and AI-derived notes.

This repo is intentionally narrow:

- the database schema (SQL migrations only)
- a small CLI to apply / inspect / scaffold migrations
- documentation an AI agent can read to populate the database safely

There is no web UI, no API server, and no application code beyond the CLI.

## Requirements

- Node 20+
- pnpm 10+
- PostgreSQL 14+

## Install

```sh
pnpm install
cp .env.example .env
# edit .env, set DATABASE_URL
```

## Commands

```sh
pnpm picardo-db --help                    # full help
pnpm picardo-db info                      # connection + schema guidance
pnpm picardo-db migrate up                # apply all pending migrations
pnpm picardo-db migrate up -n 1           # apply at most one
pnpm picardo-db migrate down              # revert the most recent migration
pnpm picardo-db migrate down -n 2         # revert the last two
pnpm picardo-db migrate status            # applied vs pending
pnpm picardo-db migrate create "add foo"  # scaffold a new SQL migration
pnpm picardo-db embeddings backfill        # dry-run local semantic embedding backfill
pnpm picardo-db embeddings backfill --apply # write local MLX embeddings
pnpm enrich:crm --limit 5                 # dry-run public CRM enrichment
pnpm enrich:crm --apply --limit 5         # write enrichment facts/notes
pnpm import:linear                        # dry-run Linear task import
pnpm import:linear --apply                # import Linear tasks into Postgres
```

After `pnpm build`, the same CLI is available as `picardo-db` (via the `bin`
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
docs/internal-db/   plan / status / schema / ai-ingestion / final-report
skills/             local AI skill for safe CRM database operations
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
  `PICARDO_DB_MIGRATIONS_TABLE` / `PICARDO_DB_MIGRATIONS_SCHEMA`).
- After a successful `migrate up` or `migrate down`, the CLI refreshes
  `schema.sql` with `pg_dump --schema-only --no-owner --no-privileges`.
  Override the output path with `PICARDO_DB_SCHEMA_DUMP_PATH`.

## Schema

See [`docs/internal-db/schema.md`](docs/internal-db/schema.md) for the full
entity model and [`docs/internal-db/ai-ingestion.md`](docs/internal-db/ai-ingestion.md)
for the contract an AI agent should follow when populating the database.

`schema.sql` is a generated convenience snapshot of the current database schema.
Schema changes should still be authored as timestamped SQL migrations.

## CRM enrichment

`picardo-db enrich` uses Perplexity's cheapest Sonar API model (`sonar`) through
Vercel's AI SDK to fill blank public profile fields for `organizations` and
`people`, then append provenance-backed `extracted_facts` and `ai_notes` when
run with `--apply`.

The command defaults to dry-run mode:

```sh
pnpm enrich:crm --limit 5
pnpm enrich:crm --entity organizations --apply --limit 10
```

It loads `DATABASE_URL` from `.env` or the local skill credentials file, and
loads `PERPLEXITY_API_KEY` from the environment or
`~/repos/cursor-agent/.env`. The default search context is `low` to keep
Perplexity request cost down; use `--search-context medium` or `high` only when
you need broader source context.

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

Embeddings live in the chunk-level `semantic_embeddings` table and are searched
with the SQL helper function:

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
model with a different vector length, add a SQL migration for the new dimension
instead of mixing dimensions in the same index.

Backfill active CRM records into chunk-level embeddings with local MLX:

```sh
pnpm picardo-db embeddings backfill
pnpm picardo-db embeddings backfill --apply
pnpm picardo-db embeddings backfill --apply --target-type document,call_transcript
```

The command is dry-run by default, skips unchanged chunks by SHA-256 hash, and
archives stale extra chunks when source content gets shorter. It loads
`DATABASE_URL` from `.env` or the local skill credentials file, and sends source
text only through the local MLX embedding runtime.

Direct source-record full-text indexes intentionally cap very long text inputs
to stay under Postgres' per-row `tsvector` limit. Full long-form coverage should
come from chunking content into `semantic_embeddings`, then using semantic
search, chunk-level full-text search, or both.

## Local AI skill

This repo includes reusable local skills under [`skills/`](skills/):

- [`skills/picardo-internal-db`](skills/picardo-internal-db) contains schema
  references, ingestion workflows, and a `psql` helper for agents that need to
  sync transcripts, conversations, documents, notes, and extracted facts.
- [`skills/picardo-db-search`](skills/picardo-db-search) contains a read-only
  hybrid search workflow that combines Postgres full-text search with local
  EmbeddingGemma semantic search through MLX.

Live database credentials are not committed. To enable the helper, copy
`skills/picardo-internal-db/references/credentials.env.example` to
`skills/picardo-internal-db/references/credentials.env`, fill in the Neon
connection string, and keep that file local.

## Development

```sh
pnpm typecheck
pnpm lint
pnpm test
pnpm build
```

End-to-end against a disposable local DB:

```sh
createdb picardo_internal_db_dev
DATABASE_URL=postgres://localhost/picardo_internal_db_dev pnpm picardo-db migrate up
DATABASE_URL=postgres://localhost/picardo_internal_db_dev pnpm picardo-db migrate status
DATABASE_URL=postgres://localhost/picardo_internal_db_dev pnpm picardo-db migrate down
dropdb picardo_internal_db_dev
```

## License

UNLICENSED — internal to Picardo / team-forge-ai.
