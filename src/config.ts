import path from 'node:path'
import { fileURLToPath } from 'node:url'
import dotenv from 'dotenv'

/**
 * Resolved configuration for the open-crm-db CLI.
 * All operational values are derived from environment variables.
 */
export interface OpenCrmDbConfig {
  /** Postgres connection string. */
  databaseUrl: string
  /** Absolute path to the SQL migrations directory. */
  migrationsDir: string
  /** Absolute path to the migration template. */
  migrationTemplate: string
  /** Migrations tracking table name. Default: pgmigrations. */
  migrationsTable: string
  /** Migrations tracking table schema. Default: public. */
  migrationsSchema: string
  /** Local path where the current schema-only dump is written after migrations. */
  schemaDumpPath: string
}

export interface ConfigOptions {
  /** Override DATABASE_URL lookup (mostly for tests). */
  databaseUrl?: string
  /** Override repo root (mostly for tests). */
  repoRoot?: string
  /** Skip loading a `.env` file. */
  skipDotenv?: boolean
}

/**
 * Repo root resolved from this file's location. Layout assumption:
 *   <root>/dist/config.js          (built)
 *   <root>/src/config.ts           (source)
 */
export function findRepoRoot(): string {
  const here = path.dirname(fileURLToPath(import.meta.url))
  // src/ or dist/ — both sit one level under the repo root.
  return path.resolve(here, '..')
}

/**
 * Load and validate config. Throws if DATABASE_URL is required but missing.
 */
export function loadConfig(options: ConfigOptions = {}): OpenCrmDbConfig {
  if (!options.skipDotenv) {
    dotenv.config()
  }

  const repoRoot = options.repoRoot ?? findRepoRoot()
  const databaseUrl = options.databaseUrl ?? process.env.DATABASE_URL

  if (!databaseUrl) {
    throw new Error(
      'DATABASE_URL is not set. Copy .env.example to .env and set ' +
        'DATABASE_URL to your Postgres connection string.',
    )
  }

  return {
    databaseUrl,
    migrationsDir: path.join(repoRoot, 'migrations'),
    migrationTemplate: path.join(repoRoot, 'templates', 'migration.sql'),
    migrationsTable: process.env.OPEN_CRM_DB_MIGRATIONS_TABLE || 'pgmigrations',
    migrationsSchema: process.env.OPEN_CRM_DB_MIGRATIONS_SCHEMA || 'public',
    schemaDumpPath: resolveSchemaDumpPath(repoRoot),
  }
}

/**
 * Resolve only the file-system paths (no DATABASE_URL required).
 * Useful for `info` and `migrate create` which do not need a live DB.
 */
export function loadPaths(
  options: Pick<ConfigOptions, 'repoRoot' | 'skipDotenv'> = {},
): Pick<
  OpenCrmDbConfig,
  | 'migrationsDir'
  | 'migrationTemplate'
  | 'migrationsTable'
  | 'migrationsSchema'
  | 'schemaDumpPath'
> {
  if (!options.skipDotenv) {
    dotenv.config()
  }
  const repoRoot = options.repoRoot ?? findRepoRoot()
  return {
    migrationsDir: path.join(repoRoot, 'migrations'),
    migrationTemplate: path.join(repoRoot, 'templates', 'migration.sql'),
    migrationsTable: process.env.OPEN_CRM_DB_MIGRATIONS_TABLE || 'pgmigrations',
    migrationsSchema: process.env.OPEN_CRM_DB_MIGRATIONS_SCHEMA || 'public',
    schemaDumpPath: resolveSchemaDumpPath(repoRoot),
  }
}

function resolveSchemaDumpPath(repoRoot: string): string {
  const configured = process.env.OPEN_CRM_DB_SCHEMA_DUMP_PATH
  if (!configured) {
    return path.join(repoRoot, 'schema.sql')
  }
  return path.isAbsolute(configured)
    ? configured
    : path.join(repoRoot, configured)
}
