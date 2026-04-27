# Agent Notes

Before doing any work in this repository, read `README.md` first. It explains
the project scope, commands, schema docs, and local AI skill.

This repo owns Picardo's internal Postgres database schema and migration CLI.
It is intentionally narrow: SQL migrations, a small TypeScript command-line
tool, and documentation for agents that populate the headless CRM safely.

Keep these points in mind:

- Use `pnpm` for project commands.
- Keep migrations as SQL files in `migrations/`; do not add JS or TS migrations.
- Follow the existing migration template with `-- Up Migration` and
  `-- Down Migration` sections.
- Do not commit live database credentials. Local credential examples live under
  `skills/picardo-internal-db/references/`.
- For database ingestion or CRM sync work, read the local skill and schema docs
  referenced from `README.md` before touching data.
