import path from 'node:path'
import { loadPaths } from '../config.js'

const HELP_TEXT = `Picardo Internal DB
===================

Purpose
-------
A small, headless TypeScript CLI that owns Postgres migrations for Picardo's
internal headless CRM. The database stores every interaction the company has
with another company or person — including raw call transcripts and AI notes.

Connection
----------
Set DATABASE_URL in the environment (or in a local .env file). Format:

    postgres://user:password@host:port/database

For local development:

    createdb picardo_internal_db_dev
    export DATABASE_URL=postgres://localhost/picardo_internal_db_dev

Operational commands
--------------------
    picardo-db migrate up           Apply all pending migrations.
    picardo-db migrate down         Revert the most recent migration.
    picardo-db migrate status       Show applied vs pending migrations.
    picardo-db migrate create NAME  Scaffold a new SQL migration.
    picardo-db info                 Print this guidance.

Migration conventions
---------------------
- All migrations are SQL only. Filename: <unix_ms>_<kebab-name>.sql
- Each migration has a "-- Up Migration" section and a "-- Down Migration"
  section. node-pg-migrate splits on those headers.
- Migrations are applied in timestamp order. Tracking table: pgmigrations.

Schema overview
---------------
- organizations               companies / counterparties
- people                      individuals
- person_emails / phones      contact handles
- affiliations                person <-> org over time, with role
- external_identities         provenance / external IDs (Gmail, HubSpot, ...)
- interactions                calls, meetings, emails, messages, notes
- interaction_participants    interactions <-> people / orgs
- call_transcripts            raw transcript + source metadata
- ai_notes                    AI summaries / action items / coaching notes
- extracted_facts             structured facts with confidence + source
- tags / taggings             flexible polymorphic tagging
- relationship_edges          flexible typed graph edges between entities

For a deeper schema reference and AI ingestion contract, see
docs/internal-db/schema.md and docs/internal-db/ai-ingestion.md in this repo.
`

export function info(): void {
  const paths = loadPaths()
  console.log(HELP_TEXT)
  console.log(`Migrations directory : ${paths.migrationsDir}`)
  console.log(`Migration template   : ${paths.migrationTemplate}`)
  console.log(
    `Tracking table       : ${paths.migrationsSchema}.${paths.migrationsTable}`,
  )
  console.log(`Working directory    : ${process.cwd()}`)
  console.log(
    `DATABASE_URL set?    : ${process.env.DATABASE_URL ? 'yes' : 'no'}`,
  )
  // Use path.basename so the absolute path doesn't dominate help output on
  // narrow terminals.
  console.log(`Repo basename        : ${path.basename(path.dirname(paths.migrationsDir))}`)
}
