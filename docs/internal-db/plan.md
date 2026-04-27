# Picardo Internal DB — Plan

## Objective

Build a small, headless, migration-first TypeScript CLI for Picardo's internal
Postgres database. The database is a headless CRM that stores every interaction
the company has with any other organization or person — including raw call
transcripts and AI-derived notes.

The CLI is intentionally minimal: it manages SQL migrations, prints connection
and schema guidance, and exposes simple ergonomics that an AI agent (or human
operator) can drive safely.

## Shape

- TypeScript, ESM, pnpm, Node 20+
- Commander-based CLI, single binary `picardo-db`
- `node-pg-migrate` for migration runtime; migrations themselves are **SQL only**
- Vitest for tests, ESLint + Prettier for hygiene
- `tsc` build to `dist/`; `bin` field points at the compiled entry

## CLI surface (v0.1)

```
picardo-db --help
picardo-db migrate up           # apply all pending migrations
picardo-db migrate down         # revert the most recent migration
picardo-db migrate status       # list applied vs pending migrations
picardo-db migrate create <name># scaffold a new SQL migration file
picardo-db info                 # print connection + schema guidance
```

All commands read `DATABASE_URL` from the environment (with optional `.env`
loading). Nothing in the repo references real secrets; `.env.example` documents
the expected variables.

## Schema (initial migration)

The first migration creates the headless-CRM core. All tables get
`uuid` primary keys, `created_at`/`updated_at` with a shared trigger, and
`archived_at` where soft delete makes sense.

Entities:

- **organizations** — companies / institutions / counterparties
- **people** — individuals
- **affiliations** — person ↔ organization over time, with role and dates
- **person_emails / person_phones** — contact handles, one row per handle
- **external_identities** — provenance: external IDs from Gmail, Google
  Contacts, LinkedIn, HubSpot, etc., scoped to entity type
- **interactions** — calls, meetings, emails, messages, notes (typed enum)
- **interaction_participants** — links interactions to people and/or orgs
- **call_transcripts** — raw transcript text + source metadata, 1:1 with the
  underlying interaction (when type = call/meeting)
- **ai_notes** — AI summaries / action items / coaching notes attached to an
  interaction or to an entity
- **extracted_facts** — structured facts ("works at", "title", "lives in")
  extracted by AI, with subject reference, confidence, and source
- **tags / taggings** — flexible polymorphic tagging
- **relationship_edges** — flexible typed graph edges between two entities
  (e.g. person→person introduction, org→org parent/subsidiary)

Constraints, indexes, and foreign keys are added inline. The schema is
normalized but not over-engineered — no premature partitioning, no JSONB-only
"god tables", no event sourcing.

## AI ingestion contract

`docs/internal-db/ai-ingestion.md` is the spec an AI agent reads in order to
populate the database. It covers:

- the purpose of each table
- which fields are authoritative vs derived
- idempotency keys (external_identities, transcript source IDs)
- upsert guidance and dedupe rules
- how to file a raw transcript and the AI notes that derive from it
- what counts as PII and how to handle it conservatively

## Acceptance criteria

- `pnpm install` succeeds.
- `pnpm typecheck`, `pnpm lint`, `pnpm test`, `pnpm build` all pass.
- `pnpm picardo-db --help` prints the command tree.
- `pnpm picardo-db info` prints schema + connection guidance with no DB.
- `pnpm picardo-db migrate status` reports correctly against a real DB.
- `pnpm picardo-db migrate up` applies the initial migration cleanly against an
  empty Postgres database, and `migrate down` reverts it.
- Initial schema covers organizations, people, affiliations, interactions,
  transcripts, AI notes, extracted facts, tags, relationship edges.
- Docs under `docs/internal-db/` exist and tell a coherent story.
- Repo pushed to `team-forge-ai/picardo-internal-db` (private).

## Risks / caveats

- node-pg-migrate's CLI ergonomics differ slightly from its programmatic API;
  the `migrate create` path must produce filenames that node-pg-migrate will
  pick up (`<unix_ms>_<slug>.sql`) and use the project's template header
  comments (`-- Up Migration` / `-- Down Migration`).
- "Status" is not a first-class node-pg-migrate command, so we implement it by
  reading the migrations directory and querying `public.pgmigrations`.
- Postgres availability cannot be assumed in CI; tests that need a live DB are
  gated behind `PICARDO_DB_TEST_URL`.

## Verification

Run from repo root with a disposable local DB:

```sh
createdb picardo_internal_db_dev
DATABASE_URL=postgres://localhost/picardo_internal_db_dev pnpm picardo-db migrate up
DATABASE_URL=postgres://localhost/picardo_internal_db_dev pnpm picardo-db migrate status
DATABASE_URL=postgres://localhost/picardo_internal_db_dev pnpm picardo-db migrate down
dropdb picardo_internal_db_dev
```
