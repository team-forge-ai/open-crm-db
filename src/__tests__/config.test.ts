import path from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { findRepoRoot, loadConfig, loadPaths } from '../config.js'

const ORIGINAL_ENV = { ...process.env }

beforeEach(() => {
  // Start from a known-empty env for the keys we care about.
  delete process.env.DATABASE_URL
  delete process.env.OPEN_CRM_DB_MIGRATIONS_TABLE
  delete process.env.OPEN_CRM_DB_MIGRATIONS_SCHEMA
  delete process.env.OPEN_CRM_DB_SCHEMA_DUMP_PATH
})

afterEach(() => {
  process.env = { ...ORIGINAL_ENV }
})

describe('loadConfig', () => {
  it('throws a helpful error when DATABASE_URL is missing', () => {
    expect(() => loadConfig({ skipDotenv: true })).toThrow(/DATABASE_URL/)
  })

  it('returns resolved paths and defaults when DATABASE_URL is present', () => {
    const config = loadConfig({
      skipDotenv: true,
      databaseUrl: 'postgres://example/db',
      repoRoot: '/tmp/open-crm-db-fake',
    })
    expect(config.databaseUrl).toBe('postgres://example/db')
    expect(config.migrationsDir).toBe('/tmp/open-crm-db-fake/migrations')
    expect(config.migrationTemplate).toBe(
      '/tmp/open-crm-db-fake/templates/migration.sql',
    )
    expect(config.migrationsTable).toBe('pgmigrations')
    expect(config.migrationsSchema).toBe('public')
    expect(config.schemaDumpPath).toBe('/tmp/open-crm-db-fake/schema.sql')
  })

  it('honors custom migrations table/schema env vars', () => {
    process.env.OPEN_CRM_DB_MIGRATIONS_TABLE = 'crm_migrations'
    process.env.OPEN_CRM_DB_MIGRATIONS_SCHEMA = 'meta'
    process.env.OPEN_CRM_DB_SCHEMA_DUMP_PATH = 'tmp/schema.sql'
    const config = loadConfig({
      skipDotenv: true,
      databaseUrl: 'postgres://example/db',
      repoRoot: '/tmp/open-crm-db-fake',
    })
    expect(config.migrationsTable).toBe('crm_migrations')
    expect(config.migrationsSchema).toBe('meta')
    expect(config.schemaDumpPath).toBe('/tmp/open-crm-db-fake/tmp/schema.sql')
  })
})

describe('loadPaths', () => {
  it('does not require DATABASE_URL', () => {
    const paths = loadPaths({
      skipDotenv: true,
      repoRoot: '/tmp/open-crm-db-fake',
    })
    expect(paths.migrationsDir).toBe('/tmp/open-crm-db-fake/migrations')
    expect(paths.migrationTemplate).toBe(
      '/tmp/open-crm-db-fake/templates/migration.sql',
    )
    expect(paths.schemaDumpPath).toBe('/tmp/open-crm-db-fake/schema.sql')
  })
})

describe('findRepoRoot', () => {
  it('resolves a directory that contains package.json', () => {
    const root = findRepoRoot()
    // We can't assert exact path (depends on test runner cwd), but we can
    // assert it is an absolute path that ends with the repo name.
    expect(path.isAbsolute(root)).toBe(true)
    expect(root.endsWith('open-crm-db')).toBe(true)
  })
})
