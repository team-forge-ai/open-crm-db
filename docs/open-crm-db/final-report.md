# open-crm-db — Final Report

Date: 2026-04-28

## Summary

`team-forge-ai/picardo-internal-db` (private) was genericized into
`team-forge-ai/open-crm-db` (private repo, MIT-licensed) without modifying
the original repo. The result is a self-contained, headless TypeScript CLI
that owns Postgres migrations for a generic CRM / internal knowledge
database, plus a self-contained agent skill bundle.

## What Was Genericized

### Branding & Identity

- Repo name: `picardo-internal-db` → `open-crm-db`.
- Package: `@team-forge-ai/picardo-internal-db` → `@team-forge-ai/open-crm-db`.
- CLI binary: `picardo-db` → `open-crm-db`.
- License: added MIT (`Copyright (c) 2026 Team Forge AI and contributors`).
- README, AGENTS.md, docs, and CLI help reframed as a generic open-source
  headless CRM / knowledge database.

### Configuration

- Env vars `PICARDO_DB_MIGRATIONS_TABLE/SCHEMA/SCHEMA_DUMP_PATH` →
  `OPEN_CRM_DB_MIGRATIONS_TABLE/SCHEMA/SCHEMA_DUMP_PATH`.
- `.env.example` rewritten with example DB name `open_crm_db_dev`.
- TypeScript config type renamed `PicardoDbConfig` → `OpenCrmDbConfig`.

### SQL & Schema

- Trigger functions renamed:
  - `picardo_set_updated_at` → `crm_set_updated_at`
  - `picardo_search_text` → `crm_search_text`
  - `picardo_check_task_project_team` → `crm_check_task_project_team`
  - `picardo_prevent_task_project_team_orphan` →
    `crm_prevent_task_project_team_orphan`
- All schema migrations and `schema.sql` snapshot updated accordingly.
- All Picardo / Linear comments and framing removed from SQL and docs. The
  task schema is presented as a generic work-item model (no "modeled on
  Linear" framing anywhere in source, schema, or docs).
- Removed seeded `linear` source row from initial-schema migration (and
  its matching down migration).

### Removed

- `src/commands/enrich.ts` — Perplexity-driven, healthcare-specific
  enrichment. Removed entirely; not appropriate for an open-source generic
  CRM.
- `src/commands/import-linear.ts` (and its tests) — Linear MCP importer
  with hard assumptions about a private Linear workspace.
- `src/__tests__/enrich.test.ts`.
- `docs/internal-db/{plan,status,final-report}.md` — original build
  artifacts for the internal Picardo project (replaced with new
  `docs/open-crm-db/{plan,status,final-report}.md`).
- `docs/prod-mlx-embeddings-backfill/` — Picardo-specific operational doc.
- `reflect-link-notes-last-six-months.md` — 295KB of private notes that
  must not ship publicly.
- AI SDK / Perplexity / Zod runtime deps that only the `enrich` command
  required.
- `enrich:crm` and `import:linear` package scripts.

### Skills Folder

- Renamed `skills/picardo-internal-db/` → `skills/open-crm-db/` (via
  `git mv`).
- Skill frontmatter `name: open-crm-db`, generic description.
- `scripts/psql.sh` env var override renamed `PICARDO_DB_CREDENTIALS` →
  `OPEN_CRM_DB_CREDENTIALS`.
- `references/credentials.env.example` rewritten without
  Neon-specific URL.
- `references/{schema.md, ai-ingestion.md, schema.sql}` re-synced from the
  canonical (now-genericized) repo copies.
- `references/sync-workflows.md` title genericized.
- `agents/openai.yaml` rebranded.

### Other

- `scripts/export-graph.mjs` paths and HTML/GraphML titles rebranded
  (`skills/picardo-internal-db` → `skills/open-crm-db`,
  `Picardo CRM Graph` → `open-crm-db Graph`,
  graph id `picardo-crm` → `open-crm-db`).

## License Status

MIT license file present at `LICENSE`. `package.json` declares
`"license": "MIT"`. `package.json` is still `"private": true` to prevent
accidental npm publish from the existing private repo; flip if/when the
project goes public on npm.

## Verification Results

All commands run from a clean `pnpm install` against pnpm 10.30.3 / Node 20:

| Step | Result |
| --- | --- |
| `pnpm install` | clean install, no script execution |
| `pnpm typecheck` (`tsc -p tsconfig.json --noEmit`) | passed |
| `pnpm lint` (`eslint .`) | passed |
| `pnpm test` (`vitest run`) | 22/22 tests passing across 4 files |
| `pnpm build` (`tsc -p tsconfig.build.json`) | passed |
| `node dist/cli.js --help` | shows `open-crm-db` branding, three commands: `migrate`, `embeddings`, `info` |
| `node dist/cli.js info` | renders the new generic guidance text |

## Grep Audit

After genericization, against all tracked files:

- `Picardo|picardo|PICARDO` → 0 hits outside `docs/open-crm-db/` (those
  references are intentional in the planning artifacts that *describe* the
  genericization).
- `Linear|LINEAR|linear` (word boundary) → 0 hits outside
  `docs/open-crm-db/`.
- No private domains, credentials, or transcript content present. The
  `references/credentials.env` file is gitignored and was not committed.

## Caveats / Follow-ups

- The MLX EmbeddingGemma backfill path still assumes a local Apple
  Silicon environment with the model downloaded; this matches the original
  design and is documented in `README.md` and `src/commands/embeddings.ts`.
- `package.json` is `"private": true`. To publish to npm, flip that flag
  and add an `.npmignore` (or `files` entry) so internal docs are not
  shipped.
- The Linear-specific importer was deliberately removed rather than
  genericized. If the project later wants importers for external work-item
  systems (Linear, Jira, GitHub Issues, Asana), they should be added under
  a clean `src/commands/import-<source>.ts` module that does not steer
  users to any one vendor.
- `docs/open-crm-db/plan.md` and `status.md` retain references to
  "Picardo" and "Linear" because they document *what was removed*; they
  are useful audit context for reviewers and maintainers, and live under
  `docs/open-crm-db/` so they do not clutter top-level docs.

## Repository

- GitHub: `git@github.com:team-forge-ai/open-crm-db.git`
- Branch: `main`
- Visibility: private
- See `git log -1` for the genericization commit SHA.
