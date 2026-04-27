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
  commands/         One file per CLI command
  __tests__/        Vitest unit tests
migrations/         SQL migrations applied in timestamp order
templates/          Migration template (`-- Up Migration` / `-- Down Migration`)
docs/internal-db/   plan / status / schema / ai-ingestion / final-report
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

## Schema

See [`docs/internal-db/schema.md`](docs/internal-db/schema.md) for the full
entity model and [`docs/internal-db/ai-ingestion.md`](docs/internal-db/ai-ingestion.md)
for the contract an AI agent should follow when populating the database.

Top-level entities:

- `organizations`, `people`, `affiliations`
- `interactions`, `interaction_participants`
- `call_transcripts`, `ai_notes`, `extracted_facts`
- `tags` / `taggings`, `relationship_edges`
- `sources`, `external_identities`

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
