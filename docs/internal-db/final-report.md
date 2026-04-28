# Picardo Internal DB - Final Report

## What shipped

A small, headless TypeScript CLI named `picardo-db` that owns the schema and
SQL migrations for Picardo's internal headless-CRM Postgres database.

The deliverable matches the brief:

- **Headless, migration-first.** No web infrastructure, no API server, no
  application code beyond the CLI.
- **SQL-only migrations.** Files live under `migrations/` and follow the
  `<unix_ms>_<kebab-name>.sql` convention. Each file uses `-- Up Migration`
  and `-- Down Migration` headers, applied via
  [`node-pg-migrate`](https://www.npmjs.com/package/node-pg-migrate).
- **Current schema snapshot.** Organizations, people, affiliations, contact
  handles, interactions, participants, documents, partnerships, tasks, raw call
  transcripts, AI notes, extracted facts, semantic embeddings, search helpers,
  tags, relationship edges, plus a `sources` provenance table seeded with the
  canonical slugs.
- **AI ingestion contract.** `docs/internal-db/ai-ingestion.md` describes how
  an AI agent should populate the database: identity & dedupe, idempotency
  keys, transcript handling, AI-notes vs extracted-facts, and privacy.

## Repo layout

```
src/
  cli.ts                 commander entrypoint, exposes buildProgram()
  config.ts              env / path resolution (DATABASE_URL, paths)
  migrations.ts          slugify + parse + list + diff + create helpers
  runner.ts              thin wrapper over node-pg-migrate
  commands/              one file per CLI command
  __tests__/             vitest unit tests
migrations/              timestamped SQL migrations
templates/
  migration.sql
docs/internal-db/
  plan.md  status.md  schema.md  ai-ingestion.md  final-report.md
skills/
  picardo-internal-db/   self-contained DB operations skill
```

## CLI surface

```
picardo-db --help
picardo-db info                       # connection + schema guidance
picardo-db migrate up [-n N]          # apply pending migrations
picardo-db migrate down [-n N]        # revert most recent (or N)
picardo-db migrate status             # applied vs pending vs orphaned
picardo-db migrate create <name>      # scaffold new SQL migration
```

`pnpm picardo-db <args>` runs from source via `tsx`; the built binary
(`dist/cli.js`) is exposed via the `bin` field.

## Verification

Run from the repo on a clean checkout:

```sh
pnpm install            # 200 packages, no warnings beyond an upstream
                        # `glob@11.0.3` deprecation noted by pnpm
pnpm typecheck          # PASS
pnpm lint               # PASS (eslint + typescript-eslint + prettier-config)
pnpm test               # PASS — 5 files, 27 tests
pnpm build              # PASS — emits dist/
node dist/cli.js --help # prints usage
node dist/cli.js info   # prints schema + connection guidance
```

End-to-end against a disposable Postgres database (`createdb` / `dropdb`):

```sh
createdb picardo_internal_db_verify
DATABASE_URL=postgres://localhost/picardo_internal_db_verify \
  node dist/cli.js migrate status   # pending migrations
DATABASE_URL=postgres://localhost/picardo_internal_db_verify \
  node dist/cli.js migrate up       # applies the current schema
psql -d picardo_internal_db_verify -c "\dt"
# Current CRM, partnership, search, embedding, and task tables plus
# pgmigrations.
psql -d picardo_internal_db_verify -c "SELECT slug FROM sources ORDER BY slug;"
# ai_extraction, gmail, google_calendar, google_meet, linear, manual, zoom
DATABASE_URL=postgres://localhost/picardo_internal_db_verify \
  node dist/cli.js migrate down     # cleanly reverts the most recent migration
DATABASE_URL=postgres://localhost/picardo_internal_db_verify \
  node dist/cli.js migrate create "Add example feature"
# -> migrations/<ts>_add-example-feature.sql
dropdb picardo_internal_db_verify
```

All of the above ran successfully on the build host (Postgres 16.13, Node
24.14, pnpm 10.30.3).

## Decisions worth flagging

- **`node-pg-migrate`** chosen for migration runtime. It is mature, supports
  raw SQL files natively, has a small surface, and is already used in the
  sibling `team-forge-ai/picardo` repo. We use its programmatic `runner` API
  for `up`/`down` and implement `status` ourselves (it is not a first-class
  command in the library).
- **`commander`** for argument parsing — small, well-known, no learning curve.
- **`citext`** extension is enabled for case-insensitive email/domain matching.
- **Polymorphic anchors** (`subject_type`/`subject_id`, `target_type`/
  `target_id`) are guarded by CHECK constraints so that exactly one anchor
  type is set per row. Foreign-key polymorphism is intentionally avoided.
- **Append-only `extracted_facts`.** "Updates" are inserts with newer
  `observed_at`. Readers pick the latest. This avoids destroying history when
  an AI revises a previous extraction.
- **`call_transcripts.raw_text` is inline** (Postgres TOASTs it). No blob
  store dependency. Structured speaker turns live in `segments jsonb`.
- **`pgmigrations` tracking table** lives in `public` by default; both the
  table and schema are overridable via env (`PICARDO_DB_MIGRATIONS_TABLE`,
  `PICARDO_DB_MIGRATIONS_SCHEMA`).

## Open / deferred

- No CI workflow yet (e.g. GitHub Actions). Easy to add when the team is
  ready: a single job that runs `pnpm install --frozen-lockfile`,
  `pnpm typecheck`, `pnpm lint`, `pnpm test`, `pnpm build`. Tests that need
  a real DB are gated behind `PICARDO_DB_TEST_URL` (currently none — the
  initial migration is exercised manually via the steps above).
- No seed-data fixtures beyond lookup rows such as `sources`. AI ingestion and
  source imports are the intended population path, not seed scripts.
- No Kysely / type-generated DB types. Out of scope for a migration-only
  CLI; downstream consumers can run `kysely-codegen` against the migrated
  schema if/when they want typed clients.

## Repo state

- Branch: `main`
- GitHub remote: `team-forge-ai/picardo-internal-db` (private).
