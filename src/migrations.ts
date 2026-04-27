import fs from 'node:fs/promises'
import path from 'node:path'
import { Client } from 'pg'

const MIGRATION_FILE_RE = /^(\d+)_([a-z0-9-]+)\.sql$/

/**
 * Convert an arbitrary human-friendly name into the slug format
 * node-pg-migrate expects: lowercase, hyphenated, alphanumeric.
 */
export function slugifyMigrationName(name: string): string {
  const slug = name
    .trim()
    .toLowerCase()
    .replace(/['"`]/g, '')
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')

  if (!slug) {
    throw new Error(
      `Migration name "${name}" produced an empty slug after normalization.`,
    )
  }
  return slug
}

/**
 * Build the canonical migration filename used by this project.
 * Format: <unix_ms>_<slug>.sql — matches node-pg-migrate's SQL convention.
 */
export function buildMigrationFilename(
  name: string,
  now: Date = new Date(),
): string {
  const slug = slugifyMigrationName(name)
  return `${now.getTime()}_${slug}.sql`
}

export interface MigrationFile {
  filename: string
  timestamp: number
  slug: string
  /** node-pg-migrate stores this in the pgmigrations.name column. */
  name: string
}

/**
 * Parse a migration filename into its parts. Returns null for files that do
 * not match the expected pattern (so callers can ignore READMEs etc.).
 */
export function parseMigrationFilename(filename: string): MigrationFile | null {
  const match = MIGRATION_FILE_RE.exec(filename)
  if (!match) {
    return null
  }
  const ts = match[1]!
  const slug = match[2]!
  return {
    filename,
    timestamp: Number(ts),
    slug,
    // node-pg-migrate strips the .sql extension and uses "<ts>_<slug>".
    name: `${ts}_${slug}`,
  }
}

/**
 * List migration files on disk, sorted by timestamp ascending.
 */
export async function listMigrationFiles(
  migrationsDir: string,
): Promise<MigrationFile[]> {
  let entries: string[]
  try {
    entries = await fs.readdir(migrationsDir)
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code === 'ENOENT') {
      return []
    }
    throw err
  }

  return entries
    .map(parseMigrationFilename)
    .filter((m): m is MigrationFile => m !== null)
    .sort((a, b) => a.timestamp - b.timestamp)
}

export interface AppliedMigration {
  name: string
  runOn: Date | null
}

/**
 * Read the pgmigrations table to discover which migrations are already
 * applied. Returns an empty list if the table does not exist yet.
 */
export async function fetchAppliedMigrations(params: {
  databaseUrl: string
  migrationsTable: string
  migrationsSchema: string
}): Promise<AppliedMigration[]> {
  const client = new Client({ connectionString: params.databaseUrl })
  await client.connect()
  try {
    const exists = await client.query<{ exists: boolean }>(
      `SELECT EXISTS (
         SELECT 1 FROM information_schema.tables
         WHERE table_schema = $1 AND table_name = $2
       ) AS exists`,
      [params.migrationsSchema, params.migrationsTable],
    )
    if (!exists.rows[0]?.exists) {
      return []
    }
    const result = await client.query<{ name: string; run_on: Date | null }>(
      `SELECT name, run_on
         FROM "${params.migrationsSchema}"."${params.migrationsTable}"
        ORDER BY id ASC`,
    )
    return result.rows.map((row) => ({ name: row.name, runOn: row.run_on }))
  } finally {
    await client.end()
  }
}

export interface MigrationStatus {
  applied: Array<{ name: string; runOn: Date | null }>
  pending: MigrationFile[]
  /** Migrations recorded in DB but missing on disk — usually a sign of branch confusion. */
  orphaned: AppliedMigration[]
}

/**
 * Diff disk migrations against applied migrations. Pure function for tests.
 */
export function diffMigrations(
  files: MigrationFile[],
  applied: AppliedMigration[],
): MigrationStatus {
  const appliedNames = new Set(applied.map((a) => a.name))
  const fileNames = new Set(files.map((f) => f.name))

  const pending = files.filter((f) => !appliedNames.has(f.name))
  const orphaned = applied.filter((a) => !fileNames.has(a.name))

  return {
    applied: applied.filter((a) => fileNames.has(a.name)),
    pending,
    orphaned,
  }
}

/**
 * Read the SQL migration template, fall back to a sane default if missing.
 */
export async function readMigrationTemplate(
  templatePath: string,
): Promise<string> {
  try {
    return await fs.readFile(templatePath, 'utf8')
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code === 'ENOENT') {
      return '-- Up Migration\n\n-- Down Migration\n\n'
    }
    throw err
  }
}

/**
 * Create a new SQL migration file, returning the absolute path written.
 */
export async function createMigration(params: {
  migrationsDir: string
  templatePath: string
  name: string
  now?: Date
}): Promise<string> {
  await fs.mkdir(params.migrationsDir, { recursive: true })
  const filename = buildMigrationFilename(params.name, params.now)
  const target = path.join(params.migrationsDir, filename)
  const template = await readMigrationTemplate(params.templatePath)
  // wx flag: fail if file already exists. Cheap collision guard.
  await fs.writeFile(target, template, { flag: 'wx' })
  return target
}
