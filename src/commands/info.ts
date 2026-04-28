import path from 'node:path'
import { loadPaths } from '../config.js'

const HELP_TEXT = `open-crm-db
===========

Purpose
-------
A small, headless TypeScript CLI that owns Postgres migrations for an open
internal CRM / knowledge database. The schema records organizations, people,
interactions (calls, meetings, emails, messages, notes), call transcripts,
AI-derived notes and extracted facts, documents, tags, partnerships, tasks,
semantic embeddings, and provenance metadata.

Connection
----------
Set DATABASE_URL in the environment (or in a local .env file). Format:

    postgres://user:password@host:port/database

For local development:

    createdb open_crm_db_dev
    export DATABASE_URL=postgres://localhost/open_crm_db_dev

Operational commands
--------------------
    open-crm-db migrate up           Apply all pending migrations.
    open-crm-db migrate down         Revert the most recent migration.
    open-crm-db migrate status       Show applied vs pending migrations.
    open-crm-db migrate create NAME  Scaffold a new SQL migration.
    open-crm-db info                 Print this guidance.

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
- external_identities         provenance / external IDs
- interactions                calls, meetings, emails, messages, notes
- interaction_participants    interactions <-> people / orgs
- call_transcripts            raw transcript + source metadata
- ai_notes                    AI summaries / action items
- extracted_facts             structured facts with confidence + source
- tags / taggings             flexible polymorphic tagging
- relationship_edges          flexible typed graph edges between entities

For a deeper schema reference and AI ingestion contract, see
docs/schema.md and docs/ai-ingestion.md in this repo.
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
